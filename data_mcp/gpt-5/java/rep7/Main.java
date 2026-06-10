import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import com.google.gson.*;
import com.google.gson.annotations.SerializedName;

import java.io.*;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public class Main {
    private static final int DEFAULT_PORT = 8080;

    public static void main(String[] args) throws Exception {
        int port = DEFAULT_PORT;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                try {
                    port = Integer.parseInt(args[i + 1]);
                    i++;
                } catch (NumberFormatException e) {
                    System.err.println("Invalid port number");
                    System.exit(1);
                }
            }
        }

        InMemoryStore store = new InMemoryStore();
        Server server = new Server(port, store);
        server.start();
    }
}

class Server {
    private final int port;
    private final InMemoryStore store;
    private HttpServer httpServer;

    private static final Gson gson = new GsonBuilder().serializeNulls().create();

    public Server(int port, InMemoryStore store) {
        this.port = port;
        this.store = store;
    }

    public void start() throws IOException {
        httpServer = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        httpServer.createContext("/", new RootHandler(store));
        httpServer.setExecutor(Executors.newCachedThreadPool());
        httpServer.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }

    static class RootHandler implements HttpHandler {
        private final InMemoryStore store;
        private final DateTimeFormatter isoFormatter = DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC);

        RootHandler(InMemoryStore store) {
            this.store = store;
        }

        @Override
        public void handle(HttpExchange exchange) throws IOException {
            try {
                String method = exchange.getRequestMethod();
                URI uri = exchange.getRequestURI();
                String path = uri.getPath();

                if (path.equals("/register") && method.equals("POST")) {
                    handleRegister(exchange);
                    return;
                }
                if (path.equals("/login") && method.equals("POST")) {
                    handleLogin(exchange);
                    return;
                }
                if (path.equals("/logout") && method.equals("POST")) {
                    User user = authenticate(exchange);
                    if (user == null) return; // authenticate already sent 401
                    handleLogout(exchange);
                    return;
                }
                if (path.equals("/me") && method.equals("GET")) {
                    User user = authenticate(exchange);
                    if (user == null) return;
                    handleMe(exchange, user);
                    return;
                }
                if (path.equals("/password") && method.equals("PUT")) {
                    User user = authenticate(exchange);
                    if (user == null) return;
                    handlePasswordChange(exchange, user);
                    return;
                }
                if (path.equals("/todos")) {
                    User user = authenticate(exchange);
                    if (user == null) return;
                    if (method.equals("GET")) {
                        handleTodosList(exchange, user);
                        return;
                    } else if (method.equals("POST")) {
                        handleTodosCreate(exchange, user);
                        return;
                    }
                }
                if (path.startsWith("/todos/") && path.length() > "/todos/".length()) {
                    User user = authenticate(exchange);
                    if (user == null) return;
                    String idStr = path.substring("/todos/".length());
                    Integer id = parseId(idStr);
                    if (id == null) {
                        sendJson(exchange, 404, error("Todo not found"));
                        return;
                    }
                    if (method.equals("GET")) {
                        handleTodoGet(exchange, user, id);
                        return;
                    } else if (method.equals("PUT")) {
                        handleTodoUpdate(exchange, user, id);
                        return;
                    } else if (method.equals("DELETE")) {
                        handleTodoDelete(exchange, user, id);
                        return;
                    }
                }

                // Not found or method not allowed
                sendJson(exchange, 404, error("Not found"));
            } catch (Exception e) {
                e.printStackTrace();
                try {
                    sendJson(exchange, 500, error("Internal server error"));
                } catch (Exception ignore) {}
            } finally {
                try { exchange.close(); } catch (Exception ignore) {}
            }
        }

        private void handleRegister(HttpExchange exchange) throws IOException {
            String body = readBody(exchange);
            if (body == null) body = "";
            JsonObject obj;
            try {
                obj = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                sendJson(exchange, 400, error("Invalid JSON"));
                return;
            }
            String username = getAsString(obj, "username");
            String password = getAsString(obj, "password");

            if (username == null || !username.matches("^[A-Za-z0-9_]{3,50}$")) {
                sendJson(exchange, 400, error("Invalid username"));
                return;
            }
            if (password == null || password.length() < 8) {
                sendJson(exchange, 400, error("Password too short"));
                return;
            }
            synchronized (store) {
                if (store.usernameToUser.containsKey(username)) {
                    sendJson(exchange, 409, error("Username already exists"));
                    return;
                }
                User user = store.createUser(username, password);
                JsonObject resp = new JsonObject();
                resp.addProperty("id", user.id);
                resp.addProperty("username", user.username);
                sendJson(exchange, 201, resp);
            }
        }

        private void handleLogin(HttpExchange exchange) throws IOException {
            String body = readBody(exchange);
            if (body == null) body = "";
            JsonObject obj;
            try {
                obj = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                sendJson(exchange, 400, error("Invalid JSON"));
                return;
            }
            String username = getAsString(obj, "username");
            String password = getAsString(obj, "password");

            if (username == null || password == null) {
                sendJson(exchange, 401, error("Invalid credentials"));
                return;
            }
            User user = store.usernameToUser.get(username);
            if (user == null || !user.password.equals(password)) {
                sendJson(exchange, 401, error("Invalid credentials"));
                return;
            }
            String token = UUID.randomUUID().toString().replaceAll("-", "");
            store.sessions.put(token, user.id);
            exchange.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            JsonObject resp = new JsonObject();
            resp.addProperty("id", user.id);
            resp.addProperty("username", user.username);
            sendJson(exchange, 200, resp);
        }

        private void handleLogout(HttpExchange exchange) throws IOException {
            String token = getSessionToken(exchange);
            if (token != null) {
                store.sessions.remove(token);
            }
            JsonObject resp = new JsonObject();
            sendJson(exchange, 200, resp);
        }

        private void handleMe(HttpExchange exchange, User user) throws IOException {
            JsonObject resp = new JsonObject();
            resp.addProperty("id", user.id);
            resp.addProperty("username", user.username);
            sendJson(exchange, 200, resp);
        }

        private void handlePasswordChange(HttpExchange exchange, User user) throws IOException {
            String body = readBody(exchange);
            if (body == null) body = "";
            JsonObject obj;
            try {
                obj = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                sendJson(exchange, 400, error("Invalid JSON"));
                return;
            }
            String oldPassword = getAsString(obj, "old_password");
            String newPassword = getAsString(obj, "new_password");

            if (oldPassword == null || !user.password.equals(oldPassword)) {
                sendJson(exchange, 401, error("Invalid credentials"));
                return;
            }
            if (newPassword == null || newPassword.length() < 8) {
                sendJson(exchange, 400, error("Password too short"));
                return;
            }
            user.password = newPassword;
            JsonObject resp = new JsonObject();
            sendJson(exchange, 200, resp);
        }

        private void handleTodosList(HttpExchange exchange, User user) throws IOException {
            List<Todo> list = new ArrayList<>();
            for (Todo t : store.todos.values()) {
                if (t.userId == user.id) list.add(t);
            }
            list.sort(Comparator.comparingInt(a -> a.id));
            JsonArray arr = new JsonArray();
            for (Todo t : list) {
                arr.add(todoToJson(t));
            }
            sendJson(exchange, 200, arr);
        }

        private void handleTodosCreate(HttpExchange exchange, User user) throws IOException {
            String body = readBody(exchange);
            if (body == null) body = "";
            JsonObject obj;
            try {
                obj = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                sendJson(exchange, 400, error("Invalid JSON"));
                return;
            }
            String title = getAsString(obj, "title");
            String description = getAsString(obj, "description");
            if (title == null || title.trim().isEmpty()) {
                sendJson(exchange, 400, error("Title is required"));
                return;
            }
            if (description == null) description = "";
            Instant now = Instant.now().truncatedTo(ChronoUnit.SECONDS);
            Todo todo = store.createTodo(user.id, title, description, now);
            sendJson(exchange, 201, todoToJson(todo));
        }

        private void handleTodoGet(HttpExchange exchange, User user, int id) throws IOException {
            Todo t = store.todos.get(id);
            if (t == null || t.userId != user.id) {
                sendJson(exchange, 404, error("Todo not found"));
                return;
            }
            sendJson(exchange, 200, todoToJson(t));
        }

        private void handleTodoUpdate(HttpExchange exchange, User user, int id) throws IOException {
            Todo t = store.todos.get(id);
            if (t == null || t.userId != user.id) {
                sendJson(exchange, 404, error("Todo not found"));
                return;
            }
            String body = readBody(exchange);
            if (body == null) body = "";
            JsonObject obj;
            try {
                obj = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                sendJson(exchange, 400, error("Invalid JSON"));
                return;
            }
            boolean modified = false;
            if (obj.has("title")) {
                JsonElement el = obj.get("title");
                if (el.isJsonNull()) {
                    // ignore nulls, but treat as empty? Spec does not allow null - we'll treat null as empty invalid
                    sendJson(exchange, 400, error("Title is required"));
                    return;
                }
                String title = el.getAsString();
                if (title.trim().isEmpty()) {
                    sendJson(exchange, 400, error("Title is required"));
                    return;
                }
                t.title = title;
                modified = true;
            }
            if (obj.has("description")) {
                if (obj.get("description").isJsonNull()) {
                    t.description = "";
                } else {
                    t.description = obj.get("description").getAsString();
                }
                modified = true;
            }
            if (obj.has("completed")) {
                if (obj.get("completed").isJsonNull()) {
                    // ignore null - do not modify
                } else {
                    t.completed = obj.get("completed").getAsBoolean();
                    modified = true;
                }
            }
            if (modified) {
                t.updatedAt = Instant.now().truncatedTo(ChronoUnit.SECONDS);
            }
            sendJson(exchange, 200, todoToJson(t));
        }

        private void handleTodoDelete(HttpExchange exchange, User user, int id) throws IOException {
            Todo t = store.todos.get(id);
            if (t == null || t.userId != user.id) {
                sendJson(exchange, 404, error("Todo not found"));
                return;
            }
            store.todos.remove(id);
            // 204 No Content, no body
            sendNoContent(exchange);
        }

        private User authenticate(HttpExchange exchange) throws IOException {
            String token = getSessionToken(exchange);
            if (token == null) {
                sendJson(exchange, 401, error("Authentication required"));
                return null;
            }
            Integer userId = store.sessions.get(token);
            if (userId == null) {
                sendJson(exchange, 401, error("Authentication required"));
                return null;
            }
            User user = store.users.get(userId);
            if (user == null) {
                sendJson(exchange, 401, error("Authentication required"));
                return null;
            }
            return user;
        }

        private String getSessionToken(HttpExchange exchange) {
            List<String> cookies = exchange.getRequestHeaders().get("Cookie");
            if (cookies == null) return null;
            for (String header : cookies) {
                String[] parts = header.split(";\\s*");
                for (String part : parts) {
                    int idx = part.indexOf('=');
                    if (idx > 0) {
                        String name = part.substring(0, idx).trim();
                        String value = part.substring(idx + 1).trim();
                        if (name.equals("session_id")) {
                            return value;
                        }
                    }
                }
            }
            return null;
        }

        private Integer parseId(String s) {
            try {
                return Integer.parseInt(s);
            } catch (Exception e) {
                return null;
            }
        }

        private String formatInstant(Instant inst) {
            return DateTimeFormatter.ISO_INSTANT.format(inst);
        }

        private JsonObject todoToJson(Todo t) {
            JsonObject obj = new JsonObject();
            obj.addProperty("id", t.id);
            obj.addProperty("title", t.title);
            obj.addProperty("description", t.description);
            obj.addProperty("completed", t.completed);
            obj.addProperty("created_at", formatInstant(t.createdAt));
            obj.addProperty("updated_at", formatInstant(t.updatedAt));
            return obj;
        }

        private void sendJson(HttpExchange exchange, int status, JsonElement json) throws IOException {
            byte[] bytes = json.toString().getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        private void sendNoContent(HttpExchange exchange) throws IOException {
            // No Content with no body
            exchange.sendResponseHeaders(204, -1);
        }

        private String readBody(HttpExchange exchange) throws IOException {
            try (InputStream is = exchange.getRequestBody()) {
                ByteArrayOutputStream baos = new ByteArrayOutputStream();
                byte[] buffer = new byte[4096];
                int r;
                while ((r = is.read(buffer)) != -1) {
                    baos.write(buffer, 0, r);
                }
                return baos.toString(StandardCharsets.UTF_8);
            }
        }

        private String getAsString(JsonObject obj, String member) {
            if (obj == null || !obj.has(member) || obj.get(member).isJsonNull()) return null;
            try { return obj.get(member).getAsString(); } catch (Exception e) { return null; }
        }

        private JsonObject error(String message) {
            JsonObject obj = new JsonObject();
            obj.addProperty("error", message);
            return obj;
        }
    }
}

class InMemoryStore {
    final Map<Integer, User> users = new ConcurrentHashMap<>();
    final Map<String, User> usernameToUser = new ConcurrentHashMap<>();
    final Map<String, Integer> sessions = new ConcurrentHashMap<>();
    final Map<Integer, Todo> todos = new ConcurrentHashMap<>();

    private final AtomicInteger userIdSeq = new AtomicInteger(1);
    private final AtomicInteger todoIdSeq = new AtomicInteger(1);

    synchronized User createUser(String username, String password) {
        int id = userIdSeq.getAndIncrement();
        User user = new User(id, username, password);
        users.put(id, user);
        usernameToUser.put(username, user);
        return user;
    }

    synchronized Todo createTodo(int userId, String title, String description, Instant now) {
        int id = todoIdSeq.getAndIncrement();
        Todo t = new Todo(id, userId, title, description, false, now, now);
        todos.put(id, t);
        return t;
    }
}

class User {
    final int id;
    final String username;
    String password;

    User(int id, String username, String password) {
        this.id = id;
        this.username = username;
        this.password = password;
    }
}

class Todo {
    final int id;
    final int userId;
    String title;
    String description;
    boolean completed;
    Instant createdAt;
    Instant updatedAt;

    Todo(int id, int userId, String title, String description, boolean completed, Instant createdAt, Instant updatedAt) {
        this.id = id;
        this.userId = userId;
        this.title = title;
        this.description = description;
        this.completed = completed;
        this.createdAt = createdAt;
        this.updatedAt = updatedAt;
    }
}

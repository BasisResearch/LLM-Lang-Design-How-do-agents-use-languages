import com.google.gson.*;
import com.sun.net.httpserver.*;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;

public class ServerMain {
    private static final Gson gson = new GsonBuilder().disableHtmlEscaping().create();

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
                i++;
            }
        }

        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer server = HttpServer.create(addr, 0);
        ServerState state = new ServerState();

        server.createContext("/register", new RegisterHandler(state));
        server.createContext("/login", new LoginHandler(state));
        server.createContext("/logout", new LogoutHandler(state));
        server.createContext("/me", new MeHandler(state));
        server.createContext("/password", new PasswordHandler(state));
        server.createContext("/todos", new TodosCollectionHandler(state));
        server.createContext("/todos/", new TodoItemHandler(state));

        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server listening on 0.0.0.0:" + port);
    }

    static class ServerState {
        private final Map<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId
        private final Map<Integer, User> usersById = new ConcurrentHashMap<>();
        private final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
        private final Map<Integer, List<Todo>> todosByUser = new ConcurrentHashMap<>();
        private final Map<Integer, Todo> todosById = new ConcurrentHashMap<>();
        private final AtomicInteger userIdSeq = new AtomicInteger(1);
        private final AtomicInteger todoIdSeq = new AtomicInteger(1);

        public synchronized User createUser(String username, String password) {
            int id = userIdSeq.getAndIncrement();
            User u = new User(id, username, password);
            usersById.put(id, u);
            usersByUsername.put(username, u);
            return u;
        }

        public synchronized Todo createTodo(int userId, String title, String description) {
            int id = todoIdSeq.getAndIncrement();
            String now = isoNow();
            Todo t = new Todo(id, userId, title, description == null ? "" : description, false, now, now);
            todosById.put(id, t);
            todosByUser.computeIfAbsent(userId, k -> Collections.synchronizedList(new ArrayList<>())).add(t);
            return t;
        }

        public static String isoNow() {
            return java.time.Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString();
        }
    }

    static class User {
        int id;
        String username;
        String password; // plaintext for simplicity per requirements (no hashing specified)
        User(int id, String username, String password) {
            this.id = id; this.username = username; this.password = password;
        }
        JsonObject toJson() {
            JsonObject o = new JsonObject();
            o.addProperty("id", id);
            o.addProperty("username", username);
            return o;
        }
    }

    static class Todo {
        int id;
        int userId;
        String title;
        String description;
        boolean completed;
        String created_at;
        String updated_at;
        Todo(int id, int userId, String title, String description, boolean completed, String created_at, String updated_at) {
            this.id = id; this.userId = userId; this.title = title; this.description = description; this.completed = completed; this.created_at = created_at; this.updated_at = updated_at;
        }
        JsonObject toJson() {
            JsonObject o = new JsonObject();
            o.addProperty("id", id);
            o.addProperty("title", title);
            o.addProperty("description", description);
            o.addProperty("completed", completed);
            o.addProperty("created_at", created_at);
            o.addProperty("updated_at", updated_at);
            return o;
        }
    }

    static abstract class BaseHandler implements HttpHandler {
        protected final ServerState state;
        BaseHandler(ServerState s) { this.state = s; }

        protected void sendJson(HttpExchange ex, int status, JsonElement body) throws IOException {
            byte[] bytes = gson.toJson(body).getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().set("Content-Type", "application/json");
            ex.sendResponseHeaders(status, bytes.length);
            try (OutputStream os = ex.getResponseBody()) {
                os.write(bytes);
            }
        }
        protected void sendJsonEmpty(HttpExchange ex, int status) throws IOException {
            ex.getResponseHeaders().set("Content-Type", "application/json");
            byte[] bytes = "{}".getBytes(StandardCharsets.UTF_8);
            ex.sendResponseHeaders(status, bytes.length);
            try (OutputStream os = ex.getResponseBody()) {
                os.write(bytes);
            }
        }
        protected void sendError(HttpExchange ex, int status, String message) throws IOException {
            JsonObject o = new JsonObject();
            o.addProperty("error", message);
            sendJson(ex, status, o);
        }

        protected JsonObject readJson(HttpExchange ex) throws IOException {
            try (InputStream is = ex.getRequestBody()) {
                String s = new String(is.readAllBytes(), StandardCharsets.UTF_8);
                if (s.isEmpty()) return new JsonObject();
                try {
                    return JsonParser.parseString(s).getAsJsonObject();
                } catch (Exception e) {
                    // If invalid JSON, treat as empty to trigger validations
                    return new JsonObject();
                }
            }
        }

        protected String getCookie(HttpExchange ex, String name) {
            List<String> cookies = ex.getRequestHeaders().get("Cookie");
            if (cookies == null) return null;
            for (String header : cookies) {
                String[] parts = header.split(";\\s*");
                for (String part : parts) {
                    int eq = part.indexOf('=');
                    if (eq > 0) {
                        String k = part.substring(0, eq).trim();
                        String v = part.substring(eq + 1).trim();
                        if (k.equals(name)) return v;
                    }
                }
            }
            return null;
        }

        protected User requireAuth(HttpExchange ex) throws IOException {
            String token = getCookie(ex, "session_id");
            if (token == null) {
                sendError(ex, 401, "Authentication required");
                return null;
            }
            Integer userId = state.sessions.get(token);
            if (userId == null) {
                sendError(ex, 401, "Authentication required");
                return null;
            }
            User u = state.usersById.get(userId);
            if (u == null) { // should not happen
                sendError(ex, 401, "Authentication required");
                return null;
            }
            return u;
        }

        protected void methodNotAllowed(HttpExchange ex) throws IOException {
            sendError(ex, 405, "Method Not Allowed");
        }
    }

    static class RegisterHandler extends BaseHandler {
        private static final Pattern USERNAME_RE = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");
        RegisterHandler(ServerState s) { super(s); }
        @Override public void handle(HttpExchange ex) throws IOException {
            if (!"POST".equals(ex.getRequestMethod())) { methodNotAllowed(ex); return; }
            JsonObject body = readJson(ex);
            String username = body.has("username") && !body.get("username").isJsonNull() ? body.get("username").getAsString() : null;
            String password = body.has("password") && !body.get("password").isJsonNull() ? body.get("password").getAsString() : null;

            if (username == null || !USERNAME_RE.matcher(username).matches()) {
                sendError(ex, 400, "Invalid username");
                return;
            }
            if (password == null || password.length() < 8) {
                sendError(ex, 400, "Password too short");
                return;
            }
            synchronized (state) {
                if (state.usersByUsername.containsKey(username)) {
                    sendError(ex, 409, "Username already exists");
                    return;
                }
                User u = state.createUser(username, password);
                sendJson(ex, 201, u.toJson());
            }
        }
    }

    static class LoginHandler extends BaseHandler {
        LoginHandler(ServerState s) { super(s); }
        @Override public void handle(HttpExchange ex) throws IOException {
            if (!"POST".equals(ex.getRequestMethod())) { methodNotAllowed(ex); return; }
            JsonObject body = readJson(ex);
            String username = body.has("username") && !body.get("username").isJsonNull() ? body.get("username").getAsString() : null;
            String password = body.has("password") && !body.get("password").isJsonNull() ? body.get("password").getAsString() : null;
            if (username == null || password == null) {
                sendError(ex, 401, "Invalid credentials");
                return;
            }
            User u = state.usersByUsername.get(username);
            if (u == null || !u.password.equals(password)) {
                sendError(ex, 401, "Invalid credentials");
                return;
            }
            String token = UUID.randomUUID().toString().replace("-", "");
            state.sessions.put(token, u.id);
            Headers resp = ex.getResponseHeaders();
            resp.add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            sendJson(ex, 200, u.toJson());
        }
    }

    static class LogoutHandler extends BaseHandler {
        LogoutHandler(ServerState s) { super(s); }
        @Override public void handle(HttpExchange ex) throws IOException {
            if (!"POST".equals(ex.getRequestMethod())) { methodNotAllowed(ex); return; }
            User u = requireAuth(ex);
            if (u == null) return; // response already sent
            String token = getCookie(ex, "session_id");
            if (token != null) {
                state.sessions.remove(token);
            }
            sendJsonEmpty(ex, 200);
        }
    }

    static class MeHandler extends BaseHandler {
        MeHandler(ServerState s) { super(s); }
        @Override public void handle(HttpExchange ex) throws IOException {
            if (!"GET".equals(ex.getRequestMethod())) { methodNotAllowed(ex); return; }
            User u = requireAuth(ex);
            if (u == null) return;
            sendJson(ex, 200, u.toJson());
        }
    }

    static class PasswordHandler extends BaseHandler {
        PasswordHandler(ServerState s) { super(s); }
        @Override public void handle(HttpExchange ex) throws IOException {
            if (!"PUT".equals(ex.getRequestMethod())) { methodNotAllowed(ex); return; }
            User u = requireAuth(ex);
            if (u == null) return;
            JsonObject body = readJson(ex);
            String oldp = body.has("old_password") && !body.get("old_password").isJsonNull() ? body.get("old_password").getAsString() : null;
            String newp = body.has("new_password") && !body.get("new_password").isJsonNull() ? body.get("new_password").getAsString() : null;
            if (oldp == null || !u.password.equals(oldp)) {
                sendError(ex, 401, "Invalid credentials");
                return;
            }
            if (newp == null || newp.length() < 8) {
                sendError(ex, 400, "Password too short");
                return;
            }
            synchronized (state) {
                u.password = newp;
            }
            sendJsonEmpty(ex, 200);
        }
    }

    static class TodosCollectionHandler extends BaseHandler {
        TodosCollectionHandler(ServerState s) { super(s); }
        @Override public void handle(HttpExchange ex) throws IOException {
            if ("GET".equals(ex.getRequestMethod())) {
                handleList(ex);
            } else if ("POST".equals(ex.getRequestMethod())) {
                handleCreate(ex);
            } else {
                methodNotAllowed(ex);
            }
        }
        private void handleList(HttpExchange ex) throws IOException {
            User u = requireAuth(ex);
            if (u == null) return;
            List<Todo> list = state.todosByUser.getOrDefault(u.id, Collections.emptyList());
            List<Todo> copy;
            synchronized (list) {
                copy = new ArrayList<>(list);
            }
            copy.sort(Comparator.comparingInt(t -> t.id));
            JsonArray arr = new JsonArray();
            for (Todo t : copy) arr.add(t.toJson());
            sendJson(ex, 200, arr);
        }
        private void handleCreate(HttpExchange ex) throws IOException {
            User u = requireAuth(ex);
            if (u == null) return;
            JsonObject body = readJson(ex);
            String title = body.has("title") && !body.get("title").isJsonNull() ? body.get("title").getAsString() : null;
            String description = body.has("description") && !body.get("description").isJsonNull() ? body.get("description").getAsString() : "";
            if (title == null || title.trim().isEmpty()) {
                sendError(ex, 400, "Title is required");
                return;
            }
            Todo t = state.createTodo(u.id, title, description);
            sendJson(ex, 201, t.toJson());
        }
    }

    static class TodoItemHandler extends BaseHandler {
        TodoItemHandler(ServerState s) { super(s); }
        @Override public void handle(HttpExchange ex) throws IOException {
            String method = ex.getRequestMethod();
            if ("GET".equals(method)) {
                handleGet(ex);
            } else if ("PUT".equals(method)) {
                handleUpdate(ex);
            } else if ("DELETE".equals(method)) {
                handleDelete(ex);
            } else {
                methodNotAllowed(ex);
            }
        }

        private Todo getTodoForUser(HttpExchange ex, User u) throws IOException {
            String path = ex.getRequestURI().getPath();
            // Expect /todos/{id}
            String[] parts = path.split("/");
            if (parts.length < 3) { sendError(ex, 404, "Todo not found"); return null; }
            String idStr = parts[2];
            int id;
            try { id = Integer.parseInt(idStr); } catch (Exception e) { sendError(ex, 404, "Todo not found"); return null; }
            Todo t = state.todosById.get(id);
            if (t == null || t.userId != u.id) { sendError(ex, 404, "Todo not found"); return null; }
            return t;
        }

        private void handleGet(HttpExchange ex) throws IOException {
            User u = requireAuth(ex);
            if (u == null) return;
            Todo t = getTodoForUser(ex, u);
            if (t == null) return;
            sendJson(ex, 200, t.toJson());
        }

        private void handleUpdate(HttpExchange ex) throws IOException {
            User u = requireAuth(ex);
            if (u == null) return;
            Todo t = getTodoForUser(ex, u);
            if (t == null) return;
            JsonObject body = readJson(ex);
            if (body.has("title") && !body.get("title").isJsonNull()) {
                String title = body.get("title").getAsString();
                if (title.trim().isEmpty()) { sendError(ex, 400, "Title is required"); return; }
                t.title = title;
            }
            if (body.has("description") && !body.get("description").isJsonNull()) {
                t.description = body.get("description").getAsString();
            }
            if (body.has("completed") && !body.get("completed").isJsonNull()) {
                try {
                    t.completed = body.get("completed").getAsBoolean();
                } catch (Exception e) {
                    // Ignore invalid type
                }
            }
            t.updated_at = ServerState.isoNow();
            sendJson(ex, 200, t.toJson());
        }

        private void handleDelete(HttpExchange ex) throws IOException {
            User u = requireAuth(ex);
            if (u == null) return;
            String path = ex.getRequestURI().getPath();
            String[] parts = path.split("/");
            if (parts.length < 3) { sendError(ex, 404, "Todo not found"); return; }
            String idStr = parts[2];
            int id;
            try { id = Integer.parseInt(idStr); } catch (Exception e) { sendError(ex, 404, "Todo not found"); return; }
            Todo t = state.todosById.get(id);
            if (t == null || t.userId != u.id) { sendError(ex, 404, "Todo not found"); return; }
            state.todosById.remove(id);
            List<Todo> list = state.todosByUser.get(u.id);
            if (list != null) {
                synchronized (list) {
                    list.removeIf(td -> td.id == id);
                }
            }
            ex.sendResponseHeaders(204, -1);
            ex.getResponseBody().close();
        }
    }
}

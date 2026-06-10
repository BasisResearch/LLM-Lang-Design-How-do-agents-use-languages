import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.security.*;

public class TodoServer {
    private final HttpServer server;

    // In-memory storage
    private final Map<Integer, User> usersById = new ConcurrentHashMap<>();
    private final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    private final Map<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId
    private final Map<Integer, Todo> todosById = new ConcurrentHashMap<>();

    private int nextUserId = 1;
    private int nextTodoId = 1;

    public TodoServer(int port) throws IOException {
        server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        HttpContext context = server.createContext("/", this::handle);
        server.setExecutor(Executors.newCachedThreadPool());
    }

    public void start() {
        server.start();
        System.out.println("Server started on 0.0.0.0:" + server.getAddress().getPort());
    }

    private void handle(HttpExchange exchange) throws IOException {
        try {
            String method = exchange.getRequestMethod();
            URI uri = exchange.getRequestURI();
            String path = uri.getPath();

            // Routing
            if (method.equals("POST") && path.equals("/register")) {
                handleRegister(exchange);
                return;
            }
            if (method.equals("POST") && path.equals("/login")) {
                handleLogin(exchange);
                return;
            }
            if (method.equals("POST") && path.equals("/logout")) {
                withAuth(exchange, (user) -> handleLogout(exchange, user));
                return;
            }
            if (method.equals("GET") && path.equals("/me")) {
                withAuth(exchange, (user) -> handleMe(exchange, user));
                return;
            }
            if (method.equals("PUT") && path.equals("/password")) {
                withAuth(exchange, (user) -> handlePassword(exchange, user));
                return;
            }
            if (path.equals("/todos") && method.equals("GET")) {
                withAuth(exchange, (user) -> handleTodosList(exchange, user));
                return;
            }
            if (path.equals("/todos") && method.equals("POST")) {
                withAuth(exchange, (user) -> handleTodosCreate(exchange, user));
                return;
            }
            if (path.startsWith("/todos/") && method.equals("GET")) {
                withAuth(exchange, (user) -> handleTodoGet(exchange, user));
                return;
            }
            if (path.startsWith("/todos/") && method.equals("PUT")) {
                withAuth(exchange, (user) -> handleTodoUpdate(exchange, user));
                return;
            }
            if (path.startsWith("/todos/") && method.equals("DELETE")) {
                withAuth(exchange, (user) -> handleTodoDelete(exchange, user));
                return;
            }

            sendJson(exchange, 404, errorJson("Not found"));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        } finally {
            // ensure streams closed
        }
    }

    // Handlers
    private void handleRegister(HttpExchange exchange) {
        try {
            if (!exchange.getRequestMethod().equals("POST")) {
                sendJson(exchange, 405, errorJson("Method not allowed"));
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> json = SimpleJson.parseObject(body);
            String username = asString(json.get("username"));
            String password = asString(json.get("password"));
            if (username == null || username.length() < 3 || username.length() > 50 || !username.matches("^[a-zA-Z0-9_]+$")) {
                sendJson(exchange, 400, errorJson("Invalid username"));
                return;
            }
            if (password == null || password.length() < 8) {
                sendJson(exchange, 400, errorJson("Password too short"));
                return;
            }
            synchronized (this) {
                if (usersByUsername.containsKey(username)) {
                    sendJson(exchange, 409, errorJson("Username already exists"));
                    return;
                }
                int id = nextUserId++;
                String hash = hashPassword(password);
                User user = new User(id, username, hash);
                usersById.put(id, user);
                usersByUsername.put(username, user);
                Map<String, Object> resp = new LinkedHashMap<>();
                resp.put("id", id);
                resp.put("username", username);
                sendJson(exchange, 201, SimpleJson.stringify(resp));
            }
        } catch (SimpleJson.ParseException e) {
            sendJson(exchange, 400, errorJson("Invalid JSON"));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        }
    }

    private void handleLogin(HttpExchange exchange) {
        try {
            if (!exchange.getRequestMethod().equals("POST")) {
                sendJson(exchange, 405, errorJson("Method not allowed"));
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> json = SimpleJson.parseObject(body);
            String username = asString(json.get("username"));
            String password = asString(json.get("password"));
            if (username == null || password == null) {
                sendJson(exchange, 401, errorJson("Invalid credentials"));
                return;
            }
            User user = usersByUsername.get(username);
            if (user == null) {
                sendJson(exchange, 401, errorJson("Invalid credentials"));
                return;
            }
            if (!user.passwordHash.equals(hashPassword(password))) {
                sendJson(exchange, 401, errorJson("Invalid credentials"));
                return;
            }
            String token = UUID.randomUUID().toString().replace("-", "");
            sessions.put(token, user.id);
            // Set-Cookie header
            Headers headers = exchange.getResponseHeaders();
            headers.add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("id", user.id);
            resp.put("username", user.username);
            sendJson(exchange, 200, SimpleJson.stringify(resp));
        } catch (SimpleJson.ParseException e) {
            sendJson(exchange, 400, errorJson("Invalid JSON"));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        }
    }

    private void handleLogout(HttpExchange exchange, User user) {
        try {
            // Invalidate the session token
            String token = getSessionToken(exchange);
            if (token != null) {
                sessions.remove(token);
            }
            sendJson(exchange, 200, "{}");
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        }
    }

    private void handleMe(HttpExchange exchange, User user) {
        try {
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("id", user.id);
            resp.put("username", user.username);
            sendJson(exchange, 200, SimpleJson.stringify(resp));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        }
    }

    private void handlePassword(HttpExchange exchange, User user) {
        try {
            String body = readBody(exchange);
            Map<String, Object> json = SimpleJson.parseObject(body);
            String oldPw = asString(json.get("old_password"));
            String newPw = asString(json.get("new_password"));
            if (oldPw == null || !user.passwordHash.equals(hashPassword(oldPw))) {
                sendJson(exchange, 401, errorJson("Invalid credentials"));
                return;
            }
            if (newPw == null || newPw.length() < 8) {
                sendJson(exchange, 400, errorJson("Password too short"));
                return;
            }
            user.passwordHash = hashPassword(newPw);
            sendJson(exchange, 200, "{}");
        } catch (SimpleJson.ParseException e) {
            sendJson(exchange, 400, errorJson("Invalid JSON"));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        }
    }

    private void handleTodosList(HttpExchange exchange, User user) {
        try {
            List<Map<String, Object>> list = new ArrayList<>();
            List<Integer> ids = new ArrayList<>();
            for (Todo t : todosById.values()) {
                if (t.userId == user.id) ids.add(t.id);
            }
            Collections.sort(ids);
            for (Integer id : ids) {
                Todo t = todosById.get(id);
                list.add(t.toMap());
            }
            sendJson(exchange, 200, SimpleJson.stringify(list));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        }
    }

    private void handleTodosCreate(HttpExchange exchange, User user) {
        try {
            String body = readBody(exchange);
            Map<String, Object> json = SimpleJson.parseObject(body);
            String title = asString(json.get("title"));
            String description = asString(json.get("description"));
            if (title == null || title.trim().isEmpty()) {
                sendJson(exchange, 400, errorJson("Title is required"));
                return;
            }
            if (description == null) description = "";
            Todo t;
            synchronized (this) {
                int id = nextTodoId++;
                String now = isoNow();
                t = new Todo(id, user.id, title, description, false, now, now);
                todosById.put(id, t);
            }
            sendJson(exchange, 201, SimpleJson.stringify(t.toMap()));
        } catch (SimpleJson.ParseException e) {
            sendJson(exchange, 400, errorJson("Invalid JSON"));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        }
    }

    private Integer parseTodoId(HttpExchange exchange) {
        String path = exchange.getRequestURI().getPath();
        String[] parts = path.split("/");
        if (parts.length >= 3) {
            try {
                return Integer.parseInt(parts[2]);
            } catch (NumberFormatException e) {
                return null;
            }
        }
        return null;
    }

    private void handleTodoGet(HttpExchange exchange, User user) {
        try {
            Integer id = parseTodoId(exchange);
            if (id == null) { sendJson(exchange, 404, errorJson("Todo not found")); return; }
            Todo t = todosById.get(id);
            if (t == null || t.userId != user.id) {
                sendJson(exchange, 404, errorJson("Todo not found"));
                return;
            }
            sendJson(exchange, 200, SimpleJson.stringify(t.toMap()));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        }
    }

    private void handleTodoUpdate(HttpExchange exchange, User user) {
        try {
            Integer id = parseTodoId(exchange);
            if (id == null) { sendJson(exchange, 404, errorJson("Todo not found")); return; }
            Todo t = todosById.get(id);
            if (t == null || t.userId != user.id) {
                sendJson(exchange, 404, errorJson("Todo not found"));
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> json = SimpleJson.parseObject(body);
            if (json.containsKey("title")) {
                String title = asString(json.get("title"));
                if (title == null || title.trim().isEmpty()) {
                    sendJson(exchange, 400, errorJson("Title is required"));
                    return;
                }
                t.title = title;
            }
            if (json.containsKey("description")) {
                String description = asString(json.get("description"));
                if (description == null) description = "";
                t.description = description;
            }
            if (json.containsKey("completed")) {
                Object v = json.get("completed");
                if (v instanceof Boolean) {
                    t.completed = (Boolean)v;
                } else {
                    // if invalid type, respond 400 invalid json
                    sendJson(exchange, 400, errorJson("Invalid JSON"));
                    return;
                }
            }
            t.updatedAt = isoNow();
            sendJson(exchange, 200, SimpleJson.stringify(t.toMap()));
        } catch (SimpleJson.ParseException e) {
            sendJson(exchange, 400, errorJson("Invalid JSON"));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(exchange, 500, errorJson("Internal server error"));
        }
    }

    private void handleTodoDelete(HttpExchange exchange, User user) {
        try {
            Integer id = parseTodoId(exchange);
            if (id == null) { sendEmpty(exchange, 404); return; }
            Todo t = todosById.get(id);
            if (t == null || t.userId != user.id) {
                sendEmpty(exchange, 404);
                return;
            }
            todosById.remove(id);
            sendEmpty(exchange, 204);
        } catch (Exception e) {
            e.printStackTrace();
            sendEmpty(exchange, 500);
        }
    }

    // Auth helper
    private interface AuthedHandler { void handle(User user) throws IOException; }

    private void withAuth(HttpExchange exchange, AuthedHandler handler) throws IOException {
        Integer userId = getAuthenticatedUserId(exchange);
        if (userId == null) {
            sendJson(exchange, 401, errorJson("Authentication required"));
            return;
        }
        User user = usersById.get(userId);
        if (user == null) {
            sendJson(exchange, 401, errorJson("Authentication required"));
            return;
        }
        handler.handle(user);
    }

    private Integer getAuthenticatedUserId(HttpExchange exchange) {
        String token = getSessionToken(exchange);
        if (token == null) return null;
        Integer uid = sessions.get(token);
        return uid;
    }

    private String getSessionToken(HttpExchange exchange) {
        Headers headers = exchange.getRequestHeaders();
        List<String> cookieHeaders = headers.get("Cookie");
        if (cookieHeaders == null) return null;
        for (String header : cookieHeaders) {
            String[] parts = header.split(";\\s*");
            for (String part : parts) {
                int eq = part.indexOf('=');
                if (eq > 0) {
                    String name = part.substring(0, eq).trim();
                    String value = part.substring(eq + 1).trim();
                    if (name.equals("session_id")) {
                        return value;
                    }
                }
            }
        }
        return null;
    }

    // Utilities
    private static String asString(Object o) {
        if (o == null) return null;
        if (o instanceof String) return (String)o;
        return null;
    }

    private static String isoNow() {
        return Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
    }

    private static String hashPassword(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] b = md.digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte bb : b) sb.append(String.format("%02x", bb));
            return sb.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException(e);
        }
    }

    private static String errorJson(String msg) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("error", msg);
        return SimpleJson.stringify(m);
    }

    private static String readBody(HttpExchange exchange) throws IOException {
        try (InputStream is = exchange.getRequestBody()) {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
            return baos.toString(StandardCharsets.UTF_8);
        }
    }

    private static void sendJson(HttpExchange exchange, int status, String body) {
        try {
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            Headers headers = exchange.getResponseHeaders();
            headers.set("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        } catch (IOException e) {
            e.printStackTrace();
        }
    }

    private static void sendEmpty(HttpExchange exchange, int status) {
        try {
            exchange.sendResponseHeaders(status, -1);
            OutputStream os = exchange.getResponseBody();
            os.close();
        } catch (IOException e) {
            e.printStackTrace();
        }
    }

    // Data classes
    private static class User {
        final int id;
        final String username;
        String passwordHash;
        User(int id, String username, String passwordHash) {
            this.id = id; this.username = username; this.passwordHash = passwordHash;
        }
    }

    private static class Todo {
        final int id;
        final int userId;
        String title;
        String description;
        boolean completed;
        String createdAt;
        String updatedAt;
        Todo(int id, int userId, String title, String description, boolean completed, String createdAt, String updatedAt) {
            this.id = id; this.userId = userId; this.title = title; this.description = description; this.completed = completed; this.createdAt = createdAt; this.updatedAt = updatedAt;
        }
        Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", id);
            m.put("title", title);
            m.put("description", description);
            m.put("completed", completed);
            m.put("created_at", createdAt);
            m.put("updated_at", updatedAt);
            return m;
        }
    }
}

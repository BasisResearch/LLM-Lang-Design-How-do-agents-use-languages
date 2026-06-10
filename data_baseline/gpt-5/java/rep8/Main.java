import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import com.google.gson.*;
import com.google.gson.reflect.TypeToken;

public class Main {
    static class User {
        int id;
        String username;
        String passwordHash; // sha-256
        String salt;
        User(int id, String username, String passwordHash, String salt) {
            this.id = id;
            this.username = username;
            this.passwordHash = passwordHash;
            this.salt = salt;
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
    }

    static class Database {
        static final AtomicInteger nextUserId = new AtomicInteger(1);
        static final AtomicInteger nextTodoId = new AtomicInteger(1);
        static final Map<Integer, User> usersById = new ConcurrentHashMap<>();
        static final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
        static final Map<String, Integer> sessions = new ConcurrentHashMap<>();
        static final Map<Integer, Todo> todosById = new ConcurrentHashMap<>();
    }

    static final Gson gson = new GsonBuilder().serializeNulls().create();
    static final DateTimeFormatter ISO_INSTANT_SECONDS = DateTimeFormatter.ISO_INSTANT; // Instant already in Z

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
                i++;
            }
        }
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/", new RootHandler());
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }

    static class RootHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
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
                    handleLogout(exchange);
                    return;
                }
                if (method.equals("GET") && path.equals("/me")) {
                    handleMe(exchange);
                    return;
                }
                if (method.equals("PUT") && path.equals("/password")) {
                    handlePassword(exchange);
                    return;
                }
                if (path.equals("/todos") && method.equals("GET")) {
                    handleTodosList(exchange);
                    return;
                }
                if (path.equals("/todos") && method.equals("POST")) {
                    handleTodosCreate(exchange);
                    return;
                }
                if (path.startsWith("/todos/") && path.length() > "/todos/".length()) {
                    String idStr = path.substring("/todos/".length());
                    Integer id = null;
                    try {
                        id = Integer.parseInt(idStr);
                    } catch (NumberFormatException nfe) {
                        sendJsonError(exchange, 404, "Todo not found");
                        return;
                    }
                    switch (method) {
                        case "GET":
                            handleTodoGet(exchange, id);
                            return;
                        case "PUT":
                            handleTodoUpdate(exchange, id);
                            return;
                        case "DELETE":
                            handleTodoDelete(exchange, id);
                            return;
                        default:
                            break;
                    }
                }

                // Not found
                sendJsonError(exchange, 404, "Not found");
            } catch (Exception e) {
                // Internal server error
                e.printStackTrace();
                sendJsonError(exchange, 500, "Internal server error");
            } finally {
                try { exchange.close(); } catch (Exception ignore) {}
            }
        }
    }

    // Helper utilities
    static String readBody(HttpExchange exchange) throws IOException {
        InputStream is = exchange.getRequestBody();
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int r;
        while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
        return baos.toString(StandardCharsets.UTF_8);
    }

    static void setJsonContentType(HttpExchange exchange) {
        Headers h = exchange.getResponseHeaders();
        h.set("Content-Type", "application/json");
    }

    static void sendJson(HttpExchange exchange, int statusCode, Object obj) throws IOException {
        setJsonContentType(exchange);
        byte[] bytes = gson.toJson(obj).getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(statusCode, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    static void sendJsonError(HttpExchange exchange, int statusCode, String message) throws IOException {
        Map<String, String> err = new LinkedHashMap<>();
        err.put("error", message);
        sendJson(exchange, statusCode, err);
    }

    static Integer authenticate(HttpExchange exchange) throws IOException {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader == null) return null;
        String sessionId = null;
        String[] parts = cookieHeader.split(";\\s*");
        for (String part : parts) {
            int eq = part.indexOf('=');
            if (eq > 0) {
                String name = part.substring(0, eq).trim();
                String val = part.substring(eq + 1).trim();
                if (name.equals("session_id")) {
                    sessionId = val;
                    break;
                }
            }
        }
        if (sessionId == null) return null;
        Integer userId = Database.sessions.get(sessionId);
        return userId;
    }

    static void requireAuthOr401(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null || Database.usersById.get(userId) == null) {
            sendJsonError(exchange, 401, "Authentication required");
            throw new RuntimeException("unauthorized");
        }
    }

    static String isoNow() {
        Instant now = Instant.now().truncatedTo(ChronoUnit.SECONDS);
        return ISO_INSTANT_SECONDS.format(now);
    }

    static String sha256(String s) {
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] b = md.digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte x : b) sb.append(String.format("%02x", x));
            return sb.toString();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    static String generateSalt() {
        byte[] b = new byte[16];
        new java.security.SecureRandom().nextBytes(b);
        StringBuilder sb = new StringBuilder();
        for (byte x : b) sb.append(String.format("%02x", x));
        return sb.toString();
    }

    static boolean verifyPassword(User u, String password) {
        String hash = sha256(u.salt + ":" + password);
        return hash.equals(u.passwordHash);
    }

    static String cleanString(JsonObject obj, String key) {
        if (obj == null || !obj.has(key) || obj.get(key).isJsonNull()) return null;
        return obj.get(key).getAsString();
    }

    static Boolean getBoolean(JsonObject obj, String key) {
        if (obj == null || !obj.has(key) || obj.get(key).isJsonNull()) return null;
        try { return obj.get(key).getAsBoolean(); } catch (Exception e) { return null; }
    }

    // Handlers
    static void handleRegister(HttpExchange exchange) throws IOException {
        String body = readBody(exchange);
        JsonObject req;
        try {
            req = JsonParser.parseString(body).getAsJsonObject();
        } catch (Exception e) {
            sendJsonError(exchange, 400, "Invalid JSON");
            return;
        }
        String username = cleanString(req, "username");
        String password = cleanString(req, "password");
        if (username == null || !username.matches("^[a-zA-Z0-9_]{3,50}$")) {
            sendJsonError(exchange, 400, "Invalid username");
            return;
        }
        if (password == null || password.length() < 8) {
            sendJsonError(exchange, 400, "Password too short");
            return;
        }
        // uniqueness
        synchronized (Database.usersByUsername) {
            if (Database.usersByUsername.containsKey(username)) {
                sendJsonError(exchange, 409, "Username already exists");
                return;
            }
            int id = Database.nextUserId.getAndIncrement();
            String salt = generateSalt();
            String hash = sha256(salt + ":" + password);
            User u = new User(id, username, hash, salt);
            Database.usersById.put(id, u);
            Database.usersByUsername.put(username, u);
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("id", id);
            resp.put("username", username);
            sendJson(exchange, 201, resp);
        }
    }

    static void handleLogin(HttpExchange exchange) throws IOException {
        String body = readBody(exchange);
        JsonObject req;
        try {
            req = JsonParser.parseString(body).getAsJsonObject();
        } catch (Exception e) {
            sendJsonError(exchange, 401, "Invalid credentials");
            return;
        }
        String username = cleanString(req, "username");
        String password = cleanString(req, "password");
        if (username == null || password == null) {
            sendJsonError(exchange, 401, "Invalid credentials");
            return;
        }
        User u = Database.usersByUsername.get(username);
        if (u == null || !verifyPassword(u, password)) {
            sendJsonError(exchange, 401, "Invalid credentials");
            return;
        }
        String token = UUID.randomUUID().toString();
        Database.sessions.put(token, u.id);
        Headers h = exchange.getResponseHeaders();
        h.add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("id", u.id);
        resp.put("username", u.username);
        sendJson(exchange, 200, resp);
    }

    static void handleLogout(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            sendJsonError(exchange, 401, "Authentication required");
            return;
        }
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader != null) {
            String[] parts = cookieHeader.split(";\\s*");
            for (String part : parts) {
                int eq = part.indexOf('=');
                if (eq > 0) {
                    String name = part.substring(0, eq).trim();
                    String val = part.substring(eq + 1).trim();
                    if (name.equals("session_id")) {
                        Database.sessions.remove(val);
                    }
                }
            }
        }
        Map<String, Object> resp = new LinkedHashMap<>();
        sendJson(exchange, 200, resp);
    }

    static void handleMe(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            sendJsonError(exchange, 401, "Authentication required");
            return;
        }
        User u = Database.usersById.get(userId);
        if (u == null) {
            sendJsonError(exchange, 401, "Authentication required");
            return;
        }
        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("id", u.id);
        resp.put("username", u.username);
        sendJson(exchange, 200, resp);
    }

    static void handlePassword(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            sendJsonError(exchange, 401, "Authentication required");
            return;
        }
        User u = Database.usersById.get(userId);
        if (u == null) {
            sendJsonError(exchange, 401, "Authentication required");
            return;
        }
        String body = readBody(exchange);
        JsonObject req;
        try {
            req = JsonParser.parseString(body).getAsJsonObject();
        } catch (Exception e) {
            sendJsonError(exchange, 400, "Invalid JSON");
            return;
        }
        String oldp = cleanString(req, "old_password");
        String newp = cleanString(req, "new_password");
        if (oldp == null || !verifyPassword(u, oldp)) {
            sendJsonError(exchange, 401, "Invalid credentials");
            return;
        }
        if (newp == null || newp.length() < 8) {
            sendJsonError(exchange, 400, "Password too short");
            return;
        }
        String newSalt = generateSalt();
        String newHash = sha256(newSalt + ":" + newp);
        u.salt = newSalt;
        u.passwordHash = newHash;
        Map<String, Object> resp = new LinkedHashMap<>();
        sendJson(exchange, 200, resp);
    }

    static void handleTodosList(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) { sendJsonError(exchange, 401, "Authentication required"); return; }
        List<Todo> out = new ArrayList<>();
        for (Todo t : Database.todosById.values()) {
            if (t.userId == userId) out.add(t);
        }
        out.sort(Comparator.comparingInt(a -> a.id));
        sendJson(exchange, 200, out);
    }

    static void handleTodosCreate(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) { sendJsonError(exchange, 401, "Authentication required"); return; }
        String body = readBody(exchange);
        JsonObject req;
        try { req = JsonParser.parseString(body).getAsJsonObject(); }
        catch (Exception e) { sendJsonError(exchange, 400, "Invalid JSON"); return; }
        String title = cleanString(req, "title");
        String description = cleanString(req, "description");
        if (title == null || title.trim().isEmpty()) {
            sendJsonError(exchange, 400, "Title is required");
            return;
        }
        if (description == null) description = "";
        Todo t = new Todo();
        t.id = Database.nextTodoId.getAndIncrement();
        t.userId = userId;
        t.title = title;
        t.description = description;
        t.completed = false;
        t.created_at = isoNow();
        t.updated_at = t.created_at;
        Database.todosById.put(t.id, t);
        sendJson(exchange, 201, t);
    }

    static Todo findOwnedTodo(int id, int userId) {
        Todo t = Database.todosById.get(id);
        if (t == null) return null;
        if (t.userId != userId) return null;
        return t;
    }

    static void handleTodoGet(HttpExchange exchange, int id) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) { sendJsonError(exchange, 401, "Authentication required"); return; }
        Todo t = findOwnedTodo(id, userId);
        if (t == null) { sendJsonError(exchange, 404, "Todo not found"); return; }
        sendJson(exchange, 200, t);
    }

    static void handleTodoUpdate(HttpExchange exchange, int id) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) { sendJsonError(exchange, 401, "Authentication required"); return; }
        Todo t = findOwnedTodo(id, userId);
        if (t == null) { sendJsonError(exchange, 404, "Todo not found"); return; }
        String body = readBody(exchange);
        JsonObject req;
        try { req = JsonParser.parseString(body).getAsJsonObject(); }
        catch (Exception e) { sendJsonError(exchange, 400, "Invalid JSON"); return; }
        if (req.has("title")) {
            String title = cleanString(req, "title");
            if (title == null || title.trim().isEmpty()) {
                sendJsonError(exchange, 400, "Title is required");
                return;
            }
            t.title = title;
        }
        if (req.has("description")) {
            String desc = cleanString(req, "description");
            t.description = (desc == null ? "" : desc);
        }
        if (req.has("completed")) {
            Boolean comp = getBoolean(req, "completed");
            if (comp != null) t.completed = comp.booleanValue();
        }
        t.updated_at = isoNow();
        sendJson(exchange, 200, t);
    }

    static void handleTodoDelete(HttpExchange exchange, int id) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) { sendJsonError(exchange, 401, "Authentication required"); return; }
        Todo t = findOwnedTodo(id, userId);
        if (t == null) { sendJsonError(exchange, 404, "Todo not found"); return; }
        Database.todosById.remove(id);
        // 204 No Content, no body
        exchange.sendResponseHeaders(204, -1);
    }
}

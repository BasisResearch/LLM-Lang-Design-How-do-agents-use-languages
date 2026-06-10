import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.*;
import com.google.gson.*;

public class Main {
    // Data models
    static class User {
        final int id;
        final String username;
        String password; // stored in-memory plain for this exercise
        User(int id, String username, String password) {
            this.id = id;
            this.username = username;
            this.password = password;
        }
        Map<String,Object> toPublicJson() {
            Map<String,Object> m = new LinkedHashMap<>();
            m.put("id", id);
            m.put("username", username);
            return m;
        }
    }

    static class Todo {
        final int id;
        final int userId;
        String title;
        String description;
        boolean completed;
        String created_at;
        String updated_at;
        Todo(int id, int userId, String title, String description, boolean completed, String created_at, String updated_at) {
            this.id = id;
            this.userId = userId;
            this.title = title;
            this.description = description;
            this.completed = completed;
            this.created_at = created_at;
            this.updated_at = updated_at;
        }
        Map<String,Object> toJson() {
            Map<String,Object> m = new LinkedHashMap<>();
            m.put("id", id);
            m.put("title", title);
            m.put("description", description);
            m.put("completed", completed);
            m.put("created_at", created_at);
            m.put("updated_at", updated_at);
            return m;
        }
    }

    static class DB {
        final ConcurrentHashMap<String, User> usersByUsername = new ConcurrentHashMap<>();
        final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
        final AtomicInteger userIdSeq = new AtomicInteger(1);

        final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
        final AtomicInteger todoIdSeq = new AtomicInteger(1);

        final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId
    }

    static final DB db = new DB();
    static final Gson gson = new GsonBuilder().serializeNulls().create();
    static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i=0; i<args.length; i++) {
            if ("--port".equals(args[i]) && i+1 < args.length) {
                port = Integer.parseInt(args[i+1]);
                i++;
            }
        }
        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer server = HttpServer.create(addr, 0);
        HttpContext root = server.createContext("/", Main::handleRoot);
        // Use a thread pool
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }

    static void handleRoot(HttpExchange ex) throws IOException {
        try {
            String method = ex.getRequestMethod();
            URI uri = ex.getRequestURI();
            String path = uri.getPath();
            if (path.equals("/register") && method.equals("POST")) {
                handleRegister(ex);
                return;
            }
            if (path.equals("/login") && method.equals("POST")) {
                handleLogin(ex);
                return;
            }
            if (path.equals("/logout") && method.equals("POST")) {
                withAuth(ex, (user, token) -> handleLogout(ex, user, token));
                return;
            }
            if (path.equals("/me") && method.equals("GET")) {
                withAuth(ex, (user, token) -> sendJson(ex, 200, user.toPublicJson()));
                return;
            }
            if (path.equals("/password") && method.equals("PUT")) {
                withAuth(ex, (user, token) -> handlePasswordChange(ex, user));
                return;
            }
            if (path.startsWith("/todos")) {
                withAuth(ex, (user, token) -> handleTodos(ex, user));
                return;
            }
            sendError(ex, 404, "Not found");
        } catch (Exception e) {
            e.printStackTrace();
            sendError(ex, 500, "Internal server error");
        }
    }

    @FunctionalInterface
    interface AuthedHandler { void handle(User user, String sessionToken) throws IOException; }

    static void withAuth(HttpExchange ex, AuthedHandler handler) throws IOException {
        String token = getSessionToken(ex.getRequestHeaders());
        if (token == null) {
            sendAuthRequired(ex);
            return;
        }
        Integer uid = db.sessions.get(token);
        if (uid == null) {
            sendAuthRequired(ex);
            return;
        }
        User user = db.usersById.get(uid);
        if (user == null) {
            // session points to missing user; treat as unauthenticated
            sendAuthRequired(ex);
            return;
        }
        handler.handle(user, token);
    }

    static void handleRegister(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        JsonObject req;
        try {
            req = gson.fromJson(body, JsonObject.class);
        } catch (JsonSyntaxException jse) {
            sendError(ex, 400, "Invalid JSON");
            return;
        }
        if (req == null) {
            sendError(ex, 400, "Invalid JSON");
            return;
        }
        String username = getAsString(req.get("username"));
        String password = getAsString(req.get("password"));
        if (username == null || !USERNAME_PATTERN.matcher(username).matches()) {
            sendError(ex, 400, "Invalid username");
            return;
        }
        if (password == null || password.length() < 8) {
            sendError(ex, 400, "Password too short");
            return;
        }
        // Uniqueness
        synchronized (db) {
            if (db.usersByUsername.containsKey(username)) {
                sendError(ex, 409, "Username already exists");
                return;
            }
            int id = db.userIdSeq.getAndIncrement();
            User user = new User(id, username, password);
            db.usersByUsername.put(username, user);
            db.usersById.put(id, user);
            sendJson(ex, 201, user.toPublicJson());
        }
    }

    static void handleLogin(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        JsonObject req;
        try {
            req = gson.fromJson(body, JsonObject.class);
        } catch (JsonSyntaxException jse) {
            sendError(ex, 400, "Invalid JSON");
            return;
        }
        if (req == null) {
            sendError(ex, 400, "Invalid JSON");
            return;
        }
        String username = getAsString(req.get("username"));
        String password = getAsString(req.get("password"));
        User user = username != null ? db.usersByUsername.get(username) : null;
        if (user == null || password == null || !safeEquals(user.password, password)) {
            sendError(ex, 401, "Invalid credentials");
            return;
        }
        String token = UUID.randomUUID().toString().replace("-", "");
        db.sessions.put(token, user.id);
        // Set-Cookie header
        ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        sendJson(ex, 200, user.toPublicJson());
    }

    static void handleLogout(HttpExchange ex, User user, String token) throws IOException {
        if (token != null) {
            db.sessions.remove(token);
        }
        sendJson(ex, 200, new LinkedHashMap<String,Object>()); // {}
    }

    static void handlePasswordChange(HttpExchange ex, User user) throws IOException {
        String body = readBody(ex);
        JsonObject req;
        try {
            req = gson.fromJson(body, JsonObject.class);
        } catch (JsonSyntaxException jse) {
            sendError(ex, 400, "Invalid JSON");
            return;
        }
        if (req == null) {
            sendError(ex, 400, "Invalid JSON");
            return;
        }
        String oldp = getAsString(req.get("old_password"));
        String newp = getAsString(req.get("new_password"));
        if (oldp == null || !safeEquals(oldp, user.password)) {
            sendError(ex, 401, "Invalid credentials");
            return;
        }
        if (newp == null || newp.length() < 8) {
            sendError(ex, 400, "Password too short");
            return;
        }
        user.password = newp;
        sendJson(ex, 200, new LinkedHashMap<String,Object>()); // {}
    }

    static void handleTodos(HttpExchange ex, User user) throws IOException {
        String method = ex.getRequestMethod();
        String path = ex.getRequestURI().getPath();
        if (path.equals("/todos")) {
            if (method.equals("GET")) {
                // list
                List<Todo> list = new ArrayList<>();
                for (Todo t : db.todosById.values()) {
                    if (t.userId == user.id) list.add(t);
                }
                list.sort(Comparator.comparingInt(t -> t.id));
                List<Map<String,Object>> out = new ArrayList<>();
                for (Todo t : list) out.add(t.toJson());
                sendJson(ex, 200, out);
                return;
            } else if (method.equals("POST")) {
                String body = readBody(ex);
                JsonObject req;
                try { req = gson.fromJson(body, JsonObject.class); } catch (JsonSyntaxException jse) { sendError(ex, 400, "Invalid JSON"); return; }
                if (req == null) { sendError(ex, 400, "Invalid JSON"); return; }
                String title = getAsString(req.get("title"));
                if (title == null || title.trim().isEmpty()) {
                    sendError(ex, 400, "Title is required");
                    return;
                }
                String description = req.has("description") && !req.get("description").isJsonNull() ? getAsString(req.get("description")) : "";
                if (description == null) description = "";
                String now = isoNow();
                int id = db.todoIdSeq.getAndIncrement();
                Todo t = new Todo(id, user.id, title, description, false, now, now);
                db.todosById.put(id, t);
                sendJson(ex, 201, t.toJson());
                return;
            } else {
                sendError(ex, 405, "Method not allowed");
                return;
            }
        } else if (path.startsWith("/todos/")) {
            String rest = path.substring("/todos/".length());
            Integer tid = parseIntOrNull(rest);
            if (tid == null) { sendError(ex, 404, "Todo not found"); return; }
            Todo t = db.todosById.get(tid);
            if (t == null || t.userId != user.id) {
                sendError(ex, 404, "Todo not found");
                return;
            }
            switch (method) {
                case "GET":
                    sendJson(ex, 200, t.toJson());
                    return;
                case "PUT": {
                    String body = readBody(ex);
                    JsonObject req;
                    try { req = gson.fromJson(body, JsonObject.class); } catch (JsonSyntaxException jse) { sendError(ex, 400, "Invalid JSON"); return; }
                    if (req == null) { sendError(ex, 400, "Invalid JSON"); return; }
                    if (req.has("title") && !req.get("title").isJsonNull()) {
                        String title = getAsString(req.get("title"));
                        if (title == null || title.trim().isEmpty()) { sendError(ex, 400, "Title is required"); return; }
                        t.title = title;
                    } else if (req.has("title") && req.get("title").isJsonNull()) {
                        // title explicitly null is treated as invalid (empty)
                        sendError(ex, 400, "Title is required");
                        return;
                    }
                    if (req.has("description")) {
                        if (req.get("description").isJsonNull()) {
                            t.description = "";
                        } else {
                            String d = getAsString(req.get("description"));
                            t.description = (d == null) ? t.description : d;
                        }
                    }
                    if (req.has("completed")) {
                        JsonElement ce = req.get("completed");
                        if (ce.isJsonNull()) {
                            // leave unchanged
                        } else if (ce.isJsonPrimitive() && ((JsonPrimitive)ce).isBoolean()) {
                            t.completed = ce.getAsBoolean();
                        } else {
                            // ignore invalid type
                        }
                    }
                    t.updated_at = isoNow();
                    sendJson(ex, 200, t.toJson());
                    return;
                }
                case "DELETE":
                    db.todosById.remove(t.id);
                    sendNoContent(ex);
                    return;
                default:
                    sendError(ex, 405, "Method not allowed");
                    return;
            }
        } else {
            sendError(ex, 404, "Not found");
        }
    }

    static String getSessionToken(Headers headers) {
        List<String> cookies = headers.get("Cookie");
        if (cookies == null) return null;
        for (String headerVal : cookies) {
            String[] parts = headerVal.split(";\\s*");
            for (String p : parts) {
                int eq = p.indexOf('=');
                if (eq > 0) {
                    String name = p.substring(0, eq).trim();
                    String val = p.substring(eq+1).trim();
                    if (name.equals("session_id")) return val;
                }
            }
        }
        return null;
    }

    static void sendJson(HttpExchange ex, int status, Object obj) throws IOException {
        byte[] data = gson.toJson(obj).getBytes(StandardCharsets.UTF_8);
        Headers h = ex.getResponseHeaders();
        h.set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, data.length);
        try (OutputStream os = ex.getResponseBody()) { os.write(data); }
    }

    static void sendNoContent(HttpExchange ex) throws IOException {
        // 204 with no body and no content-type header as per spec exception
        ex.sendResponseHeaders(204, -1);
        ex.close();
    }

    static void sendError(HttpExchange ex, int status, String message) throws IOException {
        Map<String, String> m = new LinkedHashMap<>();
        m.put("error", message);
        sendJson(ex, status, m);
    }

    static void sendAuthRequired(HttpExchange ex) throws IOException {
        sendError(ex, 401, "Authentication required");
    }

    static String readBody(HttpExchange ex) throws IOException {
        try (InputStream is = ex.getRequestBody()) {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
            return baos.toString(StandardCharsets.UTF_8);
        }
    }

    static String getAsString(JsonElement e) {
        if (e == null || e.isJsonNull()) return null;
        if (e.isJsonPrimitive()) {
            JsonPrimitive p = e.getAsJsonPrimitive();
            if (p.isString()) return p.getAsString();
            // if number or boolean provided, coerce to string
            return p.getAsString();
        }
        return null;
    }

    static Integer parseIntOrNull(String s) {
        try { return Integer.parseInt(s); } catch (Exception e) { return null; }
    }

    static String isoNow() {
        return Instant.now().truncatedTo(ChronoUnit.SECONDS).toString(); // ISO-8601, ends with 'Z'
    }

    static boolean safeEquals(String a, String b) {
        if (a == null || b == null) return false;
        if (a.length() != b.length()) return false;
        int r = 0;
        for (int i=0; i<a.length(); i++) r |= a.charAt(i) ^ b.charAt(i);
        return r == 0;
    }
}

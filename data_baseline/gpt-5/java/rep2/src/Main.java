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

public class Main {
    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length - 1; i++) {
            if ("--port".equals(args[i])) {
                port = Integer.parseInt(args[i+1]);
            }
        }
        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer server = HttpServer.create(addr, 0);
        ServerImpl impl = new ServerImpl();
        server.createContext("/", impl::handle);
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }

    static class ServerImpl {
        private final ConcurrentHashMap<String, User> usersByUsername = new ConcurrentHashMap<>();
        private final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
        private final AtomicInteger userIdSeq = new AtomicInteger(1);

        private final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId

        private final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
        private final AtomicInteger todoIdSeq = new AtomicInteger(1);

        private static final DateTimeFormatter ISO_FMT = DateTimeFormatter.ISO_INSTANT;

        public void handle(HttpExchange exchange) throws IOException {
            try {
                String method = exchange.getRequestMethod();
                URI uri = exchange.getRequestURI();
                String path = uri.getPath();

                // Route
                if (path.equals("/register") && method.equals("POST")) {
                    handleRegister(exchange);
                    return;
                } else if (path.equals("/login") && method.equals("POST")) {
                    handleLogin(exchange);
                    return;
                } else if (path.equals("/logout") && method.equals("POST")) {
                    withAuth(exchange, (user) -> handleLogout(exchange, user));
                    return;
                } else if (path.equals("/me") && method.equals("GET")) {
                    withAuth(exchange, (user) -> handleMe(exchange, user));
                    return;
                } else if (path.equals("/password") && method.equals("PUT")) {
                    withAuth(exchange, (user) -> handlePassword(exchange, user));
                    return;
                } else if (path.equals("/todos") && method.equals("GET")) {
                    withAuth(exchange, (user) -> handleTodosList(exchange, user));
                    return;
                } else if (path.equals("/todos") && method.equals("POST")) {
                    withAuth(exchange, (user) -> handleTodosCreate(exchange, user));
                    return;
                } else if (path.startsWith("/todos/") && method.equals("GET")) {
                    withAuth(exchange, (user) -> handleTodosGet(exchange, user));
                    return;
                } else if (path.startsWith("/todos/") && method.equals("PUT")) {
                    withAuth(exchange, (user) -> handleTodosUpdate(exchange, user));
                    return;
                } else if (path.startsWith("/todos/") && method.equals("DELETE")) {
                    withAuth(exchange, (user) -> handleTodosDelete(exchange, user));
                    return;
                }

                sendJson(exchange, 404, jsonError("Not found"));
            } catch (Exception e) {
                e.printStackTrace();
                try {
                    sendJson(exchange, 500, jsonError("Internal server error"));
                } catch (Exception ignored) {}
            } finally {
                // Ensure request body is consumed
                try { InputStream is = exchange.getRequestBody(); if (is != null) is.close(); } catch (Exception ignored) {}
            }
        }

        private static String nowIso() {
            Instant now = Instant.now().truncatedTo(ChronoUnit.SECONDS);
            return ISO_FMT.format(now);
        }

        private void handleRegister(HttpExchange ex) throws IOException {
            String body = readBody(ex);
            Map<String, Object> obj = SimpleJson.parseObject(body);
            String username = obj.get("username") instanceof String ? (String) obj.get("username") : null;
            String password = obj.get("password") instanceof String ? (String) obj.get("password") : null;

            if (username == null || !username.matches("^[a-zA-Z0-9_]{3,50}$")) {
                sendJson(ex, 400, jsonError("Invalid username"));
                return;
            }
            if (password == null || password.length() < 8) {
                sendJson(ex, 400, jsonError("Password too short"));
                return;
            }

            synchronized (usersByUsername) {
                if (usersByUsername.containsKey(username)) {
                    sendJson(ex, 409, jsonError("Username already exists"));
                    return;
                }
                int id = userIdSeq.getAndIncrement();
                User user = new User(id, username, password);
                usersByUsername.put(username, user);
                usersById.put(id, user);
                String resp = "{" + "\"id\":" + id + ",\"username\":" + jsonString(username) + "}";
                sendJson(ex, 201, resp);
            }
        }

        private void handleLogin(HttpExchange ex) throws IOException {
            String body = readBody(ex);
            Map<String, Object> obj = SimpleJson.parseObject(body);
            String username = obj.get("username") instanceof String ? (String) obj.get("username") : null;
            String password = obj.get("password") instanceof String ? (String) obj.get("password") : null;

            if (username == null || password == null) {
                sendJson(ex, 401, jsonError("Invalid credentials"));
                return;
            }
            User u = usersByUsername.get(username);
            if (u == null || !u.password.equals(password)) {
                sendJson(ex, 401, jsonError("Invalid credentials"));
                return;
            }
            String token = UUID.randomUUID().toString().replace("-", "");
            sessions.put(token, u.id);
            ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            String resp = "{" + "\"id\":" + u.id + ",\"username\":" + jsonString(u.username) + "}";
            sendJson(ex, 200, resp);
        }

        private void handleLogout(HttpExchange ex, User user) throws IOException {
            String token = getSessionTokenFromRequest(ex);
            if (token != null) {
                sessions.remove(token);
            }
            sendJson(ex, 200, "{}");
        }

        private void handleMe(HttpExchange ex, User user) throws IOException {
            String resp = "{" + "\"id\":" + user.id + ",\"username\":" + jsonString(user.username) + "}";
            sendJson(ex, 200, resp);
        }

        private void handlePassword(HttpExchange ex, User user) throws IOException {
            String body = readBody(ex);
            Map<String, Object> obj = SimpleJson.parseObject(body);
            String oldp = obj.get("old_password") instanceof String ? (String) obj.get("old_password") : null;
            String newp = obj.get("new_password") instanceof String ? (String) obj.get("new_password") : null;
            if (oldp == null || !user.password.equals(oldp)) {
                sendJson(ex, 401, jsonError("Invalid credentials"));
                return;
            }
            if (newp == null || newp.length() < 8) {
                sendJson(ex, 400, jsonError("Password too short"));
                return;
            }
            user.password = newp;
            sendJson(ex, 200, "{}");
        }

        private void handleTodosList(HttpExchange ex, User user) throws IOException {
            // Collect todos for user by ascending id
            List<Todo> list = new ArrayList<>();
            for (Todo t : todosById.values()) {
                if (t.userId == user.id) list.add(t);
            }
            list.sort(Comparator.comparingInt(t -> t.id));
            StringBuilder sb = new StringBuilder();
            sb.append("[");
            for (int i = 0; i < list.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(list.get(i).toJson());
            }
            sb.append("]");
            sendJson(ex, 200, sb.toString());
        }

        private void handleTodosCreate(HttpExchange ex, User user) throws IOException {
            String body = readBody(ex);
            Map<String, Object> obj = SimpleJson.parseObject(body);
            String title = obj.get("title") instanceof String ? (String) obj.get("title") : null;
            String description = obj.get("description") instanceof String ? (String) obj.get("description") : "";
            if (title == null || title.trim().isEmpty()) {
                sendJson(ex, 400, jsonError("Title is required"));
                return;
            }
            int id = todoIdSeq.getAndIncrement();
            String ts = nowIso();
            Todo todo = new Todo(id, user.id, title, description, false, ts, ts);
            todosById.put(id, todo);
            sendJson(ex, 201, todo.toJson());
        }

        private void handleTodosGet(HttpExchange ex, User user) throws IOException {
            Integer id = parseIdFromPath(ex.getRequestURI().getPath());
            if (id == null) { sendJson(ex, 404, jsonError("Todo not found")); return; }
            Todo t = todosById.get(id);
            if (t == null || t.userId != user.id) {
                sendJson(ex, 404, jsonError("Todo not found"));
                return;
            }
            sendJson(ex, 200, t.toJson());
        }

        private void handleTodosUpdate(HttpExchange ex, User user) throws IOException {
            Integer id = parseIdFromPath(ex.getRequestURI().getPath());
            if (id == null) { sendJson(ex, 404, jsonError("Todo not found")); return; }
            Todo t = todosById.get(id);
            if (t == null || t.userId != user.id) {
                sendJson(ex, 404, jsonError("Todo not found"));
                return;
            }
            String body = readBody(ex);
            Map<String, Object> obj = SimpleJson.parseObject(body);
            if (obj.containsKey("title")) {
                String title = obj.get("title") instanceof String ? (String) obj.get("title") : null;
                if (title == null || title.trim().isEmpty()) {
                    sendJson(ex, 400, jsonError("Title is required"));
                    return;
                }
                t.title = title;
            }
            if (obj.containsKey("description")) {
                String description = obj.get("description") instanceof String ? (String) obj.get("description") : "";
                t.description = description;
            }
            if (obj.containsKey("completed")) {
                Object v = obj.get("completed");
                if (v instanceof Boolean) {
                    t.completed = (Boolean) v;
                } else {
                    // If provided but not boolean, reject? Spec doesn't specify; ignore invalid type.
                    t.completed = Boolean.parseBoolean(String.valueOf(v));
                }
            }
            t.updatedAt = nowIso();
            sendJson(ex, 200, t.toJson());
        }

        private void handleTodosDelete(HttpExchange ex, User user) throws IOException {
            Integer id = parseIdFromPath(ex.getRequestURI().getPath());
            if (id == null) { sendJson(ex, 404, jsonError("Todo not found")); return; }
            Todo t = todosById.get(id);
            if (t == null || t.userId != user.id) {
                sendJson(ex, 404, jsonError("Todo not found"));
                return;
            }
            todosById.remove(id);
            sendNoContent(ex);
        }

        // Helpers
        private Integer parseIdFromPath(String path) {
            String[] parts = path.split("/");
            if (parts.length >= 3) {
                try { return Integer.parseInt(parts[2]); } catch (Exception e) { return null; }
            }
            return null;
        }

        private void withAuth(HttpExchange ex, AuthedHandler handler) throws IOException {
            User user = getAuthenticatedUser(ex);
            if (user == null) {
                sendJson(ex, 401, jsonError("Authentication required"));
                return;
            }
            handler.handle(user);
        }

        private User getAuthenticatedUser(HttpExchange ex) {
            String token = getSessionTokenFromRequest(ex);
            if (token == null) return null;
            Integer userId = sessions.get(token);
            if (userId == null) return null;
            return usersById.get(userId);
        }

        private String getSessionTokenFromRequest(HttpExchange ex) {
            Headers headers = ex.getRequestHeaders();
            List<String> cookies = headers.get("Cookie");
            if (cookies == null) return null;
            for (String c : cookies) {
                String[] parts = c.split(";");
                for (String p : parts) {
                    String s = p.trim();
                    if (s.startsWith("session_id=")) {
                        return s.substring("session_id=".length());
                    }
                }
            }
            return null;
        }

        private static String readBody(HttpExchange ex) throws IOException {
            InputStream is = ex.getRequestBody();
            if (is == null) return "";
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = is.read(buf)) != -1) {
                bos.write(buf, 0, r);
            }
            return bos.toString(StandardCharsets.UTF_8.name());
        }

        private static void sendJson(HttpExchange ex, int status, String body) throws IOException {
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            Headers h = ex.getResponseHeaders();
            h.set("Content-Type", "application/json");
            ex.sendResponseHeaders(status, bytes.length);
            try (OutputStream os = ex.getResponseBody()) { os.write(bytes); }
        }

        private static void sendNoContent(HttpExchange ex) throws IOException {
            ex.sendResponseHeaders(204, -1);
            // No body; do not set Content-Type
        }

        private static String jsonError(String msg) {
            return "{" + "\"error\":" + jsonString(msg) + "}";
        }

        private static String jsonString(String s) {
            if (s == null) return "null";
            StringBuilder sb = new StringBuilder();
            sb.append('"');
            for (int i = 0; i < s.length(); i++) {
                char ch = s.charAt(i);
                switch (ch) {
                    case '"': sb.append("\\\""); break;
                    case '\\': sb.append("\\\\"); break;
                    case '\b': sb.append("\\b"); break;
                    case '\f': sb.append("\\f"); break;
                    case '\n': sb.append("\\n"); break;
                    case '\r': sb.append("\\r"); break;
                    case '\t': sb.append("\\t"); break;
                    default:
                        if (ch < 0x20) {
                            sb.append(String.format("\\u%04x", (int) ch));
                        } else {
                            sb.append(ch);
                        }
                }
            }
            sb.append('"');
            return sb.toString();
        }

        interface AuthedHandler { void handle(User user) throws IOException; }

        static class User {
            final int id;
            final String username;
            volatile String password;
            User(int id, String username, String password) {
                this.id = id; this.username = username; this.password = password;
            }
        }

        static class Todo {
            final int id;
            final int userId;
            volatile String title;
            volatile String description;
            volatile boolean completed;
            final String createdAt;
            volatile String updatedAt;
            Todo(int id, int userId, String title, String description, boolean completed, String createdAt, String updatedAt) {
                this.id = id; this.userId = userId; this.title = title; this.description = description; this.completed = completed; this.createdAt = createdAt; this.updatedAt = updatedAt;
            }
            String toJson() {
                return "{"+
                        "\"id\":"+id+","+
                        "\"title\":"+jsonString(title)+","+
                        "\"description\":"+jsonString(description)+","+
                        "\"completed\":"+(completed?"true":"false")+","+
                        "\"created_at\":"+jsonString(createdAt)+","+
                        "\"updated_at\":"+jsonString(updatedAt)+"}";
            }
        }
    }

    // Very small JSON parser for simple flat JSON objects with string/boolean/number values
    static class SimpleJson {
        public static Map<String,Object> parseObject(String s) {
            Map<String,Object> map = new HashMap<>();
            if (s == null) return map;
            int i = 0; int n = s.length();
            while (i < n && isWs(s.charAt(i))) i++;
            if (i >= n || s.charAt(i) != '{') return map;
            i++;
            while (true) {
                while (i < n && isWs(s.charAt(i))) i++;
                if (i < n && s.charAt(i) == '}') { i++; break; }
                // key
                if (i >= n || s.charAt(i) != '"') { skipToEnd(s); return map; }
                int ks = ++i; StringBuilder keyb = new StringBuilder();
                boolean esc = false;
                while (i < n) {
                    char ch = s.charAt(i);
                    if (esc) { keyb.append(ch); esc = false; i++; continue; }
                    if (ch == '\\') { esc = true; i++; continue; }
                    if (ch == '"') break;
                    keyb.append(ch); i++;
                }
                if (i >= n || s.charAt(i) != '"') { skipToEnd(s); return map; }
                String key = keyb.toString(); i++;
                while (i < n && isWs(s.charAt(i))) i++;
                if (i >= n || s.charAt(i) != ':') { skipToEnd(s); return map; }
                i++;
                while (i < n && isWs(s.charAt(i))) i++;
                // value
                Object val = null;
                if (i < n && s.charAt(i) == '"') {
                    int vs = ++i; StringBuilder vb = new StringBuilder(); boolean escv = false;
                    while (i < n) {
                        char ch = s.charAt(i);
                        if (escv) { vb.append(unescapeChar(ch)); escv = false; i++; continue; }
                        if (ch == '\\') { escv = true; i++; continue; }
                        if (ch == '"') break;
                        vb.append(ch); i++;
                    }
                    if (i < n && s.charAt(i) == '"') { i++; val = vb.toString(); }
                } else {
                    int vs = i;
                    while (i < n && ",}\n\r\t ".indexOf(s.charAt(i)) == -1) i++;
                    String raw = s.substring(vs, i).trim();
                    if (raw.equals("true") || raw.equals("false")) {
                        val = Boolean.parseBoolean(raw);
                    } else if (raw.length() > 0) {
                        try { val = Integer.parseInt(raw); } catch (Exception e) { val = raw; }
                    }
                }
                map.put(key, val);
                while (i < n && isWs(s.charAt(i))) i++;
                if (i < n && s.charAt(i) == ',') { i++; continue; }
                if (i < n && s.charAt(i) == '}') { i++; break; }
            }
            return map;
        }
        private static boolean isWs(char c) {
            return c == ' ' || c == '\n' || c == '\r' || c == '\t';
        }
        private static void skipToEnd(String s) { /* no-op */ }
        private static char unescapeChar(char c) { return c; }
    }
}

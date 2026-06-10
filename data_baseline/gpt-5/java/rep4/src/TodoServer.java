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
import java.util.regex.*;

public class TodoServer {
    private static final DateTimeFormatter ISO_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'");

    static class User {
        final int id;
        final String username;
        String password;
        User(int id, String username, String password) {
            this.id = id; this.username = username; this.password = password;
        }
    }

    static class Todo {
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
    }

    private final HttpServer server;

    private final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Integer> usernameToId = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>();

    private final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Integer, List<Todo>> userTodos = new ConcurrentHashMap<>();

    private final AtomicInteger userIdSeq = new AtomicInteger(0);
    private final AtomicInteger todoIdSeq = new AtomicInteger(0);

    public TodoServer(int port) throws IOException {
        server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/", this::handle);
        server.setExecutor(Executors.newCachedThreadPool());
    }

    public void start() {
        server.start();
    }

    private static String nowIso() {
        return Instant.now().truncatedTo(ChronoUnit.SECONDS).atZone(ZoneOffset.UTC).format(ISO_FMT);
    }

    private static String readBody(HttpExchange ex) throws IOException {
        try (InputStream in = ex.getRequestBody()) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = in.read(buf)) != -1) bos.write(buf, 0, r);
            return bos.toString(StandardCharsets.UTF_8);
        }
    }

    private static void sendJson(HttpExchange ex, int status, String json) throws IOException {
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        Headers resp = ex.getResponseHeaders();
        resp.set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static void sendNoBody(HttpExchange ex, int status) throws IOException {
        // For DELETE 204 with no body
        ex.sendResponseHeaders(status, -1);
        ex.close();
    }

    private static void sendError(HttpExchange ex, int status, String message) throws IOException {
        String json = "{\"error\": \"" + escapeJson(message) + "\"}";
        sendJson(ex, status, json);
    }

    private static String escapeJson(String s) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int)c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.toString();
    }

    private static class JSON {
        // Minimal JSON parser for objects with string/bool/number/null
        private final String s;
        private int i;
        private JSON(String s) { this.s = s; this.i = 0; }
        static Map<String, Object> parseObject(String s) throws Exception {
            JSON p = new JSON(s);
            p.skipWs();
            Map<String, Object> obj = p.readObject();
            p.skipWs();
            if (p.i != p.s.length()) throw new Exception("Trailing data");
            return obj;
        }
        private void skipWs() { while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++; }
        private Map<String, Object> readObject() throws Exception {
            if (next() != '{') throw new Exception("Expected {");
            skipWs();
            Map<String, Object> map = new LinkedHashMap<>();
            if (peek() == '}') { i++; return map; }
            while (true) {
                skipWs();
                String key = readString();
                skipWs();
                if (next() != ':') throw new Exception("Expected :");
                skipWs();
                Object val = readValue();
                map.put(key, val);
                skipWs();
                char c = next();
                if (c == '}') break;
                if (c != ',') throw new Exception("Expected , or }");
                skipWs();
            }
            return map;
        }
        private Object readValue() throws Exception {
            char c = peek();
            if (c == '"') return readString();
            if (c == '{') return readObject();
            if (c == 't' || c == 'f') return readBoolean();
            if (c == 'n') { readNull(); return null; }
            if (c == '-' || Character.isDigit(c)) return readNumber();
            throw new Exception("Unexpected value");
        }
        private String readString() throws Exception {
            if (next() != '"') throw new Exception("Expected string");
            StringBuilder sb = new StringBuilder();
            while (i < s.length()) {
                char c = s.charAt(i++);
                if (c == '"') break;
                if (c == '\\') {
                    if (i >= s.length()) throw new Exception("Bad escape");
                    char e = s.charAt(i++);
                    switch (e) {
                        case '"': sb.append('"'); break;
                        case '\\': sb.append('\\'); break;
                        case '/': sb.append('/'); break;
                        case 'b': sb.append('\b'); break;
                        case 'f': sb.append('\f'); break;
                        case 'n': sb.append('\n'); break;
                        case 'r': sb.append('\r'); break;
                        case 't': sb.append('\t'); break;
                        case 'u':
                            if (i + 4 > s.length()) throw new Exception("Bad unicode escape");
                            String hex = s.substring(i, i+4);
                            sb.append((char)Integer.parseInt(hex, 16));
                            i += 4; break;
                        default: throw new Exception("Bad escape");
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }
        private Boolean readBoolean() throws Exception {
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
            throw new Exception("Bad boolean");
        }
        private void readNull() throws Exception {
            if (s.startsWith("null", i)) { i += 4; return; }
            throw new Exception("Bad null");
        }
        private Number readNumber() {
            int start = i;
            if (s.charAt(i) == '-') i++;
            while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
            boolean isFloat = false;
            if (i < s.length() && s.charAt(i) == '.') { isFloat = true; i++; while (i < s.length() && Character.isDigit(s.charAt(i))) i++; }
            if (i < s.length() && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) { isFloat = true; i++; if (i < s.length() && (s.charAt(i) == '+' || s.charAt(i) == '-')) i++; while (i < s.length() && Character.isDigit(s.charAt(i))) i++; }
            String num = s.substring(start, i);
            if (isFloat) return Double.parseDouble(num);
            try { return Integer.parseInt(num); } catch (NumberFormatException e) { return Long.parseLong(num); }
        }
        private char peek() throws Exception {
            if (i >= s.length()) throw new Exception("Unexpected end");
            return s.charAt(i);
        }
        private char next() throws Exception {
            if (i >= s.length()) throw new Exception("Unexpected end");
            return s.charAt(i++);
        }
    }

    private Integer authUserId(HttpExchange ex) {
        List<String> cookieHeaders = ex.getRequestHeaders().get("Cookie");
        if (cookieHeaders == null) return null;
        for (String header : cookieHeaders) {
            String[] parts = header.split(";\\s*");
            for (String part : parts) {
                int idx = part.indexOf('=');
                if (idx <= 0) continue;
                String name = part.substring(0, idx).trim();
                String val = part.substring(idx+1).trim();
                if (name.equals("session_id")) {
                    Integer uid = sessions.get(val);
                    if (uid != null) return uid;
                }
            }
        }
        return null;
    }

    private static String getPath(HttpExchange ex) {
        String p = ex.getRequestURI().getPath();
        if (p == null || p.isEmpty()) p = "/";
        return p;
    }

    private void handle(HttpExchange ex) throws IOException {
        try {
            String method = ex.getRequestMethod();
            String path = getPath(ex);

            if (method.equals("POST") && path.equals("/register")) { handleRegister(ex); return; }
            if (method.equals("POST") && path.equals("/login")) { handleLogin(ex); return; }
            if (method.equals("POST") && path.equals("/logout")) { requireAuth(ex, this::handleLogout); return; }
            if (method.equals("GET") && path.equals("/me")) { requireAuth(ex, this::handleMe); return; }
            if (method.equals("PUT") && path.equals("/password")) { requireAuth(ex, this::handlePassword); return; }

            if (path.equals("/todos")) {
                if (method.equals("GET")) { requireAuth(ex, this::handleTodosList); return; }
                if (method.equals("POST")) { requireAuth(ex, this::handleTodosCreate); return; }
            }
            if (path.startsWith("/todos/")) {
                if (method.equals("GET")) { requireAuth(ex, this::handleTodoGet); return; }
                if (method.equals("PUT")) { requireAuth(ex, this::handleTodoUpdate); return; }
                if (method.equals("DELETE")) { requireAuth(ex, this::handleTodoDelete); return; }
            }

            sendError(ex, 404, "Not found");
        } catch (Exception e) {
            e.printStackTrace();
            try { sendError(ex, 500, "Internal server error"); } catch (Exception ignore) {}
        }
    }

    @FunctionalInterface
    interface AuthedHandler { void handle(HttpExchange ex, int userId) throws Exception; }

    private void requireAuth(HttpExchange ex, AuthedHandler handler) throws IOException {
        Integer uid = authUserId(ex);
        if (uid == null) { sendError(ex, 401, "Authentication required"); return; }
        try {
            handler.handle(ex, uid);
        } catch (IOException ioe) {
            throw ioe;
        } catch (Exception e) {
            e.printStackTrace();
            sendError(ex, 500, "Internal server error");
        }
    }

    private void handleRegister(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Map<String, Object> obj;
        try {
            obj = JSON.parseObject(body);
        } catch (Exception e) {
            sendError(ex, 400, "Invalid JSON");
            return;
        }
        String username = asString(obj.get("username"));
        String password = asString(obj.get("password"));
        if (username == null || !username.matches("[A-Za-z0-9_]{3,50}")) {
            sendError(ex, 400, "Invalid username");
            return;
        }
        if (password == null || password.length() < 8) {
            sendError(ex, 400, "Password too short");
            return;
        }
        synchronized (this) {
            if (usernameToId.containsKey(username)) {
                sendError(ex, 409, "Username already exists");
                return;
            }
            int id = userIdSeq.incrementAndGet();
            User user = new User(id, username, password);
            usersById.put(id, user);
            usernameToId.put(username, id);
            String json = "{\"id\": " + id + ", \"username\": \"" + escapeJson(username) + "\"}";
            sendJson(ex, 201, json);
        }
    }

    private void handleLogin(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Map<String, Object> obj;
        try {
            obj = JSON.parseObject(body);
        } catch (Exception e) {
            sendError(ex, 400, "Invalid JSON");
            return;
        }
        String username = asString(obj.get("username"));
        String password = asString(obj.get("password"));
        if (username == null || password == null) {
            sendError(ex, 401, "Invalid credentials");
            return;
        }
        Integer uid = usernameToId.get(username);
        if (uid == null) { sendError(ex, 401, "Invalid credentials"); return; }
        User u = usersById.get(uid);
        if (u == null || !u.password.equals(password)) { sendError(ex, 401, "Invalid credentials"); return; }
        String token = UUID.randomUUID().toString().replace("-", "");
        sessions.put(token, uid);
        ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        String json = "{\"id\": " + u.id + ", \"username\": \"" + escapeJson(u.username) + "\"}";
        sendJson(ex, 200, json);
    }

    private void handleLogout(HttpExchange ex, int userId) throws IOException {
        // Invalidate the current session token
        List<String> cookieHeaders = ex.getRequestHeaders().get("Cookie");
        if (cookieHeaders != null) {
            for (String header : cookieHeaders) {
                String[] parts = header.split(";\\s*");
                for (String part : parts) {
                    int idx = part.indexOf('=');
                    if (idx <= 0) continue;
                    String name = part.substring(0, idx).trim();
                    String val = part.substring(idx+1).trim();
                    if (name.equals("session_id")) {
                        sessions.remove(val);
                    }
                }
            }
        }
        sendJson(ex, 200, "{}");
    }

    private void handleMe(HttpExchange ex, int userId) throws IOException {
        User u = usersById.get(userId);
        if (u == null) { sendError(ex, 500, "Internal server error"); return; }
        String json = "{\"id\": " + u.id + ", \"username\": \"" + escapeJson(u.username) + "\"}";
        sendJson(ex, 200, json);
    }

    private void handlePassword(HttpExchange ex, int userId) throws IOException {
        String body = readBody(ex);
        Map<String, Object> obj;
        try { obj = JSON.parseObject(body); } catch (Exception e) { sendError(ex, 400, "Invalid JSON"); return; }
        String oldp = asString(obj.get("old_password"));
        String newp = asString(obj.get("new_password"));
        User u = usersById.get(userId);
        if (u == null) { sendError(ex, 500, "Internal server error"); return; }
        if (oldp == null || !u.password.equals(oldp)) { sendError(ex, 401, "Invalid credentials"); return; }
        if (newp == null || newp.length() < 8) { sendError(ex, 400, "Password too short"); return; }
        u.password = newp;
        sendJson(ex, 200, "{}");
    }

    private void handleTodosList(HttpExchange ex, int userId) throws IOException {
        List<Todo> list = userTodos.getOrDefault(userId, Collections.emptyList());
        List<Todo> copy;
        synchronized (list) {
            copy = new ArrayList<>(list);
        }
        copy.sort(Comparator.comparingInt(t -> t.id));
        StringBuilder sb = new StringBuilder();
        sb.append("[");
        for (int i = 0; i < copy.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append(todoToJson(copy.get(i)));
        }
        sb.append("]");
        sendJson(ex, 200, sb.toString());
    }

    private void handleTodosCreate(HttpExchange ex, int userId) throws IOException {
        String body = readBody(ex);
        Map<String, Object> obj;
        try { obj = JSON.parseObject(body); } catch (Exception e) { sendError(ex, 400, "Invalid JSON"); return; }
        String title = asString(obj.get("title"));
        String description = asString(obj.get("description"));
        if (title == null || title.trim().isEmpty()) { sendError(ex, 400, "Title is required"); return; }
        if (description == null) description = "";
        int id = todoIdSeq.incrementAndGet();
        String now = nowIso();
        Todo t = new Todo(id, userId, title, description, false, now, now);
        todosById.put(id, t);
        userTodos.compute(userId, (k, v) -> {
            if (v == null) v = Collections.synchronizedList(new ArrayList<>());
            v.add(t);
            return v;
        });
        sendJson(ex, 201, todoToJson(t));
    }

    private void handleTodoGet(HttpExchange ex, int userId) throws IOException {
        Integer id = extractTodoId(getPath(ex));
        if (id == null) { sendError(ex, 404, "Not found"); return; }
        Todo t = todosById.get(id);
        if (t == null || t.userId != userId) { sendError(ex, 404, "Todo not found"); return; }
        sendJson(ex, 200, todoToJson(t));
    }

    private void handleTodoUpdate(HttpExchange ex, int userId) throws IOException {
        Integer id = extractTodoId(getPath(ex));
        if (id == null) { sendError(ex, 404, "Not found"); return; }
        Todo t = todosById.get(id);
        if (t == null || t.userId != userId) { sendError(ex, 404, "Todo not found"); return; }
        String body = readBody(ex);
        Map<String, Object> obj;
        try { obj = JSON.parseObject(body); } catch (Exception e) { sendError(ex, 400, "Invalid JSON"); return; }
        if (obj.containsKey("title")) {
            String title = asString(obj.get("title"));
            if (title == null || title.trim().isEmpty()) { sendError(ex, 400, "Title is required"); return; }
            t.title = title;
        }
        if (obj.containsKey("description")) {
            String description = asString(obj.get("description"));
            t.description = description == null ? "" : description;
        }
        if (obj.containsKey("completed")) {
            Boolean completed = asBoolean(obj.get("completed"));
            t.completed = completed != null && completed.booleanValue();
        }
        t.updatedAt = nowIso();
        sendJson(ex, 200, todoToJson(t));
    }

    private void handleTodoDelete(HttpExchange ex, int userId) throws IOException {
        Integer id = extractTodoId(getPath(ex));
        if (id == null) { sendError(ex, 404, "Not found"); return; }
        Todo t = todosById.get(id);
        if (t == null || t.userId != userId) { sendError(ex, 404, "Todo not found"); return; }
        todosById.remove(id);
        List<Todo> list = userTodos.get(userId);
        if (list != null) {
            synchronized (list) { list.removeIf(td -> td.id == id); }
        }
        sendNoBody(ex, 204);
    }

    private static Integer extractTodoId(String path) {
        if (!path.startsWith("/todos/")) return null;
        String rest = path.substring("/todos/".length());
        if (rest.isEmpty()) return null;
        try { return Integer.parseInt(rest); } catch (NumberFormatException e) { return null; }
    }

    private static String asString(Object o) {
        if (o == null) return null;
        if (o instanceof String) return (String)o;
        if (o instanceof Number || o instanceof Boolean) return String.valueOf(o);
        return null;
    }
    private static Boolean asBoolean(Object o) {
        if (o == null) return null;
        if (o instanceof Boolean) return (Boolean)o;
        if (o instanceof String) {
            String s = (String)o;
            if (s.equalsIgnoreCase("true")) return Boolean.TRUE;
            if (s.equalsIgnoreCase("false")) return Boolean.FALSE;
        }
        return null;
    }

    private static String todoToJson(Todo t) {
        StringBuilder sb = new StringBuilder();
        sb.append("{");
        sb.append("\"id\": ").append(t.id).append(", ");
        sb.append("\"title\": \"").append(escapeJson(t.title)).append("\", ");
        sb.append("\"description\": \"").append(escapeJson(t.description == null ? "" : t.description)).append("\", ");
        sb.append("\"completed\": ").append(t.completed ? "true" : "false").append(", ");
        sb.append("\"created_at\": \"").append(escapeJson(t.createdAt)).append("\", ");
        sb.append("\"updated_at\": \"").append(escapeJson(t.updatedAt)).append("\"");
        sb.append("}");
        return sb.toString();
    }

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i+1 < args.length) {
                try { port = Integer.parseInt(args[i+1]); } catch (Exception ignore) {}
                i++;
            }
        }
        TodoServer ts = new TodoServer(port);
        System.out.println("Server listening on 0.0.0.0:" + port);
        ts.start();
    }
}

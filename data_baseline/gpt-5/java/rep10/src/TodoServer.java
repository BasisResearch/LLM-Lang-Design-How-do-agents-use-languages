import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.*;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

public class TodoServer {
    // Data models
    static class User {
        final int id;
        final String username;
        String passwordHash;
        User(int id, String username, String passwordHash) {
            this.id = id; this.username = username; this.passwordHash = passwordHash;
        }
    }

    static class Todo {
        final int id;
        final int ownerId;
        String title;
        String description;
        boolean completed;
        String createdAt;
        String updatedAt;
        Todo(int id, int ownerId, String title, String description, boolean completed, String createdAt, String updatedAt) {
            this.id = id; this.ownerId = ownerId; this.title = title; this.description = description; this.completed = completed; this.createdAt = createdAt; this.updatedAt = updatedAt;
        }
    }

    // In-memory storage
    private static final AtomicInteger userIdSeq = new AtomicInteger(1);
    private static final AtomicInteger todoIdSeq = new AtomicInteger(1);
    private static final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    private static final Map<Integer, User> usersById = new ConcurrentHashMap<>();
    private static final Map<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId
    private static final Map<Integer, Todo> todosById = new ConcurrentHashMap<>();

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i+1]);
                i++;
            }
        }
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/", new RouterHandler());
        server.setExecutor(Executors.newFixedThreadPool(16));
        server.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }

    static class RouterHandler implements HttpHandler {
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
                    Integer uid = requireAuth(exchange);
                    if (uid == null) return; // response sent
                    handleLogout(exchange);
                    return;
                }
                if (method.equals("GET") && path.equals("/me")) {
                    Integer uid = requireAuth(exchange);
                    if (uid == null) return;
                    handleMe(exchange, uid);
                    return;
                }
                if (method.equals("PUT") && path.equals("/password")) {
                    Integer uid = requireAuth(exchange);
                    if (uid == null) return;
                    handlePasswordChange(exchange, uid);
                    return;
                }
                if (path.equals("/todos") && method.equals("GET")) {
                    Integer uid = requireAuth(exchange);
                    if (uid == null) return;
                    handleTodosList(exchange, uid);
                    return;
                }
                if (path.equals("/todos") && method.equals("POST")) {
                    Integer uid = requireAuth(exchange);
                    if (uid == null) return;
                    handleTodosCreate(exchange, uid);
                    return;
                }
                if (path.startsWith("/todos/")) {
                    Integer uid = requireAuth(exchange);
                    if (uid == null) return;
                    String idStr = path.substring("/todos/".length());
                    if (idStr.contains("/")) {
                        notFound(exchange);
                        return;
                    }
                    int id;
                    try { id = Integer.parseInt(idStr); } catch (NumberFormatException e) { notFound(exchange); return; }
                    if (method.equals("GET")) { handleTodosGet(exchange, uid, id); return; }
                    if (method.equals("PUT")) { handleTodosUpdate(exchange, uid, id); return; }
                    if (method.equals("DELETE")) { handleTodosDelete(exchange, uid, id); return; }
                }
                // Default 404
                notFound(exchange);
            } catch (Exception e) {
                // Internal error handler
                e.printStackTrace();
                sendJson(exchange, 500, jsonError("Internal server error"));
            } finally {
                try { exchange.close(); } catch (Exception ignore) {}
            }
        }
    }

    // Handlers
    private static void handleRegister(HttpExchange ex) throws IOException {
        Map<String, Object> body = readJsonBody(ex);
        if (body == null) return; // error already sent
        String username = asString(body.get("username"));
        String password = asString(body.get("password"));
        if (!isValidUsername(username)) {
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
            String hash = hashPassword(password);
            User u = new User(id, username, hash);
            usersByUsername.put(username, u);
            usersById.put(id, u);
            String resp = toJsonUser(u);
            sendJson(ex, 201, resp);
        }
    }

    private static void handleLogin(HttpExchange ex) throws IOException {
        Map<String, Object> body = readJsonBody(ex);
        if (body == null) return;
        String username = asString(body.get("username"));
        String password = asString(body.get("password"));
        if (username == null || password == null) {
            sendJson(ex, 401, jsonError("Invalid credentials"));
            return;
        }
        User u = usersByUsername.get(username);
        if (u == null) {
            sendJson(ex, 401, jsonError("Invalid credentials"));
            return;
        }
        if (!u.passwordHash.equals(hashPassword(password))) {
            sendJson(ex, 401, jsonError("Invalid credentials"));
            return;
        }
        String token = UUID.randomUUID().toString().replace("-", "");
        sessions.put(token, u.id);
        Headers h = ex.getResponseHeaders();
        h.add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        sendJson(ex, 200, toJsonUser(u));
    }

    private static void handleLogout(HttpExchange ex) throws IOException {
        String token = getSessionTokenFromCookies(ex.getRequestHeaders().getFirst("Cookie"));
        if (token != null) {
            sessions.remove(token);
        }
        sendJson(ex, 200, "{}");
    }

    private static void handleMe(HttpExchange ex, int uid) throws IOException {
        User u = usersById.get(uid);
        if (u == null) { sendJson(ex, 401, jsonError("Authentication required")); return; }
        sendJson(ex, 200, toJsonUser(u));
    }

    private static void handlePasswordChange(HttpExchange ex, int uid) throws IOException {
        Map<String, Object> body = readJsonBody(ex);
        if (body == null) return;
        String oldPassword = asString(body.get("old_password"));
        String newPassword = asString(body.get("new_password"));
        User u = usersById.get(uid);
        if (u == null) { sendJson(ex, 401, jsonError("Authentication required")); return; }
        if (oldPassword == null || !u.passwordHash.equals(hashPassword(oldPassword))) {
            sendJson(ex, 401, jsonError("Invalid credentials"));
            return;
        }
        if (newPassword == null || newPassword.length() < 8) {
            sendJson(ex, 400, jsonError("Password too short"));
            return;
        }
        u.passwordHash = hashPassword(newPassword);
        sendJson(ex, 200, "{}");
    }

    private static void handleTodosList(HttpExchange ex, int uid) throws IOException {
        List<Todo> list = new ArrayList<>();
        for (Todo t : todosById.values()) {
            if (t.ownerId == uid) list.add(t);
        }
        list.sort(Comparator.comparingInt(a -> a.id));
        StringBuilder sb = new StringBuilder();
        sb.append('[');
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(toJsonTodo(list.get(i)));
        }
        sb.append(']');
        sendJson(ex, 200, sb.toString());
    }

    private static void handleTodosCreate(HttpExchange ex, int uid) throws IOException {
        Map<String, Object> body = readJsonBody(ex);
        if (body == null) return;
        String title = asString(body.get("title"));
        String description = asString(body.getOrDefault("description", ""));
        if (title == null || title.trim().isEmpty()) {
            sendJson(ex, 400, jsonError("Title is required"));
            return;
        }
        int id = todoIdSeq.getAndIncrement();
        String now = isoNow();
        Todo t = new Todo(id, uid, title, description == null ? "" : description, false, now, now);
        todosById.put(id, t);
        sendJson(ex, 201, toJsonTodo(t));
    }

    private static void handleTodosGet(HttpExchange ex, int uid, int id) throws IOException {
        Todo t = todosById.get(id);
        if (t == null || t.ownerId != uid) {
            sendJson(ex, 404, jsonError("Todo not found"));
            return;
        }
        sendJson(ex, 200, toJsonTodo(t));
    }

    private static void handleTodosUpdate(HttpExchange ex, int uid, int id) throws IOException {
        Todo t = todosById.get(id);
        if (t == null || t.ownerId != uid) {
            sendJson(ex, 404, jsonError("Todo not found"));
            return;
        }
        Map<String, Object> body = readJsonBody(ex);
        if (body == null) return;
        if (body.containsKey("title")) {
            String title = asString(body.get("title"));
            if (title == null || title.trim().isEmpty()) {
                sendJson(ex, 400, jsonError("Title is required"));
                return;
            }
            t.title = title;
        }
        if (body.containsKey("description")) {
            String desc = asString(body.get("description"));
            t.description = desc == null ? "" : desc;
        }
        if (body.containsKey("completed")) {
            Boolean c = asBoolean(body.get("completed"));
            t.completed = c != null && c;
        }
        t.updatedAt = isoNow();
        sendJson(ex, 200, toJsonTodo(t));
    }

    private static void handleTodosDelete(HttpExchange ex, int uid, int id) throws IOException {
        Todo t = todosById.get(id);
        if (t == null || t.ownerId != uid) {
            // Must return 404 for non-owned items
            // Since response must have no body for DELETE success only, errors still JSON
            sendJson(ex, 404, jsonError("Todo not found"));
            return;
        }
        todosById.remove(id);
        // 204 No Content, no body
        ex.sendResponseHeaders(204, -1);
    }

    // Helpers
    private static Integer requireAuth(HttpExchange ex) throws IOException {
        String cookieHeader = ex.getRequestHeaders().getFirst("Cookie");
        String token = getSessionTokenFromCookies(cookieHeader);
        if (token == null) {
            sendJson(ex, 401, jsonError("Authentication required"));
            return null;
        }
        Integer uid = sessions.get(token);
        if (uid == null || usersById.get(uid) == null) {
            sendJson(ex, 401, jsonError("Authentication required"));
            return null;
        }
        return uid;
    }

    private static String getSessionTokenFromCookies(String cookieHeader) {
        if (cookieHeader == null) return null;
        String[] parts = cookieHeader.split(";\\s*");
        for (String part : parts) {
            int idx = part.indexOf('=');
            if (idx <= 0) continue;
            String name = part.substring(0, idx).trim();
            String value = part.substring(idx + 1).trim();
            if (name.equals("session_id")) return value;
        }
        return null;
    }

    private static void notFound(HttpExchange ex) throws IOException {
        sendJson(ex, 404, jsonError("Not found"));
    }

    private static void sendJson(HttpExchange ex, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        Headers h = ex.getResponseHeaders();
        h.set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static String jsonError(String msg) {
        return "{\"error\":\"" + escape(msg) + "\"}";
    }

    private static String toJsonUser(User u) {
        return "{" +
                "\"id\":" + u.id + "," +
                "\"username\":\"" + escape(u.username) + "\"" +
                "}";
    }

    private static String toJsonTodo(Todo t) {
        return "{" +
                "\"id\":" + t.id + "," +
                "\"title\":\"" + escape(t.title) + "\"" + "," +
                "\"description\":\"" + escape(t.description == null ? "" : t.description) + "\"" + "," +
                "\"completed\":" + (t.completed ? "true" : "false") + "," +
                "\"created_at\":\"" + t.createdAt + "\"" + "," +
                "\"updated_at\":\"" + t.updatedAt + "\"" +
                "}";
    }

    private static String escape(String s) {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
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

    private static Map<String, Object> readJsonBody(HttpExchange ex) throws IOException {
        String body = readBody(ex.getRequestBody());
        if (body == null || body.trim().isEmpty()) {
            sendJson(ex, 400, jsonError("Invalid JSON"));
            return null;
        }
        try {
            return parseJsonObject(body);
        } catch (Exception e) {
            sendJson(ex, 400, jsonError("Invalid JSON"));
            return null;
        }
    }

    private static String readBody(InputStream is) throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int r;
        while ((r = is.read(buf)) != -1) {
            baos.write(buf, 0, r);
        }
        return baos.toString(StandardCharsets.UTF_8);
    }

    // Very simple JSON object parser supporting string and boolean values
    private static Map<String, Object> parseJsonObject(String s) {
        int[] idx = new int[] {0};
        skipWs(s, idx);
        if (idx[0] >= s.length() || s.charAt(idx[0]) != '{') throw new RuntimeException("Expected {");
        idx[0]++;
        Map<String, Object> map = new HashMap<>();
        skipWs(s, idx);
        if (idx[0] < s.length() && s.charAt(idx[0]) == '}') { idx[0]++; return map; }
        while (true) {
            skipWs(s, idx);
            String key = parseString(s, idx);
            skipWs(s, idx);
            if (idx[0] >= s.length() || s.charAt(idx[0]) != ':') throw new RuntimeException("Expected :");
            idx[0]++;
            skipWs(s, idx);
            Object val = parseValue(s, idx);
            map.put(key, val);
            skipWs(s, idx);
            if (idx[0] >= s.length()) throw new RuntimeException("Unterminated object");
            char c = s.charAt(idx[0]);
            if (c == ',') { idx[0]++; continue; }
            if (c == '}') { idx[0]++; break; }
            throw new RuntimeException("Expected , or }");
        }
        return map;
    }

    private static void skipWs(String s, int[] idx) {
        while (idx[0] < s.length()) {
            char c = s.charAt(idx[0]);
            if (c == ' ' || c == '\n' || c == '\r' || c == '\t') idx[0]++; else break;
        }
    }

    private static String parseString(String s, int[] idx) {
        if (idx[0] >= s.length() || s.charAt(idx[0]) != '"') throw new RuntimeException("Expected string");
        idx[0]++;
        StringBuilder sb = new StringBuilder();
        while (idx[0] < s.length()) {
            char c = s.charAt(idx[0]++);
            if (c == '"') break;
            if (c == '\\') {
                if (idx[0] >= s.length()) throw new RuntimeException("Invalid escape");
                char e = s.charAt(idx[0]++);
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
                        if (idx[0] + 4 > s.length()) throw new RuntimeException("Invalid unicode escape");
                        String hex = s.substring(idx[0], idx[0] + 4);
                        idx[0] += 4;
                        char uc = (char) Integer.parseInt(hex, 16);
                        sb.append(uc);
                        break;
                    default: throw new RuntimeException("Invalid escape");
                }
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    private static Object parseValue(String s, int[] idx) {
        if (idx[0] >= s.length()) throw new RuntimeException("Unexpected end");
        char c = s.charAt(idx[0]);
        if (c == '"') return parseString(s, idx);
        if (c == 't' && s.startsWith("true", idx[0])) { idx[0]+=4; return Boolean.TRUE; }
        if (c == 'f' && s.startsWith("false", idx[0])) { idx[0]+=5; return Boolean.FALSE; }
        if (c == 'n' && s.startsWith("null", idx[0])) { idx[0]+=4; return null; }
        // numbers not needed currently but support int
        if (c == '-' || (c >= '0' && c <= '9')) {
            int start = idx[0];
            if (c == '-') idx[0]++;
            while (idx[0] < s.length() && Character.isDigit(s.charAt(idx[0]))) idx[0]++;
            String num = s.substring(start, idx[0]);
            try { return Integer.parseInt(num); } catch (NumberFormatException e) { return num; }
        }
        throw new RuntimeException("Unsupported value");
    }

    private static String asString(Object o) { return (o instanceof String) ? (String) o : null; }
    private static Boolean asBoolean(Object o) { return (o instanceof Boolean) ? (Boolean) o : null; }

    private static boolean isValidUsername(String username) {
        if (username == null) return false;
        if (username.length() < 3 || username.length() > 50) return false;
        return username.matches("[a-zA-Z0-9_]+");
    }

    private static String hashPassword(String password) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] h = md.digest(password.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : h) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException(e);
        }
    }

    private static String isoNow() {
        return Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
    }
}

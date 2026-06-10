package todo;

import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public class Server {
    private static final DateTimeFormatter ISO_INSTANT_SECONDS = DateTimeFormatter.ISO_INSTANT;

    // Data models
    static class User {
        final int id;
        final String username;
        String passwordHash; // simple hash for demo
        User(int id, String username, String passwordHash) {
            this.id = id; this.username = username; this.passwordHash = passwordHash;
        }
        String toJson() {
            return "{" +
                "\"id\":" + id + "," +
                "\"username\":\"" + Json.escape(username) + "\"" +
                "}";
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
        String toJson() {
            StringBuilder sb = new StringBuilder();
            sb.append('{');
            sb.append("\"id\":").append(id).append(',');
            sb.append("\"title\":\"").append(Json.escape(title)).append("\",");
            sb.append("\"description\":\"").append(Json.escape(description == null ? "" : description)).append("\",");
            sb.append("\"completed\":").append(completed).append(',');
            sb.append("\"created_at\":\"").append(createdAt).append("\",");
            sb.append("\"updated_at\":\"").append(updatedAt).append("\"");
            sb.append('}');
            return sb.toString();
        }
    }

    // Storage
    private final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, User> usersByUsername = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();

    private final AtomicInteger nextUserId = new AtomicInteger(1);
    private final AtomicInteger nextTodoId = new AtomicInteger(1);

    private final Object userLock = new Object();

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
                i++;
            }
        }
        Server app = new Server();
        app.start(port);
    }

    private void start(int port) throws IOException {
        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer httpServer = HttpServer.create(addr, 0);
        httpServer.createContext("/", new RootHandler());
        httpServer.setExecutor(Executors.newCachedThreadPool());
        httpServer.start();
        System.out.println("Server listening on 0.0.0.0:" + port);
    }

    private class RootHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            try {
                String method = exchange.getRequestMethod();
                URI uri = exchange.getRequestURI();
                String path = uri.getPath();
                if (path == null) path = "/";

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
                if (path.startsWith("/todos/")) {
                    String idStr = path.substring("/todos/".length());
                    if (!idStr.matches("[0-9]+")) {
                        sendJsonError(exchange, 404, "Not found");
                        return;
                    }
                    int id;
                    try { id = Integer.parseInt(idStr); } catch (Exception e) { sendJsonError(exchange, 404, "Not found"); return; }
                    if (method.equals("GET")) { handleTodosGet(exchange, id); return; }
                    if (method.equals("PUT")) { handleTodosUpdate(exchange, id); return; }
                    if (method.equals("DELETE")) { handleTodosDelete(exchange, id); return; }
                }

                sendJsonError(exchange, 404, "Not found");
            } catch (Exception e) {
                e.printStackTrace();
                safeSendJsonError(exchange, 500, "Internal server error");
            } finally {
                try { exchange.close(); } catch (Exception ignore) {}
            }
        }
    }

    // Handlers
    private void handleRegister(HttpExchange exchange) throws IOException {
        if (!methodIs(exchange, "POST")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        String body = readBody(exchange);
        Map<String,Object> obj;
        try {
            obj = Json.parseObject(body);
        } catch (Exception e) {
            sendJsonError(exchange, 400, "Invalid JSON");
            return;
        }
        String username = asString(obj.get("username"));
        String password = asString(obj.get("password"));
        if (username == null || !username.matches("^[a-zA-Z0-9_]{3,50}$")) {
            sendJsonError(exchange, 400, "Invalid username");
            return;
        }
        if (password == null || password.length() < 8) {
            sendJsonError(exchange, 400, "Password too short");
            return;
        }
        User user;
        synchronized (userLock) {
            if (usersByUsername.containsKey(username)) {
                sendJsonError(exchange, 409, "Username already exists");
                return;
            }
            int id = nextUserId.getAndIncrement();
            user = new User(id, username, hash(password));
            usersById.put(id, user);
            usersByUsername.put(username, user);
        }
        sendJson(exchange, 201, user.toJson());
    }

    private void handleLogin(HttpExchange exchange) throws IOException {
        if (!methodIs(exchange, "POST")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        String body = readBody(exchange);
        Map<String,Object> obj;
        try {
            obj = Json.parseObject(body);
        } catch (Exception e) {
            sendJsonError(exchange, 400, "Invalid JSON");
            return;
        }
        String username = asString(obj.get("username"));
        String password = asString(obj.get("password"));
        if (username == null || password == null) {
            sendJsonError(exchange, 401, "Invalid credentials");
            return;
        }
        User user = usersByUsername.get(username);
        if (user == null || !Objects.equals(user.passwordHash, hash(password))) {
            sendJsonError(exchange, 401, "Invalid credentials");
            return;
        }
        String token = UUID.randomUUID().toString().replace("-", "");
        sessions.put(token, user.id);
        Headers h = exchange.getResponseHeaders();
        h.add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        sendJson(exchange, 200, user.toJson());
    }

    private void handleLogout(HttpExchange exchange) throws IOException {
        if (!methodIs(exchange, "POST")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        Integer userId = requireAuth(exchange);
        if (userId == null) return; // response sent
        String token = getSessionToken(exchange.getRequestHeaders());
        if (token != null) {
            sessions.remove(token);
        }
        sendJson(exchange, 200, "{}");
    }

    private void handleMe(HttpExchange exchange) throws IOException {
        if (!methodIs(exchange, "GET")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        User user = usersById.get(userId);
        sendJson(exchange, 200, user.toJson());
    }

    private void handlePassword(HttpExchange exchange) throws IOException {
        if (!methodIs(exchange, "PUT")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        String body = readBody(exchange);
        Map<String,Object> obj;
        try { obj = Json.parseObject(body); } catch (Exception e) { sendJsonError(exchange, 400, "Invalid JSON"); return; }
        String oldPassword = asString(obj.get("old_password"));
        String newPassword = asString(obj.get("new_password"));
        User user = usersById.get(userId);
        if (oldPassword == null || !Objects.equals(user.passwordHash, hash(oldPassword))) {
            sendJsonError(exchange, 401, "Invalid credentials");
            return;
        }
        if (newPassword == null || newPassword.length() < 8) {
            sendJsonError(exchange, 400, "Password too short");
            return;
        }
        user.passwordHash = hash(newPassword);
        sendJson(exchange, 200, "{}");
    }

    private void handleTodosList(HttpExchange exchange) throws IOException {
        if (!methodIs(exchange, "GET")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        List<Todo> list = new ArrayList<>();
        for (Todo t : todosById.values()) {
            if (t.userId == userId) list.add(t);
        }
        list.sort(Comparator.comparingInt(t -> t.id));
        StringBuilder sb = new StringBuilder();
        sb.append('[');
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(list.get(i).toJson());
        }
        sb.append(']');
        sendJson(exchange, 200, sb.toString());
    }

    private void handleTodosCreate(HttpExchange exchange) throws IOException {
        if (!methodIs(exchange, "POST")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        String body = readBody(exchange);
        Map<String,Object> obj;
        try { obj = Json.parseObject(body); } catch (Exception e) { sendJsonError(exchange, 400, "Invalid JSON"); return; }
        String title = asString(obj.get("title"));
        String description = asString(obj.get("description"));
        if (title == null || title.trim().isEmpty()) {
            sendJsonError(exchange, 400, "Title is required");
            return;
        }
        if (description == null) description = "";
        int id = nextTodoId.getAndIncrement();
        String now = isoNow();
        Todo todo = new Todo(id, userId, title, description, false, now, now);
        todosById.put(id, todo);
        sendJson(exchange, 201, todo.toJson());
    }

    private void handleTodosGet(HttpExchange exchange, int id) throws IOException {
        if (!methodIs(exchange, "GET")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        Todo todo = todosById.get(id);
        if (todo == null || todo.userId != userId) {
            sendJsonError(exchange, 404, "Todo not found");
            return;
        }
        sendJson(exchange, 200, todo.toJson());
    }

    private void handleTodosUpdate(HttpExchange exchange, int id) throws IOException {
        if (!methodIs(exchange, "PUT")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        Todo todo = todosById.get(id);
        if (todo == null || todo.userId != userId) {
            sendJsonError(exchange, 404, "Todo not found");
            return;
        }
        String body = readBody(exchange);
        Map<String,Object> obj;
        try { obj = Json.parseObject(body); } catch (Exception e) { sendJsonError(exchange, 400, "Invalid JSON"); return; }
        if (obj.containsKey("title")) {
            String title = asString(obj.get("title"));
            if (title == null || title.trim().isEmpty()) {
                sendJsonError(exchange, 400, "Title is required");
                return;
            }
            todo.title = title;
        }
        if (obj.containsKey("description")) {
            String description = asString(obj.get("description"));
            todo.description = description == null ? "" : description;
        }
        if (obj.containsKey("completed")) {
            Boolean completed = asBoolean(obj.get("completed"));
            if (completed != null) todo.completed = completed;
        }
        todo.updatedAt = isoNow();
        sendJson(exchange, 200, todo.toJson());
    }

    private void handleTodosDelete(HttpExchange exchange, int id) throws IOException {
        if (!methodIs(exchange, "DELETE")) { sendJsonError(exchange, 405, "Method not allowed"); return; }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        Todo todo = todosById.get(id);
        if (todo == null || todo.userId != userId) {
            sendJsonError(exchange, 404, "Todo not found");
            return;
        }
        todosById.remove(id);
        // 204 No Content, no body and do not set Content-Type as per spec
        exchange.getResponseHeaders().remove("Content-Type");
        exchange.sendResponseHeaders(204, -1);
    }

    // Helpers
    private boolean methodIs(HttpExchange ex, String m) { return ex.getRequestMethod().equalsIgnoreCase(m); }

    private String readBody(HttpExchange exchange) throws IOException {
        try (InputStream is = exchange.getRequestBody()) {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
            return baos.toString(StandardCharsets.UTF_8);
        }
    }

    private void sendJson(HttpExchange exchange, int status, String json) throws IOException {
        Headers headers = exchange.getResponseHeaders();
        headers.set("Content-Type", "application/json");
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    private void sendJsonError(HttpExchange exchange, int status, String message) throws IOException {
        String json = "{\"error\":\"" + Json.escape(message) + "\"}";
        sendJson(exchange, status, json);
    }

    private void safeSendJsonError(HttpExchange exchange, int status, String message) {
        try {
            if (status == 204) {
                exchange.getResponseHeaders().remove("Content-Type");
                exchange.sendResponseHeaders(204, -1);
                return;
            }
            sendJsonError(exchange, status, message);
        } catch (IOException ignored) {}
    }

    private Integer requireAuth(HttpExchange exchange) throws IOException {
        String token = getSessionToken(exchange.getRequestHeaders());
        if (token == null) {
            sendJsonError(exchange, 401, "Authentication required");
            return null;
        }
        Integer uid = sessions.get(token);
        if (uid == null) {
            sendJsonError(exchange, 401, "Authentication required");
            return null;
        }
        return uid;
    }

    private String getSessionToken(Headers headers) {
        List<String> cookies = headers.get("Cookie");
        if (cookies == null) return null;
        for (String header : cookies) {
            String[] parts = header.split(";\\s*");
            for (String part : parts) {
                int eq = part.indexOf('=');
                if (eq <= 0) continue;
                String name = part.substring(0, eq).trim();
                String value = part.substring(eq + 1).trim();
                if (name.equals("session_id")) {
                    return value;
                }
            }
        }
        return null;
    }

    private static String isoNow() {
        Instant now = Instant.now().truncatedTo(ChronoUnit.SECONDS);
        return ISO_INSTANT_SECONDS.format(now);
    }

    private static String asString(Object o) {
        if (o == null) return null;
        if (o instanceof String) return (String) o;
        return String.valueOf(o);
    }

    private static Boolean asBoolean(Object o) {
        if (o == null) return null;
        if (o instanceof Boolean) return (Boolean) o;
        if (o instanceof String) {
            String s = ((String)o).trim().toLowerCase(Locale.ROOT);
            if ("true".equals(s)) return true; if ("false".equals(s)) return false;
        }
        return null;
    }

    private static String hash(String s) {
        // Simple SHA-256 hex
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    // Minimal JSON utilities
    static class Json {
        static Map<String,Object> parseObject(String s) { return new Parser(s).parseObject(); }
        static String escape(String s) {
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

        private static class Parser {
            private final String s; int i = 0;
            Parser(String s) { this.s = s == null ? "" : s; }
            Map<String,Object> parseObject() {
                skipWs();
                expect('{');
                Map<String,Object> map = new LinkedHashMap<>();
                skipWs();
                if (peek() == '}') { i++; return map; }
                while (true) {
                    skipWs();
                    String key = parseString();
                    skipWs();
                    expect(':');
                    skipWs();
                    Object val = parseValue();
                    map.put(key, val);
                    skipWs();
                    char c = peek();
                    if (c == ',') { i++; continue; }
                    if (c == '}') { i++; break; }
                    throw error("Expected ',' or '}'");
                }
                skipWs();
                if (i != s.length()) {
                    // Allow trailing whitespace
                    skipWs();
                }
                return map;
            }
            private Object parseValue() {
                char c = peek();
                if (c == '"') return parseString();
                if (c == 't') { expectWord("true"); return Boolean.TRUE; }
                if (c == 'f') { expectWord("false"); return Boolean.FALSE; }
                if (c == 'n') { expectWord("null"); return null; }
                if (c == '-' || (c >= '0' && c <= '9')) return parseNumber();
                // For our usage, arrays/objects are not expected in request bodies
                throw error("Unexpected value");
            }
            private Number parseNumber() {
                int start = i; char c;
                if (peek() == '-') i++;
                while (i < s.length()) { c = s.charAt(i); if (c < '0' || c > '9') break; i++; }
                if (i < s.length() && s.charAt(i) == '.') { i++; while (i < s.length()) { c = s.charAt(i); if (c < '0' || c > '9') break; i++; } }
                String num = s.substring(start, i);
                try {
                    if (num.contains(".")) return Double.parseDouble(num);
                    long l = Long.parseLong(num);
                    if (l <= Integer.MAX_VALUE && l >= Integer.MIN_VALUE) return (int) l; else return l;
                } catch (NumberFormatException e) {
                    throw error("Invalid number");
                }
            }
            private String parseString() {
                expect('"');
                StringBuilder sb = new StringBuilder();
                while (i < s.length()) {
                    char c = s.charAt(i++);
                    if (c == '"') break;
                    if (c == '\\') {
                        if (i >= s.length()) throw error("Invalid escape");
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
                                if (i + 4 > s.length()) throw error("Invalid unicode escape");
                                String hex = s.substring(i, i+4);
                                try { int cp = Integer.parseInt(hex, 16); sb.append((char)cp); } catch (NumberFormatException ex) { throw error("Invalid unicode escape"); }
                                i += 4; break;
                            default: throw error("Invalid escape");
                        }
                    } else {
                        sb.append(c);
                    }
                }
                return sb.toString();
            }
            private void skipWs() { while (i < s.length()) { char c = s.charAt(i); if (c==' '||c=='\n'||c=='\r'||c=='\t') i++; else break; } }
            private void expect(char ch) { skipWs(); if (i >= s.length() || s.charAt(i) != ch) throw error("Expected '"+ch+"'"); i++; }
            private void expectWord(String w) { for (int k=0;k<w.length();k++) { if (i+k>=s.length()||s.charAt(i+k)!=w.charAt(k)) throw error("Expected '"+w+"'"); } i+=w.length(); }
            private char peek() { if (i >= s.length()) throw error("Unexpected end"); return s.charAt(i); }
            private RuntimeException error(String m) { return new RuntimeException("JSON parse error at pos "+i+": "+m); }
        }
    }
}

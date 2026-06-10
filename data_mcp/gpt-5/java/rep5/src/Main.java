import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.*;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class Main {
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
        TodoApp app = new TodoApp();
        server.createContext("/", app);
        ThreadPoolExecutor threadPoolExecutor = (ThreadPoolExecutor) Executors.newFixedThreadPool(16);
        server.setExecutor(threadPoolExecutor);
        server.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }
}

class TodoApp implements HttpHandler {
    private final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    private final Map<Integer, User> usersById = new ConcurrentHashMap<>();
    private final Map<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId
    private final Map<Integer, Todo> todos = new ConcurrentHashMap<>();

    private final AtomicInteger userIdSeq = new AtomicInteger(1);
    private final AtomicInteger todoIdSeq = new AtomicInteger(1);

    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");

    private static final DateTimeFormatter ISO_UTC = DateTimeFormatter.ISO_INSTANT.withZone(ZoneOffset.UTC);

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        try {
            route(exchange);
        } catch (Exception e) {
            // As safety net, return 500 with JSON error
            e.printStackTrace();
            sendJson(exchange, 500, Json.error("Internal server error"));
        } finally {
            try { exchange.close(); } catch (Exception ignore) {}
        }
    }

    private void route(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod();
        URI uri = exchange.getRequestURI();
        String path = uri.getPath();
        
        if (method.equals("POST") && path.equals("/register")) { handleRegister(exchange); return; }
        if (method.equals("POST") && path.equals("/login")) { handleLogin(exchange); return; }
        if (method.equals("POST") && path.equals("/logout")) { handleLogout(exchange); return; }
        if (method.equals("GET") && path.equals("/me")) { handleMe(exchange); return; }
        if (method.equals("PUT") && path.equals("/password")) { handlePassword(exchange); return; }
        if (path.equals("/todos")) {
            if (method.equals("GET")) { handleTodosList(exchange); return; }
            if (method.equals("POST")) { handleTodosCreate(exchange); return; }
        }
        if (path.startsWith("/todos/")) {
            String rest = path.substring("/todos/".length());
            if (rest.isEmpty() || rest.contains("/")) {
                sendJson(exchange, 404, Json.error("Not found"));
                return;
            }
            int id;
            try { id = Integer.parseInt(rest); } catch (NumberFormatException nfe) { sendJson(exchange, 404, Json.error("Not found")); return; }
            if (method.equals("GET")) { handleTodoGet(exchange, id); return; }
            if (method.equals("PUT")) { handleTodoUpdate(exchange, id); return; }
            if (method.equals("DELETE")) { handleTodoDelete(exchange, id); return; }
        }
        sendJson(exchange, 404, Json.error("Not found"));
    }

    private void handleRegister(HttpExchange exchange) throws IOException {
        String body = readBody(exchange);
        Map<String, Object> obj = Json.parseObject(body);
        String username = safeString(obj.get("username"));
        String password = safeString(obj.get("password"));

        if (username == null || !USERNAME_PATTERN.matcher(username).matches()) {
            sendJson(exchange, 400, Json.error("Invalid username"));
            return;
        }
        if (password == null || password.length() < 8) {
            sendJson(exchange, 400, Json.error("Password too short"));
            return;
        }
        synchronized (this) {
            if (usersByUsername.containsKey(username)) {
                sendJson(exchange, 409, Json.error("Username already exists"));
                return;
            }
            int id = userIdSeq.getAndIncrement();
            User user = new User(id, username, password);
            usersByUsername.put(username, user);
            usersById.put(id, user);
            sendJson(exchange, 201, user.toJsonPublic());
        }
    }

    private void handleLogin(HttpExchange exchange) throws IOException {
        String body = readBody(exchange);
        Map<String, Object> obj = Json.parseObject(body);
        String username = safeString(obj.get("username"));
        String password = safeString(obj.get("password"));
        if (username == null || password == null) {
            sendJson(exchange, 401, Json.error("Invalid credentials"));
            return;
        }
        User user = usersByUsername.get(username);
        if (user == null || !user.password.equals(password)) {
            sendJson(exchange, 401, Json.error("Invalid credentials"));
            return;
        }
        String token = UUID.randomUUID().toString().replace("-", "");
        sessions.put(token, user.id);
        Headers headers = exchange.getResponseHeaders();
        headers.add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        sendJson(exchange, 200, user.toJsonPublic());
    }

    private void handleLogout(HttpExchange exchange) throws IOException {
        User user = authenticate(exchange);
        if (user == null) return; // authenticate() already responded
        String token = getSessionToken(exchange);
        if (token != null) {
            sessions.remove(token);
        }
        sendJson(exchange, 200, "{}");
    }

    private void handleMe(HttpExchange exchange) throws IOException {
        User user = authenticate(exchange);
        if (user == null) return;
        sendJson(exchange, 200, user.toJsonPublic());
    }

    private void handlePassword(HttpExchange exchange) throws IOException {
        User user = authenticate(exchange);
        if (user == null) return;
        String body = readBody(exchange);
        Map<String, Object> obj = Json.parseObject(body);
        String oldp = safeString(obj.get("old_password"));
        String newp = safeString(obj.get("new_password"));
        if (oldp == null || !user.password.equals(oldp)) {
            sendJson(exchange, 401, Json.error("Invalid credentials"));
            return;
        }
        if (newp == null || newp.length() < 8) {
            sendJson(exchange, 400, Json.error("Password too short"));
            return;
        }
        user.password = newp;
        sendJson(exchange, 200, "{}");
    }

    private void handleTodosList(HttpExchange exchange) throws IOException {
        User user = authenticate(exchange);
        if (user == null) return;
        List<Todo> list = new ArrayList<>();
        for (Todo t : todos.values()) {
            if (t.userId == user.id) list.add(t);
        }
        list.sort(Comparator.comparingInt(t -> t.id));
        sendJson(exchange, 200, Json.todosArray(list));
    }

    private void handleTodosCreate(HttpExchange exchange) throws IOException {
        User user = authenticate(exchange);
        if (user == null) return;
        String body = readBody(exchange);
        Map<String, Object> obj = Json.parseObject(body);
        String title = safeString(obj.get("title"));
        String description = obj.containsKey("description") ? safeString(obj.get("description")) : "";
        if (title == null || title.trim().isEmpty()) {
            sendJson(exchange, 400, Json.error("Title is required"));
            return;
        }
        int id = todoIdSeq.getAndIncrement();
        String now = nowIso();
        Todo todo = new Todo(id, user.id, title, description == null ? "" : description, false, now, now);
        todos.put(id, todo);
        sendJson(exchange, 201, todo.toJson());
    }

    private void handleTodoGet(HttpExchange exchange, int id) throws IOException {
        User user = authenticate(exchange);
        if (user == null) return;
        Todo todo = todos.get(id);
        if (todo == null || todo.userId != user.id) {
            sendJson(exchange, 404, Json.error("Todo not found"));
            return;
        }
        sendJson(exchange, 200, todo.toJson());
    }

    private void handleTodoUpdate(HttpExchange exchange, int id) throws IOException {
        User user = authenticate(exchange);
        if (user == null) return;
        Todo todo = todos.get(id);
        if (todo == null || todo.userId != user.id) {
            sendJson(exchange, 404, Json.error("Todo not found"));
            return;
        }
        String body = readBody(exchange);
        Map<String, Object> obj = Json.parseObject(body);
        boolean modified = false;
        if (obj.containsKey("title")) {
            String title = safeString(obj.get("title"));
            if (title == null || title.trim().isEmpty()) {
                sendJson(exchange, 400, Json.error("Title is required"));
                return;
            }
            todo.title = title;
            modified = true;
        }
        if (obj.containsKey("description")) {
            String description = safeString(obj.get("description"));
            todo.description = description == null ? "" : description;
            modified = true;
        }
        if (obj.containsKey("completed")) {
            Object c = obj.get("completed");
            if (c instanceof Boolean) {
                todo.completed = (Boolean) c;
                modified = true;
            }
        }
        if (modified) {
            todo.updated_at = nowIso();
        }
        sendJson(exchange, 200, todo.toJson());
    }

    private void handleTodoDelete(HttpExchange exchange, int id) throws IOException {
        User user = authenticate(exchange);
        if (user == null) return;
        Todo todo = todos.get(id);
        if (todo == null || todo.userId != user.id) {
            // for DELETE, still return JSON error and content-type? Spec: DELETE returns no body only on success
            sendJson(exchange, 404, Json.error("Todo not found"));
            return;
        }
        todos.remove(id);
        // 204 No Content, no body
        exchange.sendResponseHeaders(204, -1);
    }

    private User authenticate(HttpExchange exchange) throws IOException {
        String token = getSessionToken(exchange);
        if (token == null) {
            sendJson(exchange, 401, Json.error("Authentication required"));
            return null;
        }
        Integer userId = sessions.get(token);
        if (userId == null) {
            sendJson(exchange, 401, Json.error("Authentication required"));
            return null;
        }
        User user = usersById.get(userId);
        if (user == null) {
            sendJson(exchange, 401, Json.error("Authentication required"));
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

    private static String nowIso() {
        Instant now = Instant.now().truncatedTo(ChronoUnit.SECONDS);
        return ISO_UTC.format(now);
    }

    private static String readBody(HttpExchange exchange) throws IOException {
        InputStream is = exchange.getRequestBody();
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int r;
        int total = 0;
        while ((r = is.read(buf)) != -1) {
            baos.write(buf, 0, r);
            total += r;
            if (total > 1024 * 1024) { // 1MB limit
                break;
            }
        }
        return baos.toString(StandardCharsets.UTF_8);
    }

    private static void sendJson(HttpExchange exchange, int status, String jsonBody) throws IOException {
        Headers headers = exchange.getResponseHeaders();
        headers.set("Content-Type", "application/json");
        byte[] bytes = jsonBody.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static String safeString(Object o) {
        if (o == null) return null;
        if (o instanceof String) return (String) o;
        return String.valueOf(o);
    }
}

class User {
    public final int id;
    public final String username;
    public String password; // stored in plain for simplicity (in-memory demo)

    public User(int id, String username, String password) {
        this.id = id;
        this.username = username;
        this.password = password;
    }

    public String toJsonPublic() {
        return "{" +
                "\"id\":" + id + "," +
                "\"username\":\"" + Json.escape(username) + "\"" +
                "}";
    }
}

class Todo {
    public final int id;
    public final int userId;
    public String title;
    public String description;
    public boolean completed;
    public final String created_at;
    public String updated_at;

    public Todo(int id, int userId, String title, String description, boolean completed, String created_at, String updated_at) {
        this.id = id;
        this.userId = userId;
        this.title = title;
        this.description = description;
        this.completed = completed;
        this.created_at = created_at;
        this.updated_at = updated_at;
    }

    public String toJson() {
        StringBuilder sb = new StringBuilder();
        sb.append('{');
        sb.append("\"id\":").append(id).append(',');
        sb.append("\"title\":\"").append(Json.escape(title)).append("\",");
        sb.append("\"description\":\"").append(Json.escape(description)).append("\",");
        sb.append("\"completed\":").append(completed).append(',');
        sb.append("\"created_at\":\"").append(Json.escape(created_at)).append("\",");
        sb.append("\"updated_at\":\"").append(Json.escape(updated_at)).append("\"");
        sb.append('}');
        return sb.toString();
    }
}

class Json {
    // Very small JSON utilities for this specific API
    public static String escape(String s) {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder(s.length() + 16);
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

    public static String error(String msg) {
        return "{\"error\":\"" + escape(msg) + "\"}";
    }

    public static String todosArray(List<Todo> list) {
        StringBuilder sb = new StringBuilder();
        sb.append('[');
        boolean first = true;
        for (Todo t : list) {
            if (!first) sb.append(',');
            first = false;
            sb.append(t.toJson());
        }
        sb.append(']');
        return sb.toString();
    }

    public static Map<String, Object> parseObject(String s) throws IOException {
        Map<String, Object> map = new LinkedHashMap<>();
        if (s == null) return map;
        int[] idx = new int[]{0};
        skipWs(s, idx);
        if (idx[0] >= s.length() || s.charAt(idx[0]) != '{') return map; // empty map if malformed
        idx[0]++;
        skipWs(s, idx);
        while (idx[0] < s.length() && s.charAt(idx[0]) != '}') {
            skipWs(s, idx);
            String key = parseString(s, idx);
            if (key == null) { break; }
            skipWs(s, idx);
            if (idx[0] >= s.length() || s.charAt(idx[0]) != ':') break;
            idx[0]++;
            skipWs(s, idx);
            Object val = parseValue(s, idx);
            map.put(key, val);
            skipWs(s, idx);
            if (idx[0] < s.length() && s.charAt(idx[0]) == ',') {
                idx[0]++;
                skipWs(s, idx);
            } else {
                break;
            }
        }
        // move to closing brace if present
        while (idx[0] < s.length() && s.charAt(idx[0]) != '}') idx[0]++;
        if (idx[0] < s.length() && s.charAt(idx[0]) == '}') idx[0]++;
        return map;
    }

    private static void skipWs(String s, int[] idx) {
        while (idx[0] < s.length()) {
            char c = s.charAt(idx[0]);
            if (c == ' ' || c == '\n' || c == '\r' || c == '\t') idx[0]++; else break;
        }
    }

    private static String parseString(String s, int[] idx) {
        if (idx[0] >= s.length() || s.charAt(idx[0]) != '"') return null;
        idx[0]++;
        StringBuilder sb = new StringBuilder();
        while (idx[0] < s.length()) {
            char c = s.charAt(idx[0]++);
            if (c == '"') break;
            if (c == '\\') {
                if (idx[0] >= s.length()) break;
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
                        if (idx[0] + 4 <= s.length()) {
                            String hex = s.substring(idx[0], idx[0] + 4);
                            try { sb.append((char) Integer.parseInt(hex, 16)); } catch (Exception ex) { /* ignore */ }
                            idx[0] += 4;
                        }
                        break;
                    default: sb.append(e); break;
                }
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    private static Object parseValue(String s, int[] idx) {
        if (idx[0] >= s.length()) return null;
        char c = s.charAt(idx[0]);
        if (c == '"') return parseString(s, idx);
        if (c == 't' && s.startsWith("true", idx[0])) { idx[0] += 4; return Boolean.TRUE; }
        if (c == 'f' && s.startsWith("false", idx[0])) { idx[0] += 5; return Boolean.FALSE; }
        // null or number or other types are not expected; try to parse null
        if (c == 'n' && s.startsWith("null", idx[0])) { idx[0] += 4; return null; }
        // skip non-string primitive token
        int start = idx[0];
        while (idx[0] < s.length()) {
            char ch = s.charAt(idx[0]);
            if (ch == ',' || ch == '}' || ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' || ch == ']') break;
            idx[0]++;
        }
        String raw = s.substring(start, idx[0]).trim();
        if (raw.isEmpty()) return null;
        return raw;
    }
}

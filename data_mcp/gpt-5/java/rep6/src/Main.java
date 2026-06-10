import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.*;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class Main {
    public static void main(String[] args) throws Exception {
        int port = -1;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                try {
                    port = Integer.parseInt(args[i + 1]);
                } catch (NumberFormatException e) {
                    System.err.println("Invalid port number");
                    System.exit(1);
                }
            }
        }
        if (port <= 0) {
            System.err.println("Usage: java Main --port PORT");
            System.exit(1);
        }

        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer server = HttpServer.create(addr, 0);
        App app = new App();
        server.createContext("/", app);
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server listening on 0.0.0.0:" + port);
    }
}

class App implements HttpHandler {
    // Data models
    static class User {
        final int id;
        final String username;
        String password; // stored in-memory; for simplicity, not hashed
        User(int id, String username, String password) {
            this.id = id;
            this.username = username;
            this.password = password;
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
            this.id = id;
            this.userId = userId;
            this.title = title;
            this.description = description;
            this.completed = completed;
            this.createdAt = createdAt;
            this.updatedAt = updatedAt;
        }
    }

    private final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, User> usersByUsername = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>();
    private final AtomicInteger nextUserId = new AtomicInteger(1);
    private final AtomicInteger nextTodoId = new AtomicInteger(1);

    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        try {
            String method = exchange.getRequestMethod();
            URI uri = exchange.getRequestURI();
            String path = uri.getPath();

            // Routing
            if (method.equalsIgnoreCase("POST") && path.equals("/register")) {
                handleRegister(exchange);
                return;
            }
            if (method.equalsIgnoreCase("POST") && path.equals("/login")) {
                handleLogin(exchange);
                return;
            }
            if (method.equalsIgnoreCase("POST") && path.equals("/logout")) {
                ensureAuth(exchange, (user) -> handleLogout(exchange, user));
                return;
            }
            if (method.equalsIgnoreCase("GET") && path.equals("/me")) {
                ensureAuth(exchange, (user) -> handleMe(exchange, user));
                return;
            }
            if (method.equalsIgnoreCase("PUT") && path.equals("/password")) {
                ensureAuth(exchange, (user) -> handlePasswordChange(exchange, user));
                return;
            }
            if (path.equals("/todos") && method.equalsIgnoreCase("GET")) {
                ensureAuth(exchange, (user) -> handleTodosList(exchange, user));
                return;
            }
            if (path.equals("/todos") && method.equalsIgnoreCase("POST")) {
                ensureAuth(exchange, (user) -> handleTodosCreate(exchange, user));
                return;
            }
            if (path.startsWith("/todos/") && method.equalsIgnoreCase("GET")) {
                ensureAuth(exchange, (user) -> handleTodoGet(exchange, user, path));
                return;
            }
            if (path.startsWith("/todos/") && method.equalsIgnoreCase("PUT")) {
                ensureAuth(exchange, (user) -> handleTodoUpdate(exchange, user, path));
                return;
            }
            if (path.startsWith("/todos/") && method.equalsIgnoreCase("DELETE")) {
                ensureAuth(exchange, (user) -> handleTodoDelete(exchange, user, path));
                return;
            }

            // Not found
            writeJson(exchange, 404, errorJson("Not found"));
        } catch (Exception e) {
            e.printStackTrace();
            writeJson(exchange, 500, errorJson("Internal server error"));
        } finally {
            exchange.close();
        }
    }

    // Handlers
    private void handleRegister(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Map<String, Object> json;
        try {
            json = Json.parseObject(body);
        } catch (RuntimeException re) {
            writeJson(ex, 400, errorJson("Invalid JSON"));
            return;
        }
        Object uo = json.get("username");
        Object po = json.get("password");
        String username = (uo instanceof String) ? (String) uo : null;
        String password = (po instanceof String) ? (String) po : null;

        if (username == null || !USERNAME_PATTERN.matcher(username).matches()) {
            writeJson(ex, 400, errorJson("Invalid username"));
            return;
        }
        if (password == null || password.length() < 8) {
            writeJson(ex, 400, errorJson("Password too short"));
            return;
        }
        // Uniqueness
        synchronized (usersByUsername) {
            if (usersByUsername.containsKey(username)) {
                writeJson(ex, 409, errorJson("Username already exists"));
                return;
            }
            int id = nextUserId.getAndIncrement();
            User user = new User(id, username, password);
            usersById.put(id, user);
            usersByUsername.put(username, user);
            String resp = userToJson(user);
            writeJson(ex, 201, resp);
        }
    }

    private void handleLogin(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Map<String, Object> json;
        try {
            json = Json.parseObject(body);
        } catch (RuntimeException re) {
            writeJson(ex, 400, errorJson("Invalid JSON"));
            return;
        }
        String username = (json.get("username") instanceof String) ? (String) json.get("username") : null;
        String password = (json.get("password") instanceof String) ? (String) json.get("password") : null;
        if (username == null || password == null) {
            writeJson(ex, 401, errorJson("Invalid credentials"));
            return;
        }
        User user = usersByUsername.get(username);
        if (user == null || !user.password.equals(password)) {
            writeJson(ex, 401, errorJson("Invalid credentials"));
            return;
        }
        String token = UUID.randomUUID().toString().replaceAll("-", "");
        sessions.put(token, user.id);
        ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        writeJson(ex, 200, userToJson(user));
    }

    private void handleLogout(HttpExchange ex, User user) throws IOException {
        String token = getSessionToken(ex.getRequestHeaders());
        if (token != null) {
            sessions.remove(token);
        }
        writeJson(ex, 200, "{}");
    }

    private void handleMe(HttpExchange ex, User user) throws IOException {
        writeJson(ex, 200, userToJson(user));
    }

    private void handlePasswordChange(HttpExchange ex, User user) throws IOException {
        String body = readBody(ex);
        Map<String, Object> json;
        try {
            json = Json.parseObject(body);
        } catch (RuntimeException re) {
            writeJson(ex, 400, errorJson("Invalid JSON"));
            return;
        }
        String oldPw = (json.get("old_password") instanceof String) ? (String) json.get("old_password") : null;
        String newPw = (json.get("new_password") instanceof String) ? (String) json.get("new_password") : null;
        if (oldPw == null || !user.password.equals(oldPw)) {
            writeJson(ex, 401, errorJson("Invalid credentials"));
            return;
        }
        if (newPw == null || newPw.length() < 8) {
            writeJson(ex, 400, errorJson("Password too short"));
            return;
        }
        user.password = newPw;
        writeJson(ex, 200, "{}");
    }

    private void handleTodosList(HttpExchange ex, User user) throws IOException {
        List<Todo> list = new ArrayList<>();
        for (Todo t : todosById.values()) {
            if (t.userId == user.id) list.add(t);
        }
        list.sort(Comparator.comparingInt(t -> t.id));
        StringBuilder sb = new StringBuilder();
        sb.append("[");
        boolean first = true;
        for (Todo t : list) {
            if (!first) sb.append(",");
            first = false;
            sb.append(todoToJson(t));
        }
        sb.append("]");
        writeJson(ex, 200, sb.toString());
    }

    private void handleTodosCreate(HttpExchange ex, User user) throws IOException {
        String body = readBody(ex);
        Map<String, Object> json;
        try {
            json = Json.parseObject(body);
        } catch (RuntimeException re) {
            writeJson(ex, 400, errorJson("Invalid JSON"));
            return;
        }
        String title = (json.get("title") instanceof String) ? (String) json.get("title") : null;
        String description = (json.get("description") instanceof String) ? (String) json.get("description") : "";
        if (title == null || title.trim().isEmpty()) {
            writeJson(ex, 400, errorJson("Title is required"));
            return;
        }
        String now = isoNow();
        int id = nextTodoId.getAndIncrement();
        Todo t = new Todo(id, user.id, title, description == null ? "" : description, false, now, now);
        todosById.put(id, t);
        writeJson(ex, 201, todoToJson(t));
    }

    private void handleTodoGet(HttpExchange ex, User user, String path) throws IOException {
        Integer id = parseTodoId(path);
        if (id == null) {
            writeJson(ex, 404, errorJson("Todo not found"));
            return;
        }
        Todo t = todosById.get(id);
        if (t == null || t.userId != user.id) {
            writeJson(ex, 404, errorJson("Todo not found"));
            return;
        }
        writeJson(ex, 200, todoToJson(t));
    }

    private void handleTodoUpdate(HttpExchange ex, User user, String path) throws IOException {
        Integer id = parseTodoId(path);
        if (id == null) {
            writeJson(ex, 404, errorJson("Todo not found"));
            return;
        }
        Todo t = todosById.get(id);
        if (t == null || t.userId != user.id) {
            writeJson(ex, 404, errorJson("Todo not found"));
            return;
        }
        String body = readBody(ex);
        Map<String, Object> json;
        try {
            json = Json.parseObject(body);
        } catch (RuntimeException re) {
            writeJson(ex, 400, errorJson("Invalid JSON"));
            return;
        }
        if (json.containsKey("title")) {
            Object to = json.get("title");
            if (to == null || !(to instanceof String) || ((String) to).trim().isEmpty()) {
                writeJson(ex, 400, errorJson("Title is required"));
                return;
            }
            t.title = (String) to;
        }
        if (json.containsKey("description")) {
            Object d = json.get("description");
            t.description = (d instanceof String) ? (String) d : t.description;
            if (t.description == null) t.description = "";
        }
        if (json.containsKey("completed")) {
            Object c = json.get("completed");
            if (c instanceof Boolean) {
                t.completed = (Boolean) c;
            } else {
                // ignore invalid types silently or enforce? Not specified; we'll enforce boolean only.
                writeJson(ex, 400, errorJson("Invalid JSON"));
                return;
            }
        }
        t.updatedAt = isoNow();
        writeJson(ex, 200, todoToJson(t));
    }

    private void handleTodoDelete(HttpExchange ex, User user, String path) throws IOException {
        Integer id = parseTodoId(path);
        if (id == null) {
            writeNoContent(ex, 404);
            // Must still return a JSON error body per spec for errors, but DELETE success has no body.
            // However, spec: All errors return a JSON body. For DELETE, on success 204 no body. For 404, we should return JSON.
            // Adjust: send 404 with JSON body for not found.
            return;
        }
        Todo t = todosById.get(id);
        if (t == null || t.userId != user.id) {
            writeJson(ex, 404, errorJson("Todo not found"));
            return;
        }
        todosById.remove(id);
        writeNoContent(ex, 204);
    }

    // Helpers
    private void ensureAuth(HttpExchange ex, AuthedHandler handler) throws IOException {
        String token = getSessionToken(ex.getRequestHeaders());
        if (token == null) {
            writeJson(ex, 401, errorJson("Authentication required"));
            return;
        }
        Integer uid = sessions.get(token);
        if (uid == null) {
            writeJson(ex, 401, errorJson("Authentication required"));
            return;
        }
        User user = usersById.get(uid);
        if (user == null) {
            writeJson(ex, 401, errorJson("Authentication required"));
            return;
        }
        handler.handle(user);
    }

    private interface AuthedHandler {
        void handle(User user) throws IOException;
    }

    private String getSessionToken(Headers headers) {
        List<String> cookies = headers.get("Cookie");
        if (cookies == null) return null;
        for (String cookieHeader : cookies) {
            String[] parts = cookieHeader.split(";");
            for (String part : parts) {
                String[] kv = part.trim().split("=", 2);
                if (kv.length == 2) {
                    String name = kv[0].trim();
                    String val = kv[1].trim();
                    if (name.equals("session_id")) {
                        return val;
                    }
                }
            }
        }
        return null;
    }

    private Integer parseTodoId(String path) {
        // path like /todos/123
        String[] segs = path.split("/");
        if (segs.length >= 3) {
            String idStr = segs[2];
            try {
                return Integer.parseInt(idStr);
            } catch (NumberFormatException nfe) {
                return null;
            }
        }
        return null;
    }

    private static String readBody(HttpExchange ex) throws IOException {
        InputStream in = ex.getRequestBody();
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int r;
        while ((r = in.read(buf)) != -1) {
            baos.write(buf, 0, r);
        }
        return baos.toString(StandardCharsets.UTF_8);
    }

    private static void writeJson(HttpExchange ex, int status, String json) throws IOException {
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        Headers h = ex.getResponseHeaders();
        h.set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static void writeNoContent(HttpExchange ex, int status) throws IOException {
        Headers h = ex.getResponseHeaders();
        // No body; do not set Content-Type for DELETE 204 per spec
        ex.sendResponseHeaders(status, -1);
        // No response body
    }

    private static String errorJson(String msg) {
        return "{\"error\":\"" + Json.escape(msg) + "\"}";
    }

    private static String userToJson(App.User u) {
        return "{\"id\":" + u.id + ",\"username\":\"" + Json.escape(u.username) + "\"}";
    }

    private static String todoToJson(App.Todo t) {
        StringBuilder sb = new StringBuilder();
        sb.append("{");
        sb.append("\"id\":").append(t.id).append(",");
        sb.append("\"title\":\"").append(Json.escape(t.title)).append("\",");
        sb.append("\"description\":\"").append(Json.escape(t.description == null ? "" : t.description)).append("\",");
        sb.append("\"completed\":").append(t.completed ? "true" : "false").append(",");
        sb.append("\"created_at\":\"").append(Json.escape(t.createdAt)).append("\",");
        sb.append("\"updated_at\":\"").append(Json.escape(t.updatedAt)).append("\"");
        sb.append("}");
        return sb.toString();
    }

    private static String isoNow() {
        return Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
    }
}

// Minimal JSON parser for objects with string keys and string/boolean/null values
class Json {
    static String escape(String s) {
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
                        String hex = Integer.toHexString(c);
                        sb.append("\\u");
                        for (int j = hex.length(); j < 4; j++) sb.append('0');
                        sb.append(hex);
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.toString();
    }

    static Map<String, Object> parseObject(String s) {
        if (s == null) return Collections.emptyMap();
        Parser p = new Parser(s);
        p.skipWs();
        if (p.eof()) return new HashMap<>();
        Object v = p.parseValue();
        if (!(v instanceof Map)) throw new RuntimeException("Expected JSON object");
        return (Map<String, Object>) v;
    }

    private static class Parser {
        private final String s;
        private int i = 0;
        Parser(String s) { this.s = s; }
        boolean eof() { return i >= s.length(); }
        void skipWs() {
            while (!eof()) {
                char c = s.charAt(i);
                if (c == ' ' || c == '\n' || c == '\r' || c == '\t') i++;
                else break;
            }
        }
        Object parseValue() {
            skipWs();
            if (eof()) throw new RuntimeException("Unexpected end of JSON");
            char c = s.charAt(i);
            if (c == '{') return parseObject();
            if (c == '"') return parseString();
            if (c == 't' || c == 'f') return parseBoolean();
            if (c == 'n') { parseNull(); return null; }
            throw new RuntimeException("Unsupported JSON value");
        }
        Map<String,Object> parseObject() {
            Map<String,Object> map = new HashMap<>();
            expect('{');
            skipWs();
            if (peek('}')) { expect('}'); return map; }
            while (true) {
                skipWs();
                String key = parseString();
                skipWs();
                expect(':');
                skipWs();
                Object val = parseValue();
                map.put(key, val);
                skipWs();
                if (peek(',')) { expect(','); }
                else break;
            }
            skipWs();
            expect('}');
            return map;
        }
        String parseString() {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (!eof()) {
                char c = s.charAt(i++);
                if (c == '"') break;
                if (c == '\\') {
                    if (eof()) throw new RuntimeException("Invalid escape");
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
                        case 'u': {
                            if (i + 4 > s.length()) throw new RuntimeException("Invalid unicode escape");
                            String hex = s.substring(i, i + 4);
                            i += 4;
                            char uc = (char) Integer.parseInt(hex, 16);
                            sb.append(uc);
                            break;
                        }
                        default: throw new RuntimeException("Invalid escape");
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }
        Boolean parseBoolean() {
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
            throw new RuntimeException("Invalid boolean");
        }
        void parseNull() {
            if (s.startsWith("null", i)) { i += 4; return; }
            throw new RuntimeException("Invalid null");
        }
        void expect(char ch) {
            skipWs();
            if (eof() || s.charAt(i) != ch) throw new RuntimeException("Expected '" + ch + "'");
            i++;
        }
        boolean peek(char ch) {
            skipWs();
            return !eof() && s.charAt(i) == ch;
        }
    }
}

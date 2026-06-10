import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;

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
        server.createContext("/", app::handle);
        server.setExecutor(Executors.newFixedThreadPool(8));
        server.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }
}

class TodoApp {
    private final Map<Integer, User> usersById = new ConcurrentHashMap<>();
    private final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    private final Map<String, Integer> sessions = new ConcurrentHashMap<>(); // sessionId -> userId
    private final Map<Integer, Todo> todosById = new ConcurrentHashMap<>();
    private final AtomicCounter userIdSeq = new AtomicCounter(1);
    private final AtomicCounter todoIdSeq = new AtomicCounter(1);

    private static final DateTimeFormatter ISO_INSTANT_SECONDS = DateTimeFormatter.ISO_INSTANT;

    public void handle(HttpExchange ex) throws IOException {
        try {
            String method = ex.getRequestMethod();
            URI uri = ex.getRequestURI();
            String path = uri.getPath();

            // Routing
            if (method.equals("POST") && path.equals("/register")) {
                handleRegister(ex);
                return;
            }
            if (method.equals("POST") && path.equals("/login")) {
                handleLogin(ex);
                return;
            }
            if (method.equals("POST") && path.equals("/logout")) {
                withAuth(ex, (user) -> handleLogout(ex, user));
                return;
            }
            if (method.equals("GET") && path.equals("/me")) {
                withAuth(ex, (user) -> handleMe(ex, user));
                return;
            }
            if (method.equals("PUT") && path.equals("/password")) {
                withAuth(ex, (user) -> handlePassword(ex, user));
                return;
            }
            if (path.equals("/todos") && method.equals("GET")) {
                withAuth(ex, (user) -> handleTodosList(ex, user));
                return;
            }
            if (path.equals("/todos") && method.equals("POST")) {
                withAuth(ex, (user) -> handleTodosCreate(ex, user));
                return;
            }
            if (path.startsWith("/todos/") && method.equals("GET")) {
                withAuth(ex, (user) -> handleTodosGet(ex, user));
                return;
            }
            if (path.startsWith("/todos/") && method.equals("PUT")) {
                withAuth(ex, (user) -> handleTodosUpdate(ex, user));
                return;
            }
            if (path.startsWith("/todos/") && method.equals("DELETE")) {
                withAuth(ex, (user) -> handleTodosDelete(ex, user));
                return;
            }

            sendJson(ex, 404, Json.err("Not found"));
        } catch (Exception e) {
            // For safety, catch-all
            e.printStackTrace();
            sendJson(ex, 500, Json.err("Internal server error"));
        }
    }

    private interface Authed {
        void run(User user) throws IOException;
    }

    private void withAuth(HttpExchange ex, Authed fn) throws IOException {
        Integer userId = getUserIdFromSession(ex);
        if (userId == null) {
            sendJson(ex, 401, Json.err("Authentication required"));
            return;
        }
        User user = usersById.get(userId);
        if (user == null) {
            sendJson(ex, 401, Json.err("Authentication required"));
            return;
        }
        fn.run(user);
    }

    private void handleRegister(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Object parsed = Json.parseOrNull(body);
        if (!(parsed instanceof Map)) {
            sendJson(ex, 400, Json.err("Invalid JSON"));
            return;
        }
        Map<String, Object> obj = (Map<String, Object>) parsed;
        String username = asString(obj.get("username"));
        String password = asString(obj.get("password"));
        if (username == null || !username.matches("^[a-zA-Z0-9_]{3,50}$")) {
            sendJson(ex, 400, Json.err("Invalid username"));
            return;
        }
        if (password == null) {
            sendJson(ex, 400, Json.err("Password too short"));
            return;
        }
        if (password.length() < 8) {
            sendJson(ex, 400, Json.err("Password too short"));
            return;
        }
        synchronized (usersByUsername) {
            if (usersByUsername.containsKey(username)) {
                sendJson(ex, 409, Json.err("Username already exists"));
                return;
            }
            int id = userIdSeq.getAndIncrement();
            User user = new User(id, username, hashPassword(password));
            usersById.put(id, user);
            usersByUsername.put(username, user);
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("id", id);
            resp.put("username", username);
            sendJson(ex, 201, Json.stringify(resp));
        }
    }

    private void handleLogin(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Object parsed = Json.parseOrNull(body);
        if (!(parsed instanceof Map)) {
            sendJson(ex, 400, Json.err("Invalid JSON"));
            return;
        }
        Map<String, Object> obj = (Map<String, Object>) parsed;
        String username = asString(obj.get("username"));
        String password = asString(obj.get("password"));
        if (username == null || password == null) {
            sendJson(ex, 401, Json.err("Invalid credentials"));
            return;
        }
        User user = usersByUsername.get(username);
        if (user == null || !verifyPassword(password, user.passwordHash)) {
            sendJson(ex, 401, Json.err("Invalid credentials"));
            return;
        }
        String token = UUID.randomUUID().toString().replace("-", "");
        sessions.put(token, user.id);
        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("id", user.id);
        resp.put("username", user.username);
        Headers h = ex.getResponseHeaders();
        h.add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        sendJson(ex, 200, Json.stringify(resp));
    }

    private void handleLogout(HttpExchange ex, User user) throws IOException {
        String token = getSessionIdFromCookie(ex);
        if (token != null) {
            sessions.remove(token);
        }
        sendJson(ex, 200, "{}");
    }

    private void handleMe(HttpExchange ex, User user) throws IOException {
        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("id", user.id);
        resp.put("username", user.username);
        sendJson(ex, 200, Json.stringify(resp));
    }

    private void handlePassword(HttpExchange ex, User user) throws IOException {
        String body = readBody(ex);
        Object parsed = Json.parseOrNull(body);
        if (!(parsed instanceof Map)) {
            sendJson(ex, 400, Json.err("Invalid JSON"));
            return;
        }
        Map<String, Object> obj = (Map<String, Object>) parsed;
        String oldPass = asString(obj.get("old_password"));
        String newPass = asString(obj.get("new_password"));
        if (oldPass == null || !verifyPassword(oldPass, user.passwordHash)) {
            sendJson(ex, 401, Json.err("Invalid credentials"));
            return;
        }
        if (newPass == null || newPass.length() < 8) {
            sendJson(ex, 400, Json.err("Password too short"));
            return;
        }
        user.passwordHash = hashPassword(newPass);
        sendJson(ex, 200, "{}");
    }

    private void handleTodosList(HttpExchange ex, User user) throws IOException {
        List<Todo> list = new ArrayList<>();
        for (Todo t : todosById.values()) {
            if (t.userId == user.id) list.add(t);
        }
        list.sort(Comparator.comparingInt(a -> a.id));
        StringBuilder sb = new StringBuilder();
        sb.append("[");
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append(tdoToJson(list.get(i)));
        }
        sb.append("]");
        sendJson(ex, 200, sb.toString());
    }

    private void handleTodosCreate(HttpExchange ex, User user) throws IOException {
        String body = readBody(ex);
        Object parsed = Json.parseOrNull(body);
        if (!(parsed instanceof Map)) {
            sendJson(ex, 400, Json.err("Invalid JSON"));
            return;
        }
        Map<String, Object> obj = (Map<String, Object>) parsed;
        String title = asString(obj.get("title"));
        String description = asString(obj.get("description"));
        if (title == null || title.trim().isEmpty()) {
            sendJson(ex, 400, Json.err("Title is required"));
            return;
        }
        if (description == null) description = "";
        int id = todoIdSeq.getAndIncrement();
        String now = nowIso();
        Todo t = new Todo(id, user.id, title, description, false, now, now);
        todosById.put(id, t);
        sendJson(ex, 201, tdoToJson(t));
    }

    private Integer parseTodoId(HttpExchange ex) {
        String path = ex.getRequestURI().getPath();
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

    private void handleTodosGet(HttpExchange ex, User user) throws IOException {
        Integer id = parseTodoId(ex);
        if (id == null) {
            sendJson(ex, 404, Json.err("Todo not found"));
            return;
        }
        Todo t = todosById.get(id);
        if (t == null || t.userId != user.id) {
            sendJson(ex, 404, Json.err("Todo not found"));
            return;
        }
        sendJson(ex, 200, tdoToJson(t));
    }

    private void handleTodosUpdate(HttpExchange ex, User user) throws IOException {
        Integer id = parseTodoId(ex);
        if (id == null) {
            sendJson(ex, 404, Json.err("Todo not found"));
            return;
        }
        Todo t = todosById.get(id);
        if (t == null || t.userId != user.id) {
            sendJson(ex, 404, Json.err("Todo not found"));
            return;
        }
        String body = readBody(ex);
        Object parsed = Json.parseOrNull(body);
        if (!(parsed instanceof Map)) {
            sendJson(ex, 400, Json.err("Invalid JSON"));
            return;
        }
        Map<String, Object> obj = (Map<String, Object>) parsed;
        if (obj.containsKey("title")) {
            String title = asString(obj.get("title"));
            if (title == null || title.trim().isEmpty()) {
                sendJson(ex, 400, Json.err("Title is required"));
                return;
            }
            t.title = title;
        }
        if (obj.containsKey("description")) {
            String description = asString(obj.get("description"));
            if (description == null) description = "";
            t.description = description;
        }
        if (obj.containsKey("completed")) {
            Boolean completed = asBoolean(obj.get("completed"));
            if (completed != null) t.completed = completed;
        }
        t.updatedAt = nowIso();
        sendJson(ex, 200, tdoToJson(t));
    }

    private void handleTodosDelete(HttpExchange ex, User user) throws IOException {
        Integer id = parseTodoId(ex);
        if (id == null) {
            // error must be JSON
            sendJson(ex, 404, Json.err("Todo not found"));
            return;
        }
        Todo t = todosById.get(id);
        if (t == null || t.userId != user.id) {
            sendJson(ex, 404, Json.err("Todo not found"));
            return;
        }
        todosById.remove(id);
        sendNoBody(ex, 204);
    }

    private String asString(Object o) {
        if (o == null) return null;
        if (o instanceof String) return (String) o;
        return String.valueOf(o);
    }

    private Boolean asBoolean(Object o) {
        if (o == null) return null;
        if (o instanceof Boolean) return (Boolean) o;
        if (o instanceof String) {
            String s = ((String)o).trim().toLowerCase();
            if ("true".equals(s)) return true;
            if ("false".equals(s)) return false;
        }
        return null;
    }

    private String tdoToJson(Todo t) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", t.id);
        m.put("title", t.title);
        m.put("description", t.description);
        m.put("completed", t.completed);
        m.put("created_at", t.createdAt);
        m.put("updated_at", t.updatedAt);
        return Json.stringify(m);
    }

    private Integer getUserIdFromSession(HttpExchange ex) {
        String sid = getSessionIdFromCookie(ex);
        if (sid == null) return null;
        return sessions.get(sid);
    }

    private String getSessionIdFromCookie(HttpExchange ex) {
        List<String> cookies = ex.getRequestHeaders().get("Cookie");
        if (cookies == null) return null;
        for (String header : cookies) {
            String[] parts = header.split(";\\s*");
            for (String part : parts) {
                int eq = part.indexOf('=');
                if (eq > 0) {
                    String name = part.substring(0, eq).trim();
                    String val = part.substring(eq + 1).trim();
                    if (name.equals("session_id")) {
                        return val;
                    }
                }
            }
        }
        return null;
    }

    private static String nowIso() {
        Instant now = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS);
        return ISO_INSTANT_SECONDS.format(now);
    }

    private static String readBody(HttpExchange ex) throws IOException {
        try (InputStream is = ex.getRequestBody()) {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
            return baos.toString(StandardCharsets.UTF_8);
        }
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

    private static void sendNoBody(HttpExchange ex, int status) throws IOException {
        // No body response (e.g., DELETE 204)
        ex.sendResponseHeaders(status, -1);
        ex.close();
    }

    private static String hashPassword(String password) {
        // Simple hash for demo: SHA-256 hex
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest(password.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static boolean verifyPassword(String password, String hash) {
        return hashPassword(password).equals(hash);
    }
}

class User {
    public final int id;
    public final String username;
    public String passwordHash;
    public User(int id, String username, String passwordHash) {
        this.id = id; this.username = username; this.passwordHash = passwordHash;
    }
}

class Todo {
    public final int id;
    public final int userId;
    public String title;
    public String description;
    public boolean completed;
    public String createdAt;
    public String updatedAt;
    public Todo(int id, int userId, String title, String description, boolean completed, String createdAt, String updatedAt) {
        this.id = id; this.userId = userId; this.title = title; this.description = description; this.completed = completed; this.createdAt = createdAt; this.updatedAt = updatedAt;
    }
}

class AtomicCounter {
    private final java.util.concurrent.atomic.AtomicInteger ai;
    public AtomicCounter(int start) { ai = new java.util.concurrent.atomic.AtomicInteger(start); }
    public int getAndIncrement() { return ai.getAndIncrement(); }
}

class Json {
    // Very small JSON parser and stringifier for our needs
    public static Object parseOrNull(String s) {
        if (s == null) return null;
        s = s.trim();
        if (s.isEmpty()) return null;
        try {
            return new Parser(s).parse();
        } catch (Exception e) {
            return null;
        }
    }

    public static String err(String msg) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("error", msg);
        return stringify(m);
    }

    public static String stringify(Object o) {
        StringBuilder sb = new StringBuilder();
        writeJson(sb, o);
        return sb.toString();
        
    }

    private static void writeJson(StringBuilder sb, Object o) {
        if (o == null) {
            sb.append("null");
        } else if (o instanceof String) {
            sb.append('"').append(escape((String)o)).append('"');
        } else if (o instanceof Number) {
            sb.append(o.toString());
        } else if (o instanceof Boolean) {
            sb.append(((Boolean)o) ? "true" : "false");
        } else if (o instanceof Map) {
            sb.append('{');
            boolean first = true;
            for (Object entryObj : ((Map<?,?>)o).entrySet()) {
                Map.Entry<?,?> e = (Map.Entry<?,?>) entryObj;
                if (!first) sb.append(',');
                first = false;
                sb.append('"').append(escape(String.valueOf(e.getKey()))).append('"').append(':');
                writeJson(sb, e.getValue());
            }
            sb.append('}');
        } else if (o instanceof Iterable) {
            sb.append('[');
            boolean first = true;
            for (Object v : (Iterable<?>) o) {
                if (!first) sb.append(',');
                first = false;
                writeJson(sb, v);
            }
            sb.append(']');
        } else {
            // Fallback
            sb.append('"').append(escape(String.valueOf(o))).append('"');
        }
    }

    private static String escape(String s) {
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
        private final String s;
        private int i;
        Parser(String s) { this.s = s; this.i = 0; }
        Object parse() {
            skipWS();
            Object v = parseValue();
            skipWS();
            if (i != s.length()) throw new RuntimeException("Trailing chars");
            return v;
        }
        private Object parseValue() {
            skipWS();
            if (i >= s.length()) throw new RuntimeException("Unexpected end");
            char c = s.charAt(i);
            if (c == '"') return parseString();
            if (c == '{') return parseObject();
            if (c == '[') return parseArray();
            if (c == 't' || c == 'f') return parseBoolean();
            if (c == 'n') return parseNull();
            return parseNumber();
        }
        private Map<String,Object> parseObject() {
            Map<String,Object> m = new LinkedHashMap<>();
            expect('{');
            skipWS();
            if (peek('}')) { expect('}'); return m; }
            while (true) {
                skipWS();
                String key = parseString();
                skipWS(); expect(':'); skipWS();
                Object val = parseValue();
                m.put(key, val);
                skipWS();
                if (peek('}')) { expect('}'); break; }
                expect(',');
            }
            return m;
        }
        private List<Object> parseArray() {
            List<Object> a = new ArrayList<>();
            expect('['); skipWS();
            if (peek(']')) { expect(']'); return a; }
            while (true) {
                Object v = parseValue();
                a.add(v);
                skipWS();
                if (peek(']')) { expect(']'); break; }
                expect(',');
            }
            return a;
        }
        private String parseString() {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (i < s.length()) {
                char c = s.charAt(i++);
                if (c == '"') break;
                if (c == '\\') {
                    if (i >= s.length()) throw new RuntimeException("Bad escape");
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
                            if (i + 4 > s.length()) throw new RuntimeException("Bad unicode");
                            int code = Integer.parseInt(s.substring(i, i + 4), 16);
                            sb.append((char) code);
                            i += 4;
                            break;
                        default: throw new RuntimeException("Bad escape");
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }
        private Boolean parseBoolean() {
            if (s.startsWith("true", i)) { i += 4; return true; }
            if (s.startsWith("false", i)) { i += 5; return false; }
            throw new RuntimeException("Bad boolean");
        }
        private Object parseNull() {
            if (s.startsWith("null", i)) { i += 4; return null; }
            throw new RuntimeException("Bad null");
        }
        private Number parseNumber() {
            int start = i;
            if (s.charAt(i) == '-') i++;
            while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
            if (i < s.length() && s.charAt(i) == '.') {
                i++;
                while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
            }
            if (i < s.length() && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
                i++;
                if (i < s.length() && (s.charAt(i) == '+' || s.charAt(i) == '-')) i++;
                while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
            }
            String num = s.substring(start, i);
            if (num.contains(".") || num.contains("e") || num.contains("E")) {
                return Double.parseDouble(num);
            } else {
                try {
                    long l = Long.parseLong(num);
                    if (l <= Integer.MAX_VALUE && l >= Integer.MIN_VALUE) return (int) l;
                    return l;
                } catch (NumberFormatException e) {
                    return Double.parseDouble(num);
                }
            }
        }
        private boolean peek(char c) { return i < s.length() && s.charAt(i) == c; }
        private void expect(char c) {
            if (i >= s.length() || s.charAt(i) != c) throw new RuntimeException("Expected '"+c+"'");
            i++;
        }
        private void skipWS() {
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c == ' ' || c == '\n' || c == '\r' || c == '\t') i++;
                else break;
            }
        }
    }
}

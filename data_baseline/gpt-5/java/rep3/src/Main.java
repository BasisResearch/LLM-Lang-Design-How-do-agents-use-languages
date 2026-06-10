import java.io.*;
import java.net.*;
import com.sun.net.httpserver.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;

public class Main {
    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
            }
        }
        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer server = HttpServer.create(addr, 0);
        TodoApp app = new TodoApp();
        server.createContext("/", app::handle);
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }
}

class TodoApp {
    private final Map<Integer, User> users = new ConcurrentHashMap<>();
    private final Map<String, Integer> usernameToId = new ConcurrentHashMap<>();
    private final Map<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId
    private final Map<Integer, Todo> todos = new ConcurrentHashMap<>();
    private final Map<Integer, List<Integer>> userTodos = new ConcurrentHashMap<>(); // userId -> list of todo ids (ordered)
    private final AtomicInteger userIdSeq = new AtomicInteger(1);
    private final AtomicInteger todoIdSeq = new AtomicInteger(1);

    public void handle(HttpExchange ex) throws IOException {
        try {
            String method = ex.getRequestMethod();
            URI uri = ex.getRequestURI();
            String path = uri.getPath();
            if (path == null || path.isEmpty()) path = "/";

            // Routing
            if (method.equals("POST") && path.equals("/register")) {
                handleRegister(ex);
            } else if (method.equals("POST") && path.equals("/login")) {
                handleLogin(ex);
            } else if (method.equals("POST") && path.equals("/logout")) {
                withAuth(ex, (user) -> handleLogout(ex, user));
            } else if (method.equals("GET") && path.equals("/me")) {
                withAuth(ex, (user) -> handleMe(ex, user));
            } else if (method.equals("PUT") && path.equals("/password")) {
                withAuth(ex, (user) -> handlePassword(ex, user));
            } else if (path.equals("/todos") && method.equals("GET")) {
                withAuth(ex, (user) -> handleListTodos(ex, user));
            } else if (path.equals("/todos") && method.equals("POST")) {
                withAuth(ex, (user) -> handleCreateTodo(ex, user));
            } else if (path.startsWith("/todos/") && path.length() > 7) {
                String idStr = path.substring(7);
                Integer id = parseId(idStr);
                if (id == null) {
                    sendJson(ex, 404, errorJson("Todo not found"));
                    return;
                }
                if (method.equals("GET")) {
                    withAuth(ex, (user) -> handleGetTodo(ex, user, id));
                } else if (method.equals("PUT")) {
                    withAuth(ex, (user) -> handleUpdateTodo(ex, user, id));
                } else if (method.equals("DELETE")) {
                    withAuth(ex, (user) -> handleDeleteTodo(ex, user, id));
                } else {
                    sendJson(ex, 404, errorJson("Not found"));
                }
            } else {
                sendJson(ex, 404, errorJson("Not found"));
            }
        } catch (Exception e) {
            // Log and return 500
            e.printStackTrace();
            sendJson(ex, 500, errorJson("Internal server error"));
        } finally {
            try { ex.close(); } catch (Exception ignore) {}
        }
    }

    private static Integer parseId(String s) {
        try { return Integer.parseInt(s); } catch (Exception e) { return null; }
    }

    private interface AuthedHandler { void run(User user) throws IOException; }

    private void withAuth(HttpExchange ex, AuthedHandler handler) throws IOException {
        String token = getSessionToken(ex.getRequestHeaders());
        if (token == null) {
            sendJson(ex, 401, errorJson("Authentication required"));
            return;
        }
        Integer uid = sessions.get(token);
        if (uid == null) {
            sendJson(ex, 401, errorJson("Authentication required"));
            return;
        }
        User user = users.get(uid);
        if (user == null) {
            sendJson(ex, 401, errorJson("Authentication required"));
            return;
        }
        handler.run(user);
    }

    private String getSessionToken(Headers headers) {
        List<String> list = headers.get("Cookie");
        if (list == null) return null;
        for (String cookieHeader : list) {
            String[] parts = cookieHeader.split(";\\s*");
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

    // Endpoint handlers
    private void handleRegister(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Map<String, Object> json = Json.parseObject(body);
        String username = str(json.get("username"));
        String password = str(json.get("password"));
        if (username == null || !username.matches("^[a-zA-Z0-9_]{3,50}$")) {
            sendJson(ex, 400, errorJson("Invalid username"));
            return;
        }
        if (password == null || password.length() < 8) {
            sendJson(ex, 400, errorJson("Password too short"));
            return;
        }
        synchronized (this) {
            if (usernameToId.containsKey(username)) {
                sendJson(ex, 409, errorJson("Username already exists"));
                return;
            }
            int id = userIdSeq.getAndIncrement();
            User user = new User(id, username, password);
            users.put(id, user);
            usernameToId.put(username, id);
            sendJson(ex, 201, user.toPublicJson());
        }
    }

    private void handleLogin(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Map<String, Object> json = Json.parseObject(body);
        String username = str(json.get("username"));
        String password = str(json.get("password"));
        if (username == null || password == null) {
            sendJson(ex, 401, errorJson("Invalid credentials"));
            return;
        }
        Integer id = usernameToId.get(username);
        if (id == null) {
            sendJson(ex, 401, errorJson("Invalid credentials"));
            return;
        }
        User user = users.get(id);
        if (user == null || !user.password.equals(password)) {
            sendJson(ex, 401, errorJson("Invalid credentials"));
            return;
        }
        String token = UUID.randomUUID().toString().replaceAll("-", "");
        sessions.put(token, user.id);
        Headers resp = ex.getResponseHeaders();
        resp.add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        sendJson(ex, 200, user.toPublicJson());
    }

    private void handleLogout(HttpExchange ex, User user) throws IOException {
        String token = getSessionToken(ex.getRequestHeaders());
        if (token != null) {
            sessions.remove(token);
        }
        sendJson(ex, 200, "{}");
    }

    private void handleMe(HttpExchange ex, User user) throws IOException {
        sendJson(ex, 200, user.toPublicJson());
    }

    private void handlePassword(HttpExchange ex, User user) throws IOException {
        String body = readBody(ex);
        Map<String, Object> json = Json.parseObject(body);
        String oldp = str(json.get("old_password"));
        String newp = str(json.get("new_password"));
        if (oldp == null || !user.password.equals(oldp)) {
            sendJson(ex, 401, errorJson("Invalid credentials"));
            return;
        }
        if (newp == null || newp.length() < 8) {
            sendJson(ex, 400, errorJson("Password too short"));
            return;
        }
        user.password = newp;
        sendJson(ex, 200, "{}");
    }

    private void handleListTodos(HttpExchange ex, User user) throws IOException {
        List<Integer> ids = userTodos.getOrDefault(user.id, Collections.emptyList());
        // Ensure ascending order by id
        List<Integer> copy = new ArrayList<>(ids);
        Collections.sort(copy);
        StringBuilder sb = new StringBuilder();
        sb.append("[");
        boolean first = true;
        for (Integer id : copy) {
            Todo t = todos.get(id);
            if (t == null) continue;
            if (!first) sb.append(",");
            sb.append(t.toJson());
            first = false;
        }
        sb.append("]");
        sendJson(ex, 200, sb.toString());
    }

    private void handleCreateTodo(HttpExchange ex, User user) throws IOException {
        String body = readBody(ex);
        Map<String, Object> json = Json.parseObject(body);
        String title = str(json.get("title"));
        String description = str(json.get("description"));
        if (title == null || title.trim().isEmpty()) {
            sendJson(ex, 400, errorJson("Title is required"));
            return;
        }
        if (description == null) description = "";
        int id = todoIdSeq.getAndIncrement();
        String now = nowIso();
        Todo t = new Todo(id, user.id, title, description, false, now, now);
        todos.put(id, t);
        userTodos.computeIfAbsent(user.id, k -> Collections.synchronizedList(new ArrayList<>())).add(id);
        sendJson(ex, 201, t.toJson());
    }

    private void handleGetTodo(HttpExchange ex, User user, int id) throws IOException {
        Todo t = todos.get(id);
        if (t == null || t.userId != user.id) {
            sendJson(ex, 404, errorJson("Todo not found"));
            return;
        }
        sendJson(ex, 200, t.toJson());
    }

    private void handleUpdateTodo(HttpExchange ex, User user, int id) throws IOException {
        Todo t = todos.get(id);
        if (t == null || t.userId != user.id) {
            sendJson(ex, 404, errorJson("Todo not found"));
            return;
        }
        String body = readBody(ex);
        Map<String, Object> json = Json.parseObject(body);
        boolean any = false;
        if (json.containsKey("title")) {
            String title = str(json.get("title"));
            if (title == null || title.trim().isEmpty()) {
                sendJson(ex, 400, errorJson("Title is required"));
                return;
            }
            t.title = title;
            any = true;
        }
        if (json.containsKey("description")) {
            String description = str(json.get("description"));
            if (description == null) description = "";
            t.description = description;
            any = true;
        }
        if (json.containsKey("completed")) {
            Boolean c = bool(json.get("completed"));
            if (c != null) {
                t.completed = c.booleanValue();
                any = true;
            }
        }
        if (any) {
            t.updatedAt = nowIso();
        }
        sendJson(ex, 200, t.toJson());
    }

    private void handleDeleteTodo(HttpExchange ex, User user, int id) throws IOException {
        Todo t = todos.get(id);
        if (t == null || t.userId != user.id) {
            sendEmpty(ex, 404, errorJson("Todo not found"));
            return;
        }
        todos.remove(id);
        List<Integer> ids = userTodos.get(user.id);
        if (ids != null) ids.remove((Integer)id);
        // DELETE success: 204 no body
        sendNoContent(ex);
    }

    private static String str(Object o) { return (o instanceof String) ? (String)o : null; }
    private static Boolean bool(Object o) { return (o instanceof Boolean) ? (Boolean)o : null; }

    private static String errorJson(String msg) { return "{\"error\":\"" + Json.escape(msg) + "\"}"; }

    private static String nowIso() {
        return DateTimeFormatter.ISO_INSTANT.format(Instant.now().truncatedTo(ChronoUnit.SECONDS));
    }

    private static String readBody(HttpExchange ex) throws IOException {
        InputStream is = ex.getRequestBody();
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
        String charset = "UTF-8";
        return bos.toString(charset);
    }

    private static void sendJson(HttpExchange ex, int status, String json) throws IOException {
        Headers headers = ex.getResponseHeaders();
        headers.set("Content-Type", "application/json");
        byte[] bytes = json.getBytes("UTF-8");
        ex.sendResponseHeaders(status, bytes.length);
        OutputStream os = ex.getResponseBody();
        os.write(bytes);
        os.flush();
    }

    private static void sendEmpty(HttpExchange ex, int status, String json) throws IOException {
        // For error on DELETE we still return JSON body
        sendJson(ex, status, json);
    }

    private static void sendNoContent(HttpExchange ex) throws IOException {
        // 204 no body
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(204, -1);
    }
}

class User {
    public final int id;
    public final String username;
    public String password; // stored in plain for simplicity (in-memory only)

    public User(int id, String username, String password) {
        this.id = id;
        this.username = username;
        this.password = password;
    }

    public String toPublicJson() {
        return "{\"id\":" + id + ",\"username\":\"" + Json.escape(username) + "\"}";
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
        this.id = id;
        this.userId = userId;
        this.title = title;
        this.description = description;
        this.completed = completed;
        this.createdAt = createdAt;
        this.updatedAt = updatedAt;
    }

    public String toJson() {
        StringBuilder sb = new StringBuilder();
        sb.append("{");
        sb.append("\"id\":").append(id).append(",");
        sb.append("\"title\":\"").append(Json.escape(title)).append("\",");
        sb.append("\"description\":\"").append(Json.escape(description)).append("\",");
        sb.append("\"completed\":").append(completed).append(",");
        sb.append("\"created_at\":\"").append(Json.escape(createdAt)).append("\",");
        sb.append("\"updated_at\":\"").append(Json.escape(updatedAt)).append("\"");
        sb.append("}");
        return sb.toString();
    }
}

class Json {
    // Minimal JSON utilities for our use-case
    public static Map<String,Object> parseObject(String s) throws IOException {
        if (s == null) return new HashMap<>();
        Parser p = new Parser(s);
        Object v = p.parseValue();
        if (!(v instanceof Map)) return new HashMap<>();
        return (Map<String,Object>)v;
    }

    public static String escape(String s) {
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

    static class Parser {
        private final String s;
        private int i = 0;
        Parser(String s) { this.s = s; }

        private void skipWs() {
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c == ' ' || c == '\n' || c == '\r' || c == '\t') i++; else break;
            }
        }

        Object parseValue() throws IOException {
            skipWs();
            if (i >= s.length()) return null;
            char c = s.charAt(i);
            if (c == '{') return parseObject();
            if (c == '"') return parseString();
            if (c == 't' || c == 'f') return parseBoolean();
            if (c == 'n') { parseNull(); return null; }
            // number not needed but parse minimal
            if (c == '-' || (c >= '0' && c <= '9')) return parseNumber();
            return null;
        }

        Map<String,Object> parseObject() throws IOException {
            Map<String,Object> map = new LinkedHashMap<>();
            expect('{');
            skipWs();
            if (peek('}')) { i++; return map; }
            while (true) {
                skipWs();
                String key = parseString();
                skipWs();
                expect(':');
                Object val = parseValue();
                map.put(key, val);
                skipWs();
                if (peek(',')) { i++; continue; }
                if (peek('}')) { i++; break; }
                throw new IOException("Invalid JSON object");
            }
            return map;
        }

        String parseString() throws IOException {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (i < s.length()) {
                char c = s.charAt(i++);
                if (c == '"') break;
                if (c == '\\') {
                    if (i >= s.length()) throw new IOException("Invalid escape");
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
                            if (i + 4 > s.length()) throw new IOException("Invalid unicode escape");
                            String hex = s.substring(i, i+4);
                            i += 4;
                            sb.append((char)Integer.parseInt(hex, 16));
                            break;
                        default:
                            throw new IOException("Invalid escape");
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }

        Boolean parseBoolean() throws IOException {
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
            throw new IOException("Invalid boolean");
        }

        void parseNull() throws IOException {
            if (s.startsWith("null", i)) { i += 4; return; }
            throw new IOException("Invalid null");
        }

        Number parseNumber() throws IOException {
            int start = i;
            if (s.charAt(i) == '-') i++;
            while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
            if (i < s.length() && s.charAt(i) == '.') {
                i++;
                while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
            }
            String num = s.substring(start, i);
            try {
                if (num.contains(".")) return Double.parseDouble(num);
                else return Long.parseLong(num);
            } catch (NumberFormatException e) {
                throw new IOException("Invalid number");
            }
        }

        private void expect(char ch) throws IOException {
            skipWs();
            if (i >= s.length() || s.charAt(i) != ch) throw new IOException("Expected '" + ch + "'");
            i++;
        }
        private boolean peek(char ch) {
            skipWs();
            return i < s.length() && s.charAt(i) == ch;
        }
    }
}

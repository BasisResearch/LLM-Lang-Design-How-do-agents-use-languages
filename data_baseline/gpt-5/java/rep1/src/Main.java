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

public class Main {
    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                try {
                    port = Integer.parseInt(args[i + 1]);
                } catch (NumberFormatException e) {
                    System.err.println("Invalid port: " + args[i + 1]);
                    System.exit(1);
                }
            }
        }
        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer server = HttpServer.create(addr, 0);
        DataStore store = new DataStore();
        server.createContext("/", new Router(store));
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }

    static class Router implements HttpHandler {
        private final DataStore store;
        Router(DataStore store) { this.store = store; }

        @Override
        public void handle(HttpExchange ex) throws IOException {
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
                    handleLogout(ex);
                    return;
                }
                if (path.equals("/me") && method.equals("GET")) {
                    handleMe(ex);
                    return;
                }
                if (path.equals("/password") && method.equals("PUT")) {
                    handlePassword(ex);
                    return;
                }
                if (path.equals("/todos")) {
                    if (method.equals("GET")) { handleTodosList(ex); return; }
                    if (method.equals("POST")) { handleTodosCreate(ex); return; }
                }
                if (path.startsWith("/todos/")) {
                    String idStr = path.substring("/todos/".length());
                    if (idStr.isEmpty() || idStr.contains("/")) {
                        sendJson(ex, 404, JsonUtil.error("Not found"));
                        return;
                    }
                    int id;
                    try { id = Integer.parseInt(idStr); } catch (NumberFormatException e) { sendJson(ex, 404, JsonUtil.error("Not found")); return; }
                    if (method.equals("GET")) { handleTodoGet(ex, id); return; }
                    if (method.equals("PUT")) { handleTodoUpdate(ex, id); return; }
                    if (method.equals("DELETE")) { handleTodoDelete(ex, id); return; }
                }
                sendJson(ex, 404, JsonUtil.error("Not found"));
            } catch (Throwable t) {
                t.printStackTrace();
                try { sendJson(ex, 500, JsonUtil.error("Internal server error")); } catch (Exception ignore) {}
            }
        }

        private void handleRegister(HttpExchange ex) throws IOException {
            Map<String, Object> body = readJsonBody(ex);
            String username = asString(body.get("username"));
            String password = asString(body.get("password"));
            // Debug
            System.err.println("/register body keys=" + body.keySet());
            System.err.println("/register username=" + username + " passwordLen=" + (password==null?null:password.length()));
            if (username == null || !username.matches("^[a-zA-Z0-9_]{3,50}$")) {
                sendJson(ex, 400, JsonUtil.error("Invalid username"));
                return;
            }
            if (password == null || password.length() < 8) {
                sendJson(ex, 400, JsonUtil.error("Password too short"));
                return;
            }
            User user;
            try {
                user = store.createUser(username, password);
            } catch (DataStore.ConflictException ce) {
                sendJson(ex, 409, JsonUtil.error("Username already exists"));
                return;
            }
            String resp = JsonUtil.user(user);
            sendJson(ex, 201, resp);
        }

        private void handleLogin(HttpExchange ex) throws IOException {
            Map<String, Object> body = readJsonBody(ex);
            String username = asString(body.get("username"));
            String password = asString(body.get("password"));
            if (username == null || password == null) {
                sendJson(ex, 401, JsonUtil.error("Invalid credentials"));
                return;
            }
            User user = store.getUserByUsername(username);
            if (user == null || !user.password.equals(password)) {
                sendJson(ex, 401, JsonUtil.error("Invalid credentials"));
                return;
            }
            String token = store.createSession(user.id);
            ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            String resp = JsonUtil.user(user);
            sendJson(ex, 200, resp);
        }

        private void handleLogout(HttpExchange ex) throws IOException {
            AuthContext auth = requireAuth(ex);
            if (auth == null) return; // response already sent
            store.invalidateSession(auth.sessionToken);
            sendJson(ex, 200, "{}");
        }

        private void handleMe(HttpExchange ex) throws IOException {
            AuthContext auth = requireAuth(ex);
            if (auth == null) return;
            String resp = JsonUtil.user(auth.user);
            sendJson(ex, 200, resp);
        }

        private void handlePassword(HttpExchange ex) throws IOException {
            AuthContext auth = requireAuth(ex);
            if (auth == null) return;
            Map<String, Object> body = readJsonBody(ex);
            String oldp = asString(body.get("old_password"));
            String newp = asString(body.get("new_password"));
            if (oldp == null || !auth.user.password.equals(oldp)) {
                sendJson(ex, 401, JsonUtil.error("Invalid credentials"));
                return;
            }
            if (newp == null || newp.length() < 8) {
                sendJson(ex, 400, JsonUtil.error("Password too short"));
                return;
            }
            store.updatePassword(auth.user.id, newp);
            sendJson(ex, 200, "{}");
        }

        private void handleTodosList(HttpExchange ex) throws IOException {
            AuthContext auth = requireAuth(ex);
            if (auth == null) return;
            List<Todo> list = store.listTodosForUser(auth.user.id);
            String resp = JsonUtil.todos(list);
            sendJson(ex, 200, resp);
        }

        private void handleTodosCreate(HttpExchange ex) throws IOException {
            AuthContext auth = requireAuth(ex);
            if (auth == null) return;
            Map<String, Object> body = readJsonBody(ex);
            String title = asString(body.get("title"));
            String description = asString(body.get("description"));
            if (title == null || title.trim().isEmpty()) {
                sendJson(ex, 400, JsonUtil.error("Title is required"));
                return;
            }
            if (description == null) description = "";
            Todo todo = store.createTodo(auth.user.id, title, description);
            sendJson(ex, 201, JsonUtil.todo(todo));
        }

        private void handleTodoGet(HttpExchange ex, int id) throws IOException {
            AuthContext auth = requireAuth(ex);
            if (auth == null) return;
            Todo t = store.getTodo(id);
            if (t == null || t.userId != auth.user.id) {
                sendJson(ex, 404, JsonUtil.error("Todo not found"));
                return;
            }
            sendJson(ex, 200, JsonUtil.todo(t));
        }

        private void handleTodoUpdate(HttpExchange ex, int id) throws IOException {
            AuthContext auth = requireAuth(ex);
            if (auth == null) return;
            Todo t = store.getTodo(id);
            if (t == null || t.userId != auth.user.id) {
                sendJson(ex, 404, JsonUtil.error("Todo not found"));
                return;
            }
            Map<String, Object> body = readJsonBody(ex);
            boolean change = false;
            if (body.containsKey("title")) {
                String title = asString(body.get("title"));
                if (title == null || title.trim().isEmpty()) {
                    sendJson(ex, 400, JsonUtil.error("Title is required"));
                    return;
                }
                t.title = title;
                change = true;
            }
            if (body.containsKey("description")) {
                String description = asString(body.get("description"));
                if (description == null) description = "";
                t.description = description;
                change = true;
            }
            if (body.containsKey("completed")) {
                Object val = body.get("completed");
                if (val instanceof Boolean) {
                    t.completed = (Boolean) val;
                    change = true;
                }
            }
            if (change) {
                t.updatedAt = nowIso();
            }
            store.updateTodo(t);
            sendJson(ex, 200, JsonUtil.todo(t));
        }

        private void handleTodoDelete(HttpExchange ex, int id) throws IOException {
            AuthContext auth = requireAuth(ex);
            if (auth == null) return;
            Todo t = store.getTodo(id);
            if (t == null || t.userId != auth.user.id) {
                sendJson(ex, 404, JsonUtil.error("Todo not found"));
                return;
            }
            store.deleteTodo(id);
            sendNoContent(ex);
        }

        private static String nowIso() {
            return Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
        }

        private AuthContext requireAuth(HttpExchange ex) throws IOException {
            String cookie = ex.getRequestHeaders().getFirst("Cookie");
            String token = null;
            if (cookie != null) {
                String[] parts = cookie.split(";\\s*");
                for (String p : parts) {
                    String[] kv = p.trim().split("=", 2);
                    if (kv.length == 2) {
                        if (kv[0].trim().equals("session_id")) {
                            token = kv[1];
                            break;
                        }
                    }
                }
            }
            if (token == null) {
                sendJson(ex, 401, JsonUtil.error("Authentication required"));
                return null;
            }
            Integer uid = store.getUserIdForSession(token);
            if (uid == null) {
                sendJson(ex, 401, JsonUtil.error("Authentication required"));
                return null;
            }
            User user = store.getUserById(uid);
            if (user == null) {
                sendJson(ex, 401, JsonUtil.error("Authentication required"));
                return null;
            }
            return new AuthContext(user, token);
        }

        private static Map<String, Object> readJsonBody(HttpExchange ex) throws IOException {
            InputStream is = ex.getRequestBody();
            if (is == null) return new HashMap<>();
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            int total = 0;
            while ((r = is.read(buf)) != -1) { baos.write(buf, 0, r); total += r; }
            String s;
            try {
                s = baos.toString(StandardCharsets.UTF_8.name());
            } catch (Exception e) {
                s = new String(baos.toByteArray(), StandardCharsets.UTF_8);
            }
            s = s.trim();
            System.err.println("Read body bytes=" + total + " content='" + s + "'");
            if (s.isEmpty()) return new HashMap<>();
            try {
                Object parsed = JsonUtil.parse(s);
                if (parsed instanceof Map) {
                    return (Map<String, Object>) parsed;
                } else {
                    return new HashMap<>();
                }
            } catch (Exception e) {
                System.err.println("JSON parse error: " + e.getMessage());
                return new HashMap<>();
            }
        }

        private static String asString(Object o) {
            if (o == null) return null;
            if (o instanceof String) return (String) o;
            return null;
        }

        private static void sendJson(HttpExchange ex, int status, String body) throws IOException {
            byte[] data = body.getBytes(StandardCharsets.UTF_8);
            Headers h = ex.getResponseHeaders();
            h.set("Content-Type", "application/json");
            ex.sendResponseHeaders(status, data.length);
            try (OutputStream os = ex.getResponseBody()) {
                os.write(data);
            }
        }

        private static void sendNoContent(HttpExchange ex) throws IOException {
            ex.getResponseHeaders().set("Content-Type", "application/json");
            ex.sendResponseHeaders(204, -1);
            ex.close();
        }
    }

    static class AuthContext {
        final User user;
        final String sessionToken;
        AuthContext(User user, String sessionToken) { this.user = user; this.sessionToken = sessionToken; }
    }

    static class DataStore {
        static class ConflictException extends RuntimeException {}
        private final AtomicInteger userIdCounter = new AtomicInteger(1);
        private final AtomicInteger todoIdCounter = new AtomicInteger(1);
        private final ConcurrentHashMap<String, User> usersByUsername = new ConcurrentHashMap<>();
        private final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
        private final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>();
        private final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
        private final Object userCreateLock = new Object();

        public User createUser(String username, String password) {
            synchronized (userCreateLock) {
                if (usersByUsername.containsKey(username)) {
                    throw new ConflictException();
                }
                int id = userIdCounter.getAndIncrement();
                User u = new User(id, username, password);
                usersByUsername.put(username, u);
                usersById.put(id, u);
                return u;
            }
        }

        public User getUserByUsername(String username) {
            return usersByUsername.get(username);
        }

        public User getUserById(int id) { return usersById.get(id); }

        public void updatePassword(int userId, String newPassword) {
            User u = usersById.get(userId);
            if (u != null) {
                u.password = newPassword;
            }
        }

        public String createSession(int userId) {
            String token = UUID.randomUUID().toString().replace("-", "");
            sessions.put(token, userId);
            return token;
        }

        public Integer getUserIdForSession(String token) { return sessions.get(token); }

        public void invalidateSession(String token) { if (token != null) sessions.remove(token); }

        public Todo createTodo(int userId, String title, String description) {
            int id = todoIdCounter.getAndIncrement();
            String now = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
            Todo t = new Todo(id, userId, title, description, false, now, now);
            todosById.put(id, t);
            return t;
        }

        public Todo getTodo(int id) { return todosById.get(id); }

        public void updateTodo(Todo t) { if (t != null) todosById.put(t.id, t); }

        public void deleteTodo(int id) { todosById.remove(id); }

        public List<Todo> listTodosForUser(int userId) {
            List<Todo> res = new ArrayList<>();
            for (Todo t : todosById.values()) {
                if (t.userId == userId) res.add(t);
            }
            res.sort(Comparator.comparingInt(a -> a.id));
            return res;
        }
    }

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

    static class JsonUtil {
        static String error(String msg) { return "{\"error\":\"" + escape(msg) + "\"}"; }
        static String user(User u) {
            return "{" +
                    "\"id\":" + u.id + "," +
                    "\"username\":\"" + escape(u.username) + "\"" +
                    "}";
        }
        static String todo(Todo t) {
            return "{" +
                    "\"id\":" + t.id + "," +
                    "\"title\":\"" + escape(t.title) + "\"," +
                    "\"description\":\"" + escape(t.description == null ? "" : t.description) + "\"," +
                    "\"completed\":" + (t.completed ? "true" : "false") + "," +
                    "\"created_at\":\"" + escape(t.createdAt) + "\"," +
                    "\"updated_at\":\"" + escape(t.updatedAt) + "\"" +
                    "}";
        }
        static String todos(List<Todo> list) {
            StringBuilder sb = new StringBuilder();
            sb.append("[");
            boolean first = true;
            for (Todo t : list) {
                if (!first) sb.append(",");
                first = false;
                sb.append(todo(t));
            }
            sb.append("]");
            return sb.toString();
        }
        static String escape(String s) {
            if (s == null) return "";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '"': sb.append("\\\""); break;
                    case '\\': sb.append("\\\\"); break;
                    case '\n': sb.append("\\n"); break;
                    case '\r': sb.append("\\r"); break;
                    case '\t': sb.append("\\t"); break;
                    case '\b': sb.append("\\b"); break;
                    case '\f': sb.append("\\f"); break;
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

        static Object parse(String s) {
            Parser p = new Parser(s);
            Object v = p.parseValue();
            p.skipWs();
            if (!p.eof()) throw new RuntimeException("Extra data");
            return v;
        }
        static class Parser {
            private final String s;
            private int i = 0;
            Parser(String s) { this.s = s; }
            boolean eof() { return i >= s.length(); }
            void skipWs() { while (!eof()) { char c = s.charAt(i); if (c==' '||c=='\n'||c=='\r'||c=='\t') i++; else break; } }
            char peek() { return s.charAt(i); }
            char next() { return s.charAt(i++); }

            Object parseValue() {
                skipWs();
                if (eof()) throw new RuntimeException("Unexpected end");
                char c = peek();
                if (c == '"') return parseString();
                if (c == '{') return parseObject();
                if (c == '[') return parseArray();
                if (c == 't' || c == 'f') return parseBoolean();
                if (c == 'n') { parseNull(); return null; }
                if (c == '-' || (c >= '0' && c <= '9')) return parseNumber();
                throw new RuntimeException("Unexpected char: " + c);
            }
            Map<String,Object> parseObject() {
                Map<String,Object> m = new LinkedHashMap<>();
                expect('{');
                skipWs();
                if (!eof() && peek()=='}') { next(); return m; }
                while (true) {
                    skipWs();
                    if (eof() || peek()!='"') throw new RuntimeException("Expected string key");
                    String key = parseString();
                    skipWs(); expect(':');
                    Object val = parseValue();
                    m.put(key, val);
                    skipWs();
                    if (!eof() && peek()==',') { next(); continue; }
                    if (!eof() && peek()=='}') { next(); break; }
                    throw new RuntimeException("Expected , or } in object");
                }
                return m;
            }
            List<Object> parseArray() {
                List<Object> arr = new ArrayList<>();
                expect('[');
                skipWs();
                if (!eof() && peek()==']') { next(); return arr; }
                while (true) {
                    Object v = parseValue();
                    arr.add(v);
                    skipWs();
                    if (!eof() && peek()==',') { next(); continue; }
                    if (!eof() && peek()==']') { next(); break; }
                    throw new RuntimeException("Expected , or ] in array");
                }
                return arr;
            }
            String parseString() {
                expect('"');
                StringBuilder sb = new StringBuilder();
                while (true) {
                    if (eof()) throw new RuntimeException("Unterminated string");
                    char c = next();
                    if (c == '"') break;
                    if (c == '\\') {
                        if (eof()) throw new RuntimeException("Bad escape");
                        char e = next();
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
                                if (i + 4 > s.length()) throw new RuntimeException("Bad unicode escape");
                                String hex = s.substring(i, i+4);
                                i += 4;
                                try {
                                    int cp = Integer.parseInt(hex, 16);
                                    sb.append((char)cp);
                                } catch (NumberFormatException ex) { throw new RuntimeException("Bad unicode escape"); }
                                break;
                            default: throw new RuntimeException("Bad escape: \\" + e);
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
                throw new RuntimeException("Bad boolean");
            }
            void parseNull() {
                if (s.startsWith("null", i)) { i += 4; return; }
                throw new RuntimeException("Bad null");
            }
            Number parseNumber() {
                int start = i;
                if (peek()=='-') i++;
                while (!eof() && Character.isDigit(peek())) i++;
                if (!eof() && peek()=='.') { i++; while (!eof() && Character.isDigit(peek())) i++; }
                if (!eof() && (peek()=='e' || peek()=='E')) { i++; if (!eof() && (peek()=='+'||peek()=='-')) i++; while (!eof() && Character.isDigit(peek())) i++; }
                String num = s.substring(start, i);
                try {
                    if (num.contains(".") || num.contains("e") || num.contains("E")) {
                        return Double.parseDouble(num);
                    } else {
                        long v = Long.parseLong(num);
                        if (v >= Integer.MIN_VALUE && v <= Integer.MAX_VALUE) return (int)v;
                        return v;
                    }
                } catch (NumberFormatException e) {
                    throw new RuntimeException("Bad number");
                }
            }
            void expect(char c) {
                skipWs();
                if (eof() || next()!=c) throw new RuntimeException("Expected '"+c+"'");
            }
        }
    }
}

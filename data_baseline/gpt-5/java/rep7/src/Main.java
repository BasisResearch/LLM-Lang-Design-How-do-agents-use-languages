import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.*;

public class Main {
    // Data models
    static class User {
        final int id;
        final String username;
        String password; // stored plain for simplicity
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

    // In-memory storage
    static final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
    static final ConcurrentHashMap<String, User> usersByUsername = new ConcurrentHashMap<>();
    static final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId
    static final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
    static final AtomicInteger userIdSeq = new AtomicInteger(1);
    static final AtomicInteger todoIdSeq = new AtomicInteger(1);

    static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");

    static final DateTimeFormatter ISO_INSTANT_SECONDS = DateTimeFormatter.ISO_INSTANT; // we'll truncate to seconds

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
                i++;
            }
        }
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/", new RootHandler());
        server.setExecutor(Executors.newCachedThreadPool());
        System.out.println("Server listening on 0.0.0.0:" + port);
        server.start();
    }

    static class RootHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            try {
                dispatch(exchange);
            } catch (Exception e) {
                // Internal server error
                sendJson(exchange, 500, jsonError("Internal server error"));
                e.printStackTrace();
            }
        }

        private void dispatch(HttpExchange ex) throws IOException {
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
                Integer uid = requireAuth(ex);
                if (uid == null) return; // response already sent
                handleLogout(ex);
                return;
            }
            if (method.equals("GET") && path.equals("/me")) {
                Integer uid = requireAuth(ex);
                if (uid == null) return;
                handleMe(ex, uid);
                return;
            }
            if (method.equals("PUT") && path.equals("/password")) {
                Integer uid = requireAuth(ex);
                if (uid == null) return;
                handlePasswordChange(ex, uid);
                return;
            }
            if (path.equals("/todos") && method.equals("GET")) {
                Integer uid = requireAuth(ex);
                if (uid == null) return;
                handleTodosList(ex, uid);
                return;
            }
            if (path.equals("/todos") && method.equals("POST")) {
                Integer uid = requireAuth(ex);
                if (uid == null) return;
                handleTodosCreate(ex, uid);
                return;
            }
            if (path.startsWith("/todos/")) {
                Integer uid = requireAuth(ex);
                if (uid == null) return;
                String idStr = path.substring("/todos/".length());
                int id;
                try {
                    id = Integer.parseInt(idStr);
                } catch (NumberFormatException nfe) {
                    sendJson(ex, 404, jsonError("Todo not found"));
                    return;
                }
                if (method.equals("GET")) {
                    handleTodoGet(ex, uid, id);
                    return;
                } else if (method.equals("PUT")) {
                    handleTodoUpdate(ex, uid, id);
                    return;
                } else if (method.equals("DELETE")) {
                    handleTodoDelete(ex, uid, id);
                    return;
                } else {
                    sendJson(ex, 404, jsonError("Not found"));
                    return;
                }
            }

            // Not found
            sendJson(ex, 404, jsonError("Not found"));
        }

        private void handleRegister(HttpExchange ex) throws IOException {
            String body = readBody(ex);
            Map<String, Object> json = SimpleJson.parseObject(body);
            if (json == null) {
                sendJson(ex, 400, jsonError("Invalid JSON"));
                return;
            }
            String username = asString(json.get("username"));
            String password = asString(json.get("password"));
            if (username == null || !USERNAME_PATTERN.matcher(username).matches()) {
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
                User u = new User(id, username, password);
                usersById.put(id, u);
                usersByUsername.put(username, u);
                sendJson(ex, 201, userToJson(u));
            }
        }

        private void handleLogin(HttpExchange ex) throws IOException {
            String body = readBody(ex);
            Map<String, Object> json = SimpleJson.parseObject(body);
            if (json == null) {
                // Treat invalid JSON as invalid credentials? Spec says only username not found or password incorrect -> 401
                sendJson(ex, 401, jsonError("Invalid credentials"));
                return;
            }
            String username = asString(json.get("username"));
            String password = asString(json.get("password"));
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
            Headers headers = ex.getResponseHeaders();
            headers.add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            sendJson(ex, 200, userToJson(u));
        }

        private void handleLogout(HttpExchange ex) throws IOException {
            String token = getSessionTokenFromRequest(ex);
            if (token != null) {
                sessions.remove(token);
            }
            sendJson(ex, 200, "{}");
        }

        private void handleMe(HttpExchange ex, int uid) throws IOException {
            User u = usersById.get(uid);
            if (u == null) {
                sendJson(ex, 401, jsonError("Authentication required"));
                return;
            }
            sendJson(ex, 200, userToJson(u));
        }

        private void handlePasswordChange(HttpExchange ex, int uid) throws IOException {
            String body = readBody(ex);
            Map<String, Object> json = SimpleJson.parseObject(body);
            if (json == null) {
                sendJson(ex, 400, jsonError("Invalid JSON"));
                return;
            }
            String oldp = asString(json.get("old_password"));
            String newp = asString(json.get("new_password"));
            User u = usersById.get(uid);
            if (u == null) {
                sendJson(ex, 401, jsonError("Authentication required"));
                return;
            }
            if (oldp == null || !u.password.equals(oldp)) {
                sendJson(ex, 401, jsonError("Invalid credentials"));
                return;
            }
            if (newp == null || newp.length() < 8) {
                sendJson(ex, 400, jsonError("Password too short"));
                return;
            }
            u.password = newp;
            sendJson(ex, 200, "{}");
        }

        private void handleTodosList(HttpExchange ex, int uid) throws IOException {
            List<Todo> list = new ArrayList<>();
            for (Todo t : todosById.values()) {
                if (t.userId == uid) list.add(t);
            }
            list.sort(Comparator.comparingInt(a -> a.id));
            StringBuilder sb = new StringBuilder();
            sb.append("[");
            boolean first = true;
            for (Todo t : list) {
                if (!first) sb.append(",");
                sb.append(todoToJson(t));
                first = false;
            }
            sb.append("]");
            sendJson(ex, 200, sb.toString());
        }

        private void handleTodosCreate(HttpExchange ex, int uid) throws IOException {
            String body = readBody(ex);
            Map<String, Object> json = SimpleJson.parseObject(body);
            if (json == null) {
                sendJson(ex, 400, jsonError("Invalid JSON"));
                return;
            }
            String title = asString(json.get("title"));
            String description = asString(json.get("description"));
            if (title == null || title.trim().isEmpty()) {
                sendJson(ex, 400, jsonError("Title is required"));
                return;
            }
            if (description == null) description = "";
            int id = todoIdSeq.getAndIncrement();
            String now = nowIso();
            Todo t = new Todo(id, uid, title, description, false, now, now);
            todosById.put(id, t);
            sendJson(ex, 201, todoToJson(t));
        }

        private void handleTodoGet(HttpExchange ex, int uid, int id) throws IOException {
            Todo t = todosById.get(id);
            if (t == null || t.userId != uid) {
                sendJson(ex, 404, jsonError("Todo not found"));
                return;
            }
            sendJson(ex, 200, todoToJson(t));
        }

        private void handleTodoUpdate(HttpExchange ex, int uid, int id) throws IOException {
            Todo t = todosById.get(id);
            if (t == null || t.userId != uid) {
                sendJson(ex, 404, jsonError("Todo not found"));
                return;
            }
            String body = readBody(ex);
            Map<String, Object> json = SimpleJson.parseObject(body);
            if (json == null) {
                sendJson(ex, 400, jsonError("Invalid JSON"));
                return;
            }
            if (json.containsKey("title")) {
                String title = asString(json.get("title"));
                if (title == null || title.trim().isEmpty()) {
                    sendJson(ex, 400, jsonError("Title is required"));
                    return;
                }
                t.title = title;
            }
            if (json.containsKey("description")) {
                String description = asString(json.get("description"));
                t.description = description == null ? "" : description;
            }
            if (json.containsKey("completed")) {
                Boolean b = asBoolean(json.get("completed"));
                if (b != null) t.completed = b.booleanValue();
                else {
                    // If provided but not boolean, treat as invalid JSON
                    sendJson(ex, 400, jsonError("Invalid JSON"));
                    return;
                }
            }
            t.updatedAt = nowIso();
            sendJson(ex, 200, todoToJson(t));
        }

        private void handleTodoDelete(HttpExchange ex, int uid, int id) throws IOException {
            Todo t = todosById.get(id);
            if (t == null || t.userId != uid) {
                // Even for delete, error responses should have JSON
                sendJson(ex, 404, jsonError("Todo not found"));
                return;
            }
            todosById.remove(id);
            // 204 No Content, and per spec no body and no Content-Type
            ex.sendResponseHeaders(204, -1);
            OutputStream os = ex.getResponseBody();
            os.close();
        }

        // Helpers
        private static String readBody(HttpExchange ex) throws IOException {
            InputStream is = ex.getRequestBody();
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
            return baos.toString(StandardCharsets.UTF_8);
        }

        private Integer requireAuth(HttpExchange ex) throws IOException {
            String token = getSessionTokenFromRequest(ex);
            if (token == null) {
                sendJson(ex, 401, jsonError("Authentication required"));
                return null;
            }
            Integer uid = sessions.get(token);
            if (uid == null) {
                sendJson(ex, 401, jsonError("Authentication required"));
                return null;
            }
            return uid;
        }

        private String getSessionTokenFromRequest(HttpExchange ex) {
            List<String> cookies = ex.getRequestHeaders().get("Cookie");
            if (cookies == null) return null;
            for (String header : cookies) {
                String[] parts = header.split(";\\s*");
                for (String p : parts) {
                    int eq = p.indexOf('=');
                    if (eq > 0) {
                        String name = p.substring(0, eq).trim();
                        String val = p.substring(eq + 1).trim();
                        if (name.equals("session_id")) {
                            return val;
                        }
                    }
                }
            }
            return null;
        }

        private static void sendJson(HttpExchange ex, int status, String json) throws IOException {
            Headers headers = ex.getResponseHeaders();
            // For DELETE 204 we don't call this function
            headers.set("Content-Type", "application/json");
            byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
            ex.sendResponseHeaders(status, bytes.length);
            try (OutputStream os = ex.getResponseBody()) {
                os.write(bytes);
            }
        }

        private static String jsonError(String message) {
            return "{\"error\":\"" + SimpleJson.escape(message) + "\"}";
        }

        private static String userToJson(User u) {
            return "{\"id\":" + u.id + ",\"username\":\"" + SimpleJson.escape(u.username) + "\"}";
        }

        private static String todoToJson(Todo t) {
            StringBuilder sb = new StringBuilder();
            sb.append("{");
            sb.append("\"id\":").append(t.id).append(",");
            sb.append("\"title\":\"").append(SimpleJson.escape(t.title)).append("\",");
            sb.append("\"description\":\"").append(SimpleJson.escape(t.description == null ? "" : t.description)).append("\",");
            sb.append("\"completed\":").append(t.completed ? "true" : "false").append(",");
            sb.append("\"created_at\":\"").append(SimpleJson.escape(t.createdAt)).append("\",");
            sb.append("\"updated_at\":\"").append(SimpleJson.escape(t.updatedAt)).append("\"");
            sb.append("}");
            return sb.toString();
        }

        private static String nowIso() {
            Instant now = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS);
            return ISO_INSTANT_SECONDS.format(now);
        }

        private static String asString(Object o) {
            if (o == null) return null;
            if (o instanceof String) return (String)o;
            return String.valueOf(o);
        }
        private static Boolean asBoolean(Object o) {
            if (o instanceof Boolean) return (Boolean)o;
            if (o instanceof String) {
                if (((String)o).equalsIgnoreCase("true")) return Boolean.TRUE;
                if (((String)o).equalsIgnoreCase("false")) return Boolean.FALSE;
            }
            return null;
        }
    }

    // Minimal JSON utilities for our usage
    static class SimpleJson {
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

        static Map<String, Object> parseObject(String s) {
            if (s == null) return null;
            Parser p = new Parser(s);
            try {
                p.skipWs();
                if (!p.consume('{')) return null;
                Map<String, Object> map = new LinkedHashMap<>();
                p.skipWs();
                if (p.peek('}')) { p.consume('}'); return map; }
                while (true) {
                    p.skipWs();
                    String key = p.readString();
                    if (key == null) return null;
                    p.skipWs();
                    if (!p.consume(':')) return null;
                    p.skipWs();
                    Object val = p.readValue();
                    if (val == Parser.ERROR) return null;
                    map.put(key, val);
                    p.skipWs();
                    if (p.consume(',')) {
                        continue;
                    } else if (p.consume('}')) {
                        break;
                    } else {
                        return null;
                    }
                }
                p.skipWs();
                return map;
            } catch (Exception e) {
                return null;
            }
        }

        static class Parser {
            final String s;
            int i = 0;
            static final Object ERROR = new Object();
            Parser(String s) { this.s = s; }
            void skipWs() { while (i < s.length()) { char c = s.charAt(i); if (c==' '||c=='\n'||c=='\r'||c=='\t') i++; else break; } }
            boolean consume(char c) { if (i < s.length() && s.charAt(i)==c) { i++; return true; } return false; }
            boolean peek(char c) { return i < s.length() && s.charAt(i)==c; }
            String readString() {
                if (!consume('"')) return null;
                StringBuilder sb = new StringBuilder();
                while (i < s.length()) {
                    char c = s.charAt(i++);
                    if (c == '"') return sb.toString();
                    if (c == '\\') {
                        if (i >= s.length()) return null;
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
                                if (i + 4 > s.length()) return null;
                                String hex = s.substring(i, i+4);
                                try {
                                    int cp = Integer.parseInt(hex, 16);
                                    sb.append((char)cp);
                                } catch (NumberFormatException nfe) {
                                    return null;
                                }
                                i += 4;
                                break;
                            default: return null;
                        }
                    } else {
                        sb.append(c);
                    }
                }
                return null;
            }
            Object readValue() {
                skipWs();
                if (i >= s.length()) return ERROR;
                char c = s.charAt(i);
                if (c == '"') return readString();
                if (c == 't') { if (readLiteral("true")) return Boolean.TRUE; else return ERROR; }
                if (c == 'f') { if (readLiteral("false")) return Boolean.FALSE; else return ERROR; }
                if (c == 'n') { if (readLiteral("null")) return null; else return ERROR; }
                // number support (simplified integer or decimal)
                if (c == '-' || (c >= '0' && c <= '9')) return readNumber();
                // We do not support arrays for input; treat as error
                return ERROR;
            }
            boolean readLiteral(String lit) {
                if (s.regionMatches(i, lit, 0, lit.length())) { i += lit.length(); return true; } else return false;
            }
            Object readNumber() {
                int start = i;
                if (s.charAt(i) == '-') i++;
                while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
                if (i < s.length() && s.charAt(i) == '.') {
                    i++;
                    while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
                }
                String num = s.substring(start, i);
                try {
                    if (num.indexOf('.') >= 0) return Double.parseDouble(num);
                    else return Long.parseLong(num);
                } catch (NumberFormatException nfe) {
                    return ERROR;
                }
            }
        }
    }
}

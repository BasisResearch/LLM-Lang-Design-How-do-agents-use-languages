import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.*;

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
        ServerState state = new ServerState();
        server.createContext("/", new Router(state));
        server.setExecutor(Executors.newCachedThreadPool());
        System.out.println("Server started on 0.0.0.0:" + port);
        server.start();
    }

    static class ServerState {
        final Map<String, Integer> sessions = new ConcurrentHashMap<>(); // sessionId -> userId
        final Map<Integer, User> usersById = new ConcurrentHashMap<>();
        final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
        final Map<Integer, Todo> todosById = new ConcurrentHashMap<>();
        final AtomicInteger userIdSeq = new AtomicInteger(0);
        final AtomicInteger todoIdSeq = new AtomicInteger(0);
    }

    static class User {
        final int id;
        final String username;
        String password; // stored plaintext for in-memory simplicity
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

    static class Router implements HttpHandler {
        private final ServerState state;
        private final Pattern usernamePattern = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");

        Router(ServerState state) {
            this.state = state;
        }

        @Override
        public void handle(HttpExchange exchange) throws IOException {
            try {
                String method = exchange.getRequestMethod();
                String path = exchange.getRequestURI().getPath();

                if (path.equals("/register") && method.equals("POST")) {
                    handleRegister(exchange);
                    return;
                }
                if (path.equals("/login") && method.equals("POST")) {
                    handleLogin(exchange);
                    return;
                }
                if (path.equals("/logout") && method.equals("POST")) {
                    handleLogout(exchange);
                    return;
                }
                if (path.equals("/me") && method.equals("GET")) {
                    handleMe(exchange);
                    return;
                }
                if (path.equals("/password") && method.equals("PUT")) {
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
                    String idPart = path.substring("/todos/".length());
                    if (idPart.indexOf('/') != -1) {
                        // unexpected extra path
                        notFound(exchange);
                        return;
                    }
                    int id;
                    try { id = Integer.parseInt(idPart); } catch (NumberFormatException e) { notFound(exchange); return; }
                    if (method.equals("GET")) { handleTodosGet(exchange, id); return; }
                    if (method.equals("PUT")) { handleTodosUpdate(exchange, id); return; }
                    if (method.equals("DELETE")) { handleTodosDelete(exchange, id); return; }
                }

                // method not allowed or not found
                if (method.equals("GET") || method.equals("POST") || method.equals("PUT") || method.equals("DELETE")) {
                    notFound(exchange);
                } else {
                    methodNotAllowed(exchange);
                }
            } catch (Exception ex) {
                ex.printStackTrace();
                sendJson(exchange, 500, JsonUtil.obj("error", "Internal server error"));
            }
        }

        private void ensureAuth(HttpExchange exchange) throws IOException, UnauthorizedException {
            String cookieHeader = headerFirst(exchange.getRequestHeaders(), "Cookie");
            if (cookieHeader == null) {
                throw new UnauthorizedException();
            }
            Map<String, String> cookies = parseCookies(cookieHeader);
            String token = cookies.get("session_id");
            if (token == null) {
                throw new UnauthorizedException();
            }
            Integer uid = state.sessions.get(token);
            if (uid == null) {
                throw new UnauthorizedException();
            }
            exchange.setAttribute("userId", uid);
            exchange.setAttribute("sessionToken", token);
        }

        private int currentUserId(HttpExchange exchange) {
            Object o = exchange.getAttribute("userId");
            return (o instanceof Integer) ? (Integer)o : -1;
        }

        private void handleRegister(HttpExchange exchange) throws IOException {
            String body = readBody(exchange);
            Map<String, Object> json;
            try { json = JsonUtil.parseObject(body); } catch (Exception e) {
                sendJson(exchange, 400, JsonUtil.obj("error", "Invalid JSON"));
                return;
            }
            String username = asString(json.get("username"));
            String password = asString(json.get("password"));
            if (username == null || !usernamePattern.matcher(username).matches()) {
                sendJson(exchange, 400, JsonUtil.obj("error", "Invalid username"));
                return;
            }
            if (password == null || password.length() < 8) {
                sendJson(exchange, 400, JsonUtil.obj("error", "Password too short"));
                return;
            }
            synchronized (state) {
                if (state.usersByUsername.containsKey(username)) {
                    sendJson(exchange, 409, JsonUtil.obj("error", "Username already exists"));
                    return;
                }
                int id = state.userIdSeq.incrementAndGet();
                User user = new User(id, username, password);
                state.usersById.put(id, user);
                state.usersByUsername.put(username, user);
                Map<String, Object> resp = new LinkedHashMap<>();
                resp.put("id", id);
                resp.put("username", username);
                sendJson(exchange, 201, resp);
            }
        }

        private void handleLogin(HttpExchange exchange) throws IOException {
            String body = readBody(exchange);
            Map<String, Object> json;
            try { json = JsonUtil.parseObject(body); } catch (Exception e) {
                sendJson(exchange, 400, JsonUtil.obj("error", "Invalid JSON"));
                return;
            }
            String username = asString(json.get("username"));
            String password = asString(json.get("password"));
            if (username == null || password == null) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Invalid credentials"));
                return;
            }
            User user = state.usersByUsername.get(username);
            if (user == null || !user.password.equals(password)) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Invalid credentials"));
                return;
            }
            String token = UUID.randomUUID().toString().replace("-", "");
            state.sessions.put(token, user.id);
            exchange.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("id", user.id);
            resp.put("username", user.username);
            sendJson(exchange, 200, resp);
        }

        private void handleLogout(HttpExchange exchange) throws IOException {
            try {
                ensureAuth(exchange);
            } catch (UnauthorizedException e) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Authentication required"));
                return;
            }
            String token = (String) exchange.getAttribute("sessionToken");
            if (token != null) {
                state.sessions.remove(token);
            }
            sendJson(exchange, 200, new LinkedHashMap<>());
        }

        private void handleMe(HttpExchange exchange) throws IOException {
            try {
                ensureAuth(exchange);
            } catch (UnauthorizedException e) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Authentication required"));
                return;
            }
            int uid = currentUserId(exchange);
            User u = state.usersById.get(uid);
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("id", u.id);
            resp.put("username", u.username);
            sendJson(exchange, 200, resp);
        }

        private void handlePassword(HttpExchange exchange) throws IOException {
            try {
                ensureAuth(exchange);
            } catch (UnauthorizedException e) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Authentication required"));
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> json;
            try { json = JsonUtil.parseObject(body); } catch (Exception e) {
                sendJson(exchange, 400, JsonUtil.obj("error", "Invalid JSON"));
                return;
            }
            String oldPass = asString(json.get("old_password"));
            String newPass = asString(json.get("new_password"));
            int uid = currentUserId(exchange);
            User u = state.usersById.get(uid);
            if (oldPass == null || !u.password.equals(oldPass)) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Invalid credentials"));
                return;
            }
            if (newPass == null || newPass.length() < 8) {
                sendJson(exchange, 400, JsonUtil.obj("error", "Password too short"));
                return;
            }
            u.password = newPass;
            sendJson(exchange, 200, new LinkedHashMap<>());
        }

        private void handleTodosList(HttpExchange exchange) throws IOException {
            try {
                ensureAuth(exchange);
            } catch (UnauthorizedException e) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Authentication required"));
                return;
            }
            int uid = currentUserId(exchange);
            List<Todo> list = new ArrayList<>();
            for (Todo t : state.todosById.values()) {
                if (t.userId == uid) list.add(t);
            }
            list.sort(Comparator.comparingInt(t -> t.id));
            String json = JsonUtil.toJsonTodos(list);
            sendJson(exchange, 200, json);
        }

        private void handleTodosCreate(HttpExchange exchange) throws IOException {
            try {
                ensureAuth(exchange);
            } catch (UnauthorizedException e) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Authentication required"));
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> json;
            try { json = JsonUtil.parseObject(body); } catch (Exception e) {
                sendJson(exchange, 400, JsonUtil.obj("error", "Invalid JSON"));
                return;
            }
            String title = asString(json.get("title"));
            if (title == null || title.trim().isEmpty()) {
                sendJson(exchange, 400, JsonUtil.obj("error", "Title is required"));
                return;
            }
            String description = asString(json.get("description"));
            if (description == null) description = "";
            int uid = currentUserId(exchange);
            int id = state.todoIdSeq.incrementAndGet();
            String now = isoNow();
            Todo t = new Todo(id, uid, title, description, false, now, now);
            state.todosById.put(id, t);
            sendJson(exchange, 201, JsonUtil.todoToJson(t));
        }

        private void handleTodosGet(HttpExchange exchange, int id) throws IOException {
            try {
                ensureAuth(exchange);
            } catch (UnauthorizedException e) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Authentication required"));
                return;
            }
            int uid = currentUserId(exchange);
            Todo t = state.todosById.get(id);
            if (t == null || t.userId != uid) {
                sendJson(exchange, 404, JsonUtil.obj("error", "Todo not found"));
                return;
            }
            sendJson(exchange, 200, JsonUtil.todoToJson(t));
        }

        private void handleTodosUpdate(HttpExchange exchange, int id) throws IOException {
            try {
                ensureAuth(exchange);
            } catch (UnauthorizedException e) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Authentication required"));
                return;
            }
            int uid = currentUserId(exchange);
            Todo t = state.todosById.get(id);
            if (t == null || t.userId != uid) {
                sendJson(exchange, 404, JsonUtil.obj("error", "Todo not found"));
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> json;
            try { json = JsonUtil.parseObject(body); } catch (Exception e) {
                sendJson(exchange, 400, JsonUtil.obj("error", "Invalid JSON"));
                return;
            }
            if (json.containsKey("title")) {
                String title = asString(json.get("title"));
                if (title == null || title.trim().isEmpty()) {
                    sendJson(exchange, 400, JsonUtil.obj("error", "Title is required"));
                    return;
                }
                t.title = title;
            }
            if (json.containsKey("description")) {
                String description = asString(json.get("description"));
                if (description == null) description = "";
                t.description = description;
            }
            if (json.containsKey("completed")) {
                Boolean comp = asBoolean(json.get("completed"));
                if (comp != null) t.completed = comp;
            }
            t.updatedAt = isoNow();
            sendJson(exchange, 200, JsonUtil.todoToJson(t));
        }

        private void handleTodosDelete(HttpExchange exchange, int id) throws IOException {
            try {
                ensureAuth(exchange);
            } catch (UnauthorizedException e) {
                sendJson(exchange, 401, JsonUtil.obj("error", "Authentication required"));
                return;
            }
            int uid = currentUserId(exchange);
            Todo t = state.todosById.get(id);
            if (t == null || t.userId != uid) {
                sendJson(exchange, 404, JsonUtil.obj("error", "Todo not found"));
                return;
            }
            state.todosById.remove(id);
            // 204 No Content, no body
            exchange.getResponseHeaders().remove("Content-Type");
            exchange.sendResponseHeaders(204, -1);
            exchange.close();
        }

        private void notFound(HttpExchange exchange) throws IOException {
            sendJson(exchange, 404, JsonUtil.obj("error", "Not found"));
        }
        private void methodNotAllowed(HttpExchange exchange) throws IOException {
            sendJson(exchange, 405, JsonUtil.obj("error", "Method not allowed"));
        }

        private static String readBody(HttpExchange exchange) throws IOException {
            InputStream is = exchange.getRequestBody();
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = is.read(buf)) != -1) { baos.write(buf, 0, r); }
            return new String(baos.toByteArray(), StandardCharsets.UTF_8);
        }

        private static String headerFirst(Headers headers, String key) {
            List<String> vals = headers.get(key);
            if (vals == null || vals.isEmpty()) return null;
            return vals.get(0);
        }

        private static Map<String, String> parseCookies(String header) {
            Map<String, String> map = new HashMap<>();
            String[] parts = header.split(";\\s*");
            for (String p : parts) {
                int eq = p.indexOf('=');
                if (eq > 0) {
                    String name = p.substring(0, eq).trim();
                    String val = p.substring(eq + 1).trim();
                    map.put(name, val);
                }
            }
            return map;
        }

        private static void sendJson(HttpExchange exchange, int status, Map<String, Object> obj) throws IOException {
            String json = JsonUtil.toJsonObject(obj);
            sendJson(exchange, status, json);
        }
        private static void sendJson(HttpExchange exchange, int status, String json) throws IOException {
            byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
            Headers h = exchange.getResponseHeaders();
            h.set("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        private static String asString(Object o) {
            return (o instanceof String) ? (String)o : null;
        }
        private static Boolean asBoolean(Object o) {
            return (o instanceof Boolean) ? (Boolean)o : null;
        }

        private static String isoNow() {
            return Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
        }

        static class UnauthorizedException extends Exception {}
    }

    static class JsonUtil {
        // Minimal JSON utilities for controlled inputs/outputs
        static Map<String, Object> parseObject(String s) {
            if (s == null) return new LinkedHashMap<>();
            s = s.trim();
            if (s.isEmpty()) return new LinkedHashMap<>();
            if (s.charAt(0) != '{' || s.charAt(s.length()-1) != '}') throw new IllegalArgumentException("Invalid JSON object");
            int i = 1; // after '{'
            Map<String, Object> map = new LinkedHashMap<>();
            while (true) {
                i = skipWs(s, i);
                if (i >= s.length()) throw new IllegalArgumentException("Invalid JSON");
                if (s.charAt(i) == '}') { i++; break; }
                // key
                if (s.charAt(i) != '"') throw new IllegalArgumentException("Expected string key");
                ParseResult keyRes = parseString(s, i);
                String key = (String) keyRes.value;
                i = skipWs(s, keyRes.nextIndex);
                if (i >= s.length() || s.charAt(i) != ':') throw new IllegalArgumentException("Expected :");
                i++;
                i = skipWs(s, i);
                // value: string, boolean, null, number(not needed) -> we only support string/boolean
                char c = s.charAt(i);
                Object val;
                if (c == '"') {
                    ParseResult valRes = parseString(s, i);
                    val = valRes.value;
                    i = valRes.nextIndex;
                } else if (s.startsWith("true", i)) {
                    val = Boolean.TRUE; i += 4;
                } else if (s.startsWith("false", i)) {
                    val = Boolean.FALSE; i += 5;
                } else if (s.startsWith("null", i)) {
                    val = null; i += 4;
                } else {
                    // try to parse a number as string (we don't need numbers), but accept to avoid crash
                    int j = i;
                    while (j < s.length()) {
                        char cj = s.charAt(j);
                        if (cj == ',' || cj == '}' || Character.isWhitespace(cj)) break;
                        j++;
                    }
                    String raw = s.substring(i, j).trim();
                    if (raw.isEmpty()) throw new IllegalArgumentException("Invalid value");
                    val = raw; // store as string
                    i = j;
                }
                map.put(key, val);
                i = skipWs(s, i);
                if (i < s.length() && s.charAt(i) == ',') { i++; continue; }
                if (i < s.length() && s.charAt(i) == '}') { i++; break; }
                if (i >= s.length()) throw new IllegalArgumentException("Invalid JSON");
            }
            return map;
        }

        private static int skipWs(String s, int i) {
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c == ' ' || c == '\n' || c == '\r' || c == '\t') i++; else break;
            }
            return i;
        }

        private static class ParseResult {
            final Object value; final int nextIndex;
            ParseResult(Object v, int n) { this.value = v; this.nextIndex = n; }
        }
        private static ParseResult parseString(String s, int i) {
            if (s.charAt(i) != '"') throw new IllegalArgumentException("Expected string");
            StringBuilder sb = new StringBuilder();
            i++; // skip opening quote
            while (i < s.length()) {
                char c = s.charAt(i++);
                if (c == '"') break;
                if (c == '\\') {
                    if (i >= s.length()) throw new IllegalArgumentException("Invalid escape");
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
                            if (i + 4 > s.length()) throw new IllegalArgumentException("Invalid unicode escape");
                            String hex = s.substring(i, i+4);
                            sb.append((char)Integer.parseInt(hex, 16));
                            i += 4;
                            break;
                        default: throw new IllegalArgumentException("Invalid escape");
                    }
                } else {
                    sb.append(c);
                }
            }
            return new ParseResult(sb.toString(), i);
        }

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

        static String obj(String k, String v) {
            return toJsonObject(Collections.singletonMap(k, v));
        }

        static String toJsonObject(Map<String, Object> map) {
            StringBuilder sb = new StringBuilder();
            sb.append('{');
            boolean first = true;
            for (Map.Entry<String, Object> e : map.entrySet()) {
                if (!first) sb.append(',');
                first = false;
                sb.append('"').append(escape(e.getKey())).append('"').append(':');
                sb.append(toJsonValue(e.getValue()));
            }
            sb.append('}');
            return sb.toString();
        }

        static String toJsonValue(Object v) {
            if (v == null) return "null";
            if (v instanceof String) return '"' + escape((String)v) + '"';
            if (v instanceof Number) return v.toString();
            if (v instanceof Boolean) return ((Boolean)v) ? "true" : "false";
            if (v instanceof Map) return toJsonObject((Map<String, Object>) v);
            if (v instanceof List) return toJsonArray((List<?>) v);
            return '"' + escape(String.valueOf(v)) + '"';
        }

        static String toJsonArray(List<?> list) {
            StringBuilder sb = new StringBuilder();
            sb.append('[');
            boolean first = true;
            for (Object o : list) {
                if (!first) sb.append(',');
                first = false;
                sb.append(toJsonValue(o));
            }
            sb.append(']');
            return sb.toString();
        }

        static String todoToJson(Todo t) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", t.id);
            m.put("title", t.title);
            m.put("description", t.description);
            m.put("completed", t.completed);
            m.put("created_at", t.createdAt);
            m.put("updated_at", t.updatedAt);
            return toJsonObject(m);
        }

        static String toJsonTodos(List<Todo> list) {
            StringBuilder sb = new StringBuilder();
            sb.append('[');
            boolean first = true;
            for (Todo t : list) {
                if (!first) sb.append(',');
                first = false;
                sb.append(todoToJson(t));
            }
            sb.append(']');
            return sb.toString();
        }
    }
}

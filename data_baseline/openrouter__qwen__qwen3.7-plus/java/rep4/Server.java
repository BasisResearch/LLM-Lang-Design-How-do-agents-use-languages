import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpExchange;
import java.net.InetSocketAddress;
import java.util.*;
import java.util.concurrent.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.time.format.DateTimeFormatter;

public class Server {

    static class User {
        int id;
        String username;
        String password;
    }

    static class Todo {
        int id;
        int userId;
        String title;
        String description;
        boolean completed;
        String createdAt;
        String updatedAt;
    }

    static Map<Integer, User> users = new ConcurrentHashMap<>();
    static Map<String, Integer> usernames = new ConcurrentHashMap<>();
    static Map<Integer, Todo> todos = new ConcurrentHashMap<>();
    static Map<String, Integer> sessions = new ConcurrentHashMap<>();

    static int nextUserId = 1;
    static int nextTodoId = 1;
    static final Object userIdLock = new Object();
    static final Object todoIdLock = new Object();

    static String generateToken() {
        return UUID.randomUUID().toString().replace("-", "");
    }

    static String getTimestamp() {
        return DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
                .withZone(ZoneId.of("UTC"))
                .format(Instant.now());
    }

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--port") && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
            }
        }
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/", Server::handle);
        server.setExecutor(Executors.newFixedThreadPool(10));
        server.start();
        System.out.println("Server started on port " + port);
    }

    static void handle(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod();
        String path = exchange.getRequestURI().getPath();

        try {
            if (path.equals("/register") && method.equals("POST")) {
                handleRegister(exchange);
            } else if (path.equals("/login") && method.equals("POST")) {
                handleLogin(exchange);
            } else if (path.equals("/logout") && method.equals("POST")) {
                handleLogout(exchange);
            } else if (path.equals("/me") && method.equals("GET")) {
                handleMe(exchange);
            } else if (path.equals("/password") && method.equals("PUT")) {
                handlePassword(exchange);
            } else if (path.equals("/todos") && method.equals("GET")) {
                handleGetTodos(exchange);
            } else if (path.equals("/todos") && method.equals("POST")) {
                handlePostTodo(exchange);
            } else if (path.matches("^/todos/\\d+$") && method.equals("GET")) {
                handleGetTodo(exchange, path);
            } else if (path.matches("^/todos/\\d+$") && method.equals("PUT")) {
                handlePutTodo(exchange, path);
            } else if (path.matches("^/todos/\\d+$") && method.equals("DELETE")) {
                handleDeleteTodo(exchange, path);
            } else {
                respondJson(exchange, 404, "{\"error\": \"Not found\"}");
            }
        } catch (Exception e) {
            respondJson(exchange, 500, "{\"error\": \"Internal server error\"}");
        }
    }

    static String getAuthToken(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader != null) {
            String[] cookies = cookieHeader.split(";");
            for (String cookie : cookies) {
                cookie = cookie.trim();
                if (cookie.startsWith("session_id=")) {
                    return cookie.substring("session_id=".length());
                }
            }
        }
        return null;
    }

    static Integer getAuthUser(HttpExchange exchange) {
        String token = getAuthToken(exchange);
        if (token != null) {
            return sessions.get(token);
        }
        return null;
    }

    static void respond(HttpExchange exchange, int status, String body, boolean isJson) throws IOException {
        if (isJson && body != null) {
            exchange.getResponseHeaders().set("Content-Type", "application/json");
        }
        byte[] bytes = body != null ? body.getBytes(StandardCharsets.UTF_8) : new byte[0];
        exchange.sendResponseHeaders(status, bytes.length);
        if (bytes.length > 0) {
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        } else {
            exchange.getResponseBody().close();
        }
    }

    static void respondJson(HttpExchange exchange, int status, String body) throws IOException {
        respond(exchange, status, body, true);
    }

    static String readBody(HttpExchange exchange) throws IOException {
        InputStream is = exchange.getRequestBody();
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        int nRead;
        byte[] data = new byte[1024];
        while ((nRead = is.read(data, 0, data.length)) != -1) {
            buffer.write(data, 0, nRead);
        }
        return new String(buffer.toByteArray(), StandardCharsets.UTF_8);
    }

    static void handleRegister(HttpExchange exchange) throws IOException {
        String body = readBody(exchange);
        Map<String, Object> data;
        try {
            data = Json.parseObject(body);
        } catch (Exception e) {
            respondJson(exchange, 400, "{\"error\": \"Invalid JSON\"}");
            return;
        }

        if (!data.containsKey("username") || !(data.get("username") instanceof String)) {
            respondJson(exchange, 400, "{\"error\": \"Invalid username\"}");
            return;
        }
        String username = (String) data.get("username");

        if (username.length() < 3 || username.length() > 50 || !username.matches("^[a-zA-Z0-9_]+$")) {
            respondJson(exchange, 400, "{\"error\": \"Invalid username\"}");
            return;
        }

        if (!data.containsKey("password") || !(data.get("password") instanceof String)) {
            respondJson(exchange, 400, "{\"error\": \"Password too short\"}");
            return;
        }
        String password = (String) data.get("password");
        if (password.length() < 8) {
            respondJson(exchange, 400, "{\"error\": \"Password too short\"}");
            return;
        }

        synchronized (userIdLock) {
            if (usernames.containsKey(username)) {
                respondJson(exchange, 409, "{\"error\": \"Username already exists\"}");
                return;
            }

            int id = nextUserId++;
            User user = new User();
            user.id = id;
            user.username = username;
            user.password = password;

            users.put(id, user);
            usernames.put(username, id);

            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("id", id);
            resp.put("username", username);
            respondJson(exchange, 201, Json.stringify(resp));
        }
    }

    static void handleLogin(HttpExchange exchange) throws IOException {
        String body = readBody(exchange);
        Map<String, Object> data;
        try {
            data = Json.parseObject(body);
        } catch (Exception e) {
            respondJson(exchange, 401, "{\"error\": \"Invalid credentials\"}");
            return;
        }

        Object uObj = data.get("username");
        Object pObj = data.get("password");

        if (!(uObj instanceof String) || !(pObj instanceof String)) {
            respondJson(exchange, 401, "{\"error\": \"Invalid credentials\"}");
            return;
        }

        String username = (String) uObj;
        String password = (String) pObj;

        Integer userId = usernames.get(username);
        if (userId == null) {
            respondJson(exchange, 401, "{\"error\": \"Invalid credentials\"}");
            return;
        }

        User user = users.get(userId);
        if (!user.password.equals(password)) {
            respondJson(exchange, 401, "{\"error\": \"Invalid credentials\"}");
            return;
        }

        String token = generateToken();
        sessions.put(token, userId);

        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("id", user.id);
        resp.put("username", user.username);

        exchange.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        respondJson(exchange, 200, Json.stringify(resp));
    }

    static void handleLogout(HttpExchange exchange) throws IOException {
        Integer userId = getAuthUser(exchange);
        if (userId == null) {
            respondJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return;
        }
        String token = getAuthToken(exchange);
        if (token != null) {
            sessions.remove(token);
        }
        respondJson(exchange, 200, "{}");
    }

    static void handleMe(HttpExchange exchange) throws IOException {
        Integer userId = getAuthUser(exchange);
        if (userId == null) {
            respondJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return;
        }

        User user = users.get(userId);
        if (user == null) {
            respondJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return;
        }

        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("id", user.id);
        resp.put("username", user.username);
        respondJson(exchange, 200, Json.stringify(resp));
    }

    static void handlePassword(HttpExchange exchange) throws IOException {
        Integer userId = getAuthUser(exchange);
        if (userId == null) {
            respondJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return;
        }

        String body = readBody(exchange);
        Map<String, Object> data;
        try {
            data = Json.parseObject(body);
        } catch (Exception e) {
            respondJson(exchange, 400, "{\"error\": \"Invalid request\"}");
            return;
        }

        if (!data.containsKey("old_password") || !(data.get("old_password") instanceof String) ||
            !data.containsKey("new_password") || !(data.get("new_password") instanceof String)) {
            respondJson(exchange, 400, "{\"error\": \"Invalid request\"}");
            return;
        }

        String oldPassword = (String) data.get("old_password");
        String newPassword = (String) data.get("new_password");

        User user = users.get(userId);
        if (!user.password.equals(oldPassword)) {
            respondJson(exchange, 401, "{\"error\": \"Invalid credentials\"}");
            return;
        }

        if (newPassword.length() < 8) {
            respondJson(exchange, 400, "{\"error\": \"Password too short\"}");
            return;
        }

        user.password = newPassword;
        respondJson(exchange, 200, "{}");
    }

    static Map<String, Object> todoToMap(Todo todo) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", todo.id);
        m.put("title", todo.title);
        m.put("description", todo.description);
        m.put("completed", todo.completed);
        m.put("created_at", todo.createdAt);
        m.put("updated_at", todo.updatedAt);
        return m;
    }

    static void handleGetTodos(HttpExchange exchange) throws IOException {
        Integer userId = getAuthUser(exchange);
        if (userId == null) {
            respondJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return;
        }

        List<Map<String, Object>> list = new ArrayList<>();
        for (Todo todo : todos.values()) {
            if (todo.userId == userId) {
                list.add(todoToMap(todo));
            }
        }

        list.sort(Comparator.comparingInt(m -> (Integer) m.get("id")));
        respondJson(exchange, 200, Json.stringify(list));
    }

    static void handlePostTodo(HttpExchange exchange) throws IOException {
        Integer userId = getAuthUser(exchange);
        if (userId == null) {
            respondJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return;
        }

        String body = readBody(exchange);
        Map<String, Object> data;
        try {
            data = Json.parseObject(body);
        } catch (Exception e) {
            respondJson(exchange, 400, "{\"error\": \"Invalid JSON\"}");
            return;
        }

        Object tObj = data.get("title");
        if (!(tObj instanceof String) || ((String) tObj).isEmpty()) {
            respondJson(exchange, 400, "{\"error\": \"Title is required\"}");
            return;
        }

        String title = (String) tObj;
        String description = "";
        if (data.containsKey("description") && data.get("description") instanceof String) {
            description = (String) data.get("description");
        }

        synchronized (todoIdLock) {
            int id = nextTodoId++;
            Todo todo = new Todo();
            todo.id = id;
            todo.userId = userId;
            todo.title = title;
            todo.description = description;
            todo.completed = false;
            String now = getTimestamp();
            todo.createdAt = now;
            todo.updatedAt = now;

            todos.put(id, todo);
            respondJson(exchange, 201, Json.stringify(todoToMap(todo)));
        }
    }

    static void handleGetTodo(HttpExchange exchange, String path) throws IOException {
        Integer userId = getAuthUser(exchange);
        if (userId == null) {
            respondJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return;
        }

        int id = Integer.parseInt(path.substring("/todos/".length()));
        Todo todo = todos.get(id);
        if (todo == null || todo.userId != userId) {
            respondJson(exchange, 404, "{\"error\": \"Todo not found\"}");
            return;
        }

        respondJson(exchange, 200, Json.stringify(todoToMap(todo)));
    }

    static void handlePutTodo(HttpExchange exchange, String path) throws IOException {
        Integer userId = getAuthUser(exchange);
        if (userId == null) {
            respondJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return;
        }

        int id = Integer.parseInt(path.substring("/todos/".length()));
        Todo todo = todos.get(id);
        if (todo == null || todo.userId != userId) {
            respondJson(exchange, 404, "{\"error\": \"Todo not found\"}");
            return;
        }

        String body = readBody(exchange);
        Map<String, Object> data;
        try {
            data = Json.parseObject(body);
        } catch (Exception e) {
            respondJson(exchange, 400, "{\"error\": \"Invalid JSON\"}");
            return;
        }

        if (data.containsKey("title")) {
            Object tObj = data.get("title");
            if (!(tObj instanceof String) || ((String) tObj).isEmpty()) {
                respondJson(exchange, 400, "{\"error\": \"Title is required\"}");
                return;
            }
            todo.title = (String) tObj;
        }

        if (data.containsKey("description")) {
            Object dObj = data.get("description");
            if (dObj instanceof String) {
                todo.description = (String) dObj;
            }
        }

        if (data.containsKey("completed")) {
            Object cObj = data.get("completed");
            if (cObj instanceof Boolean) {
                todo.completed = (Boolean) cObj;
            }
        }

        todo.updatedAt = getTimestamp();
        respondJson(exchange, 200, Json.stringify(todoToMap(todo)));
    }

    static void handleDeleteTodo(HttpExchange exchange, String path) throws IOException {
        Integer userId = getAuthUser(exchange);
        if (userId == null) {
            respondJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return;
        }

        int id = Integer.parseInt(path.substring("/todos/".length()));
        Todo todo = todos.get(id);
        if (todo == null || todo.userId != userId) {
            respondJson(exchange, 404, "{\"error\": \"Todo not found\"}");
            return;
        }

        todos.remove(id);
        respond(exchange, 204, "", false);
    }

    static class Json {
        static Map<String, Object> parseObject(String s) {
            Map<String, Object> map = new LinkedHashMap<>();
            s = s.trim();
            if (!s.startsWith("{") || !s.endsWith("}")) {
                throw new RuntimeException("Invalid JSON object");
            }
            s = s.substring(1, s.length() - 1).trim();
            if (s.isEmpty()) return map;

            int i = 0;
            while (i < s.length()) {
                while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
                if (i >= s.length()) break;

                if (s.charAt(i) != '"') throw new RuntimeException("Expected '\"' at " + i);
                i++;
                int start = i;
                while (i < s.length() && s.charAt(i) != '"') {
                    if (s.charAt(i) == '\\') i++;
                    i++;
                }
                String key = unescape(s.substring(start, i));
                i++;

                while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
                if (i >= s.length() || s.charAt(i) != ':') throw new RuntimeException("Expected ':'");
                i++;

                while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;

                Object value = null;
                if (s.charAt(i) == '"') {
                    i++;
                    start = i;
                    while (i < s.length() && s.charAt(i) != '"') {
                        if (s.charAt(i) == '\\') i++;
                        i++;
                    }
                    value = unescape(s.substring(start, i));
                    i++;
                } else if (s.regionMatches(i, "true", 0, 4)) {
                    value = true; i += 4;
                } else if (s.regionMatches(i, "false", 0, 5)) {
                    value = false; i += 5;
                } else if (s.regionMatches(i, "null", 0, 4)) {
                    value = null; i += 4;
                } else {
                    start = i;
                    while (i < s.length() && (Character.isDigit(s.charAt(i)) || s.charAt(i) == '.' || s.charAt(i) == '-' || s.charAt(i) == 'e' || s.charAt(i) == 'E' || s.charAt(i) == '+')) i++;
                    String numStr = s.substring(start, i);
                    if (numStr.contains(".") || numStr.contains("e") || numStr.contains("E")) {
                        value = Double.parseDouble(numStr);
                    } else {
                        value = Long.parseLong(numStr);
                    }
                }

                map.put(key, value);

                while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
                if (i < s.length() && s.charAt(i) == ',') i++;
            }
            return map;
        }

        static String unescape(String s) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c == '\\' && i + 1 < s.length()) {
                    char next = s.charAt(i + 1);
                    if (next == '"') { sb.append('"'); i++; }
                    else if (next == '\\') { sb.append('\\'); i++; }
                    else if (next == 'n') { sb.append('\n'); i++; }
                    else if (next == 'r') { sb.append('\r'); i++; }
                    else if (next == 't') { sb.append('\t'); i++; }
                    else { sb.append(c); }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }

        static String stringify(Object obj) {
            if (obj == null) return "null";
            if (obj instanceof String) {
                String str = (String) obj;
                StringBuilder sb = new StringBuilder("\"");
                for (int i = 0; i < str.length(); i++) {
                    char c = str.charAt(i);
                    if (c == '"') sb.append("\\\"");
                    else if (c == '\\') sb.append("\\\\");
                    else if (c == '\n') sb.append("\\n");
                    else if (c == '\r') sb.append("\\r");
                    else if (c == '\t') sb.append("\\t");
                    else sb.append(c);
                }
                sb.append("\"");
                return sb.toString();
            }
            if (obj instanceof Boolean) return obj.toString();
            if (obj instanceof Number) return obj.toString();
            if (obj instanceof Map) {
                StringBuilder sb = new StringBuilder("{");
                boolean first = true;
                for (Map.Entry<?, ?> e : ((Map<?, ?>) obj).entrySet()) {
                    if (!first) sb.append(",");
                    sb.append(stringify(e.getKey())).append(":").append(stringify(e.getValue()));
                    first = false;
                }
                sb.append("}");
                return sb.toString();
            }
            if (obj instanceof List) {
                StringBuilder sb = new StringBuilder("[");
                boolean first = true;
                for (Object e : (List<?>) obj) {
                    if (!first) sb.append(",");
                    sb.append(stringify(e));
                    first = false;
                }
                sb.append("]");
                return sb.toString();
            }
            return obj.toString();
        }
    }
}

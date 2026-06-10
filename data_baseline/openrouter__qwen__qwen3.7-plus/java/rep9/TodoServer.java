import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

public class TodoServer {
    static Map<String, User> users = new ConcurrentHashMap<>();
    static Map<Integer, Todo> todos = new ConcurrentHashMap<>();
    static Map<String, Integer> sessions = new ConcurrentHashMap<>();
    static AtomicInteger nextUserId = new AtomicInteger(1);
    static AtomicInteger nextTodoId = new AtomicInteger(1);

    static class User {
        int id;
        String username;
        String password;
        public User(int id, String username, String password) {
            this.id = id;
            this.username = username;
            this.password = password;
        }
    }

    static class Todo {
        int id;
        int userId;
        String title;
        String description;
        boolean completed;
        String createdAt;
        String updatedAt;

        public Todo(int id, int userId, String title, String description, boolean completed, String createdAt, String updatedAt) {
            this.id = id;
            this.userId = userId;
            this.title = title;
            this.description = description;
            this.completed = completed;
            this.createdAt = createdAt;
            this.updatedAt = updatedAt;
        }

        public Map<String, Object> toMap() {
            return mapOf(
                "id", id,
                "title", title,
                "description", description,
                "completed", completed,
                "created_at", createdAt,
                "updated_at", updatedAt
            );
        }
    }

    static Map<String, Object> mapOf(Object... entries) {
        Map<String, Object> map = new LinkedHashMap<>();
        for (int i = 0; i < entries.length; i += 2) {
            map.put((String) entries[i], entries[i + 1]);
        }
        return map;
    }

    static String getIso8601() {
        return ZonedDateTime.now(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }

    static String readBody(HttpExchange exchange) throws IOException {
        InputStream is = exchange.getRequestBody();
        return new String(is.readAllBytes(), StandardCharsets.UTF_8);
    }

    static void sendJson(HttpExchange exchange, int code, Object data) throws IOException {
        String json = JsonGen.stringify(data);
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(code, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    static void sendError(HttpExchange exchange, int code, String message) throws IOException {
        sendJson(exchange, code, mapOf("error", message));
    }

    static Integer getUserIdFromSession(HttpExchange exchange) {
        List<String> cookies = exchange.getRequestHeaders().get("Cookie");
        if (cookies != null) {
            for (String cookie : cookies) {
                String[] parts = cookie.split(";");
                for (String part : parts) {
                    part = part.trim();
                    if (part.startsWith("session_id=")) {
                        String token = part.substring("session_id=".length());
                        return sessions.get(token);
                    }
                }
            }
        }
        return null;
    }

    static boolean requireAuth(HttpExchange exchange) throws IOException {
        Integer userId = getUserIdFromSession(exchange);
        if (userId == null) {
            sendError(exchange, 401, "Authentication required");
            return false;
        }
        return true;
    }

    static User getUserById(int id) {
        for (User u : users.values()) {
            if (u.id == id) return u;
        }
        return null;
    }

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--port") && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
            }
        }

        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/register", new RegisterHandler());
        server.createContext("/login", new LoginHandler());
        server.createContext("/logout", new LogoutHandler());
        server.createContext("/me", new MeHandler());
        server.createContext("/password", new PasswordHandler());
        server.createContext("/todos", new TodosHandler());
        server.createContext("/todos/", new TodoHandler());

        server.setExecutor(null);
        server.start();
        System.out.println("Server started on port " + port);
    }

    static class RegisterHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("POST")) {
                sendError(exchange, 405, "Method not allowed");
                return;
            }
            String body = readBody(exchange);
            JsonParser parser = new JsonParser(body);
            Map<String, Object> req;
            try {
                req = parser.readObject();
            } catch (Exception e) {
                sendError(exchange, 400, "Invalid JSON");
                return;
            }

            if (!(req.get("username") instanceof String)) {
                sendError(exchange, 400, "Invalid username");
                return;
            }
            String username = (String) req.get("username");

            if (!(req.get("password") instanceof String)) {
                sendError(exchange, 400, "Password too short");
                return;
            }
            String password = (String) req.get("password");

            if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
                sendError(exchange, 400, "Invalid username");
                return;
            }

            if (password.length() < 8) {
                sendError(exchange, 400, "Password too short");
                return;
            }

            synchronized (users) {
                if (users.containsKey(username)) {
                    sendError(exchange, 409, "Username already exists");
                    return;
                }
                int id = nextUserId.getAndIncrement();
                User user = new User(id, username, password);
                users.put(username, user);
                sendJson(exchange, 201, mapOf("id", id, "username", username));
            }
        }
    }

    static class LoginHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("POST")) {
                sendError(exchange, 405, "Method not allowed");
                return;
            }
            String body = readBody(exchange);
            JsonParser parser = new JsonParser(body);
            Map<String, Object> req;
            try {
                req = parser.readObject();
            } catch (Exception e) {
                sendError(exchange, 400, "Invalid JSON");
                return;
            }

            if (!(req.get("username") instanceof String) || !(req.get("password") instanceof String)) {
                sendError(exchange, 401, "Invalid credentials");
                return;
            }

            String username = (String) req.get("username");
            String password = (String) req.get("password");

            User user = users.get(username);
            if (user == null || !user.password.equals(password)) {
                sendError(exchange, 401, "Invalid credentials");
                return;
            }

            String token = UUID.randomUUID().toString();
            sessions.put(token, user.id);
            exchange.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            sendJson(exchange, 200, mapOf("id", user.id, "username", user.username));
        }
    }

    static class LogoutHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("POST")) {
                sendError(exchange, 405, "Method not allowed");
                return;
            }
            if (!requireAuth(exchange)) return;

            List<String> cookies = exchange.getRequestHeaders().get("Cookie");
            if (cookies != null) {
                for (String cookie : cookies) {
                    String[] parts = cookie.split(";");
                    for (String part : parts) {
                        part = part.trim();
                        if (part.startsWith("session_id=")) {
                            String token = part.substring("session_id=".length());
                            sessions.remove(token);
                        }
                    }
                }
            }
            sendJson(exchange, 200, new LinkedHashMap<>());
        }
    }

    static class MeHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("GET")) {
                sendError(exchange, 405, "Method not allowed");
                return;
            }
            if (!requireAuth(exchange)) return;

            Integer userId = getUserIdFromSession(exchange);
            User user = getUserById(userId);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            sendJson(exchange, 200, mapOf("id", user.id, "username", user.username));
        }
    }

    static class PasswordHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("PUT")) {
                sendError(exchange, 405, "Method not allowed");
                return;
            }
            if (!requireAuth(exchange)) return;

            Integer userId = getUserIdFromSession(exchange);
            User user = getUserById(userId);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }

            String body = readBody(exchange);
            JsonParser parser = new JsonParser(body);
            Map<String, Object> req;
            try {
                req = parser.readObject();
            } catch (Exception e) {
                sendError(exchange, 400, "Invalid JSON");
                return;
            }

            if (!(req.get("old_password") instanceof String) || !(req.get("new_password") instanceof String)) {
                sendError(exchange, 401, "Invalid credentials");
                return;
            }

            String oldPassword = (String) req.get("old_password");
            String newPassword = (String) req.get("new_password");

            if (!user.password.equals(oldPassword)) {
                sendError(exchange, 401, "Invalid credentials");
                return;
            }

            if (newPassword.length() < 8) {
                sendError(exchange, 400, "Password too short");
                return;
            }

            user.password = newPassword;
            sendJson(exchange, 200, new LinkedHashMap<>());
        }
    }

    static class TodosHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (exchange.getRequestMethod().equals("GET")) {
                if (!requireAuth(exchange)) return;
                Integer userId = getUserIdFromSession(exchange);

                List<Map<String, Object>> result = new ArrayList<>();
                synchronized (todos) {
                    for (Todo todo : todos.values()) {
                        if (todo.userId == userId) {
                            result.add(todo.toMap());
                        }
                    }
                }
                result.sort((a, b) -> Integer.compare((Integer) a.get("id"), (Integer) b.get("id")));
                sendJson(exchange, 200, result);
                return;
            }

            if (exchange.getRequestMethod().equals("POST")) {
                if (!requireAuth(exchange)) return;
                Integer userId = getUserIdFromSession(exchange);

                String body = readBody(exchange);
                JsonParser parser = new JsonParser(body);
                Map<String, Object> req;
                try {
                    req = parser.readObject();
                } catch (Exception e) {
                    sendError(exchange, 400, "Invalid JSON");
                    return;
                }

                if (!req.containsKey("title") || !(req.get("title") instanceof String)) {
                    sendError(exchange, 400, "Title is required");
                    return;
                }

                String title = (String) req.get("title");
                if (title.isEmpty()) {
                    sendError(exchange, 400, "Title is required");
                    return;
                }

                String description = req.containsKey("description") && req.get("description") instanceof String 
                    ? (String) req.get("description") : "";

                String now = getIso8601();
                int id = nextTodoId.getAndIncrement();
                Todo todo = new Todo(id, userId, title, description, false, now, now);

                synchronized (todos) {
                    todos.put(id, todo);
                }

                sendJson(exchange, 201, todo.toMap());
                return;
            }

            sendError(exchange, 405, "Method not allowed");
        }
    }

    static class TodoHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            String path = exchange.getRequestURI().getPath();
            String[] parts = path.split("/");
            
            if (parts.length >= 3 && parts[1].equals("todos") && !parts[2].isEmpty()) {
                int todoId;
                try {
                    todoId = Integer.parseInt(parts[2]);
                } catch (NumberFormatException e) {
                    sendError(exchange, 404, "Todo not found");
                    return;
                }

                if (!requireAuth(exchange)) return;
                Integer userId = getUserIdFromSession(exchange);

                Todo todo;
                synchronized (todos) {
                    todo = todos.get(todoId);
                }

                if (todo == null || todo.userId != userId) {
                    sendError(exchange, 404, "Todo not found");
                    return;
                }

                if (exchange.getRequestMethod().equals("GET")) {
                    sendJson(exchange, 200, todo.toMap());
                } else if (exchange.getRequestMethod().equals("PUT")) {
                    String body = readBody(exchange);
                    JsonParser parser = new JsonParser(body);
                    Map<String, Object> req;
                    try {
                        req = parser.readObject();
                    } catch (Exception e) {
                        sendError(exchange, 400, "Invalid JSON");
                        return;
                    }

                    Map<String, Object> responseMap;
                    synchronized (todos) {
                        if (req.containsKey("title")) {
                            if (!(req.get("title") instanceof String) || ((String) req.get("title")).isEmpty()) {
                                sendError(exchange, 400, "Title is required");
                                return;
                            }
                            todo.title = (String) req.get("title");
                        }

                        if (req.containsKey("description")) {
                            todo.description = req.get("description") instanceof String ? (String) req.get("description") : "";
                        }

                        if (req.containsKey("completed")) {
                            if (req.get("completed") instanceof Boolean) {
                                todo.completed = (Boolean) req.get("completed");
                            }
                        }

                        todo.updatedAt = getIso8601();
                        responseMap = todo.toMap();
                    }
                    sendJson(exchange, 200, responseMap);
                } else if (exchange.getRequestMethod().equals("DELETE")) {
                    synchronized (todos) {
                        todos.remove(todoId);
                    }
                    exchange.getResponseHeaders().set("Content-Type", "application/json");
                    exchange.sendResponseHeaders(204, -1);
                } else {
                    sendError(exchange, 405, "Method not allowed");
                }
            } else {
                sendError(exchange, 404, "Not found");
            }
        }
    }

    static class JsonParser {
        String json;
        int pos;

        public JsonParser(String json) {
            this.json = json;
            this.pos = 0;
        }

        void skipWhitespace() {
            while (pos < json.length() && Character.isWhitespace(json.charAt(pos))) pos++;
        }

        char peek() {
            skipWhitespace();
            return pos < json.length() ? json.charAt(pos) : '\0';
        }

        boolean match(char c) {
            skipWhitespace();
            if (pos < json.length() && json.charAt(pos) == c) {
                pos++;
                return true;
            }
            return false;
        }

        void expect(char c) {
            if (!match(c)) throw new RuntimeException("Expected '" + c + "'");
        }

        String readString() {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (pos < json.length()) {
                char c = json.charAt(pos++);
                if (c == '"') break;
                if (c == '\\') {
                    if (pos < json.length()) {
                        char esc = json.charAt(pos++);
                        if (esc == 'n') sb.append('\n');
                        else if (esc == 't') sb.append('\t');
                        else if (esc == 'r') sb.append('\r');
                        else if (esc == '\\') sb.append('\\');
                        else if (esc == '"') sb.append('"');
                        else sb.append(esc);
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }

        Object readValue() {
            skipWhitespace();
            if (pos >= json.length()) return null;
            char c = json.charAt(pos);
            if (c == '"') return readString();
            if (c == '{') return readObject();
            if (c == '[') return readArray();
            if (json.startsWith("true", pos)) { pos += 4; return true; }
            if (json.startsWith("false", pos)) { pos += 5; return false; }
            if (json.startsWith("null", pos)) { pos += 4; return null; }
            
            int start = pos;
            if (c == '-') pos++;
            while (pos < json.length() && (Character.isDigit(json.charAt(pos)) || json.charAt(pos) == '.' || json.charAt(pos) == 'e' || json.charAt(pos) == 'E' || json.charAt(pos) == '+' || json.charAt(pos) == '-')) {
                pos++;
            }
            String numStr = json.substring(start, pos);
            if (numStr.isEmpty()) return null;
            if (numStr.contains(".") || numStr.contains("e") || numStr.contains("E")) {
                return Double.parseDouble(numStr);
            }
            return Long.parseLong(numStr);
        }

        Map<String, Object> readObject() {
            expect('{');
            Map<String, Object> map = new LinkedHashMap<>();
            if (peek() == '}') { pos++; return map; }
            do {
                String key = readString();
                expect(':');
                Object value = readValue();
                map.put(key, value);
            } while (match(','));
            expect('}');
            return map;
        }

        List<Object> readArray() {
            expect('[');
            List<Object> list = new ArrayList<>();
            if (peek() == ']') { pos++; return list; }
            do {
                list.add(readValue());
            } while (match(','));
            expect(']');
            return list;
        }
    }

    static class JsonGen {
        static String stringify(Object obj) {
            if (obj == null) return "null";
            if (obj instanceof String) {
                String s = (String) obj;
                StringBuilder sb = new StringBuilder("\"");
                for (int i = 0; i < s.length(); i++) {
                    char c = s.charAt(i);
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
            if (obj instanceof Number) return obj.toString();
            if (obj instanceof Boolean) return obj.toString();
            if (obj instanceof Map) {
                Map<?, ?> map = (Map<?, ?>) obj;
                StringBuilder sb = new StringBuilder("{");
                boolean first = true;
                for (Map.Entry<?, ?> entry : map.entrySet()) {
                    if (!first) sb.append(",");
                    first = false;
                    sb.append(stringify(entry.getKey().toString())).append(":").append(stringify(entry.getValue()));
                }
                sb.append("}");
                return sb.toString();
            }
            if (obj instanceof List) {
                List<?> list = (List<?>) obj;
                StringBuilder sb = new StringBuilder("[");
                boolean first = true;
                for (Object item : list) {
                    if (!first) sb.append(",");
                    first = false;
                    sb.append(stringify(item));
                }
                sb.append("]");
                return sb.toString();
            }
            return "null";
        }
    }
}
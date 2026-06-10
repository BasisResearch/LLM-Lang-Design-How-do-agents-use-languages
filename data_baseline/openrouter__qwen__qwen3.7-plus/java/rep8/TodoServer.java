import com.sun.net.httpserver.*;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.*;
import java.time.*;
import java.time.format.*;
import java.util.*;
import java.util.stream.*;

public class TodoServer {
    private static final DateTimeFormatter ISO_FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);
    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]+$");
    private static final AtomicInteger userIdCounter = new AtomicInteger(0);
    private static final AtomicInteger todoIdCounter = new AtomicInteger(0);
    
    private static final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, User> usersByUsername = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, User> sessions = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
    
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

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i+1]);
            }
        }
        
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/register", new RegisterHandler());
        server.createContext("/login", new LoginHandler());
        server.createContext("/logout", new LogoutHandler());
        server.createContext("/me", new MeHandler());
        server.createContext("/password", new PasswordHandler());
        server.createContext("/todos", new TodosHandler());
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server started on port " + port);
    }
    
    static String escapeJson(String s) {
        if (s == null) return "null";
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
                    if (c < ' ') {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.toString();
    }

    static void sendJson(HttpExchange exchange, int statusCode, String json) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(statusCode, body.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(body);
        }
    }

    static String getSessionId(HttpExchange exchange) {
        String cookies = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookies != null) {
            String[] parts = cookies.split(";");
            for (String part : parts) {
                part = part.trim();
                if (part.startsWith("session_id=")) {
                    return part.substring("session_id=".length());
                }
            }
        }
        return null;
    }

    static User checkAuth(HttpExchange exchange) throws IOException {
        String sessionId = getSessionId(exchange);
        if (sessionId == null) {
            sendJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return null;
        }
        User user = sessions.get(sessionId);
        if (user == null) {
            sendJson(exchange, 401, "{\"error\": \"Authentication required\"}");
            return null;
        }
        return user;
    }

    static String todoToJson(Todo todo) {
        return "{" +
            "\"id\": " + todo.id + "," +
            "\"title\": \"" + escapeJson(todo.title) + "\"," +
            "\"description\": \"" + escapeJson(todo.description) + "\"," +
            "\"completed\": " + todo.completed + "," +
            "\"created_at\": \"" + todo.createdAt + "\"," +
            "\"updated_at\": \"" + todo.updatedAt + "\"" +
            "}";
    }

    static class JsonParser {
        public static String extract(String json, String key) {
            String pattern = "\"" + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"";
            Pattern p = Pattern.compile(pattern);
            Matcher m = p.matcher(json);
            if (m.find()) {
                return m.group(1).replace("\\\"", "\"").replace("\\\\", "\\");
            }
            return null;
        }
        
        public static Boolean extractBoolean(String json, String key) {
            String pattern = "\"" + key + "\"\\s*:\\s*(true|false)";
            Pattern p = Pattern.compile(pattern);
            Matcher m = p.matcher(json);
            if (m.find()) {
                return Boolean.parseBoolean(m.group(1));
            }
            return null;
        }
    }

    static class RegisterHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendJson(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            String body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            String username = JsonParser.extract(body, "username");
            String password = JsonParser.extract(body, "password");

            if (username == null || username.length() < 3 || username.length() > 50 || !USERNAME_PATTERN.matcher(username).matches()) {
                sendJson(exchange, 400, "{\"error\": \"Invalid username\"}");
                return;
            }
            if (password == null || password.length() < 8) {
                sendJson(exchange, 400, "{\"error\": \"Password too short\"}");
                return;
            }
            
            User newUser = new User();
            newUser.id = userIdCounter.incrementAndGet();
            newUser.username = username;
            newUser.password = password;
            
            if (usersByUsername.putIfAbsent(username, newUser) != null) {
                sendJson(exchange, 409, "{\"error\": \"Username already exists\"}");
                return;
            }
            
            usersById.put(newUser.id, newUser);
            sendJson(exchange, 201, "{\"id\": " + newUser.id + ", \"username\": \"" + escapeJson(username) + "\"}");
        }
    }

    static class LoginHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendJson(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            String body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            String username = JsonParser.extract(body, "username");
            String password = JsonParser.extract(body, "password");
            
            User user = usersByUsername.get(username);
            if (user == null || !user.password.equals(password)) {
                sendJson(exchange, 401, "{\"error\": \"Invalid credentials\"}");
                return;
            }
            
            String token = java.util.UUID.randomUUID().toString().replace("-", "");
            sessions.put(token, user);
            
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.getResponseHeaders().set("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            byte[] resp = ("{\"id\": " + user.id + ", \"username\": \"" + escapeJson(user.username) + "\"}").getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, resp.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(resp);
            }
        }
    }

    static class LogoutHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendJson(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            User user = checkAuth(exchange);
            if (user == null) return;
            
            String sessionId = getSessionId(exchange);
            sessions.remove(sessionId);
            sendJson(exchange, 200, "{}");
        }
    }

    static class MeHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!"GET".equals(exchange.getRequestMethod())) {
                sendJson(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            User user = checkAuth(exchange);
            if (user == null) return;
            sendJson(exchange, 200, "{\"id\": " + user.id + ", \"username\": \"" + escapeJson(user.username) + "\"}");
        }
    }

    static class PasswordHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            if (!"PUT".equals(exchange.getRequestMethod())) {
                sendJson(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            User user = checkAuth(exchange);
            if (user == null) return;
            
            String body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            String oldPassword = JsonParser.extract(body, "old_password");
            String newPassword = JsonParser.extract(body, "new_password");
            
            if (!user.password.equals(oldPassword)) {
                sendJson(exchange, 401, "{\"error\": \"Invalid credentials\"}");
                return;
            }
            if (newPassword == null || newPassword.length() < 8) {
                sendJson(exchange, 400, "{\"error\": \"Password too short\"}");
                return;
            }
            
            user.password = newPassword;
            sendJson(exchange, 200, "{}");
        }
    }

    static class TodosHandler implements HttpHandler {
        public void handle(HttpExchange exchange) throws IOException {
            String path = exchange.getRequestURI().getPath();
            String method = exchange.getRequestMethod();
            
            if (path.equals("/todos")) {
                if ("GET".equals(method)) {
                    handleGetAll(exchange);
                } else if ("POST".equals(method)) {
                    handlePost(exchange);
                } else {
                    sendJson(exchange, 405, "{\"error\": \"Method not allowed\"}");
                }
            } else if (path.startsWith("/todos/")) {
                String idStr = path.substring(7);
                int todoId;
                try {
                    todoId = Integer.parseInt(idStr);
                } catch (NumberFormatException e) {
                    sendJson(exchange, 404, "{\"error\": \"Todo not found\"}");
                    return;
                }
                if ("GET".equals(method)) {
                    handleGetOne(exchange, todoId);
                } else if ("PUT".equals(method)) {
                    handlePut(exchange, todoId);
                } else if ("DELETE".equals(method)) {
                    handleDelete(exchange, todoId);
                } else {
                    sendJson(exchange, 405, "{\"error\": \"Method not allowed\"}");
                }
            } else {
                sendJson(exchange, 404, "{\"error\": \"Not found\"}");
            }
        }
        
        private void handleGetAll(HttpExchange exchange) throws IOException {
            User user = checkAuth(exchange);
            if (user == null) return;
            
            List<Todo> userTodos = todosById.values().stream()
                .filter(t -> t.userId == user.id)
                .sorted(Comparator.comparingInt(t -> t.id))
                .collect(Collectors.toList());
                
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < userTodos.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(todoToJson(userTodos.get(i)));
            }
            sb.append("]");
            sendJson(exchange, 200, sb.toString());
        }

        private void handlePost(HttpExchange exchange) throws IOException {
            User user = checkAuth(exchange);
            if (user == null) return;
            
            String body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            String title = JsonParser.extract(body, "title");
            String description = JsonParser.extract(body, "description");
            
            if (title == null || title.isEmpty()) {
                sendJson(exchange, 400, "{\"error\": \"Title is required\"}");
                return;
            }
            
            Todo newTodo = new Todo();
            newTodo.id = todoIdCounter.incrementAndGet();
            newTodo.userId = user.id;
            newTodo.title = title;
            newTodo.description = description == null ? "" : description;
            newTodo.completed = false;
            newTodo.createdAt = ISO_FORMATTER.format(Instant.now());
            newTodo.updatedAt = newTodo.createdAt;
            
            todosById.put(newTodo.id, newTodo);
            sendJson(exchange, 201, todoToJson(newTodo));
        }

        private void handleGetOne(HttpExchange exchange, int todoId) throws IOException {
            User user = checkAuth(exchange);
            if (user == null) return;
            
            Todo todo = todosById.get(todoId);
            if (todo == null || todo.userId != user.id) {
                sendJson(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            sendJson(exchange, 200, todoToJson(todo));
        }

        private void handlePut(HttpExchange exchange, int todoId) throws IOException {
            User user = checkAuth(exchange);
            if (user == null) return;
            
            Todo todo = todosById.get(todoId);
            if (todo == null || todo.userId != user.id) {
                sendJson(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            String body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            String title = JsonParser.extract(body, "title");
            String description = JsonParser.extract(body, "description");
            Boolean completed = JsonParser.extractBoolean(body, "completed");
            
            if (title != null && title.isEmpty()) {
                sendJson(exchange, 400, "{\"error\": \"Title is required\"}");
                return;
            }
            
            if (title != null) todo.title = title;
            if (description != null) todo.description = description;
            if (completed != null) todo.completed = completed;
            
            todo.updatedAt = ISO_FORMATTER.format(Instant.now());
            sendJson(exchange, 200, todoToJson(todo));
        }

        private void handleDelete(HttpExchange exchange, int todoId) throws IOException {
            User user = checkAuth(exchange);
            if (user == null) return;
            
            Todo todo = todosById.get(todoId);
            if (todo == null || todo.userId != user.id) {
                sendJson(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            todosById.remove(todoId);
            exchange.sendResponseHeaders(204, -1);
        }
    }
}
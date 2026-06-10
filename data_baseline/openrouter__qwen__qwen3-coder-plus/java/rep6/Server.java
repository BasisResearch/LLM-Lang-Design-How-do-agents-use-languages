import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;

import java.io.IOException;
import java.io.OutputStream;
import java.util.concurrent.ConcurrentHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.time.Instant;
import java.util.regex.Pattern;
import java.util.List;
import java.util.ArrayList;
import java.util.UUID;

// Simple utility for JSON parsing - minimal implementation using only standard Java
class JsonParser {
    public static Map<String, Object> parse(String jsonString) {
        if (jsonString == null || jsonString.trim().isEmpty()) {
            return null;
        }
        
        jsonString = jsonString.trim();
        if (!jsonString.startsWith("{") || !jsonString.endsWith("}")) {
            return null;
        }
        
        Map<String, Object> result = new java.util.LinkedHashMap<>();
        
        // Extract content inside the main object braces
        String content = jsonString.substring(1, jsonString.length() - 1).trim();
        if (content.isEmpty()) {
            return result;
        }
        
        int start = 0;
        int depth = 0;
        boolean inQuotes = false;
        char quoteChar = '"';
        boolean escapeNext = false;
        
        for (int i = 0; i < content.length(); i++) {
            char c = content.charAt(i);
            
            if (escapeNext) {
                escapeNext = false;
                continue;
            }
            
            if (c == '\\') {
                escapeNext = true;
                continue;
            }
            
            if (c == '"' || c == '\'') {
                if (!inQuotes) {
                    inQuotes = true;
                    quoteChar = c;
                } else if (c == quoteChar) {
                    inQuotes = false;
                }
                continue;
            }
            
            if (!inQuotes) {
                if (c == '{' || c == '[') {
                    depth++;
                } else if (c == '}' || c == ']') {
                    depth--;
                } else if (c == ',' && depth == 0) {
                    // Found a top-level comma - process the segment
                    String pair = content.substring(start, i).trim();
                    addToResult(result, pair);
                    start = i + 1;
                }
            }
        }
        
        // Process the final segment
        String pair = content.substring(start).trim();
        addToResult(result, pair);
        
        return result;
    }
    
    private static void addToResult(Map<String, Object> result, String pair) {
        int colonIdx = -1;
        boolean inQuotes = false;
        char quoteChar = '"';
        boolean escapeNext = false;
        
        for (int i = 0; i < pair.length(); i++) {
            char c = pair.charAt(i);
            
            if (escapeNext) {
                escapeNext = false;
                continue;
            }
            
            if (c == '\\') {
                escapeNext = true;
                continue;
            }
            
            if (c == '"' || c == '\'') {
                if (!inQuotes) {
                    inQuotes = true;
                    quoteChar = c;
                } else if (c == quoteChar) {
                    inQuotes = false;
                }
                continue;
            }
            
            if (!inQuotes && c == ':') {
                colonIdx = i;
                break;
            }
        }
        
        if (colonIdx == -1) return;
        
        String key = pair.substring(0, colonIdx).trim();
        String value = pair.substring(colonIdx + 1).trim();
        
        // Remove surrounding quotes from the key if present
        if (key.startsWith("\"") && key.endsWith("\"") && key.length() >= 2) {
            key = key.substring(1, key.length() - 1);
        } else if (key.startsWith("'") && key.endsWith("'") && key.length() >= 2) {
            key = key.substring(1, key.length() - 1);
        }
        
        // Handle the value
        Object parsedValue = parseValue(value);
        if (parsedValue != null || !result.containsKey(key)) {
            result.put(key, parsedValue);
        }
    }
    
    private static Object parseValue(String value) {
        if (value.isEmpty()) return value;
        
        // Handle quoted strings
        if ((value.startsWith("\"") && value.endsWith("\"") && value.length() >= 2) ||
            (value.startsWith("'") && value.endsWith("'") && value.length() >= 2)) {
            String unquoted = value.substring(1, value.length() - 1);
            // Unescape common escapes
            return unquoted.replace("\\\"", "\"")
                          .replace("\\'", "'")
                          .replace("\\\\", "\\")
                          .replace("\\n", "\n")
                          .replace("\\r", "\r")
                          .replace("\\t", "\t");
        }
        
        // Handle booleans
        if ("true".equalsIgnoreCase(value)) return true;
        if ("false".equalsIgnoreCase(value)) return false;
        if ("null".equalsIgnoreCase(value)) return null;
        
        // Handle numbers
        if (value.matches("-?\\d+\\.\\d+")) {
            try {
                return Double.parseDouble(value);
            } catch (NumberFormatException e) {
                return value; // Return as a string if not a number
            }
        } else if (value.matches("-?\\d+")) {
            try {
                long l = Long.parseLong(value);
                // Check if it fits in int
                if (l <= Integer.MAX_VALUE && l >= Integer.MIN_VALUE) {
                    return (int) l;
                } else {
                    return l;
                }
            } catch (NumberFormatException e) {
                return value; // Return as a string if not a number
            }
        }
        
        return value;
    }
}

public class Server {
    
    private static final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    private static final Map<Integer, User> usersById = new ConcurrentHashMap<>();
    private static final Map<String, String> passwords = new ConcurrentHashMap<>(); // userId -> password
    private static final AtomicInteger nextUserId = new AtomicInteger(1);

    private static final Map<Integer, Todo> todos = new ConcurrentHashMap<>();
    private static final Map<String, Integer> activeSessionUsers = new ConcurrentHashMap<>(); // sessionId -> userId
    private static final AtomicInteger nextTodoId = new AtomicInteger(1);
    private static final Pattern VALID_USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]+$");

    public static void main(String[] args) throws IOException {
        int port = 8080; // default
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
                break;
            }
        }

        HttpServer server = HttpServer.create(new java.net.InetSocketAddress(port), 0);

        server.createContext("/register", new RegisterHandler());
        server.createContext("/login", new LoginHandler());
        server.createContext("/logout", new LogoutHandler());
        server.createContext("/me", new MeHandler());
        server.createContext("/password", new PasswordHandler());
        server.createContext("/todos", new TodosHandler());

        System.out.println("Starting server on port " + port);
        server.start();
    }

    static class User {
        int id;
        String username;

        public User(int id, String username) {
            this.id = id;
            this.username = username;
        }
    }

    static class Todo {
        int id;
        String title;
        String description;
        boolean completed;
        String createdAt;
        String updatedAt;

        public Todo(int id, String title, String description) {
            this.id = id;
            this.title = title;
            this.description = description != null ? description : "";
            this.completed = false;
            this.createdAt = getCurrentTimestamp();
            this.updatedAt = this.createdAt;
        }
    }

    private static String getCurrentTimestamp() {
        return Instant.now().toString().substring(0, 19) + "Z";
    }

    private static class RegisterHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }

            String requestBody = getRequestBody(exchange);
            Map<String, Object> reqData = JsonParser.parse(requestBody);

            if (reqData == null) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                return;
            }

            String username = (String) reqData.get("username");
            String password = (String) reqData.get("password");

            if (username == null || username.isEmpty()) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid username\"}");
                return;
            }

            if (username.length() < 3 || username.length() > 50 || !VALID_USERNAME_PATTERN.matcher(username).matches()) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid username\"}");
                return;
            }

            if (password == null || password.length() < 8) {
                sendResponse(exchange, 400, "{\"error\": \"Password too short\"}");
                return;
            }

            if (usersByUsername.containsKey(username)) {
                sendResponse(exchange, 409, "{\"error\": \"Username already exists\"}");
                return;
            }

            int userId = nextUserId.getAndIncrement();
            User user = new User(userId, username);
            usersByUsername.put(username, user);
            usersById.put(userId, user);
            passwords.put(String.valueOf(userId), password);

            Map<String, Object> response = new java.util.HashMap<>();
            response.put("id", userId);
            response.put("username", username);

            sendResponse(exchange, 201, toJson(response));
        }
    }

    private static class LoginHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }

            String requestBody = getRequestBody(exchange);
            Map<String, Object> reqData = JsonParser.parse(requestBody);

            if (reqData == null) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                return;
            }

            String username = (String) reqData.get("username");
            String password = (String) reqData.get("password");

            User user = usersByUsername.get(username);
            if (user == null || !passwords.get(String.valueOf(user.id)).equals(password)) {
                sendResponse(exchange, 401, "{\"error\": \"Invalid credentials\"}");
                return;
            }

            String sessionId = UUID.randomUUID().toString();
            activeSessionUsers.put(sessionId, user.id);

            Map<String, Object> response = new java.util.HashMap<>();
            response.put("id", user.id);
            response.put("username", user.username);

            exchange.getResponseHeaders().set("Set-Cookie", 
                                              "session_id=" + sessionId + "; Path=/; HttpOnly");
            
            sendResponse(exchange, 200, toJson(response));
        }
    }

    private static class LogoutHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            Integer userId = extractUserId(exchange);
            if (userId == null) {
                sendAuthRequired(exchange);
                return;
            }
            
            String sessionId = extractSessionId(exchange);
            if (sessionId != null) {
                activeSessionUsers.remove(sessionId);
            }
            
            sendResponse(exchange, 200, "{}");
        }
    }

    private static class MeHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"GET".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            Integer userId = extractUserId(exchange);
            if (userId == null) {
                sendAuthRequired(exchange);
                return;
            }
            
            User user = usersById.get(userId);
            if (user == null) {
                sendAuthRequired(exchange);
                return;
            }
            
            Map<String, Object> response = new java.util.HashMap<>();
            response.put("id", user.id);
            response.put("username", user.username);
            
            sendResponse(exchange, 200, toJson(response));
        }
    }

    private static class PasswordHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"PUT".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            Integer userId = extractUserId(exchange);
            if (userId == null) {
                sendAuthRequired(exchange);
                return;
            }
            
            String requestBody = getRequestBody(exchange);
            Map<String, Object> reqData = JsonParser.parse(requestBody);
            
            if (reqData == null) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                return;
            }
            
            String oldPassword = (String) reqData.get("old_password");
            String newPassword = (String) reqData.get("new_password");
            
            String currentPassword = passwords.get(String.valueOf(userId));
            if (!currentPassword.equals(oldPassword)) {
                sendResponse(exchange, 401, "{\"error\": \"Invalid credentials\"}");
                return;
            }
            
            if (newPassword == null || newPassword.length() < 8) {
                sendResponse(exchange, 400, "{\"error\": \"Password too short\"}");
                return;
            }
            
            passwords.put(String.valueOf(userId), newPassword);
            sendResponse(exchange, 200, "{}");
        }
    }

    private static class TodosHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            Integer userId = extractUserId(exchange);
            if (userId == null) {
                sendAuthRequired(exchange);
                return;
            }
            
            String path = exchange.getRequestURI().getPath();
            String contextPath = exchange.getHttpContext().getPath();
            
            // Normalize path: remove leading/trailing slashes and extract parts
            String relativePath = path.substring(contextPath.length());
            if (relativePath.startsWith("/")) relativePath = relativePath.substring(1);
            
            if (relativePath.isEmpty() || relativePath.equals("")) {
                // This is a request to /todos - handle CRUD on the collection
                String method = exchange.getRequestMethod();
                
                if ("GET".equals(method)) {
                    handleListTodos(exchange, userId);
                } else if ("POST".equals(method)) {
                    handleCreateTodo(exchange, userId);
                } else {
                    sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                }
            } else {
                // This is a request to /todos/{id} - handle CRUD on individual item
                String[] parts = relativePath.split("/");
                
                if (parts.length > 0) {
                    try {
                        int todoId = Integer.parseInt(parts[0]);  // Take first part as the ID
                        
                        String method = exchange.getRequestMethod();
                        if ("GET".equals(method)) {
                            handleGetTodo(exchange, userId, todoId);
                        } else if ("PUT".equals(method)) {
                            handleUpdateTodo(exchange, userId, todoId);
                        } else if ("DELETE".equals(method)) {
                            handleDeleteTodo(exchange, userId, todoId);
                        } else {
                            sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                        }
                    } catch (NumberFormatException e) {
                        sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                    }
                } else {
                    sendResponse(exchange, 404, "{\"error\": \"Not Found\"}");
                }
            }
        }
        
        // We need to maintain the relationship between todos and users
        private final Map<Integer, Integer> todoUserMap = new ConcurrentHashMap<>(); // todoId -> userId
        
        private void assignTodoToUser(int todoId, int userId) {
            todoUserMap.put(todoId, userId);
        }
        
        private boolean belongsToUser(int todoId, int userId) {
            Integer todoOwner = todoUserMap.get(todoId);
            return todoOwner != null && todoOwner.intValue() == userId;
        }
        
        private void handleListTodos(HttpExchange exchange, int userId) throws IOException {
            List<Todo> userTodos = new ArrayList<>();
            
            for (Map.Entry<Integer, Todo> entry : todos.entrySet()) {
                Todo todo = entry.getValue();
                if (belongsToUser(todo.id, userId)) {
                    userTodos.add(todo);
                }
            }
            
            userTodos.sort((a, b) -> Integer.compare(a.id, b.id));
            
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < userTodos.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(todosToJson(userTodos.get(i)));
            }
            sb.append("]");
            
            sendResponse(exchange, 200, sb.toString());
        }
        
        private void handleCreateTodo(HttpExchange exchange, int userId) throws IOException {
            String requestBody = getRequestBody(exchange);
            Map<String, Object> reqData = JsonParser.parse(requestBody);
            
            if (reqData == null) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                return;
            }
            
            String title = (String) reqData.get("title");
            
            if (title == null || "".equals(title)) {
                sendResponse(exchange, 400, "{\"error\": \"Title is required\"}");
                return;
            }
            
            String description = (String) reqData.get("description");
            int todoId = nextTodoId.getAndIncrement();
            
            Todo todo = new Todo(todoId, title, description);
            todos.put(todoId, todo);
            
            assignTodoToUser(todoId, userId);
            
            sendResponse(exchange, 201, todosToJson(todo));
        }
        
        private void handleGetTodo(HttpExchange exchange, int userId, int todoId) throws IOException {
            Todo todo = todos.get(todoId);
            
            if (todo == null || !belongsToUser(todoId, userId)) {
                sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            sendResponse(exchange, 200, todosToJson(todo));
        }
        
        private void handleUpdateTodo(HttpExchange exchange, int userId, int todoId) throws IOException {
            Todo todo = todos.get(todoId);
            
            if (todo == null || !belongsToUser(todoId, userId)) {
                sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            String requestBody = getRequestBody(exchange);
            Map<String, Object> updates = JsonParser.parse(requestBody);
            
            if (updates == null) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                return;
            }
            
            // Validate title if present
            if (updates.containsKey("title")) {
                String newTitle = (String) updates.get("title");
                if (newTitle != null && newTitle.isEmpty()) {
                    sendResponse(exchange, 400, "{\"error\": \"Title is required\"}");
                    return;
                }
            }
            
            // Apply updates
            if (updates.containsKey("title")) {
                todo.title = (String) updates.get("title");
            }
            if (updates.containsKey("description")) {
                todo.description = (String) updates.get("description");
            }
            if (updates.containsKey("completed")) {
                Object completedValue = updates.get("completed");
                // Handle both Boolean objects and "true"/"false" string values
                if (completedValue instanceof Boolean) {
                    todo.completed = (Boolean) completedValue;
                } else if (completedValue instanceof String) {
                    todo.completed = Boolean.parseBoolean((String) completedValue);
                } else if (completedValue instanceof Number) {
                    todo.completed = ((Number) completedValue).intValue() != 0;
                }
            }
            
            todo.updatedAt = getCurrentTimestamp();
            
            sendResponse(exchange, 200, todosToJson(todo));
        }
        
        private void handleDeleteTodo(HttpExchange exchange, int userId, int todoId) throws IOException {
            Todo todo = todos.get(todoId);
            
            if (todo == null || !belongsToUser(todoId, userId)) {
                sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            todos.remove(todoId);
            todoUserMap.remove(todoId);
            
            exchange.sendResponseHeaders(204, -1); // No content
            OutputStream os = exchange.getResponseBody();
            os.close();
        }
    }

    private static String extractSessionId(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader != null) {
            String[] cookies = cookieHeader.split(";");
            for (String cookie : cookies) {
                cookie = cookie.trim();
                if (cookie.startsWith("session_id=")) {
                    return cookie.substring(11).trim(); // Remove "session_id="
                }
            }
        }
        return null;
    }

    private static Integer extractUserId(HttpExchange exchange) {
        String sessionId = extractSessionId(exchange);
        if (sessionId != null) {
            return activeSessionUsers.get(sessionId);
        }
        return null;
    }

    private static void sendAuthRequired(HttpExchange exchange) throws IOException {
        sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
    }

    private static void sendResponse(HttpExchange exchange, int code, String response) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        byte[] responseBytes = response.getBytes("UTF-8");
        exchange.sendResponseHeaders(code, responseBytes.length);
        OutputStream os = exchange.getResponseBody();
        os.write(responseBytes);
        os.close();
    }

    private static String getRequestBody(HttpExchange exchange) throws IOException {
        java.io.BufferedReader reader = new java.io.BufferedReader(
                new java.io.InputStreamReader(exchange.getRequestBody()));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            sb.append(line);
        }
        return sb.toString();
    }

    private static String toJson(Map<String, Object> obj) {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        
        for (Map.Entry<String, Object> entry : obj.entrySet()) {
            if (first) first = false;
            else sb.append(",");
            
            sb.append("\"").append(escapeJson(entry.getKey())).append("\":");
            
            Object value = entry.getValue();
            if (value == null) {
                sb.append("null");
            } else if (value instanceof String) {
                sb.append("\"").append(escapeJson((String) value)).append("\"");
            } else if (value instanceof Boolean) {
                sb.append(((Boolean) value).booleanValue() ? "true" : "false");
            } else if (value instanceof Number) {
                // Use toString() method to handle different number types                
                sb.append(value.toString());
            } else {
                // Fallback - could implement array/object handling here if necessary
                sb.append("\"").append(escapeJson(value.toString())).append("\"");
            }
        }
        
        sb.append("}");
        return sb.toString();
    }

    private static String escapeJson(String s) {
        if (s == null) return null;
        return s.replace("\\", "\\\\")
               .replace("\"", "\\\"")
               .replace("\n", "\\n")
               .replace("\r", "\\r")
               .replace("\t", "\\t"); 
    }

    private static String todosToJson(Todo todo) {
        StringBuilder sb = new StringBuilder("{");
        sb.append("\"id\":").append(todo.id).append(",");
        sb.append("\"title\":\"").append(escapeJson(todo.title)).append("\",");
        sb.append("\"description\":\"").append(escapeJson(todo.description)).append("\",");
        sb.append("\"completed\":").append(todo.completed).append(",");
        sb.append("\"created_at\":\"").append(todo.createdAt).append("\",");
        sb.append("\"updated_at\":\"").append(todo.updatedAt).append("\"");
        sb.append("}");
        return sb.toString();
    }
}
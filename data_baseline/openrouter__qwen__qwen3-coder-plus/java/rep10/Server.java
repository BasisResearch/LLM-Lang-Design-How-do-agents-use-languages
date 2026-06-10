import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;

import java.io.IOException;
import java.io.OutputStream;
import java.util.concurrent.ConcurrentHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;
import java.util.regex.Matcher;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.Instant;
import java.util.List;
import java.util.ArrayList;
import java.util.UUID;
import java.util.Arrays;
import java.util.Collections;

public class Server {
    private static final AtomicInteger nextUserId = new AtomicInteger(1);
    private static final AtomicInteger nextTodoId = new AtomicInteger(1);
    
    // Memory storage
    private static final Map<Integer, User> users = new ConcurrentHashMap<>();
    private static final Map<String, Integer> sessionToUserId = new ConcurrentHashMap<>();
    private static final Map<String, String> userPasswords = new ConcurrentHashMap<>();
    private static final Map<Integer, Todo> todos = new ConcurrentHashMap<>();
    private static final Map<Integer, Integer> todoToOwner = new ConcurrentHashMap<>();
    
    // Regular expression for username validation
    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");
    
    public static void main(String[] args) throws IOException {
        int port = 8080; // Default port
        
        // Parse command line arguments
        for (int i = 0; i < args.length; i += 2) {
            if (args[i].equals("--port")) {
                port = Integer.parseInt(args[i + 1]);
            }
        }
        
        // Start server - Fixed binding approach
        HttpServer server = HttpServer.create(new java.net.InetSocketAddress("0.0.0.0", port), 0);
        
        // Add handlers for each endpoint
        server.createContext("/register", new RegisterHandler());
        server.createContext("/login", new LoginHandler());
        server.createContext("/logout", new LogoutHandler());
        server.createContext("/me", new MeHandler());
        server.createContext("/password", new PasswordHandler());
        server.createContext("/todos/", new TodosWithIdHandler()); // Context for /todos/{id}
        server.createContext("/todos", new TodosHandler()); // Context for /todos list/create
        server.createContext("/", new GenericHandler()); // Catch all for others that are 404
        
        server.setExecutor(null); // creates a default executor
        System.out.println("Server started on port " + port);
        server.start();
    }
    
    // Handler for register endpoint
    static class RegisterHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String body = new String(exchange.getRequestBody().readAllBytes());
            Map<String, Object> jsonMap = parseJsonToObjectMap(body);
            
            String username = jsonMap.get("username") != null ? jsonMap.get("username").toString() : null;
            String password = jsonMap.get("password") != null ? jsonMap.get("password").toString() : null;
            
            if (username == null || !USERNAME_PATTERN.matcher(username).matches()) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid username\"}");
                return;
            }
            
            if (password == null || password.length() < 8) {
                sendResponse(exchange, 400, "{\"error\": \"Password too short\"}");
                return;
            }
            
            // Check if username already exists
            for (User user : users.values()) {
                if (user.username.equals(username)) {
                    sendResponse(exchange, 409, "{\"error\": \"Username already exists\"}");
                    return;
                }
            }
            
            int userId = nextUserId.getAndIncrement();
            User newUser = new User(userId, username);
            users.put(userId, newUser);
            userPasswords.put(username, password);
            
            String responseJson = "{";
            responseJson += "\"id\": " + userId + ", ";
            responseJson += "\"username\": \"" + escapeJson(username) + "\"";
            responseJson += "}";
            
            sendResponseWithHeaders(exchange, 201, responseJson);
        }
    }
    
    // Handler for login endpoint
    static class LoginHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String body = new String(exchange.getRequestBody().readAllBytes());
            Map<String, Object> jsonMap = parseJsonToObjectMap(body);
            
            String username = jsonMap.get("username") != null ? jsonMap.get("username").toString() : null;
            String password = jsonMap.get("password") != null ? jsonMap.get("password").toString() : null;
            
            // Check user existence and password match
            User user = null;
            for (User u : users.values()) {
                if (u.username.equals(username) && userPasswords.get(username).equals(password)) {
                    user = u;
                    break;
                }
            }
            
            if (user == null) {
                sendResponse(exchange, 401, "{\"error\": \"Invalid credentials\"}");
                return;
            }
            
            String sessionId = UUID.randomUUID().toString();
            sessionToUserId.put(sessionId, user.id);
            
            String responseJson = "{";
            responseJson += "\"id\": " + user.id + ", ";
            responseJson += "\"username\": \"" + escapeJson(username) + "\"";
            responseJson += "}";
            
            // Set cookie in header
            exchange.getResponseHeaders().add("Set-Cookie", 
                                             "session_id=" + sessionId + "; Path=/; HttpOnly");
            sendResponseWithHeaders(exchange, 200, responseJson);
        }
    }
    
    // Handler for logout endpoint
    static class LogoutHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String sessionId = getSessionIdFromCookie(exchange);
            if (sessionId == null || !sessionToUserId.containsKey(sessionId)) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            // Invalidate the session
            sessionToUserId.remove(sessionId);
            
            sendResponseWithHeaders(exchange, 200, "{}");
        }
    }
    
    // Handler for me endpoint
    static class MeHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"GET".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String sessionId = getSessionIdFromCookie(exchange);
            if (sessionId == null || !sessionToUserId.containsKey(sessionId)) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            int userId = sessionToUserId.get(sessionId);
            User user = users.get(userId);
            
            if (user == null) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            String responseJson = "{";
            responseJson += "\"id\": " + user.id + ", ";
            responseJson += "\"username\": \"" + escapeJson(user.username) + "\"";
            responseJson += "}";
            
            sendResponseWithHeaders(exchange, 200, responseJson);
        }
    }
    
    // Handler for password endpoint
    static class PasswordHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"PUT".equals(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String sessionId = getSessionIdFromCookie(exchange);
            if (sessionId == null || !sessionToUserId.containsKey(sessionId)) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            int userId = sessionToUserId.get(sessionId);
            User user = users.get(userId);
            
            String body = new String(exchange.getRequestBody().readAllBytes());
            Map<String, Object> jsonMap = parseJsonToObjectMap(body);
            
            String oldPassword = jsonMap.get("old_password") != null ? jsonMap.get("old_password").toString() : null;
            String newPassword = jsonMap.get("new_password") != null ? jsonMap.get("new_password").toString() : null;
            
            String currentPassword = userPasswords.get(user.username);
            if (!currentPassword.equals(oldPassword)) {
                sendResponse(exchange, 401, "{\"error\": \"Invalid credentials\"}");
                return;
            }
            
            if (newPassword == null || newPassword.length() < 8) {
                sendResponse(exchange, 400, "{\"error\": \"Password too short\"}");
                return;
            }
            
            userPasswords.put(user.username, newPassword);
            sendResponseWithHeaders(exchange, 200, "{}");
        }
    }
    
    // Handler for general todos (listing and creation) at /todos
    static class TodosHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            String path = exchange.getRequestURI().getPath();
            String method = exchange.getRequestMethod();
            
            String sessionId = getSessionIdFromCookie(exchange);
            if (sessionId == null || !sessionToUserId.containsKey(sessionId)) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            switch (method) {
                case "GET":
                    handleGetTodos(exchange, sessionId);
                    break;
                case "POST":
                    handleCreateTodo(exchange, sessionId);
                    break;
                default:
                    sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
            }
        }
        
        private void handleGetTodos(HttpExchange exchange, String sessionId) throws IOException {
            int userId = sessionToUserId.get(sessionId);
            
            List<Todo> userTodos = new ArrayList<>();
            for (Map.Entry<Integer, Todo> entry : todos.entrySet()) {
                Integer todoId = entry.getKey();
                if (todoToOwner.get(todoId).equals(userId)) {
                    userTodos.add(entry.getValue());
                }
            }
            
            // Sort by ID ascending
            Collections.sort(userTodos, (a, b) -> Integer.compare(a.id, b.id));
            
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < userTodos.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(todoToJson(userTodos.get(i)));
            }
            sb.append("]");
            
            sendResponseWithHeaders(exchange, 200, sb.toString());
        }
        
        private void handleCreateTodo(HttpExchange exchange, String sessionId) throws IOException {
            int userId = sessionToUserId.get(sessionId);
            
            String body = new String(exchange.getRequestBody().readAllBytes());
            Map<String, Object> jsonMap = parseJsonToObjectMap(body);
            
            String title = jsonMap.get("title") != null ? jsonMap.get("title").toString() : null;
            String description = (String) jsonMap.getOrDefault("description", "");
            
            if (title == null || title.isEmpty()) {
                sendResponse(exchange, 400, "{\"error\": \"Title is required\"}");
                return;
            }
            
            String timestamp = getCurrentTimestamp();
            
            int todoId = nextTodoId.getAndIncrement();
            Todo newTodo = new Todo(todoId, title, description, false, timestamp, timestamp);
            todos.put(todoId, newTodo);
            todoToOwner.put(todoId, userId);
            
            sendResponseWithHeaders(exchange, 201, todoToJson(newTodo));
        }
    }
    
    // Handler for todos with IDs like /todos/123
    static class TodosWithIdHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            String path = exchange.getRequestURI().getPath();
            String method = exchange.getRequestMethod();
          
            // Extract todoId from path - path will be like /todos/{id}
            String[] parts = path.split("/");
            if (parts.length == 3) { // Expected: ["", "todos", "{id}"]
                try {
                    int todoId = Integer.parseInt(parts[2]);
                    
                    String sessionId = getSessionIdFromCookie(exchange);
                    if (sessionId == null || !sessionToUserId.containsKey(sessionId)) {
                        sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                        return;
                    }
                                    
                    switch (method) {
                        case "GET":
                            handleGetTodo(exchange, sessionId, todoId);
                            break;
                        case "PUT":
                            handleUpdateTodo(exchange, sessionId, todoId);
                            break;
                        case "DELETE":
                            handleDeleteTodo(exchange, sessionId, todoId);
                            break;
                        default:
                            sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                    }
                    return;
                } catch (NumberFormatException e) {
                    // If ID couldn't be parsed, treat as not found
                }
            }
            
            sendResponse(exchange, 404, "{\"error\": \"Not found\"}");
        }
        
        private void handleGetTodo(HttpExchange exchange, String sessionId, int todoId) throws IOException {
            int userId = sessionToUserId.get(sessionId);
            
            // Check if the todo exists and belongs to this user
            Integer ownerUserId = todoToOwner.get(todoId);
            if (ownerUserId == null || !ownerUserId.equals(userId)) {
                sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            Todo todo = todos.get(todoId);
            if (todo == null) {
                sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            sendResponseWithHeaders(exchange, 200, todoToJson(todo));
        }
        
        private void handleUpdateTodo(HttpExchange exchange, String sessionId, int todoId) throws IOException {
            int userId = sessionToUserId.get(sessionId);
            
            // Check if the todo exists and belongs to this user
            Integer ownerUserId = todoToOwner.get(todoId);
            if (ownerUserId == null || !ownerUserId.equals(userId)) {
                sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            Todo existingTodo = todos.get(todoId);
            if (existingTodo == null) {
                sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            String body = new String(exchange.getRequestBody().readAllBytes());
            Map<String, Object> updates = parseJsonToObjectMap(body);
            
            // Apply updates only if they're provided in the request
            if (updates.containsKey("title")) {
                String title = updates.get("title").toString();
                if (title == null || title.isEmpty()) {
                    sendResponse(exchange, 400, "{\"error\": \"Title is required\"}");
                    return;
                }
                existingTodo.title = title;
            }
            
            if (updates.containsKey("description")) {
                existingTodo.description = updates.get("description").toString();
            }
            
            if (updates.containsKey("completed")) {
                Object completedObj = updates.get("completed");
                if (completedObj instanceof Boolean) {
                    existingTodo.completed = (Boolean) completedObj;
                } else {
                    // Handle string representation
                    String completedStr = completedObj.toString();
                    existingTodo.completed = Boolean.parseBoolean(completedStr.toLowerCase());
                }
            }
            
            // Update timestamps
            existingTodo.updated_at = getCurrentTimestamp();
            
            // Store updated todo
            todos.put(todoId, existingTodo);
            
            sendResponseWithHeaders(exchange, 200, todoToJson(existingTodo));
        }
        
        private void handleDeleteTodo(HttpExchange exchange, String sessionId, int todoId) throws IOException {
            int userId = sessionToUserId.get(sessionId);
            
            // Check if the todo exists and belongs to this user
            Integer ownerUserId = todoToOwner.get(todoId);
            if (ownerUserId == null || !ownerUserId.equals(userId)) {
                sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            Todo todo = todos.get(todoId);
            if (todo == null) {
                sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                return;
            }
            
            // Remove this todo
            todos.remove(todoId);
            todoToOwner.remove(todoId);
            
            // For DELETE, send 204 with no content body
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(204, -1);
        }
    }

    // Generic handler for unmatched paths (404)
    static class GenericHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            sendResponse(exchange, 404, "{\"error\": \"Not found\"}");
        }
    }
    
    // Helper methods
    
    private static Map<String, Object> parseJsonToObjectMap(String json) {
        Map<String, Object> result = new java.util.LinkedHashMap<>();
        
        if (json == null || json.trim().isEmpty() || !json.trim().startsWith("{") || !json.trim().endsWith("}")) {
            return result;
        }
        
        json = json.trim().substring(1, json.length() - 1); // remove outer braces
        
        int braceDepth = 0;
        int bracketDepth = 0;
        int currentStart = 0;
        boolean inString = false;
        char lastChar = 0;
        
        for (int i = 0; i < json.length(); i++) {
            char c = json.charAt(i);
            
            // Handle string literals correctly 
            if (c == '"' && lastChar != '\\') {
                inString = !inString;
            }
            
            if (!inString) {
                if (c == '{') {
                    braceDepth++;
                } else if (c == '}') {
                    braceDepth--;
                } else if (c == '[') {
                    bracketDepth++;
                } else if (c == ']') {
                    bracketDepth--;
                } else if (c == ',' && braceDepth == 0 && bracketDepth == 0) {
                    // Process this key-value pair
                    processNameValuePair(json.substring(currentStart, i).trim(), result);
                    currentStart = i + 1;
                }
            }
            
            lastChar = c;
        }
        
        // Process the last key-value pair
        if (currentStart < json.length()) {
            processNameValuePair(json.substring(currentStart).trim(), result);
        }
        
        return result;
    }
    
    private static void processNameValuePair(String pair, Map<String, Object> map) {
        if (pair.isEmpty()) return;
        
        int colonIndex = -1;
        boolean inString = false;
        char lastChar = 0;
        
        // Find first colon that's not inside a string
        for (int i = 0; i < pair.length(); i++) {
            char c = pair.charAt(i);
            if (c == '"' && lastChar != '\\') {
                inString = !inString;
            } else if (c == ':' && !inString) {
                colonIndex = i;
                break;
            }
            lastChar = c;
        }
        
        if (colonIndex == -1) return;
        
        String key = pair.substring(0, colonIndex).trim();
        String valuePart = pair.substring(colonIndex + 1).trim();
        
        // Extract the key name (without quotes)
        String extractedKey = extractQuotedValue(key);
        
        if (extractedKey != null) {
            // Determine value type by examining it
            Object value = parseJsonValue(valuePart);
            map.put(extractedKey, value);
        }
    }
    
    private static Object parseJsonValue(String valueStr) {
        valueStr = valueStr.trim();
        
        if (valueStr.startsWith("\"") && valueStr.endsWith("\"")) {
            return extractQuotedValue(valueStr);
        } else if ("true".equalsIgnoreCase(valueStr)) {
            return true;
        } else if ("false".equalsIgnoreCase(valueStr)) {
            return false;
        } else if ("null".equalsIgnoreCase(valueStr)) {
            return null;
        } else if (valueStr.matches("-?\\d+")) {
            // Try to parse as an integer first
            try {
                return Long.parseLong(valueStr);
            } catch (NumberFormatException e) {
                return valueStr; // fallback to string
            }
        } else if (valueStr.matches("-?\\d*\\.\\d+")) {
            // Try to parse as double
            try {
                return Double.parseDouble(valueStr);
            } catch (NumberFormatException e) {
                return valueStr; // fallback to string
            }
        } else {
            // Return as-is if unparseable
            return valueStr;
        }
    }
    
    private static String extractQuotedValue(String str) {
        if (str.length() >= 2 && str.startsWith("\"") && str.endsWith("\"")) {
            str = str.substring(1, str.length() - 1);
            // Replace escaped quotes and other escaped characters
            str = str.replace("\\\"", "\"")
                     .replace("\\\\", "\\")
                     .replace("\\n", "\n")
                     .replace("\\r", "\r")
                     .replace("\\t", "\t");
            return str;
        }
        return null;
    }
    
    private static String getSessionIdFromCookie(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader == null) return null;
        
        String prefix = "session_id=";
        int startIndex = cookieHeader.indexOf(prefix);
        if (startIndex == -1) return null;
        
        startIndex += prefix.length();
        int endIndex = cookieHeader.indexOf(";", startIndex);
        if (endIndex == -1) {
            endIndex = cookieHeader.length();
        }
        
        return cookieHeader.substring(startIndex, endIndex);
    }
    
    private static void sendResponse(HttpExchange exchange, int code, String responseBody) throws IOException {
        byte[] responseBytes = responseBody.getBytes("UTF-8");
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(code, responseBytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(responseBytes);
        }
    }
    
    private static void sendResponseWithHeaders(HttpExchange exchange, int code, String responseBody) throws IOException {
        byte[] responseBytes = responseBody.getBytes("UTF-8");
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(code, responseBytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(responseBytes);
        }
    }
    
    private static String getCurrentTimestamp() {
        return Instant.now().atOffset(ZoneOffset.UTC)
            .format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }
    
    private static boolean needsAuth(String method, String path) {
        // These specific paths and methods don't need auth
        if (path.equals("/register") || path.equals("/login")) {
            return false;
        }
        return true;
    }
    
    private static String escapeJson(String str) {
        if (str == null) return null;
        return str.replace("\\", "\\\\")
                  .replace("\"", "\\\"")
                  .replace("\b", "\\b")
                  .replace("\f", "\\f")
                  .replace("\n", "\\n")
                  .replace("\r", "\\r")
                  .replace("\t", "\\t");
    }
    
    private static String todoToJson(Todo todo) {
        StringBuilder sb = new StringBuilder();
        sb.append("{");
        sb.append("\"id\": ").append(todo.id).append(", ");
        sb.append("\"title\": \"").append(escapeJson(todo.title)).append("\", ");
        sb.append("\"description\": \"").append(escapeJson(todo.description)).append("\", ");
        sb.append("\"completed\": ").append(todo.completed).append(", ");
        sb.append("\"created_at\": \"").append(todo.created_at).append("\", ");
        sb.append("\"updated_at\": \"").append(todo.updated_at).append("\"");
        sb.append("}");
        return sb.toString();
    }
    
    // Data classes
    static class User {
        public int id;
        public String username;
        
        public User(int id, String username) {
            this.id = id;
            this.username = username;
        }
    }
    
    static class Todo {
        public int id;
        public String title;
        public String description;
        public boolean completed;
        public String created_at;
        public String updated_at;
        
        public Todo(int id, String title, String description, boolean completed, String created_at, String updated_at) {
            this.id = id;
            this.title = title;
            this.description = description;
            this.completed = completed;
            this.created_at = created_at;
            this.updated_at = updated_at;
        }
    }
}
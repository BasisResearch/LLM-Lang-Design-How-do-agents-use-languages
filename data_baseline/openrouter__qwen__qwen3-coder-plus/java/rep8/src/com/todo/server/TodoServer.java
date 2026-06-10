package com.todo.server;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;
import java.io.*;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.concurrent.ConcurrentHashMap;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.regex.Pattern;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;

public class TodoServer {
    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");
    private static final String SESSION_ID_COOKIE_NAME = "session_id";
    private static final int MIN_PASSWORD_LENGTH = 8;

    // In-memory storage  
    private final ConcurrentHashMap<Integer, User> users = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Integer> usernameToId = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Integer, String> passwords = new ConcurrentHashMap<>(); // store hashed passwords
    private final ConcurrentHashMap<Integer, List<Todo>> userTodos = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>();
    
    // ID counters
    private int nextUserId = 1;
    private int nextTodoId = 1;

    public void start(int port) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.setExecutor(null); // creates a default executor
        
        // Register handlers
        server.createContext("/register", new RegisterHandler());
        server.createContext("/login", new LoginHandler());
        server.createContext("/logout", new LogoutHandler());
        server.createContext("/me", new MeHandler());
        server.createContext("/password", new PasswordHandler());
        
        // Todo handlers
        server.createContext("/todos", new TodosHandler());
        
        System.out.println("Server starting on port " + port);
        server.start();
    }

    // Simple JSON parsing helper that extracts fields from a JSON string
    private Map<String, String> parseJsonFields(String json) {
        Map<String, String> fields = new HashMap<>();
        
        if (json == null) return fields;
        
        // Handle potential boolean field separately with special handling
        int pos = 0;
        while (pos < json.length()) {
            // Find the next field pattern
            int quoteStart = json.indexOf('"', pos);
            if (quoteStart == -1) break;
            
            int quoteEnd = json.indexOf('"', quoteStart + 1);
            if (quoteEnd == -1) break;
            
            String key = json.substring(quoteStart + 1, quoteEnd);
            
            // Skip past colon
            int colonPos = json.indexOf(':', quoteEnd);
            if (colonPos == -1) break;
            
            int valueStart = colonPos + 1;
            while (valueStart < json.length() && Character.isWhitespace(json.charAt(valueStart))) {
                valueStart++;
            }
            
            if (valueStart >= json.length()) break;
            
            String value = "";
            char firstChar = json.charAt(valueStart);
            
            if (firstChar == '"') { // String value
                int valueEnd = json.indexOf('"', valueStart + 1);
                // Handle escaped quotes
                int actualEnd = valueEnd;
                while (actualEnd > 0 && json.charAt(actualEnd - 1) == '\\') {
                    // Count consecutive backslashes
                    int slashCount = 0;
                    int temp = actualEnd - 1;
                    while (temp >= 0 && json.charAt(temp) == '\\') {
                        slashCount++;
                        temp--;
                    }
                    
                    if (slashCount % 2 == 1) {
                        // Previous backslash was escaped, so look for next quote
                        actualEnd = json.indexOf('"', actualEnd + 1);
                        if (actualEnd == -1) break;
                    } else {
                        break; // Non-escaped, this is the closing quote
                    }
                }
                if (actualEnd != -1) {
                    value = json.substring(valueStart + 1, actualEnd);
                    pos = actualEnd + 1; // Move position past the end of this value
                } else {
                    pos = json.length(); // Can't process more if no proper closing quote found
                }
            } else if (firstChar == 't' || firstChar == 'f' || firstChar == 'n') { // boolean or null
                // For boolean values (true, false)
                if (json.startsWith("true", valueStart)) {
                    value = "true";
                    pos = valueStart + 4;
                } else if (json.startsWith("false", valueStart)) {
                    value = "false";
                    pos = valueStart + 5;
                } else if (json.startsWith("null", valueStart)) {
                    value = "null";
                    pos = valueStart + 4;
                } else {
                    // Read until comma or closing brace
                    int end = valueStart;
                    while (end < json.length() && json.charAt(end) != ',' && json.charAt(end) != '}') {
                        end++;
                    }
                    value = json.substring(valueStart, end).trim();
                    pos = end; // Move position past this value
                }
            } else { // number or anything else
                int end = valueStart;
                while (end < json.length() && json.charAt(end) != ',' && json.charAt(end) != '}') {
                    end++;
                }
                value = json.substring(valueStart, end).trim();
                pos = end; // Move position past this value
            }
            
            if (value != null) {
                fields.put(key, value);
            }
        }
        
        return fields;
    }

    private class RegisterHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("POST")) {
                sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
                return;
            }
            
            String requestBody = getRequestBody(exchange.getRequestBody());
            
            Map<String, String> fields = parseJsonFields(requestBody);
            String username = fields.get("username");
            String password = fields.get("password");

            if (password == null || password.length() < MIN_PASSWORD_LENGTH) {
                sendResponse(exchange, 400, "{\"error\":\"Password too short\"}");
                return;
            }

            if (username == null || !USERNAME_PATTERN.matcher(username).matches()) {
                sendResponse(exchange, 400, "{\"error\":\"Invalid username\"}");
                return;
            }

            synchronized (users) {
                if (usernameToId.containsKey(username)) {
                    sendResponse(exchange, 409, "{\"error\":\"Username already exists\"}");
                    return;
                }

                int userId = nextUserId++;
                User user = new User(userId, username);
                users.put(userId, user);
                usernameToId.put(username, userId);
                passwords.put(userId, hashPassword(password));
                
                userTodos.put(userId, new ArrayList<>());

                String response = "{\"id\": " + user.id + ", \"username\": \"" + user.username + "\"}";
                
                sendResponse(exchange, 201, response);
            }
        }
    }

    private class LoginHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("POST")) {
                sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
                return;
            }
            
            String requestBody = getRequestBody(exchange.getRequestBody());
            
            Map<String, String> fields = parseJsonFields(requestBody);
            String username = fields.get("username");
            String password = fields.get("password");

            if (username == null || password == null) {
                sendResponse(exchange, 401, "{\"error\":\"Invalid credentials\"}");
                return;
            }

            Integer userId = usernameToId.get(username);
            if (userId == null) {
                sendResponse(exchange, 401, "{\"error\":\"Invalid credentials\"}");
                return;
            }

            String storedPasswordHash = passwords.get(userId);
            if (!isPasswordValid(password, storedPasswordHash)) {
                sendResponse(exchange, 401, "{\"error\":\"Invalid credentials\"}");
                return;
            }

            String sessionId = UUID.randomUUID().toString();
            sessions.put(sessionId, userId);

            User user = users.get(userId);

            // Prepare response
            String response = "{\"id\": " + user.id + ", \"username\": \"" + user.username + "\"}";

            // Set response headers including cookie
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.getResponseHeaders().add("Set-Cookie", 
                SESSION_ID_COOKIE_NAME + "=" + sessionId + "; Path=/; HttpOnly");
            
            exchange.sendResponseHeaders(200, response.getBytes().length);
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
        }
    }

    private class LogoutHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("POST")) {
                sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
                return;
            }
            
            String sessionId = getSessionIdFromCookie(exchange);
            if (sessionId == null || !sessions.containsKey(sessionId)) {
                sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                return;
            }

            // Remove session
            sessions.remove(sessionId);
            
            // Send empty response
            sendResponse(exchange, 200, "{}");
        }
    }

    private class MeHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("GET")) {
                sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
                return;
            }
            
            String sessionId = getSessionIdFromCookie(exchange);
            Integer userId = getUserIdForSession(sessionId);
            if (userId == null) {
                sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                return;
            }

            User user = users.get(userId);
            if (user == null) {
                sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                return;
            }

            String response = "{\"id\": " + user.id + ", \"username\": \"" + user.username + "\"}";
            sendResponse(exchange, 200, response);
        }
    }

    private class PasswordHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("PUT")) {
                sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
                return;
            }
            
            String sessionId = getSessionIdFromCookie(exchange);
            Integer userId = getUserIdForSession(sessionId);
            if (userId == null) {
                sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                return;
            }

            String requestBody = getRequestBody(exchange.getRequestBody());
            
            Map<String, String> fields = parseJsonFields(requestBody);
            String oldPassword = fields.get("old_password");
            String newPassword = fields.get("new_password");

            if (oldPassword == null) {
                sendResponse(exchange, 400, "{\"error\":\"Invalid JSON\"}");
                return;
            }

            if (newPassword == null || newPassword.length() < MIN_PASSWORD_LENGTH) {
                sendResponse(exchange, 400, "{\"error\":\"Password too short\"}");
                return;
            }

            String storedPasswordHash = passwords.get(userId);
            if (!isPasswordValid(oldPassword, storedPasswordHash)) {
                sendResponse(exchange, 401, "{\"error\":\"Invalid credentials\"}");
                return;
            }

            passwords.put(userId, hashPassword(newPassword));
            sendResponse(exchange, 200, "{}");
        }
    }

    private class TodosHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            String method = exchange.getRequestMethod();
            String path = exchange.getRequestURI().getPath();
            
            // Extract todo ID if present
            Integer todoId = extractTodoId(path);

            // Check authentication for protected endpoints
            boolean needsAuth = !(method.equals("POST") && path.equals("/todos"));  // POST /todos doesn't need auth, but needs to get userId later
            
            // Determine if we have path-based access without ID (for list operations)
            boolean isPathForList = path.equals("/todos") && todoId == null;

            if (needsAuth && !isPathForList) {  // For individual operations, check auth now
                String sessionId = getSessionIdFromCookie(exchange);
                Integer userId = getUserIdForSession(sessionId);
                if (userId == null) {
                    sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                    return;
                }
            }

            switch (method) {
                case "GET":
                    if (todoId != null) {
                        // Need auth for single todo query
                        String sessionId = getSessionIdFromCookie(exchange);
                        Integer userId = getUserIdForSession(sessionId);
                        if (userId == null) {
                            sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                            return;
                        }
                        handleGetTodo(exchange, userId, todoId);
                    } else {
                        // Need auth for listing todos
                        String sessionId = getSessionIdFromCookie(exchange);
                        Integer userId = getUserIdForSession(sessionId);
                        if (userId == null) {
                            sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                            return;
                        }
                        handleGetTodos(exchange, userId);
                    }
                    break;
                case "POST":
                    if (path.equals("/todos")) { // Specifically check for /todos without ID
                        // We verify auth inside the handler for this specific case
                        String sessionId = getSessionIdFromCookie(exchange);
                        Integer userId = getUserIdForSession(sessionId);
                        if (userId == null) {
                            sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                            return;
                        }
                        handleCreateTodo(exchange, userId);
                    } else {
                        sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
                    }
                    break;
                case "PUT":
                    if (todoId != null) {
                        String sessionId = getSessionIdFromCookie(exchange);
                        Integer userId = getUserIdForSession(sessionId);
                        if (userId == null) {
                            sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                            return;
                        }
                        handleUpdateTodo(exchange, userId, todoId);
                    } else {
                        sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
                    }
                    break;
                case "DELETE":
                    if (todoId != null) {
                        String sessionId = getSessionIdFromCookie(exchange);
                        Integer userId = getUserIdForSession(sessionId);
                        if (userId == null) {
                            sendResponse(exchange, 401, "{\"error\":\"Authentication required\"}");
                            return;
                        }
                        handleDeleteTodo(exchange, userId, todoId);
                    } else {
                        sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
                    }
                    break;
                default:
                    sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
                    break;
            }
        }

        private void handleGetTodos(HttpExchange exchange, Integer userId) throws IOException {
            List<Todo> todos = userTodos.get(userId);
            if (todos == null) {
                sendResponse(exchange, 200, "[]");
                return;
            }

            StringBuilder response = new StringBuilder("[");
            for (int i = 0; i < todos.size(); i++) {
                if (i > 0) response.append(",");
                response.append(toJson(todos.get(i)));
            }
            response.append("]");
            sendResponse(exchange, 200, response.toString());
        }

        private void handleCreateTodo(HttpExchange exchange, Integer userId) throws IOException {
            String requestBody = getRequestBody(exchange.getRequestBody());
            
            Map<String, String> fields = parseJsonFields(requestBody);
            String title = fields.get("title");
            String description = fields.get("description");  // Optional field
            if (description == null) description = "";  // Default to empty string if not provided

            if (title == null || title.trim().isEmpty()) {
                sendResponse(exchange, 400, "{\"error\":\"Title is required\"}");
                return;
            }

            synchronized (userTodos) {
                List<Todo> userTodoList = userTodos.computeIfAbsent(userId, k -> new ArrayList<>());

                // Create timestamp strings
                String nowStr = getCurrentTimestamp();

                int newTodoId = nextTodoId++;
                Todo newTodo = new Todo(newTodoId, title, description, false, nowStr, nowStr);
                
                userTodoList.add(newTodo);

                sendResponse(exchange, 201, toJson(newTodo));
            }
        }

        private void handleGetTodo(HttpExchange exchange, Integer userId, Integer todoId) throws IOException {
            List<Todo> todos = userTodos.get(userId);
            if (todos == null) {
                sendResponse(exchange, 404, "{\"error\":\"Todo not found\"}");
                return;
            }

            Todo targetTodo = null;
            for (Todo t : todos) {
                if (t.id == todoId) {
                    targetTodo = t;
                    break;
                }
            }

            if (targetTodo == null) {
                sendResponse(exchange, 404, "{\"error\":\"Todo not found\"}");
                return;
            }

            sendResponse(exchange, 200, toJson(targetTodo));
        }

        private void handleUpdateTodo(HttpExchange exchange, Integer userId, Integer todoId) throws IOException {
            List<Todo> todos = userTodos.get(userId);
            if (todos == null) {
                sendResponse(exchange, 404, "{\"error\":\"Todo not found\"}");
                return;
            }

            Todo targetTodo = null;
            int targetIndex = -1;
            for (int i = 0; i < todos.size(); i++) {
                if (todos.get(i).id == todoId) {
                    targetTodo = todos.get(i);
                    targetIndex = i;
                    break;
                }
            }

            if (targetTodo == null) {
                sendResponse(exchange, 404, "{\"error\":\"Todo not found\"}");
                return;
            }

            String requestBody = getRequestBody(exchange.getRequestBody());
            Map<String, String> fields = parseJsonFields(requestBody);

            // Update the todo with new values, keeping old ones if not provided
            String updatedTitle = targetTodo.title;
            if (fields.containsKey("title")) {
                String newTitle = fields.get("title");
                if (newTitle == null || newTitle.trim().isEmpty()) {
                    sendResponse(exchange, 400, "{\"error\":\"Title is required\"}");
                    return;
                }
                updatedTitle = newTitle;
            }
            
            String updatedDescription = targetTodo.description;
            if (fields.containsKey("description")) {
                String newDesc = fields.get("description");
                if (newDesc != null) {  // Description is optional, can be null to mean no change
                    updatedDescription = newDesc;
                }
            }
            
            boolean updatedCompleted = targetTodo.completed;
            if (fields.containsKey("completed")) {
                String completedStr = fields.get("completed");
                updatedCompleted = "true".equals(completedStr);
            }

            String nowStr = getCurrentTimestamp();
            Todo updatedTodo = new Todo(todoId, updatedTitle, updatedDescription, updatedCompleted, 
                                targetTodo.created_at, nowStr);

            // Replace the todo in the list
            todos.set(targetIndex, updatedTodo);

            sendResponse(exchange, 200, toJson(updatedTodo));
        }

        private void handleDeleteTodo(HttpExchange exchange, Integer userId, Integer todoId) throws IOException {
            List<Todo> todos = userTodos.get(userId);
            if (todos == null) {
                sendResponse(exchange, 404, "{\"error\":\"Todo not found\"}");
                return;
            }

            int indexToRemove = -1;
            for (int i = 0; i < todos.size(); i++) {
                if (todos.get(i).id == todoId) {
                    indexToRemove = i;
                    break;
                }
            }

            if (indexToRemove == -1) {
                sendResponse(exchange, 404, "{\"error\":\"Todo not found\"}");
                return;
            }

            todos.remove(indexToRemove);
            sendResponse(exchange, 204, "");
        }
    }

    // Utility methods
    private String getSessionIdFromCookie(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader == null) {
            return null;
        }

        String[] cookies = cookieHeader.split("; ");
        for (String cookie : cookies) {
            if (cookie.startsWith(SESSION_ID_COOKIE_NAME + "=")) {
                return cookie.substring((SESSION_ID_COOKIE_NAME + "=").length());
            }
        }
        return null;
    }

    private Integer getUserIdForSession(String sessionId) {
        if (sessionId == null) {
            return null;
        }
        return sessions.get(sessionId);
    }

    private Integer extractTodoId(String path) {
        if (path.startsWith("/todos/")) {
            String idStr = path.substring(7); // "/todos/".length() = 7
            try {
                return Integer.parseInt(idStr);
            } catch (NumberFormatException e) {
                // Invalid ID in path
                return null;
            }
        }
        return null;
    }

    private String getRequestBody(InputStream inputStream) throws IOException {
        StringBuilder sb = new StringBuilder();
        BufferedReader reader = new BufferedReader(new InputStreamReader(inputStream, StandardCharsets.UTF_8));
        String line;
        while ((line = reader.readLine()) != null) {
            sb.append(line);
        }
        return sb.toString();
    }

    private void sendResponse(HttpExchange exchange, int statusCode, String response) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        if (statusCode == 204) {
            exchange.sendResponseHeaders(statusCode, -1); // No body for 204
        } else {
            byte[] responseBytes = response.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(statusCode, responseBytes.length);
            OutputStream os = exchange.getResponseBody();
            os.write(responseBytes);
            os.close();
        }
    }

    private String getCurrentTimestamp() {
        return Instant.now().atOffset(ZoneOffset.UTC)
                         .format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }

    private String toJson(Todo todo) {
        return "{\"id\":" + todo.id + ",\"title\":\"" + escapeJson(todo.title) 
               + "\",\"description\":\"" + escapeJson(todo.description) 
               + "\",\"completed\":" + todo.completed 
               + ",\"created_at\":\"" + todo.created_at 
               + "\",\"updated_at\":\"" + todo.updated_at + "}";
    }

    // Simple JSON escape to handle special characters in strings
    private String escapeJson(String str) {
        if (str == null) return "";
        return str.replace("\\", "\\\\")
                  .replace("\"", "\\\"")
                  .replace("\b", "\\b")
                  .replace("\f", "\\f")
                  .replace("\n", "\\n")
                  .replace("\r", "\\r")
                  .replace("\t", "\\t");
    }

    private String hashPassword(String password) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hashedPassword = md.digest(password.getBytes(StandardCharsets.UTF_8));
            return Base64.getEncoder().encodeToString(hashedPassword);
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException(e);
        }
    }

    private boolean isPasswordValid(String password, String storedPasswordHash) {
        return hashPassword(password).equals(storedPasswordHash);
    }

    // Data classes
    static class User {
        int id;
        String username;

        User(int id, String username) {
            this.id = id;
            this.username = username;
        }
    }

    static class Todo {
        int id;
        String title;
        String description;
        boolean completed;
        String created_at;
        String updated_at;

        Todo(int id, String title, String description, boolean completed, 
             String created_at, String updated_at) {
            this.id = id;
            this.title = title;
            this.description = description;
            this.completed = completed;
            this.created_at = created_at;
            this.updated_at = updated_at;
        }
    }

    public static void main(String[] args) throws IOException {
        TodoServer server = new TodoServer();
        
        // Parse arguments
        int port = 8080; // default
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                try {
                    port = Integer.parseInt(args[i + 1]);
                    i++; // Skip next arg
                } catch (NumberFormatException e) {
                    System.err.println("Invalid port number: " + args[i + 1]);
                    System.exit(1);
                }
            } else if ("--help".equals(args[i]) || "-h".equals(args[i])) {
                System.out.println("Usage: java TodoServer --port PORT");
                System.exit(0);
            }
        }
        
        server.start(port);
    }
}
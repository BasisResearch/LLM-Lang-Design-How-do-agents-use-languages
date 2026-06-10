package com.todo.server;

import com.google.gson.*;
import java.io.*;
import java.net.InetSocketAddress;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;
import java.security.SecureRandom;
import java.security.MessageDigest;
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;

public class TodoServer {
    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]+$");
    private static final DateTimeFormatter DATE_FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'");
    
    // In-memory storage
    private final Map<Integer, User> users = new ConcurrentHashMap<>();
    private final Map<Integer, Todo> todos = new ConcurrentHashMap<>();
    private final Map<String, Integer> sessionTokens = new ConcurrentHashMap<>();  // token -> userId mapping
    
    private int nextUserId = 1;
    private int nextTodoId = 1;
    private final Map<Integer, String> passwords = new ConcurrentHashMap<>();
    
    public static void main(String[] args) throws Exception {
        int port = 8080; // default
        
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
                break;
            }
        }
        
        TodoServer server = new TodoServer();
        server.start(port);
    }
    
    public void start(int port) throws Exception {
        HttpServer httpServer = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        httpServer.createContext("/register", new RegisterHandler());
        httpServer.createContext("/login", new LoginHandler());
        httpServer.createContext("/logout", new LogoutHandler());
        httpServer.createContext("/me", new MeHandler());
        httpServer.createContext("/password", new PasswordHandler());
        httpServer.createContext("/todos", new TodosHandler());
        
        httpServer.setExecutor(null);
        System.out.println("Server starting on port " + port);
        httpServer.start();
    }

    private class User {
        public final int id;
        public final String username;
        
        public User(int id, String username) {
            this.id = id;
            this.username = username;
        }
    }
    
    private class Todo {
        public final int id;
        public String title;
        public String description;
        public boolean completed;
        public final String createdAt;
        public String updatedAt;
        public int userId;
        
        public Todo(int id, String title, String description, int userId) {
            this.id = id;
            this.title = title;
            this.description = description;
            this.completed = false;
            this.createdAt = getCurrentTimestamp();
            this.updatedAt = this.createdAt;
            this.userId = userId;
        }
        
        public Todo(int id, String title, String description, boolean completed, String createdAt, String updatedAt, int userId) {
            this.id = id;
            this.title = title;
            this.description = description;
            this.completed = completed;
            this.createdAt = createdAt;
            this.updatedAt = updatedAt;
            this.userId = userId;
        }

        public JsonObject toJson() {
            JsonObject obj = new JsonObject();
            obj.addProperty("id", id);
            obj.addProperty("title", title);
            obj.addProperty("description", description);
            obj.addProperty("completed", completed);
            obj.addProperty("created_at", createdAt);
            obj.addProperty("updated_at", updatedAt);
            return obj;
        }
    }
    
    // Helper methods
    private String getCurrentTimestamp() {
        return Instant.now().atOffset(ZoneOffset.UTC).format(DATE_FORMATTER);
    }
    
    private String generateSessionId() {
        SecureRandom random = new SecureRandom();
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }
    
    private Integer validateSession(String sessionId) {
        if (sessionId == null || !sessionTokens.containsKey(sessionId)) {
            return null;
        }
        return sessionTokens.get(sessionId);
    }
    
    private void setJsonResponse(HttpExchange exchange, int statusCode, JsonObject response) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        String jsonResponse = new Gson().toJson(response);
        byte[] responseBytes = jsonResponse.getBytes("UTF-8");
        exchange.sendResponseHeaders(statusCode, responseBytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(responseBytes);
        }
    }
    
    private void setEmptyResponse(HttpExchange exchange, int statusCode) throws IOException {
        exchange.sendResponseHeaders(statusCode, -1); // No response body
    }
    
    private String getCookieValue(Map<String, String> cookies, String name) {
        return cookies.get(name);
    }
    
    private Map<String, String> parseCookies(HttpExchange exchange) {
        Map<String, String> cookies = new HashMap<>();
        List<String> cookieHeaders = exchange.getRequestHeaders().get("Cookie");
        if (cookieHeaders != null) {
            String cookieStr = String.join("; ", cookieHeaders);
            String[] cookiePairs = cookieStr.split("; ");
            for (String pair : cookiePairs) {
                if (pair.contains("=")) {
                    int eqIndex = pair.indexOf('=');
                    String name = pair.substring(0, eqIndex).trim();
                    String value = pair.substring(eqIndex + 1).trim();
                    cookies.put(name, value);
                }
            }
        }
        return cookies;
    }
    
    private JsonObject parseJsonFromRequest(HttpExchange exchange) throws IOException {
        InputStream inputStream = exchange.getRequestBody();
        BufferedReader reader = new BufferedReader(new InputStreamReader(inputStream, "UTF-8"));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            sb.append(line);
        }
        String jsonInput = sb.toString();
        
        if (jsonInput.trim().isEmpty()) {
            return new JsonObject();
        }
        
        try {
            JsonParser parser = new JsonParser();
            JsonElement element = parser.parse(jsonInput);
            if (element.isJsonObject()) {
                return element.getAsJsonObject();
            } else {
                throw new IllegalArgumentException("Request body is not a valid JSON object");
            }
        } catch (JsonSyntaxException e) {
            throw new IllegalArgumentException("Invalid JSON syntax", e);
        }
    }
    
    private boolean isValidPassword(String password) {
        return password != null && password.length() >= 8;
    }
    
    private boolean isValidUsername(String username) {
        if (username == null) {
            return false;
        }
        return username.length() >= 3 && 
               username.length() <= 50 && 
               USERNAME_PATTERN.matcher(username).matches();
    }
    
    // Handler classes
    class RegisterHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            try {
                JsonObject reqData = parseJsonFromRequest(exchange);
                
                String username = reqData.has("username") ? reqData.get("username").getAsString() : null;
                String password = reqData.has("password") ? reqData.get("password").getAsString() : null;
                
                // Validate username
                if (!isValidUsername(username)) {
                    JsonObject error = new JsonObject();
                    error.addProperty("error", "Invalid username");
                    setJsonResponse(exchange, 400, error);
                    return;
                }
                
                // Check if username exists
                for (User user : users.values()) {
                    if (user.username.equals(username)) {
                        JsonObject error = new JsonObject();
                        error.addProperty("error", "Username already exists");
                        setJsonResponse(exchange, 409, error);
                        return;
                    }
                }
                
                // Validate password
                if (!isValidPassword(password)) {
                    JsonObject error = new JsonObject();
                    error.addProperty("error", "Password too short");
                    setJsonResponse(exchange, 400, error);
                    return;
                }
                
                // Create user
                int newUserId = nextUserId++;
                User newUser = new User(newUserId, username);
                users.put(newUserId, newUser);
                passwords.put(newUserId, hashPassword(password));
                
                JsonObject response = new JsonObject();
                response.addProperty("id", newUserId);
                response.addProperty("username", username);
                
                setJsonResponse(exchange, 201, response);
            } catch (IllegalArgumentException e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", e.getMessage());
                setJsonResponse(exchange, 400, error);
            } catch (Exception e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Internal server error");
                setJsonResponse(exchange, 500, error);
            }
        }
    }
    
    class LoginHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            try {
                JsonObject reqData = parseJsonFromRequest(exchange);
                
                String username = reqData.has("username") ? reqData.get("username").getAsString() : null;
                String password = reqData.has("password") ? reqData.get("password").getAsString() : null;
                
                // Find user by username
                Integer userId = null;
                
                for (Map.Entry<Integer, User> entry : users.entrySet()) {
                    if (entry.getValue().username.equals(username)) {
                        userId = entry.getKey();
                        break;
                    }
                }
                
                if (userId == null || !hashPassword(password).equals(passwords.get(userId))) {
                    JsonObject error = new JsonObject();
                    error.addProperty("error", "Invalid credentials");
                    setJsonResponse(exchange, 401, error);
                    return;
                }
                
                // Generate session token
                String sessionId = generateSessionId();
                sessionTokens.put(sessionId, userId);
                
                // Set cookie header
                List<String> cookieHeaderValue = new ArrayList<>();
                cookieHeaderValue.add(String.format("session_id=%s; Path=/; HttpOnly", sessionId));
                exchange.getResponseHeaders().put("Set-Cookie", cookieHeaderValue);
                
                JsonObject response = new JsonObject();
                response.addProperty("id", userId);
                response.addProperty("username", username);
                
                setJsonResponse(exchange, 200, response);
            } catch (Exception e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Internal server error");
                setJsonResponse(exchange, 500, error);
            }
        }
    }
    
    class LogoutHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            try {
                Map<String, String> cookies = parseCookies(exchange);
                String sessionId = getCookieValue(cookies, "session_id");
                Integer userId = validateSession(sessionId);
                
                if (userId == null) {
                    JsonObject error = new JsonObject();
                    error.addProperty("error", "Authentication required");
                    setJsonResponse(exchange, 401, error);
                    return;
                }
                
                // Remove session token
                if (sessionId != null) {
                    sessionTokens.remove(sessionId);
                }
                
                JsonObject response = new JsonObject();
                setJsonResponse(exchange, 200, response);
            } catch (Exception e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Internal server error");
                setJsonResponse(exchange, 500, error);
            }
        }
    }
    
    class MeHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"GET".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            try {
                Map<String, String> cookies = parseCookies(exchange);
                String sessionId = getCookieValue(cookies, "session_id");
                Integer userId = validateSession(sessionId);
                
                if (userId == null) {
                    JsonObject error = new JsonObject();
                    error.addProperty("error", "Authentication required");
                    setJsonResponse(exchange, 401, error);
                    return;
                }
                
                User user = users.get(userId);
                JsonObject response = new JsonObject();
                response.addProperty("id", user.id);
                response.addProperty("username", user.username);
                
                setJsonResponse(exchange, 200, response);
            } catch (Exception e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Internal server error");
                setJsonResponse(exchange, 500, error);
            }
        }
    }
    
    class PasswordHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"PUT".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            try {
                Map<String, String> cookies = parseCookies(exchange);
                String sessionId = getCookieValue(cookies, "session_id");
                Integer userId = validateSession(sessionId);
                
                if (userId == null) {
                    JsonObject error = new JsonObject();
                    error.addProperty("error", "Authentication required");
                    setJsonResponse(exchange, 401, error);
                    return;
                }
                
                JsonObject reqData = parseJsonFromRequest(exchange);
                
                String oldPassword = reqData.has("old_password") ? reqData.get("old_password").getAsString() : null;
                String newPassword = reqData.has("new_password") ? reqData.get("new_password").getAsString() : null;
                
                // Validate old password
                String currentHashedPassword = passwords.get(userId);
                String inputOldHashedPassword = hashPassword(oldPassword);
                
                if (!inputOldHashedPassword.equals(currentHashedPassword)) {
                    JsonObject error = new JsonObject();
                    error.addProperty("error", "Invalid credentials");
                    setJsonResponse(exchange, 401, error);
                    return;
                }
                
                // Validate new password
                if (!isValidPassword(newPassword)) {
                    JsonObject error = new JsonObject();
                    error.addProperty("error", "Password too short");
                    setJsonResponse(exchange, 400, error);
                    return;
                }
                
                // Update password
                passwords.put(userId, hashPassword(newPassword));
                
                JsonObject response = new JsonObject();
                setJsonResponse(exchange, 200, response);
            } catch (Exception e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Internal server error");
                setJsonResponse(exchange, 500, error);
            }
        }
    }
    
    class TodosHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            Map<String, String> cookies = parseCookies(exchange);
            String sessionId = getCookieValue(cookies, "session_id");
            Integer userId = validateSession(sessionId);
            
            String method = exchange.getRequestMethod();
            String path = exchange.getRequestURI().getPath();
            
            // Authentication check for operations requiring auth
            boolean requiresAuth = !("POST".equals(method) && path.equals("/todos")) || 
                                   (method.matches("GET|PUT|DELETE") && path.startsWith("/todos/")) ||
                                   ("GET".equals(method) && path.equals("/todos"));
            
            if (requiresAuth && userId == null) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Authentication required");
                setJsonResponse(exchange, 401, error);
                return;
            }
            
            // Handle different methods and paths
            if ("GET".equals(method) && path.equals("/todos")) {
                handleGetTodos(exchange, userId);
            } else if ("POST".equals(method) && path.equals("/todos")) {
                handlePostTodo(exchange, userId);
            } else if (method.matches("GET|PUT|DELETE") && path.startsWith("/todos/")) {
                String idStr = path.substring("/todos/".length());
                if (idStr.contains("/")) {
                    exchange.sendResponseHeaders(404, -1);
                    return;
                }
                
                try {
                    int todoId = Integer.parseInt(idStr);
                    switch (method) {
                        case "GET":
                            handleGetTodoById(exchange, userId, todoId);
                            break;
                        case "PUT":
                            handlePutTodoById(exchange, userId, todoId);
                            break;
                        case "DELETE":
                            handleDeleteTodoById(exchange, userId, todoId);
                            break;
                        default:
                            exchange.sendResponseHeaders(405, -1);
                            break;
                    }
                } catch (NumberFormatException e) {
                    exchange.sendResponseHeaders(404, -1);
                }
            } else {
                exchange.sendResponseHeaders(404, -1);
            }
        }
        
        private void handleGetTodos(HttpExchange exchange, Integer userId) throws IOException {
            JsonArray response = new JsonArray();
            
            // Get all todos belonging to user's ID and sort by ID
            List<Todo> userTodos = new ArrayList<>();
            for (Todo todo : todos.values()) {
                if (todo.userId == userId) {
                    userTodos.add(todo);
                }
            }
            
            // Sort by ID ascending
            userTodos.sort((a, b) -> Integer.compare(a.id, b.id));
            
            for (Todo todo : userTodos) {
                response.add(todo.toJson());
            }
            
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            String jsonResponse = new Gson().toJson(response);
            byte[] responseBytes = jsonResponse.getBytes("UTF-8");
            exchange.sendResponseHeaders(200, responseBytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(responseBytes);
            }
        }
        
        private void handlePostTodo(HttpExchange exchange, Integer userId) throws IOException {
            try {
                JsonObject reqData = parseJsonFromRequest(exchange);
                
                String title = reqData.has("title") ? reqData.get("title").getAsString() : null;
                
                if (title == null || title.trim().isEmpty()) {
                    JsonObject error = new JsonObject();
                    error.addProperty("error", "Title is required");
                    setJsonResponse(exchange, 400, error);
                    return;
                }
                
                String description = reqData.has("description") ? reqData.get("description").getAsString() : "";
                
                int newTodoId = nextTodoId++;
                Todo newTodo = new Todo(newTodoId, title, description, userId);
                todos.put(newTodoId, newTodo);
                
                setJsonResponse(exchange, 201, newTodo.toJson());
            } catch (IllegalArgumentException e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", e.getMessage());
                setJsonResponse(exchange, 400, error);
            } catch (Exception e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Internal server error");
                setJsonResponse(exchange, 500, error);
            }
        }
        
        private void handleGetTodoById(HttpExchange exchange, Integer userId, int todoId) throws IOException {
            Todo todo = todos.get(todoId);
            
            if (todo == null || todo.userId != userId) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Todo not found");
                setJsonResponse(exchange, 404, error);
                return;
            }
            
            setJsonResponse(exchange, 200, todo.toJson());
        }
        
        private void handlePutTodoById(HttpExchange exchange, Integer userId, int todoId) throws IOException {
            Todo todo = todos.get(todoId);
            
            if (todo == null || todo.userId != userId) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Todo not found");
                setJsonResponse(exchange, 404, error);
                return;
            }
            
            try {
                JsonObject reqData = parseJsonFromRequest(exchange);
                
                if (reqData.has("title")) {
                    String newTitle = reqData.get("title").getAsString();
                    if (newTitle.trim().isEmpty()) {
                        JsonObject error = new JsonObject();
                        error.addProperty("error", "Title is required");
                        setJsonResponse(exchange, 400, error);
                        return;
                    }
                    todo.title = newTitle;
                }
                
                if (reqData.has("description")) {
                    String newDescription = reqData.get("description").getAsString();
                    todo.description = newDescription;
                }
                
                if (reqData.has("completed")) {
                    boolean newCompleted = reqData.get("completed").getAsBoolean();
                    todo.completed = newCompleted;
                }
                
                todo.updatedAt = getCurrentTimestamp();
                
                todos.put(todoId, todo);
                setJsonResponse(exchange, 200, todo.toJson());
            } catch (IllegalArgumentException e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", e.getMessage());
                setJsonResponse(exchange, 400, error);
            } catch (Exception e) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Internal server error");
                setJsonResponse(exchange, 500, error);
            }
        }
        
        private void handleDeleteTodoById(HttpExchange exchange, Integer userId, int todoId) throws IOException {
            Todo todo = todos.get(todoId);
            
            if (todo == null || todo.userId != userId) {
                JsonObject error = new JsonObject();
                error.addProperty("error", "Todo not found");
                setJsonResponse(exchange, 404, error);
                return;
            }
            
            todos.remove(todoId);
            setEmptyResponse(exchange, 204);
        }
    }
    
    // Helper method to hash passwords
    private String hashPassword(String password) {
        if (password == null) {
            return null;
        }
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(password.getBytes("UTF-8"));
            StringBuilder hexString = new StringBuilder();
            for (byte b : hash) {
                String hex = Integer.toHexString(0xff & b);
                if (hex.length() == 1) {
                    hexString.append('0');
                }
                hexString.append(hex);
            }
            return hexString.toString();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
package com.todoserver;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;
import java.io.*;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class TodoServer {
    private UserService userService;
    private TodoService todoService;
    private SessionManager sessionManager;
    
    // Pattern to match URL paths
    private final Pattern registerPattern = Pattern.compile("^/register$");
    private final Pattern loginPattern = Pattern.compile("^/login$");
    private final Pattern logoutPattern = Pattern.compile("^/logout$");
    private final Pattern mePattern = Pattern.compile("^/me$");
    private final Pattern passwordPattern = Pattern.compile("^/password$");
    private final Pattern todosPattern = Pattern.compile("^/todos$");
    private final Pattern todoIdPattern = Pattern.compile("^/todos/(\\d+)$");
    
    public TodoServer() {
        this.userService = new UserService();
        this.todoService = new TodoService();
        this.sessionManager = new SessionManager();
        
        // Pre-populate some default users for testing (in production, this wouldn't be here)
        // User user = userService.registerUser("testuser", "password123");
        // todoService.addTodo(user.getId(), "Sample Todo", "A sample task description");
    }
    
    public void start(int port) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/register", new RegisterHandler(this));
        server.createContext("/login", new LoginHandler(this));
        server.createContext("/logout", new LogoutHandler(this));
        server.createContext("/me", new MeHandler(this));
        server.createContext("/password", new PasswordHandler(this));
        server.createContext("/todos", new TodosHandler(this));
        
        server.setExecutor(null); // creates a default executor
        server.start();
    }
    
    protected UserService getUserService() {
        return userService;
    }
    
    protected TodoService getTodoService() {
        return todoService;
    }
    
    protected SessionManager getSessionManager() {
        return sessionManager;
    }
    
    // Handler for various endpoints
    class RegisterHandler implements HttpHandler {
        private TodoServer server;
        
        public RegisterHandler(TodoServer server) {
            this.server = server;
        }
        
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String requestBody = getRequestBody(exchange);
            
            // Parse JSON request
            JsonResponse jsonReq = JsonResponse.parseJson(requestBody);
            if (jsonReq == null) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                return;
            }
            
            String username = jsonReq.getString("username");
            String password = jsonReq.getString("password");
            
            if (username == null || !isValidUsername(username)) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid username\"}");
                return;
            }
            
            if (password == null || password.length() < 8) {
                sendResponse(exchange, 400, "{\"error\": \"Password too short\"}");
                return;
            }
            
            User user = server.getUserService().getUserByUsername(username);
            if (user != null) {
                sendResponse(exchange, 409, "{\"error\": \"Username already exists\"}");
                return;
            }
            
            User newUser = server.getUserService().registerUser(username, password);
            JsonResponse response = new JsonResponse();
            response.put("id", newUser.getId());
            response.put("username", newUser.getUsername());
            
            sendResponse(exchange, 201, response.toString());
        }
    }
    
    class LoginHandler implements HttpHandler {
        private TodoServer server;
        
        public LoginHandler(TodoServer server) {
            this.server = server;
        }
        
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String requestBody = getRequestBody(exchange);
            
            JsonResponse jsonReq = JsonResponse.parseJson(requestBody);
            if (jsonReq == null) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                return;
            }
            
            String username = jsonReq.getString("username");
            String password = jsonReq.getString("password");
            
            User user = server.getUserService().authenticateUser(username, password);
            if (user == null) {
                sendResponse(exchange, 401, "{\"error\": \"Invalid credentials\"}");
                return;
            }
            
            String sessionId = server.getSessionManager().createSession(user.getId());
            
            JsonResponse response = new JsonResponse();
            response.put("id", user.getId());
            response.put("username", user.getUsername());
            
            // Set cookie header
            exchange.getResponseHeaders().set("Set-Cookie", 
                "session_id=" + sessionId + "; Path=/; HttpOnly");
            
            sendResponse(exchange, 200, response.toString());
        }
    }
    
    class LogoutHandler implements HttpHandler {
        private TodoServer server;
        
        public LogoutHandler(TodoServer server) {
            this.server = server;
        }
        
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String sessionId = extractSessionId(exchange);
            if (sessionId == null) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            server.getSessionManager().destroySession(sessionId);
            
            JsonResponse response = new JsonResponse(); // Empty for logout
            
            sendResponse(exchange, 200, response.toString());
        }
    }
    
    class MeHandler implements HttpHandler {
        private TodoServer server;
        
        public MeHandler(TodoServer server) {
            this.server = server;
        }
        
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"GET".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String sessionId = extractSessionId(exchange);
            if (sessionId == null) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            Integer userId = server.getSessionManager().getUserIdBySession(sessionId);
            if (userId == null) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            User user = server.getUserService().getUserById(userId);
            if (user == null) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            JsonResponse response = new JsonResponse();
            response.put("id", user.getId());
            response.put("username", user.getUsername());
            
            sendResponse(exchange, 200, response.toString());
        }
    }
    
    class PasswordHandler implements HttpHandler {
        private TodoServer server;
        
        public PasswordHandler(TodoServer server) {
            this.server = server;
        }
        
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"PUT".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                return;
            }
            
            String sessionId = extractSessionId(exchange);
            if (sessionId == null) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            Integer userId = server.getSessionManager().getUserIdBySession(sessionId);
            if (userId == null) {
                sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                return;
            }
            
            String requestBody = getRequestBody(exchange);
            
            JsonResponse jsonReq = JsonResponse.parseJson(requestBody);
            if (jsonReq == null) {
                sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                return;
            }
            
            String oldPassword = jsonReq.getString("old_password");
            String newPassword = jsonReq.getString("new_password");
            
            if (oldPassword == null) {
                sendResponse(exchange, 400, "{\"error\": \"Old password is required\"}");
                return;
            }
            
            if (newPassword == null || newPassword.length() < 8) {
                sendResponse(exchange, 400, "{\"error\": \"Password too short\"}");
                return;
            }
            
            boolean success = server.getUserService().updatePassword(userId, oldPassword, newPassword);
            if (!success) {
                sendResponse(exchange, 401, "{\"error\": \"Invalid credentials\"}");
                return;
            }
            
            sendResponse(exchange, 200, "{}");
        }
    }
    
    class TodosHandler implements HttpHandler {
        private TodoServer server;
        
        public TodosHandler(TodoServer server) {
            this.server = server;
        }
        
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            // Extract path info to handle both /todos and /todos/{id}
            String path = exchange.getRequestURI().getPath();
            Matcher idMatcher = todoIdPattern.matcher(path);
            
            String method = exchange.getRequestMethod();
            String sessionId = extractSessionId(exchange);
            
            // Check if we need authentication for this endpoint
            boolean requiresAuth = !("/register".equals(path) || "/login".equals(path));
            boolean isTodosEndpoint = "/todos".equals(path) || path.startsWith("/todos/");
            
            // Handle authentication first
            Integer userId = null;
            if (requiresAuth) {
                if (sessionId == null) {
                    sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                    return;
                }
                
                userId = server.getSessionManager().getUserIdBySession(sessionId);
                if (userId == null) {
                    sendResponse(exchange, 401, "{\"error\": \"Authentication required\"}");
                    return;
                }
            }
            
            if ("/todos".equals(path)) {
                // Handle /todos endpoints
                switch (method) {
                    case "GET":
                        // List all todos
                        JsonResponse response = new JsonResponse(server.getTodoService().getTodosForUser(userId));
                        sendResponse(exchange, 200, response.toString());
                        break;
                    case "POST":
                        // Create a new todo
                        String requestBody = getRequestBody(exchange);
                        JsonResponse jsonReq = JsonResponse.parseJson(requestBody);
                        
                        if (jsonReq == null) {
                            sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                            return;
                        }
                        
                        String title = jsonReq.getString("title");
                        if (title == null || title.trim().isEmpty()) {
                            sendResponse(exchange, 400, "{\"error\": \"Title is required\"}");
                            return;
                        }
                        
                        String description = jsonReq.getString("description");
                        if (description == null) {
                            description = "";
                        }
                        
                        Todo newTodo = server.getTodoService().addTodo(userId, title, description);
                        JsonResponse newResponse = new JsonResponse(newTodo);
                        sendResponse(exchange, 201, newResponse.toString());
                        break;
                    default:
                        sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                }
            } else if (idMatcher.matches()) {
                // Handle /todos/{id} endpoints
                int id = Integer.parseInt(idMatcher.group(1));
                
                switch (method) {
                    case "GET":
                        // Get specific todo
                        Todo todo = server.getTodoService().getTodoById(id);
                        if (todo == null || todo.getUserId() != userId) {
                            sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                            return;
                        }
                        JsonResponse responseGet = new JsonResponse(todo);
                        sendResponse(exchange, 200, responseGet.toString());
                        break;
                    case "PUT":
                        // Update specific todo
                        Todo existingTodo = server.getTodoService().getTodoById(id);
                        if (existingTodo == null || existingTodo.getUserId() != userId) {
                            sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                            return;
                        }
                        
                        String putRequestBody = getRequestBody(exchange);
                        JsonResponse putJsonReq = JsonResponse.parseJson(putRequestBody);
                        
                        if (putJsonReq == null) {
                            sendResponse(exchange, 400, "{\"error\": \"Invalid JSON\"}");
                            return;
                        }
                        
                        String newTitle = putJsonReq.getString("title");
                        String newDescription = putJsonReq.getString("description");
                        Boolean completed = putJsonReq.getBoolean("completed");
                        
                        if (newTitle != null && newTitle.trim().isEmpty()) {
                            sendResponse(exchange, 400, "{\"error\": \"Title is required\"}");
                            return;
                        }
                        
                        Todo updatedTodo = server.getTodoService().updateTodo(
                            id, newTitle, newDescription, completed);
                            
                        JsonResponse updateResponse = new JsonResponse(updatedTodo);
                        sendResponse(exchange, 200, updateResponse.toString());
                        break;
                    case "DELETE":
                        // Delete specific todo
                        Todo todoToDelete = server.getTodoService().getTodoById(id);
                        if (todoToDelete == null || todoToDelete.getUserId() != userId) {
                            sendResponse(exchange, 404, "{\"error\": \"Todo not found\"}");
                            return;
                        }
                        
                        server.getTodoService().deleteTodo(id);
                        // 204 No Content
                        exchange.sendResponseHeaders(204, -1);
                        exchange.close();
                        break;
                    default:
                        sendResponse(exchange, 405, "{\"error\": \"Method not allowed\"}");
                }
            } else {
                sendResponse(exchange, 404, "{\"error\": \"Not found\"}");
            }
        }
    }
    
    // Helper method to retrieve session ID from cookies
    private String extractSessionId(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader != null) {
            Pattern pattern = Pattern.compile("session_id=([^;\\s]+)");
            Matcher matcher = pattern.matcher(cookieHeader);
            if (matcher.find()) {
                return matcher.group(1);
            }
        }
        return null;
    }
    
    // Helper method to validate username
    private boolean isValidUsername(String username) {
        if (username == null || username.length() < 3 || username.length() > 50) {
            return false;
        }
        return username.matches("^[a-zA-Z0-9_]+$");
    }
    
    // Helper method to read request body
    private String getRequestBody(HttpExchange exchange) throws IOException {
        InputStream inputStream = exchange.getRequestBody();
        StringBuilder builder = new StringBuilder();
        BufferedReader reader = new BufferedReader(new InputStreamReader(inputStream, StandardCharsets.UTF_8));
        String line;
        while ((line = reader.readLine()) != null) {
            builder.append(line);
        }
        return builder.toString();
    }
    
    // Send response helper method
    private void sendResponse(HttpExchange exchange, int statusCode, String responseBody) throws IOException {
        byte[] responseBytes = responseBody.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(statusCode, responseBytes.length);
        OutputStream os = exchange.getResponseBody();
        os.write(responseBytes);
        os.close();
    }
}
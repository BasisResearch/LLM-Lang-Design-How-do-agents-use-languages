package com.todo.server;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;

import java.io.*;
import java.net.InetSocketAddress;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;
import java.nio.charset.StandardCharsets;

public class TodoServer {
    private static final Map<Integer, User> users = new ConcurrentHashMap<>();
    private static final Map<String, Integer> usernamesToIds = new ConcurrentHashMap<>();
    private static final Map<String, String> passwords = new ConcurrentHashMap<>();
    private static final Map<Integer, List<Todo>> userTodos = new ConcurrentHashMap<>();
    private static final Map<String, Session> sessions = new ConcurrentHashMap<>();
    
    private static int userIdCounter = 1;
    private static int todoIdCounter = 1;
    
    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");
    
    public static void main(String[] args) {
        int port = 8080; // default port
        
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                try {
                    port = Integer.parseInt(args[i + 1]);
                    i++; // skip next argument
                } catch (NumberFormatException e) {
                    System.err.println("Invalid port number: " + args[i + 1]);
                    System.exit(1);
                }
            }
        }
        
        TodoServer server = new TodoServer();
        server.start(port);
    }
    
    public void start(int port) {
        try {
            HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
            
            // Register handlers
            server.createContext("/register", new RegisterHandler());
            server.createContext("/login", new LoginHandler());
            server.createContext("/logout", new LogoutHandler());
            server.createContext("/me", new MeHandler());
            server.createContext("/password", new PasswordHandler());
            server.createContext("/todos", new TodosHandler());
            
            server.setExecutor(null); // creates a default executor
            System.out.println("Server starting on port " + port);
            server.start();
        } catch (Exception e) {
            System.err.println("Error starting server: " + e.getMessage());
            e.printStackTrace();
        }
    }

    // Inner classes for our JSON parsing
    static class JsonParserHelper {
        public static String getJsonValue(String json, String fieldName) {
            if (json == null || json.isEmpty()) return null;
            
            String searchKey = "\"" + fieldName + "\"";
            int index = json.indexOf(searchKey);
            if (index == -1) return null;
            
            index += searchKey.length();
            // Skip colon and whitespace 
            while (index < json.length() && (json.charAt(index) == ':' || Character.isWhitespace(json.charAt(index)))) {
                index++;
            }
            
            if (index >= json.length()) return null;
            
            char quote = json.charAt(index);
            if (quote != '"' && quote != '\'' && !Character.isDigit(quote) && quote != 't' && quote != 'f' && quote != 'n') {
                return null;
            }
            
            if (quote == 't' || quote == 'f') { // Handle booleans explicitly
                if (json.substring(index).startsWith("true")) {
                    return "true";
                } else if (json.substring(index).startsWith("false")) {
                    return "false";
                }
                return null;
            }
            
            if (quote == 'n') { // Handle null values
                if (json.substring(index).startsWith("null")) {
                    return "null";
                }
                return null;
            }
            
            if (quote == '"' || quote == '\'') {
                int start = index + 1;
                int end = start;
                char ch;
                boolean escaped = false;
                
                while (end < json.length()) {
                    ch = json.charAt(end);
                    if (ch == quote && !escaped) {
                        break;
                    }
                    if (ch == '\\' && !escaped) {
                        escaped = true;
                    } else {
                        escaped = false;
                    }
                    end++;
                }
                
                return json.substring(start, end);
            }
            
            // Handle numbers and other values
            int start = index;
            int end = start;
            
            while (end < json.length() && 
                  (Character.isLetterOrDigit(json.charAt(end)) || 
                   json.charAt(end) == '.' || 
                   json.charAt(end) == '-' ||
                   json.charAt(end) == 'e' ||
                   json.charAt(end) == 'E')) {
                end++;
            }
            
            return json.substring(start, end);
        }
    }

    // Stringify our objects to JSON
    static class JsonBuilder {
        public static String toJson(Map<String, Object> map) {
            StringBuilder sb = new StringBuilder();
            sb.append("{");
            boolean first = true;
            for (Map.Entry<String, Object> entry : map.entrySet()) {
                if (!first) {
                    sb.append(",");
                } else {
                    first = false;
                }
                
                sb.append("\"").append(entry.getKey()).append("\":");
                
                if (entry.getValue() instanceof String) {
                    sb.append("\"").append(escapeJsonString((String) entry.getValue())).append("\"");
                } else if (entry.getValue() == null) {
                    sb.append("null");
                } else if (entry.getValue() instanceof Boolean || entry.getValue() instanceof Number) {
                    sb.append(entry.getValue().toString());
                } else { // nested object - this is simplified
                    sb.append(entry.getValue().toString()); // would need more sophisticated handling
                }
            }
            sb.append("}");
            return sb.toString();
        }
        
        private static String escapeJsonString(String input) {
            if (input == null) return null;
            StringBuilder sb = new StringBuilder();
            for (char c : input.toCharArray()) {
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
    }

    // Inner classes for request/response structs
    static class User {
        int id;
        String username;
        
        public User(int id, String username) {
            this.id = id;
            this.username = username;
        }
    }
    
    static class Session {
        String sessionId;
        int userId;
        long createdTime;
        
        public Session(String sessionId, int userId, long createdTime) {
            this.sessionId = sessionId;
            this.userId = userId;
            this.createdTime = createdTime;
        }
    }
    
    static class Todo {
        int id;
        String title;
        String description;
        boolean completed;
        String createdAt;
        String updatedAt;
        int userId;
        
        public Todo(int userId, String title, String description) {
            this.id = getNextTodoId();
            this.userId = userId;
            this.title = title;
            this.description = description != null ? description : "";
            this.completed = false;
            LocalDateTime now = LocalDateTime.now();
            String isoTime = now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
            this.createdAt = isoTime;
            this.updatedAt = isoTime;
        }
        
        private synchronized int getNextTodoId() {
            return todoIdCounter++;
        }
    }
    
    abstract class AuthenticatedHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            // Check authentication
            Session session = getSessionFromRequest(exchange);
            if (session == null) {
                sendErrorResponse(exchange, 401, "Authentication required");
                return;
            }
            
            handleAuthenticatedRequest(exchange, session);
        }
        
        abstract void handleAuthenticatedRequest(HttpExchange exchange, Session session) throws IOException;
    }
    
    private Session getSessionFromRequest(HttpExchange exchange) {
        java.util.List<String> cookieHeaders = exchange.getRequestHeaders().get("Cookie");
        
        if (cookieHeaders == null || cookieHeaders.isEmpty()) {
            return null;
        }
        
        String sessionId = null;
        for (String cookieHeader : cookieHeaders) {
            String[] cookies = cookieHeader.split(";");
            for (String cookie : cookies) {
                cookie = cookie.trim();
                if (cookie.startsWith("session_id=")) {
                    sessionId = cookie.substring("session_id=".length());
                    break;
                }
            }
            if (sessionId != null) {
                break;
            }
        }
        
        if (sessionId == null) {
            return null;
        }
        
        Session session = sessions.get(sessionId);
        if (session == null) {
            return null;
        }
        
        return session;
    }
    
    private void addSessionCookie(HttpExchange exchange, String sessionId) {
        exchange.getResponseHeaders().add("Set-Cookie", String.format("session_id=%s; Path=/; HttpOnly", sessionId));
    }
    
    private byte[] getUserBytes(User user) {
        Map<String, Object> userInfo = new HashMap<>();
        userInfo.put("id", user.id);
        userInfo.put("username", user.username);
        return JsonBuilder.toJson(userInfo).getBytes(StandardCharsets.UTF_8);
    }
    
    private byte[] getTodoBytes(Todo todo) {
        Map<String, Object> todoData = new HashMap<>();
        todoData.put("id", todo.id);
        todoData.put("title", todo.title);
        todoData.put("description", todo.description);
        todoData.put("completed", todo.completed);
        todoData.put("created_at", todo.createdAt);
        todoData.put("updated_at", todo.updatedAt);
        
        return JsonBuilder.toJson(todoData).getBytes(StandardCharsets.UTF_8);
    }
    
    private byte[] getErrorBytes(String errorMessage) {
        Map<String, Object> error = new HashMap<>();
        error.put("error", errorMessage);
        return JsonBuilder.toJson(error).getBytes(StandardCharsets.UTF_8);
    }
    
    private void sendSuccessResponse(HttpExchange exchange, byte[] response) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, response.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(response);
        }
    }
    
    private void sendCreatedResponse(HttpExchange exchange, byte[] response) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(201, response.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(response);
        }
    }
    
    private void sendNoContentResponse(HttpExchange exchange) throws IOException {
        exchange.sendResponseHeaders(204, -1); // No body needed
    }
    
    private void sendErrorResponse(HttpExchange exchange, int statusCode, String message) throws IOException {
        byte[] response = getErrorBytes(message);
        
        if (statusCode == 204) {
            exchange.sendResponseHeaders(204, -1);
            return;
        }
        
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(statusCode, response.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(response);
        }
    }
    
    private Todo getTodoById(int todoId) {
        for (List<Todo> todosList : userTodos.values()) {
            for (Todo todo : todosList) {
                if (todo.id == todoId) {
                    return todo;
                }
            }
        }
        return null;
    }
    
    private User getUserById(int userId) {
        return users.get(userId);
    }
    
    // Handler implementations
    class RegisterHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            String requestBody = new BufferedReader(new InputStreamReader(
                exchange.getRequestBody(), StandardCharsets.UTF_8)).lines()
                .reduce("", (accumulator, actual) -> accumulator + actual);
                
            try {
                String username = JsonParserHelper.getJsonValue(requestBody, "username");
                String password = JsonParserHelper.getJsonValue(requestBody, "password");
                
                if (username == null || password == null) {
                    sendErrorResponse(exchange, 400, "Username and password are required");
                    return;
                }
                
                if (!USERNAME_PATTERN.matcher(username).matches()) {
                    sendErrorResponse(exchange, 400, "Invalid username");
                    return;
                }
                
                if (password.length() < 8) {
                    sendErrorResponse(exchange, 400, "Password too short");
                    return;
                }
                
                // Check if username already exists
                if (usernamesToIds.containsKey(username)) {
                    sendErrorResponse(exchange, 409, "Username already exists");
                    return;
                }
                
                // Create new user
                int userId = getNextUserId();
                User newUser = new User(userId, username);
                users.put(userId, newUser);
                usernamesToIds.put(username, userId);
                passwords.put(Integer.toString(userId), password);
                
                // Initialize user's todo list
                userTodos.put(userId, new ArrayList<>());
                
                sendCreatedResponse(exchange, getUserBytes(newUser));
                
            } catch (Exception e) {
                sendErrorResponse(exchange, 400, "Invalid JSON");
            }
        }
        
        private synchronized int getNextUserId() {
            int id = userIdCounter;
            userIdCounter++;
            return id;
        }
    }
    
    class LoginHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            String requestBody = new BufferedReader(new InputStreamReader(
                exchange.getRequestBody(), StandardCharsets.UTF_8)).lines()
                .reduce("", (accumulator, actual) -> accumulator + actual);
                
            try {
                String username = JsonParserHelper.getJsonValue(requestBody, "username");
                String password = JsonParserHelper.getJsonValue(requestBody, "password");
                
                if (username == null || password == null) {
                    sendErrorResponse(exchange, 400, "Username and password are required");
                    return;
                }
                
                Integer userId = usernamesToIds.get(username);
                
                if (userId == null || !password.equals(passwords.get(Integer.toString(userId)))) {
                    sendErrorResponse(exchange, 401, "Invalid credentials");
                    return;
                }
                
                // Create session
                String sessionId = UUID.randomUUID().toString();
                Session session = new Session(sessionId, userId, System.currentTimeMillis());
                sessions.put(sessionId, session);
                
                User user = getUserById(userId);
                
                addSessionCookie(exchange, sessionId);
                sendSuccessResponse(exchange, getUserBytes(user));
            } catch (Exception e) {
                sendErrorResponse(exchange, 400, "Invalid JSON");
            }
        }
    }
    
    class LogoutHandler extends AuthenticatedHandler {
        @Override
        void handleAuthenticatedRequest(HttpExchange exchange, Session session) throws IOException {
            if (!"POST".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            // Remove session
            sessions.remove(session.sessionId);
            
            // Send success response
            byte[] response = "{}".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(response);
            }
        }
    }
    
    class MeHandler extends AuthenticatedHandler {
        @Override
        void handleAuthenticatedRequest(HttpExchange exchange, Session session) throws IOException {
            if (!"GET".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            User user = getUserById(session.userId);
            if (user == null) {
                sendErrorResponse(exchange, 404, "User not found");
                return;
            }
            
            sendSuccessResponse(exchange, getUserBytes(user));
        }
    }
    
    class PasswordHandler extends AuthenticatedHandler {
        @Override
        void handleAuthenticatedRequest(HttpExchange exchange, Session session) throws IOException {
            if (!"PUT".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            
            String requestBody = new BufferedReader(new InputStreamReader(
                exchange.getRequestBody(), StandardCharsets.UTF_8)).lines()
                .reduce("", (accumulator, actual) -> accumulator + actual);
                
            try {
                String oldPassword = JsonParserHelper.getJsonValue(requestBody, "old_password");
                String newPassword = JsonParserHelper.getJsonValue(requestBody, "new_password");
                
                if (oldPassword == null || newPassword == null) {
                    sendErrorResponse(exchange, 400, "Old password and new password are required");
                    return;
                }
                
                String correctPassword = passwords.get(Integer.toString(session.userId));
                
                if (!correctPassword.equals(oldPassword)) {
                    sendErrorResponse(exchange, 401, "Invalid credentials");
                    return;
                }
                
                if (newPassword.length() < 8) {
                    sendErrorResponse(exchange, 400, "Password too short");
                    return;
                }
                
                // Update password
                passwords.put(Integer.toString(session.userId), newPassword);
                
                // Send success response (empty)
                byte[] response = "{}".getBytes(StandardCharsets.UTF_8);
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(200, response.length);
                try (OutputStream os = exchange.getResponseBody()) {
                    os.write(response);
                }
                
            } catch (Exception e) {
                sendErrorResponse(exchange, 400, "Invalid JSON");
            }
        }
    }
    
    class TodosHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            String method = exchange.getRequestMethod();
            String path = exchange.getRequestURI().getPath();
            
            Session session = getSessionFromRequest(exchange);
            if (session == null) {
                sendErrorResponse(exchange, 401, "Authentication required");
                return;
            }
            
            // Extract todo ID if present in path
            int todoId = -1;
            String[] pathParts = path.split("/");
            if (pathParts.length >= 3) {
                try {
                    todoId = Integer.parseInt(pathParts[2]);
                } catch (NumberFormatException e) {
                    // Ignore if not a valid number
                }
            }
            
            switch (method) {
                case "GET":
                    if (todoId == -1) {
                        // GET /todos (list all)
                        handleGetTodos(exchange, session);
                    } else {
                        // GET /todos/{id}
                        handleGetTodoById(exchange, session, todoId);
                    }
                    break;
                    
                case "POST":
                    if (todoId == -1) {
                        // POST /todos (create new)
                        handleCreateTodo(exchange, session);
                    } else {
                        sendErrorResponse(exchange, 404, "Not Found");
                    }
                    break;
                    
                case "PUT":
                    if (todoId != -1) {
                        // PUT /todos/{id} (update)
                        handleUpdateTodo(exchange, session, todoId);
                    } else {
                        sendErrorResponse(exchange, 404, "Not Found");
                    }
                    break;
                    
                case "DELETE":
                    if (todoId != -1) {
                        // DELETE /todos/{id}
                        handleDeleteTodo(exchange, session, todoId);
                    } else {
                        sendErrorResponse(exchange, 404, "Not Found");
                    }
                    break;
                    
                default:
                    exchange.sendResponseHeaders(405, -1);
                    break;
            }
        }
        
        private void handleGetTodos(HttpExchange exchange, Session session) throws IOException {
            List<Todo> userTodoList = userTodos.get(session.userId);
            if (userTodoList == null) {
                userTodoList = new ArrayList<>();
            }
            
            StringBuilder sb = new StringBuilder();
            sb.append("[");
            for (int i = 0; i < userTodoList.size(); i++) {
                if (i > 0) sb.append(",");
                String todoJsonStr = new String(getTodoBytes(userTodoList.get(i)), StandardCharsets.UTF_8);
                sb.append(todoJsonStr);
            }
            sb.append("]");
            
            byte[] response = sb.toString().getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(response);
            }
        }
        
        private void handleCreateTodo(HttpExchange exchange, Session session) throws IOException {
            String requestBody = new BufferedReader(new InputStreamReader(
                exchange.getRequestBody(), StandardCharsets.UTF_8)).lines()
                .reduce("", (accumulator, actual) -> accumulator + actual);
                
            try {
                String title = JsonParserHelper.getJsonValue(requestBody, "title");
                
                if (title == null) {
                    sendErrorResponse(exchange, 400, "Title is required");
                    return;
                }
                
                if (title.trim().isEmpty()) {
                    sendErrorResponse(exchange, 400, "Title is required");
                    return;
                }
                
                String description = JsonParserHelper.getJsonValue(requestBody, "description");
                if (description == null) {
                    description = "";
                }
                
                Todo todo = new Todo(session.userId, title, description);
                List<Todo> userTodoList = userTodos.get(session.userId);
                if (userTodoList == null) {
                    userTodoList = new ArrayList<>();
                    userTodos.put(session.userId, userTodoList);
                }
                userTodoList.add(todo);
                
                sendCreatedResponse(exchange, getTodoBytes(todo));
            } catch (Exception e) {
                sendErrorResponse(exchange, 400, "Invalid JSON");
            }
        }
        
        private void handleGetTodoById(HttpExchange exchange, Session session, int todoId) throws IOException {
            // Get the specific todo that belongs to this user
            List<Todo> userTodoList = userTodos.get(session.userId);
            if (userTodoList == null) {
                sendErrorResponse(exchange, 404, "Todo not found");
                return;
            }
            
            Todo todo = null;
            for (Todo t : userTodoList) {
                if (t.id == todoId) {
                    todo = t;
                    break;
                }
            }
            
            if (todo == null) {
                sendErrorResponse(exchange, 404, "Todo not found");
                return;
            }
            
            sendSuccessResponse(exchange, getTodoBytes(todo));
        }
        
        private void handleUpdateTodo(HttpExchange exchange, Session session, int todoId) throws IOException {
            // Get the todo that belongs to this user
            List<Todo> userTodoList = userTodos.get(session.userId);
            if (userTodoList == null) {
                sendErrorResponse(exchange, 404, "Todo not found");
                return;
            }
            
            Todo todo = null;
            int todoIndex = -1;
            for (int i = 0; i < userTodoList.size(); i++) {
                if (userTodoList.get(i).id == todoId) {
                    todo = userTodoList.get(i);
                    todoIndex = i;
                    break;
                }
            }
            
            if (todo == null) {
                sendErrorResponse(exchange, 404, "Todo not found");
                return;
            }
            
            String requestBody = new BufferedReader(new InputStreamReader(
                exchange.getRequestBody(), StandardCharsets.UTF_8)).lines()
                .reduce("", (accumulator, actual) -> accumulator + actual);
                
            try {
                String title = JsonParserHelper.getJsonValue(requestBody, "title");
                String description = JsonParserHelper.getJsonValue(requestBody, "description"); 
                String completedStr = JsonParserHelper.getJsonValue(requestBody, "completed");
                
                boolean completedParsed = false;
                if (title != null) {
                    if (title.trim().isEmpty()) {
                        sendErrorResponse(exchange, 400, "Title is required");
                        return;
                    }
                    todo.title = title;
                }
                
                if (description != null) {
                    todo.description = description;
                }
                
                if (completedStr != null && !"null".equals(completedStr)) {
                    todo.completed = Boolean.parseBoolean(completedStr);
                    completedParsed = true;
                }
                
                // Update the updated_at field
                LocalDateTime now = LocalDateTime.now();
                String isoTime = now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
                todo.updatedAt = isoTime;
                
                // Replace the todo in the list
                userTodoList.set(todoIndex, todo);
                
                sendSuccessResponse(exchange, getTodoBytes(todo));
            } catch (Exception e) {
                sendErrorResponse(exchange, 400, "Invalid JSON");
            }
        }
        
        private void handleDeleteTodo(HttpExchange exchange, Session session, int todoId) throws IOException {
            // Get the todo that belongs to this user
            List<Todo> userTodoList = userTodos.get(session.userId);
            if (userTodoList == null) {
                sendErrorResponse(exchange, 404, "Todo not found");
                return;
            }
            
            boolean removed = false;
            Iterator<Todo> iterator = userTodoList.iterator();
            while (iterator.hasNext()) {
                Todo todo = iterator.next();
                if (todo.id == todoId) {
                    iterator.remove();
                    removed = true;
                    break;
                }
            }
            
            if (!removed) {
                sendErrorResponse(exchange, 404, "Todo not found");
                return;
            }
            
            sendNoContentResponse(exchange);
        }
    }
}
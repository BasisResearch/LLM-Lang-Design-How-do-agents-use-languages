package com.todoserver;

import java.io.IOException;
import java.io.OutputStream;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.regex.Pattern;

import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public class RequestHandler {
    private final Database db;
    private final SessionManager sessionManager;
    
    public RequestHandler(Database db, SessionManager sessionManager) {
        this.db = db;
        this.sessionManager = sessionManager;
    }
    
    public void handleRegister(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equalsIgnoreCase("post")) {
            sendJsonErrorWithCode(exchange, 405, "Method not allowed");
            return;
        }
        
        String requestBody = readRequestBody(exchange);
        Map<String, String> body = SimpleJsonParser.parseJsonObject(requestBody);
        
        String username = body.get("username");
        String password = body.get("password");
        
        // Validate username
        if (username == null || !db.isValidUsername(username)) {
            sendJsonErrorWithCode(exchange, 400, "Invalid username");
            return;
        }
        
        // Validate password
        if (password == null || password.length() < 8) {
            sendJsonErrorWithCode(exchange, 400, "Password too short");
            return;
        }
        
        // Check if username is already taken
        if (db.isUsernameTaken(username)) {
            sendJsonErrorWithCode(exchange, 409, "Username already exists");
            return;
        }
        
        // Create user
        Database.User user = db.createUser(username, password);
        
        String response = "{\"id\": " + user.id + ", \"username\": \"" + escapeJson(user.username) + "\"}";
        sendResponse(exchange, 201, response);
    }
    
    public void handleLogin(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equalsIgnoreCase("post")) {
            sendJsonErrorWithCode(exchange, 405, "Method not allowed");
            return;
        }
        
        String requestBody = readRequestBody(exchange);
        Map<String, String> body = SimpleJsonParser.parseJsonObject(requestBody);
        
        String username = body.get("username");
        String password = body.get("password");
        
        Database.User user = db.findUserByUsername(username);
        if (user == null || !db.checkPassword(user, password)) {
            sendJsonErrorWithCode(exchange, 401, "Invalid credentials");
            return;
        }
        
        String sessionId = sessionManager.createSession(user.id);
        
        String response = "{\"id\": " + user.id + ", \"username\": \"" + escapeJson(user.username) + "\"}";
        
        // Set the session cookie
        Headers headers = exchange.getResponseHeaders();
        headers.add("Set-Cookie", "session_id=" + sessionId + "; Path=/; HttpOnly");
        
        sendResponse(exchange, 200, response);
    }
    
    public void handleLogout(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equalsIgnoreCase("post")) {
            sendJsonErrorWithCode(exchange, 405, "Method not allowed");
            return;
        }
        
        String sessionId = extractSessionId(exchange);
        if (sessionId == null || !hasValidSession(sessionId)) {
            sendJsonErrorWithCode(exchange, 401, "Authentication required");
            return;
        }
        
        sessionManager.logoutSession(sessionId);
        sendResponse(exchange, 200, "{}");
    }
    
    public void handleMe(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equalsIgnoreCase("get")) {
            sendJsonErrorWithCode(exchange, 405, "Method not allowed");
            return;
        }
        
        String sessionId = extractSessionId(exchange);
        SessionManager.Session session = getSession(sessionId);
        if (session == null) {
            sendJsonErrorWithCode(exchange, 401, "Authentication required");
            return;
        }
        
        Database.User user = db.findUserById(session.userId);
        if (user == null) { // Should not happen if session is valid
            sendJsonErrorWithCode(exchange, 401, "Authentication required");
            return;
        }
        
        String response = "{\"id\": " + user.id + ", \"username\": \"" + escapeJson(user.username) + "\"}";
        sendResponse(exchange, 200, response);
    }
    
    public void handlePassword(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equalsIgnoreCase("put")) {
            sendJsonErrorWithCode(exchange, 405, "Method not allowed");
            return;
        }
        
        String sessionId = extractSessionId(exchange);
        SessionManager.Session session = getSession(sessionId);
        if (session == null) {
            sendJsonErrorWithCode(exchange, 401, "Authentication required");
            return;
        }
        
        String requestBody = readRequestBody(exchange);
        Map<String, String> body = SimpleJsonParser.parseJsonObject(requestBody);
        
        String oldPassword = body.get("old_password");
        String newPassword = body.get("new_password");
        
        if (newPassword == null || newPassword.length() < 8) {
            sendJsonErrorWithCode(exchange, 400, "Password too short");
            return;
        }
        
        if (!db.changeUserPassword(session.userId, oldPassword, newPassword)) {
            sendJsonErrorWithCode(exchange, 401, "Invalid credentials");
            return;
        }
        
        sendResponse(exchange, 200, "{}");
    }
    
    public void handleTodos(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod().toLowerCase();
        String path = exchange.getRequestURI().getPath();
        
        // Extract todo ID if present (the part after /todos/)
        Pattern pattern = Pattern.compile("^/todos/(\\d+)(?:/.*)?$");
        java.util.regex.Matcher matcher = pattern.matcher(path);
        
        if (matcher.find()) {
            int todoId;
            try {
                todoId = Integer.parseInt(matcher.group(1));
            } catch (NumberFormatException e) {
                sendJsonErrorWithCode(exchange, 400, "Invalid todo ID");
                return;
            }
            
            switch (method) {
                case "get":
                    handleGetTodoById(exchange, todoId);
                    break;
                case "put":
                    handlePutTodoById(exchange, todoId);
                    break;
                case "delete":
                    handleDeleteTodoById(exchange, todoId);
                    break;
                default:
                    sendJsonErrorWithCode(exchange, 405, "Method not allowed");
                    break;
            }
        } else {
            // Handle requests to /todos without ID
            switch (method) {
                case "get":
                    handleGetTodos(exchange);
                    break;
                case "post":
                    handlePostTodo(exchange);
                    break;
                default:
                    sendJsonErrorWithCode(exchange, 405, "Method not allowed");
                    break;
            }
        }
    }
    
    private void handleGetTodos(HttpExchange exchange) throws IOException {
        String sessionId = extractSessionId(exchange);
        SessionManager.Session session = getSession(sessionId);
        if (session == null) {
            sendJsonErrorWithCode(exchange, 401, "Authentication required");
            return;
        }
        
        List<Database.Todo> todos = db.getTodos(session.userId);
        
        // Sort by ID ascending
        todos.sort((t1, t2) -> Integer.compare(t1.id, t2.id));
        
        // Convert to JSON array
        StringBuilder response = new StringBuilder("[");
        for (int i = 0; i < todos.size(); i++) {
            Database.Todo todo = todos.get(i);
            if (i > 0) response.append(",");
            response.append("{")
                   .append("\"id\":" + todo.id)
                   .append(",\"title\":\"" + escapeJson(todo.title) + "\"")
                   .append(",\"description\":\"" + escapeJson(todo.description) + "\"")
                   .append(",\"completed\":" + todo.completed)
                   .append(",\"created_at\":\"" + escapeJson(todo.created_at) + "\"")
                   .append(",\"updated_at\":\"" + escapeJson(todo.updated_at) + "\"")
                   .append("}");
        }
        response.append("]");
        
        sendResponse(exchange, 200, response.toString());
    }
    
    private void handlePostTodo(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equalsIgnoreCase("post")) {
            sendJsonErrorWithCode(exchange, 405, "Method not allowed");
            return;
        }
        
        String sessionId = extractSessionId(exchange);
        SessionManager.Session session = getSession(sessionId);
        if (session == null) {
            sendJsonErrorWithCode(exchange, 401, "Authentication required");
            return;
        }
        
        String requestBody = readRequestBody(exchange);
        Map<String, String> body = SimpleJsonParser.parseJsonObject(requestBody);
        
        String title = body.get("title");
        
        // Validate title (must be present and non-empty)
        if (title == null || title.trim().isEmpty()) {
            sendJsonErrorWithCode(exchange, 400, "Title is required");
            return;
        }
        
        // Get optional description
        String description = SimpleJsonParser.parseStringValue(body.getOrDefault("description", "\"\""));
        
        // Add the todo
        Database.Todo todo = db.addTodo(session.userId, title, description);
        
        // Send response with the newly created todo
        String response = "{"
                + "\"id\":" + todo.id + ","
                + "\"title\":\"" + escapeJson(todo.title) + "\","
                + "\"description\":\"" + escapeJson(todo.description) + "\","
                + "\"completed\":" + todo.completed + ","
                + "\"created_at\":\"" + escapeJson(todo.created_at) + "\","
                + "\"updated_at\":\"" + escapeJson(todo.updated_at) + "\""
                + "}";
        
        sendResponse(exchange, 201, response);
    }
    
    private void handleGetTodoById(HttpExchange exchange, int todoId) throws IOException {
        String sessionId = extractSessionId(exchange);
        SessionManager.Session session = getSession(sessionId);
        if (session == null) {
            sendJsonErrorWithCode(exchange, 401, "Authentication required");
            return;
        }
        
        Database.Todo todo = db.getTodo(session.userId, todoId);
        
        if (todo == null) {
            sendJsonErrorWithCode(exchange, 404, "Todo not found");
            return;
        }
        
        String response = "{"
                + "\"id\":" + todo.id + ","
                + "\"title\":\"" + escapeJson(todo.title) + "\","
                + "\"description\":\"" + escapeJson(todo.description) + "\","
                + "\"completed\":" + todo.completed + ","
                + "\"created_at\":\"" + escapeJson(todo.created_at) + "\","
                + "\"updated_at\":\"" + escapeJson(todo.updated_at) + "\"" 
                + "}";
        
        sendResponse(exchange, 200, response);
    }
    
    private void handlePutTodoById(HttpExchange exchange, int todoId) throws IOException {
        if (!exchange.getRequestMethod().equalsIgnoreCase("put")) {
            sendJsonErrorWithCode(exchange, 405, "Method not allowed");
            return;
        }
        
        String sessionId = extractSessionId(exchange);
        SessionManager.Session session = getSession(sessionId);
        if (session == null) {
            sendJsonErrorWithCode(exchange, 401, "Authentication required");
            return;
        }
        
        String requestBody = readRequestBody(exchange);
        Map<String, String> body = SimpleJsonParser.parseJsonObject(requestBody);
        
        // Extract the fields that might be in the request
        String title = body.get("title");
        String description = body.get("description");
        String completedStr = body.get("completed");
        
        Boolean completed = null;
        if (completedStr != null) {
            if ("true".equals(completedStr) || "1".equals(completedStr)) {
                completed = true;
            } else if ("false".equals(completedStr) || "0".equals(completedStr)) {
                completed = false;
            }
        }
        
        // Validate title if it's provided and non-empty (if empty, reject)
        if (title != null && title.trim().isEmpty()) {
            sendJsonErrorWithCode(exchange, 400, "Title is required");
            return;
        }
        
        // If a field is not in the request body, pass null to preserve current value
        String titleForUpdate = title; 
        String descForUpdate = description != null ? SimpleJsonParser.parseStringValue(description) : null;
        
        boolean updated = db.updateTodo(session.userId, todoId, titleForUpdate, descForUpdate, completed);
        
        if (!updated) {
            sendJsonErrorWithCode(exchange, 404, "Todo not found");
            return;
        }
        
        // Get the updated todo back to return
        Database.Todo todo = db.getTodo(session.userId, todoId);
        
        String response = "{"
                + "\"id\":" + todo.id + ","
                + "\"title\":\"" + escapeJson(todo.title) + "\","
                + "\"description\":\"" + escapeJson(todo.description) + "\","
                + "\"completed\":" + todo.completed + ","
                + "\"created_at\":\"" + escapeJson(todo.created_at) + "\","
                + "\"updated_at\":\"" + escapeJson(todo.updated_at) + "\"" 
                + "}";
        
        sendResponse(exchange, 200, response);
    }
    
    private void handleDeleteTodoById(HttpExchange exchange, int todoId) throws IOException {
        if (!exchange.getRequestMethod().equalsIgnoreCase("delete")) {
            sendJsonErrorWithCode(exchange, 405, "Method not allowed");
            return;
        }
        
        String sessionId = extractSessionId(exchange);
        SessionManager.Session session = getSession(sessionId);
        if (session == null) {
            sendJsonErrorWithCode(exchange, 401, "Authentication required");
            return;
        }
        
        boolean deleted = db.deleteTodo(session.userId, todoId);
        
        if (!deleted) {
            sendJsonErrorWithCode(exchange, 404, "Todo not found");
            return;
        }
        
        // Successful deletion returns 204 with no body
        exchange.sendResponseHeaders(204, -1); // -1 indicates no response body
        OutputStream os = exchange.getResponseBody();
        os.close();
    }
    
    private String readRequestBody(HttpExchange exchange) throws IOException {
        BufferedReader reader = new BufferedReader(new InputStreamReader(exchange.getRequestBody()));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            sb.append(line);
        }
        return sb.toString();
    }
    
    private void sendResponse(HttpExchange exchange, int statusCode, String response) throws IOException {
        sendResponse(exchange, statusCode, response, "application/json");
    }
    
    private void sendResponse(HttpExchange exchange, int statusCode, String response, String contentType) throws IOException {
        Headers headers = exchange.getResponseHeaders();
        headers.add("Content-Type", contentType);
        if (statusCode != 204) {
            // For status other than 204, we have content
            exchange.sendResponseHeaders(statusCode, response.getBytes("UTF-8").length);
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes("UTF-8"));
            os.close();
        } else {
            // For 204 No Content, don't send any body
            exchange.sendResponseHeaders(statusCode, -1);
            OutputStream os = exchange.getResponseBody();
            os.close();
        }
    }
    
    private void sendJsonErrorWithCode(HttpExchange exchange, int statusCode, String errorMessage) throws IOException {
        String errorJson = "{\"error\": \"" + escapeJson(errorMessage) + "\"}";
        sendResponse(exchange, statusCode, errorJson);
    }
    
    private String escapeJson(String input) {
        if (input == null) return null;
        return input.replace("\\", "\\\\")
                   .replace("\"", "\\\"")
                   .replace("\b", "\\b")
                   .replace("\f", "\\f")
                   .replace("\n", "\\n")
                   .replace("\r", "\\r")
                   .replace("\t", "\\t");
    }
    
    private String extractSessionId(HttpExchange exchange) {
        Headers headers = exchange.getRequestHeaders();
        java.util.List<String> cookies = headers.get("Cookie");
        
        if (cookies == null) return null;
        
        for (String cookieHeader : cookies) {
            if (cookieHeader != null) {
                String[] cookiesArray = cookieHeader.split(";");
                for (String cookie : cookiesArray) {
                    cookie = cookie.trim();
                    if (cookie.startsWith("session_id=")) {
                        return cookie.substring("session_id=".length());
                    }
                }
            }
        }
        return null;
    }
    
    private boolean hasValidSession(String sessionId) {
        return getSession(sessionId) != null;
    }
    
    private SessionManager.Session getSession(String sessionId) {
        if (sessionId == null) return null;
        return sessionManager.getSession(sessionId);
    }
}
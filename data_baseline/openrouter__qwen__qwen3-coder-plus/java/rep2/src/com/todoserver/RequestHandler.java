package com.todoserver;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

import java.io.*;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class RequestHandler implements HttpHandler {
    private final DataStore dataStore = DataStore.getInstance();

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod();
        String path = exchange.getRequestURI().getPath();
        String response;
        int statusCode = 200; // Default to 200 

        // CORS headers
        exchange.getResponseHeaders().set("Access-Control-Allow-Origin", "*");
        exchange.getResponseHeaders().set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE");
        exchange.getResponseHeaders().set("Access-Control-Allow-Headers", "Content-Type");

        if ("OPTIONS".equals(method)) {
           exchange.sendResponseHeaders(200, -1);
           return;
        }

        try {
            switch (method) {
                case "POST":
                    if ("/register".equals(path)) {
                        response = handleRegister(exchange);
                        statusCode = 201;
                        exchange.getResponseHeaders().set("Content-Type", "application/json");
                    } else if ("/login".equals(path)) {
                        response = handleLogin(exchange);
                        statusCode = 200;
                        exchange.getResponseHeaders().set("Content-Type", "application/json");
                    } else if ("/logout".equals(path)) {
                        response = handleLogout(exchange);
                        // Need to check auth, return 401 if not authenticated
                        statusCode = isAuthenticated(exchange) ? 200 : 401;
                        if(statusCode == 401) response = "{\"error\": \"Authentication required\"}";
                        else exchange.getResponseHeaders().set("Content-Type", "application/json");
                    } else if ("/todos".equals(path)) {
                        // Need to check auth before creating todo
                        if(isAuthenticated(exchange)) {
                            response = handleCreateTodo(exchange);
                            statusCode = 201;
                            exchange.getResponseHeaders().set("Content-Type", "application/json");
                        } else {
                            statusCode = 401;
                            response = "{\"error\": \"Authentication required\"}";
                        }
                    } else {
                        response = "{\"error\": \"Endpoint not found\"}";
                        statusCode = 404;
                        exchange.getResponseHeaders().set("Content-Type", "application/json");
                    }
                    break;
                case "PUT":
                    if ("/password".equals(path)) {
                        if(isAuthenticated(exchange)) {
                           response = handleUpdatePassword(exchange);
                           // handleUpdatePassword already checks auth but we check here early
                           exchange.getResponseHeaders().set("Content-Type", "application/json");
                        } else {
                            statusCode = 401;
                            response = "{\"error\": \"Authentication required\"}";
                        }
                    } else if (path.startsWith("/todos/")) {
                        if(isAuthenticated(exchange)) {
                           String idParam = path.substring("/todos/".length());
                           response = handleUpdateTodo(exchange, idParam);
                           // handleUpdateTodo already checks auth but response code needs to be correct
                           if(response.contains("\"error\"")) {
                               statusCode = getStatusForErrorResponse(response);
                           } 
                           exchange.getResponseHeaders().set("Content-Type", "application/json");
                        } else {
                            statusCode = 401;
                            response = "{\"error\": \"Authentication required\"}";
                        }
                    } else {
                        response = "{\"error\": \"Endpoint not found\"}";
                        statusCode = 404;
                        exchange.getResponseHeaders().set("Content-Type", "application/json");
                    }
                    break;
                case "GET":
                    if ("/me".equals(path)) {
                        if(isAuthenticated(exchange)) {
                            response = handleGetMe(exchange);
                            exchange.getResponseHeaders().set("Content-Type", "application/json");
                        } else {
                            statusCode = 401;
                            response = "{\"error\": \"Authentication required\"}";
                        }
                    } else if ("/todos".equals(path)) {
                        if(isAuthenticated(exchange)) {
                            response = handleGetTodos(exchange);
                            exchange.getResponseHeaders().set("Content-Type", "application/json");
                        } else {
                            statusCode = 401;
                            response = "{\"error\": \"Authentication required\"}";
                        }
                    } else if (path.startsWith("/todos/")) {
                        if(isAuthenticated(exchange)) {
                           String idParam = path.substring("/todos/".length());
                           response = handleGetTodoById(exchange, idParam);
                           if(response.contains("\"error\"")) {
                               statusCode = getStatusForErrorResponse(response);
                           }
                           exchange.getResponseHeaders().set("Content-Type", "application/json");
                        } else {
                            statusCode = 401;
                            response = "{\"error\": \"Authentication required\"}";
                        }
                    } else {
                        response = "{\"error\": \"Endpoint not found\"}";
                        statusCode = 404;
                        exchange.getResponseHeaders().set("Content-Type", "application/json");
                    }
                    break;
                case "DELETE":
                    if (path.startsWith("/todos/")) {
                        if(isAuthenticated(exchange)) {
                            String idParam = path.substring("/todos/".length());
                            response = handleDeleteTodo(exchange, idParam);
                             if(response.contains("\"error\"")) {
                                 statusCode = getStatusForErrorResponse(response);
                             } else {
                                statusCode = 204; // 204 No Content for DELETE success
                                response = ""; // Don't send response body for DELETE
                             }
                        } else {
                            statusCode = 401;
                            response = "{\"error\": \"Authentication required\"}";
                        }
                    } else {
                        response = "{\"error\": \"Endpoint not found\"}";
                        statusCode = 404;
                        exchange.getResponseHeaders().set("Content-Type", "application/json");
                    }
                    break;
                default:
                    response = "{\"error\": \"Method not allowed\"}";
                    statusCode = 405;
                    exchange.getResponseHeaders().set("Content-Type", "application/json");
            }

            // Send response
            if (statusCode == 204) {  // Only for DELETE success
                exchange.sendResponseHeaders(204, -1);
            } else {
                byte[] responseBytes = response.getBytes("UTF-8");
                exchange.sendResponseHeaders(statusCode, responseBytes.length);
                OutputStream os = exchange.getResponseBody();
                os.write(responseBytes);
                os.close();
            }
        } catch (Exception e) {
            e.printStackTrace();
            // Return error response in case of exception
            String errorResponse = "{\"error\": \"Internal server error\"}";
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] responseBytes = errorResponse.getBytes("UTF-8");
            exchange.sendResponseHeaders(500, responseBytes.length);
            OutputStream os = exchange.getResponseBody();
            os.write(responseBytes);
            os.close();
        }
    }

    // Utility to determine appropriate status from error response
    private int getStatusForErrorResponse(String response) {
        if(response.contains("not found") || response.contains("does not exist")) {
            return 404;
        } else if(response.contains("Authentication required") || 
                 response.contains("Invalid credentials") || 
                 response.contains("unauthorized")) {
            return 401;
        } else if(response.contains("invalid") || 
                 response.contains("required") || 
                 response.contains("bad request")) {
            return 400;
        } else if(response.contains("already exists") || 
                 response.contains("conflict")) {
            return 409;
        } else {
            return 400; // Default error
        }
    }

    private boolean isAuthenticated(HttpExchange exchange) throws IOException {
        String sessionId = getSessionIdFromCookie(exchange);
        return sessionId != null && dataStore.validateSession(sessionId);
    }
    
    private String handleRegister(HttpExchange exchange) throws IOException {
        String requestBody = getRequestBody(exchange);
        Map<String, Object> json = parseJson(requestBody);

        String username = (String) json.get("username");
        String password = (String) json.get("password");

        // Validate username
        if (username == null || username.trim().isEmpty() || username.length() < 3 || username.length() > 50 || 
            !username.matches("^[a-zA-Z0-9_]+$")) {
            return "{\"error\": \"Invalid username\"}";
        }

        // Validate password length
        if (password == null || password.length() < 8) {
            return "{\"error\": \"Password too short\"}";
        }

        // Check if username already exists
        if (dataStore.usernameExists(username)) {
            return "{\"error\": \"Username already exists\"}";
        }

        // Create user
        User user = dataStore.createUser(username, password);
        return String.format("{\"id\": %d, \"username\": \"%s\"}", user.getId(), escapeJson(user.getUsername()));
    }

    private String handleLogin(HttpExchange exchange) throws IOException {
        String requestBody = getRequestBody(exchange);
        Map<String, Object> json = parseJson(requestBody);

        String username = (String) json.get("username");
        String password = (String) json.get("password");

        User user = dataStore.getUserByUsername(username);
        if (user == null || !PasswordUtil.checkPassword(password, user.getPasswordHash())) {
            return "{\"error\": \"Invalid credentials\"}";
        }

        // Generate a new session ID and store it
        String sessionId = dataStore.createSession(user.getId());

        // Add session cookie to response
        exchange.getResponseHeaders().add("Set-Cookie", String.format("session_id=%s; Path=/; HttpOnly", sessionId));

        return String.format("{\"id\": %d, \"username\": \"%s\"}", user.getId(), escapeJson(user.getUsername()));
    }

    private String handleLogout(HttpExchange exchange) throws IOException {
        String sessionId = getSessionIdFromCookie(exchange);
        if (sessionId == null || !dataStore.validateSession(sessionId)) {
            return "{\"error\": \"Authentication required\"}";
        }

        dataStore.invalidateSession(sessionId);
        return "{}";
    }

    private String handleGetMe(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            return "{\"error\": \"Authentication required\"}";
        }

        User user = dataStore.getUserById(userId);
        if (user == null) {
            return "{\"error\": \"Authentication required\"}"; // User might have been deleted but session still exists
        }

        return String.format("{\"id\": %d, \"username\": \"%s\"}", user.getId(), escapeJson(user.getUsername()));
    }

    private String handleUpdatePassword(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            return "{\"error\": \"Authentication required\"}";
        }

        String requestBody = getRequestBody(exchange);
        Map<String, Object> json = parseJson(requestBody);

        String oldPassword = (String) json.get("old_password");
        String newPassword = (String) json.get("new_password");

        // Validate new password length
        if (newPassword == null || newPassword.length() < 8) {
            return "{\"error\": \"Password too short\"}";
        }

        if (!dataStore.changeUserPassword(userId, oldPassword, newPassword)) {
            return "{\"error\": \"Invalid credentials\"}";
        }

        return "{}";
    }

    private String handleGetTodos(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            return "{\"error\": \"Authentication required\"}";
        }

        List<Todo> todos = dataStore.getTodosByUserId(userId);
        StringBuilder response = new StringBuilder("[");
        
        for (int i = 0; i < todos.size(); i++) {
            Todo todo = todos.get(i);
            if (i > 0) response.append(",");
            
            response.append(String.format(
                "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %b, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                todo.getId(),
                escapeJson(todo.getTitle()),
                escapeJson(todo.getDescription()),
                todo.isCompleted(),
                todo.getCreatedAt(),
                todo.getUpdatedAt()
            ));
        }
        
        response.append("]");
        return response.toString();
    }

    private String handleCreateTodo(HttpExchange exchange) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            return "{\"error\": \"Authentication required\"}";
        }

        String requestBody = getRequestBody(exchange);
        Map<String, Object> json = parseJson(requestBody);

        String title = (String) json.get("title");
        String description = (String) json.get("description");

        // Validate title
        if (title == null || title.trim().isEmpty()) {
            return "{\"error\": \"Title is required\"}";
        }

        // Handle when description is null
        if (description == null) {
            description = "";
        }

        Todo todo = dataStore.createTodo(userId, title, description);

        return String.format(
            "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %b, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
            todo.getId(),
            escapeJson(todo.getTitle()),
            escapeJson(todo.getDescription()),
            todo.isCompleted(),
            todo.getCreatedAt(),
            todo.getUpdatedAt()
        );
    }

    private String handleGetTodoById(HttpExchange exchange, String idParam) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            return "{\"error\": \"Authentication required\"}";
        }

        int todoId;
        try {
            todoId = Integer.parseInt(idParam);
        } catch (NumberFormatException e) {
            return "{\"error\": \"Todo not found\"}";
        }

        Todo todo = dataStore.getTodoById(todoId);
        if (todo == null || !dataStore.isTodoBelongToUser(todoId, userId)) {
            return "{\"error\": \"Todo not found\"}";
        }

        return String.format(
            "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %b, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
            todo.getId(),
            escapeJson(todo.getTitle()),
            escapeJson(todo.getDescription()),
            todo.isCompleted(),
            todo.getCreatedAt(),
            todo.getUpdatedAt()
        );
    }

    private String handleUpdateTodo(HttpExchange exchange, String idParam) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            return "{\"error\": \"Authentication required\"}";
        }

        int todoId;
        try {
            todoId = Integer.parseInt(idParam);
        } catch (NumberFormatException e) {
            return "{\"error\": \"Todo not found\"}";
        }

        // Verify that the todo exists and belongs to the user
        if (!dataStore.isTodoBelongToUser(todoId, userId)) {
            return "{\"error\": \"Todo not found\"}";
        }

        String requestBody = getRequestBody(exchange);
        Map<String, Object> json = parseJson(requestBody);

        String title = (String) json.get("title");
        String description = (String) json.get("description");
        Boolean completed = (Boolean) json.get("completed");

        // Validate title if provided
        if (title != null && title.trim().isEmpty()) {
            return "{\"error\": \"Title is required\"}";
        }

        boolean success = dataStore.updateTodo(todoId, title, description, completed);
        if (!success) {
            return "{\"error\": \"Todo not found\"}";  // In case of update failure, assume invalid ID
        }

        // Get the updated todo to return
        Todo updatedTodo = dataStore.getTodoById(todoId);
        return String.format(
            "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %b, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
            updatedTodo.getId(),
            escapeJson(updatedTodo.getTitle()),
            escapeJson(updatedTodo.getDescription()),
            updatedTodo.isCompleted(),
            updatedTodo.getCreatedAt(),
            updatedTodo.getUpdatedAt()
        );
    }

    private String handleDeleteTodo(HttpExchange exchange, String idParam) throws IOException {
        Integer userId = authenticate(exchange);
        if (userId == null) {
            return "{\"error\": \"Authentication required\"}";
        }

        int todoId;
        try {
            todoId = Integer.parseInt(idParam);
        } catch (NumberFormatException e) {
            return "{\"error\": \"Todo not found\"}";
        }

        // Verify that the todo exists and belongs to the user
        if (!dataStore.isTodoBelongToUser(todoId, userId)) {
            return "{\"error\": \"Todo not found\"}";
        }

        boolean success = dataStore.deleteTodo(todoId);
        if (!success) {
            return "{\"error\": \"Todo not found\"}";
        }

        // For deletion, return empty response
        return "";
    }

    // Helper methods
    private String getRequestBody(HttpExchange exchange) throws IOException {
        InputStream inputStream = exchange.getRequestBody();
        StringBuilder stringBuilder = new StringBuilder();

        String line;
        try (BufferedReader bufferedReader = new BufferedReader(new InputStreamReader(inputStream))) {
            while ((line = bufferedReader.readLine()) != null) {
                stringBuilder.append(line);
            }
        }

        return stringBuilder.toString();
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> parseJson(String jsonString) {
        Map<String, Object> result = new HashMap<>();
        
        if (jsonString == null || jsonString.trim().isEmpty()) {
            return result;
        }
        
        // Clean up: keep whitespace inside the strings only
        jsonString = jsonString.trim();
        
        // Remove the outer brace characters and process the content
        if (jsonString.startsWith("{") && jsonString.endsWith("}")) {
            // Remove the outer braces
            jsonString = jsonString.substring(1, jsonString.length() - 1).trim();
            
            // Break down key-value pairs preserving values in quotes
            int pos = 0;
            while (pos < jsonString.length()) {
                // Skip leading whitespace
                while (pos < jsonString.length() && Character.isWhitespace(jsonString.charAt(pos))) {
                    pos++;
                }
                
                if (pos >= jsonString.length()) break;
                
                // Expect opening quote for the key
                if (jsonString.charAt(pos) != '"') {
                    pos++;
                    continue; // Skip invalid parts
                }
                
                // Find end of key
                pos++; // Move past the opening quote
                int keyStart = pos;
                while (pos < jsonString.length() && jsonString.charAt(pos) != '"') {
                    if (jsonString.charAt(pos) == '\\' && pos + 1 < jsonString.length()) {
                        pos += 2; // Skip escaped characters
                    } else {
                        pos++;
                    }
                }
                String key = jsonString.substring(keyStart, pos);
                pos++; // Move past closing quote
                
                // Skip whitespace to find colon
                while (pos < jsonString.length() && Character.isWhitespace(jsonString.charAt(pos))) {
                    pos++;
                }
                
                if (pos >= jsonString.length() || jsonString.charAt(pos) != ':') {
                    break; // Malformed JSON
                }
                pos++; // Move past colon
                
                // Skip whitespace before value
                while (pos < jsonString.length() && Character.isWhitespace(jsonString.charAt(pos))) {
                    pos++;
                }
                
                // Parse the value now
                String value = parseValue(jsonString, pos);
                Object convertedValue = convertValue(value);
                result.put(key, convertedValue);
                
                // Skip to after the value we processed
                pos = updatePosAfterValue(jsonString, pos, value, convertedValue);
                
                // Look for comma and skip whitespace
                boolean foundComma = false;
                while (pos < jsonString.length()) {
                    if (jsonString.charAt(pos) == ',') {
                        pos++;
                        foundComma = true;
                        break;
                    } else if (!Character.isWhitespace(jsonString.charAt(pos))) {
                        break;
                    }
                    pos++;
                }
                
                if (!foundComma) break;
            }
        }
        
        return result;
    }

    // Helper to find where we ended after reading a value
    private String parseValue(String s, int startPos) {
        // Check first character to see if it's a string, number, boolean, or object/array
        while (startPos < s.length() && Character.isWhitespace(s.charAt(startPos))) {
            startPos++;
        }
        
        if (startPos >= s.length()) return "";
        
        char firstChar = s.charAt(startPos);
        
        if (firstChar == '"') {
            // Handle string value
            int endQuote = startPos + 1;
            while (endQuote < s.length()) {
                if (s.charAt(endQuote) == '"') {
                    char prev = (endQuote > 0) ? s.charAt(endQuote - 1) : '\0';
                    boolean escaped = (prev == '\\' && !(endQuote > 1 && s.charAt(endQuote - 2) == '\\'));
                    if (!escaped) break;
                }
                endQuote++;
            }
            // Include the closing quote so caller knows this was a string value
            return s.substring(startPos, Math.min(endQuote + 1, s.length()));
        } else if (Character.isDigit(firstChar) || firstChar == '-') {
            // Handle numeric value
            int numEnd = startPos;
            while (numEnd < s.length() && (
                Character.isDigit(s.charAt(numEnd)) || 
                s.charAt(numEnd) == '.' || 
                s.charAt(numEnd) == '-' || 
                s.charAt(numEnd) == '+' ||
                s.charAt(numEnd) == 'e' ||
                s.charAt(numEnd) == 'E')) {
                numEnd++;
            }
            return s.substring(startPos, numEnd);
        } else if (s.startsWith("true", startPos)) {
            return "true";
        } else if (s.startsWith("false", startPos)) {
            return "false";
        } else if (s.startsWith("null", startPos)) {
            return "null";
        } else if (s.charAt(startPos) == '{' || s.charAt(startPos) == '[') {
            // This is complex - we'd need to match nested brackets/braces properly
            // For now, we'll just include what's in these outer structures
            char openChar = s.charAt(startPos);
            char closeChar = (openChar == '{') ? '}' : ']';
            int depth = 1;
            int end = startPos + 1;
            while (end < s.length() && depth > 0) {
                char c = s.charAt(end);
                if (c == openChar) {
                    depth++;
                } else if (c == closeChar) {
                    depth--;
                } else if (c == '"') {
                    // Handle quoted strings to avoid counting braces inside strings
                    end++;
                    while (end < s.length()) {
                        if (s.charAt(end) == '"' && (end == 0 || s.charAt(end - 1) != '\\')) {
                            break;
                        }
                        end++;
                    }
                }
                if (depth > 0) end++;
            }
            if (depth == 0) {
                return s.substring(startPos, end + 1);
            } else {
                // Malformed JSON
                return s.substring(startPos);
            }
        } else {
            // Just grab until we hit a separator
            int valEnd = startPos;
            while (valEnd < s.length() && 
                   s.charAt(valEnd) != ',' && 
                   s.charAt(valEnd) != '}' && 
                   s.charAt(valEnd) != ']') {
                valEnd++;
            }
            return s.substring(startPos, valEnd);
        }
    }

    // Helper to advance position after processing a value
    private int updatePosAfterValue(String s, int pos, String value, Object convertedValue) {
        int valueEnd = pos;
        String valueStr = value;
        
        // If we stored the full value string, advance to its end
        valueEnd += valueStr.length();
        
        // Adjust slightly differently based on value type
        if (convertedValue instanceof String && valueStr.startsWith("\"") && valueStr.endsWith("\"")) {
            valueEnd = pos + valueStr.length();
        } else {
            valueEnd = pos + valueStr.length();
        }
        
        // Make sure we're positioned right
        return valueEnd;
    }

    // Convert string value to appropriate type based on content
    private Object convertValue(String valueStr) {
        if (valueStr == null || valueStr.trim().isEmpty()) {
            return valueStr;
        }
        
        valueStr = valueStr.trim();
        
        if (valueStr.startsWith("\"") && valueStr.endsWith("\"")) {
            // Extract string value inside quotes
            String extracted = valueStr.substring(1, valueStr.length() - 1);
            return unescapeJson(extracted);
        } else if (valueStr.equals("true")) {
            return true;
        } else if (valueStr.equals("false")) {
            return false;
        } else if (valueStr.equals("null")) {
            return null;
        } else {
            try {
                // Try integer first
                if (valueStr.matches("-?\\d+")) {
                    return Integer.parseInt(valueStr);
                } 
                // Then float if it has decimal point
                else /* if (valueStr.matches("-?\\d*\\.\\d+")) */ {
                    return Double.parseDouble(valueStr);
                }
            } catch (NumberFormatException e) {
                return valueStr; // Fall back to string
            }
        }
    }


    private String escapeJson(String str) {
        if (str == null) return null;
        return str.replace("\\", "\\\\")
                  .replace("\"", "\\\"")
                  .replace("\n", "\\n")
                  .replace("\r", "\\r")
                  .replace("\t", "\\t");
    }

    private String unescapeJson(String str) {
        if (str == null) return null;
        return str.replace("\\\"", "\"")
                  .replace("\\\\", "\\")
                  .replace("\\n", "\n")
                  .replace("\\r", "\r")
                  .replace("\\t", "\t");
    }

    private Integer authenticate(HttpExchange exchange) throws IOException {
        String sessionId = getSessionIdFromCookie(exchange);

        if (sessionId == null || !dataStore.validateSession(sessionId)) {
            return null;
        }

        return dataStore.getUserIdBySessionId(sessionId);
    }

    private String getSessionIdFromCookie(HttpExchange exchange) throws IOException {
        List<String> cookies = exchange.getRequestHeaders().get("Cookie");
        if (cookies == null || cookies.isEmpty()) {
            return null;
        }

        String cookieHeader = cookies.get(0);
        String[] cookiePairs = cookieHeader.split(";");

        for (String cookiePair : cookiePairs) {
            cookiePair = cookiePair.trim();
            if (cookiePair.startsWith("session_id=")) {
                return cookiePair.substring("session_id=".length());
            }
        }

        return null;
    }
}
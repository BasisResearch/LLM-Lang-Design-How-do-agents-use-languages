package com.todoserver;

import java.io.IOException;
import java.io.OutputStream;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

public class TodosHandler implements HttpHandler {
    
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        String pathInfo = exchange.getRequestURI().getPath();
        String method = exchange.getRequestMethod();
        
        // Extract todo ID if present in path
        Pattern pattern = Pattern.compile("/todos/(\\d+)");
        Matcher matcher = pattern.matcher(pathInfo);
        Integer todoId = null;
        
        if (matcher.find()) {
            try {
                todoId = Integer.parseInt(matcher.group(1));
            } catch (NumberFormatException e) {
                String errorJson = "{\"error\": \"Invalid todo ID\"}";
                sendErrorResponse(exchange, 400, errorJson);
                return;
            }
        }
        
        // Require authentication for all endpoints except when noted otherwise
        boolean requiresAuth = !("/todos".equals(pathInfo) && "GET".equals(method));
        String sessionId = null;
        Integer userId = null;
        
        if (requiresAuth) {
            // Extract session cookie
            List<String> cookieHeaders = exchange.getRequestHeaders().get("Cookie");
            if (cookieHeaders != null) {
                for (String cookieHeader : cookieHeaders) {
                    if (cookieHeader != null) {
                        String[] cookiePairs = cookieHeader.split(";");
                        for (String cookiePair : cookiePairs) {
                            cookiePair = cookiePair.trim();
                            if (cookiePair.startsWith("session_id=")) {
                                sessionId = cookiePair.substring("session_id=".length());
                                break;
                            }
                        }
                        if (sessionId != null) break;
                    }
                }
            }
            
            if (sessionId == null || !Main.sessionManager.isValidSession(sessionId)) {
                String errorJson = "{\"error\": \"Authentication required\"}";
                sendErrorResponse(exchange, 401, errorJson);
                return;
            }
            
            userId = Main.sessionManager.getUserIdFromSession(sessionId);
            if (userId == null) {
                String errorJson = "{\"error\": \"Authentication required\"}";
                sendErrorResponse(exchange, 401, errorJson);
                return;
            }
        }
        
        switch (method) {
            case "GET":
                if (todoId != null) {
                    handleGetTodo(exchange, userId, todoId);
                } else {
                    handleGetTodos(exchange, userId);
                }
                break;
            case "POST":
                if (todoId == null) {
                    handleCreateTodo(exchange, userId);
                } else {
                    // No POST with ID - send 405
                    exchange.sendResponseHeaders(405, -1);
                }
                break;
            case "PUT":
                if (todoId != null) {
                    handleUpdateTodo(exchange, userId, todoId);
                } else {
                    exchange.sendResponseHeaders(405, -1);
                }
                break;
            case "DELETE":
                if (todoId != null) {
                    handleDeleteTodo(exchange, userId, todoId);
                } else {
                    exchange.sendResponseHeaders(405, -1);
                }
                break;
            default:
                exchange.sendResponseHeaders(405, -1);
                break;
        }
    }
    
    private void handleGetTodos(HttpExchange exchange, Integer userId) throws IOException {
        List<Todo> todos = Main.storage.getUserTodos(userId);
        Gson gson = new Gson();
        String response = gson.toJson(todos);
        
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, response.getBytes().length);
        OutputStream os = exchange.getResponseBody();
        os.write(response.getBytes());
        os.close();
    }
    
    private void handleCreateTodo(HttpExchange exchange, Integer userId) throws IOException {
        String requestBody = new String(exchange.getRequestBody().readAllBytes());
        Gson gson = new Gson();
        
        try {
            JsonObject json = JsonParser.parseString(requestBody).getAsJsonObject();
            
            if (!json.has("title")) {
                String errorJson = "{\"error\": \"Title is required\"}";
                sendErrorResponse(exchange, 400, errorJson);
                return;
            }
            
            String title = json.get("title").getAsString();
            
            if (title == null || title.trim().isEmpty()) {
                String errorJson = "{\"error\": \"Title is required\"}";
                sendErrorResponse(exchange, 400, errorJson);
                return;
            }
            
            String description = "";
            if (json.has("description")) {
                description = json.get("description").getAsString();
            }
            
            Todo createdTodo = Main.storage.createTodo(userId, title, description);
            String response = gson.toJson(createdTodo);
            
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(201, response.getBytes().length);
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
            
        } catch (Exception e) {
            String errorJson = "{\"error\": \"Invalid JSON in request\"}";
            sendErrorResponse(exchange, 400, errorJson);
        }
    }
    
    private void handleGetTodo(HttpExchange exchange, Integer userId, Integer todoId) throws IOException {
        Todo todo = Main.storage.getTodoById(todoId);
        
        if (todo == null || !Main.storage.isTodoOwnedByUser(todoId, userId)) {
            String errorJson = "{\"error\": \"Todo not found\"}";
            sendErrorResponse(exchange, 404, errorJson);
            return;
        }
        
        Gson gson = new Gson();
        String response = gson.toJson(todo);
        
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, response.getBytes().length);
        OutputStream os = exchange.getResponseBody();
        os.write(response.getBytes());
        os.close();
    }
    
    private void handleUpdateTodo(HttpExchange exchange, Integer userId, Integer todoId) throws IOException {
        Todo existingTodo = Main.storage.getTodoById(todoId);
        
        if (existingTodo == null || !Main.storage.isTodoOwnedByUser(todoId, userId)) {
            String errorJson = "{\"error\": \"Todo not found\"}";
            sendErrorResponse(exchange, 404, errorJson);
            return;
        }
        
        String requestBody = new String(exchange.getRequestBody().readAllBytes());
        Gson gson = new Gson();
        
        try {
            JsonObject json = JsonParser.parseString(requestBody).getAsJsonObject();
            
            String title = null;
            String description = null;
            Boolean completed = null;
            
            if (json.has("title")) {
                title = json.get("title").getAsString();
                if (title != null && title.trim().isEmpty()) {
                    String errorJson = "{\"error\": \"Title is required\"}";
                    sendErrorResponse(exchange, 400, errorJson);
                    return;
                }
            }
            
            if (json.has("description")) {
                description = json.get("description").getAsString();
            }
            
            if (json.has("completed")) {
                completed = json.get("completed").getAsBoolean();
            }
            
            Todo updatedTodo = Main.storage.updateTodo(todoId, title, description, completed);
            
            if (updatedTodo == null) {
                String errorJson = "{\"error\": \"Todo not found\"}";
                sendErrorResponse(exchange, 404, errorJson);
                return;
            }
            
            String response = gson.toJson(updatedTodo);
            
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.getBytes().length);
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
            
        } catch (Exception e) {
            String errorJson = "{\"error\": \"Invalid JSON in request\"}";
            sendErrorResponse(exchange, 400, errorJson);
        }
    }
    
    private void handleDeleteTodo(HttpExchange exchange, Integer userId, Integer todoId) throws IOException {
        Todo todo = Main.storage.getTodoById(todoId);
        
        if (todo == null || !Main.storage.isTodoOwnedByUser(todoId, userId)) {
            String errorJson = "{\"error\": \"Todo not found\"}";
            sendErrorResponse(exchange, 404, errorJson);
            return;
        }
        
        boolean deleted = Main.storage.deleteTodo(todoId);
        
        if (deleted) {
            // 204 No Content
            exchange.sendResponseHeaders(204, -1);
        } else {
            String errorJson = "{\"error\": \"Todo not found\"}";
            sendErrorResponse(exchange, 404, errorJson);
        }
    }
    
    private void sendErrorResponse(HttpExchange exchange, int statusCode, String errorJson) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(statusCode, errorJson.getBytes().length);
        OutputStream os = exchange.getResponseBody();
        os.write(errorJson.getBytes());
        os.close();
    }
}
package com.todoserver;

import java.io.IOException;
import java.io.OutputStream;
import java.util.List;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

public class PasswordHandler implements HttpHandler {
    
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!"PUT".equals(exchange.getRequestMethod())) {
            exchange.sendResponseHeaders(405, -1);
            return;
        }
        
        // Extract session cookie
        List<String> cookieHeaders = exchange.getRequestHeaders().get("Cookie");
        String sessionId = null;
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
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(401, errorJson.getBytes().length);
            OutputStream os = exchange.getResponseBody();
            os.write(errorJson.getBytes());
            os.close();
            return;
        }
        
        // Get user ID from session
        Integer userId = Main.sessionManager.getUserIdFromSession(sessionId);
        if (userId == null) {
            String errorJson = "{\"error\": \"Authentication required\"}";
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(401, errorJson.getBytes().length);
            OutputStream os = exchange.getResponseBody();
            os.write(errorJson.getBytes());
            os.close();
            return;
        }
        
        String requestBody = new String(exchange.getRequestBody().readAllBytes());
        Gson gson = new Gson();
        
        try {
            JsonObject json = JsonParser.parseString(requestBody).getAsJsonObject();
            
            if (!json.has("old_password") || !json.has("new_password")) {
                String errorJson = "{\"error\": \"Missing old_password or new_password\"}";
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(400, errorJson.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(errorJson.getBytes());
                os.close();
                return;
            }
            
            String oldPassword = json.get("old_password").getAsString();
            String newPassword = json.get("new_password").getAsString();
            
            // Get the user to check the old password
            User user = Main.storage.getUserById(userId);
            if (user == null || !PasswordUtils.verifyPassword(oldPassword, user.getPassword())) {
                String errorJson = "{\"error\": \"Invalid credentials\"}";
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(401, errorJson.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(errorJson.getBytes());
                os.close();
                return;
            }
            
            // Validate new password length
            if (newPassword.length() < 8) {
                String errorJson = "{\"error\": \"Password too short\"}";
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(400, errorJson.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(errorJson.getBytes());
                os.close();
                return;
            }
            
            // Hash and update the new password
            String newHash = PasswordUtils.hashPassword(newPassword);
            boolean success = Main.storage.updatePassword(userId, newHash);
            
            if (success) {
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(200, 2);  // "{}".length() = 2  
                OutputStream os = exchange.getResponseBody();
                os.write(new byte[]{'{', '}'});
                os.close();
            } else {
                String errorJson = "{\"error\": \"Failed to update password\"}";
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(500, errorJson.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(errorJson.getBytes());
                os.close();
            }
            
        } catch (Exception e) {
            String errorJson = "{\"error\": \"Invalid JSON in request\"}";
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(400, errorJson.getBytes().length);
            OutputStream os = exchange.getResponseBody();
            os.write(errorJson.getBytes());
            os.close();
        }
    }
}
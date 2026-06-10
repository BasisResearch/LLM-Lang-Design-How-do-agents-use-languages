package com.todoserver;

import java.io.IOException;
import java.io.OutputStream;
import java.util.Map;
import java.util.regex.Pattern;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

public class RegisterHandler implements HttpHandler {
    
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        // Only accept POST
        if (!"POST".equals(exchange.getRequestMethod())) {
            exchange.sendResponseHeaders(405, -1);
            return;
        }
        
        // Read request body
        String requestBody = new String(exchange.getRequestBody().readAllBytes());
        Gson gson = new Gson();
        
        try {
            JsonObject json = JsonParser.parseString(requestBody).getAsJsonObject();
            
            if (!json.has("username") || !json.has("password")) {
                String errorJson = "{\"error\": \"Missing username or password\"}";
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(400, errorJson.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(errorJson.getBytes());
                os.close();
                return;
            }
            
            String username = json.get("username").getAsString();
            String password = json.get("password").getAsString();
            
            // Validate username
            if (username == null || username.length() < 3 || username.length() > 50 || !isValidUsername(username)) {
                String errorJson = "{\"error\": \"Invalid username\"}";
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(400, errorJson.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(errorJson.getBytes());
                os.close();
                return;
            }
            
            // Validate password length
            if (password.length() < 8) {
                String errorJson = "{\"error\": \"Password too short\"}";
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(400, errorJson.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(errorJson.getBytes());
                os.close();
                return;
            }
            
            // Check if user already exists
            if (Main.storage.getUserByUsername(username) != null) {
                String errorJson = "{\"error\": \"Username already exists\"}";
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(409, errorJson.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(errorJson.getBytes());
                os.close();
                return;
            }
            
            // Hash password and create user
            String passwordHash = PasswordUtils.hashPassword(password);
            boolean success = Main.storage.createUser(username, passwordHash);
            
            if (success) {
                User user = Main.storage.getUserByUsername(username);
                // Create a response object without password
                JsonObject responseObj = new JsonObject();
                responseObj.addProperty("id", user.getId());
                responseObj.addProperty("username", user.getUsername());
                String response = responseObj.toString();
                
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(201, response.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(response.getBytes());
                os.close();
            } else {
                String errorJson = "{\"error\": \"Registration failed\"}";
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
    
    private boolean isValidUsername(String username) {
        return Pattern.matches("^[a-zA-Z0-9_]+$", username);
    }
}
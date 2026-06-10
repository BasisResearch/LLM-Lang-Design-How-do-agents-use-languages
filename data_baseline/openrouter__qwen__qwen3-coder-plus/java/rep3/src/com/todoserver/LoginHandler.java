package com.todoserver;

import java.io.IOException;
import java.io.OutputStream;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

public class LoginHandler implements HttpHandler {
    
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) {
            exchange.sendResponseHeaders(405, -1);
            return;
        }
        
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
            
            User authenticatedUser = Main.storage.authenticateUser(username, password);
            
            if (authenticatedUser == null) {
                String errorJson = "{\"error\": \"Invalid credentials\"}";
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(401, errorJson.getBytes().length);
                OutputStream os = exchange.getResponseBody();
                os.write(errorJson.getBytes());
                os.close();
                return;
            }
            
            // Create a response object without password
            JsonObject responseObj = new JsonObject();
            responseObj.addProperty("id", authenticatedUser.getId());
            responseObj.addProperty("username", authenticatedUser.getUsername());
            String response = responseObj.toString();
            
            // Create session
            String sessionId = Main.sessionManager.createSession(authenticatedUser.getId());
            
            // Respond with user info and set cookie
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.getResponseHeaders().set("Set-Cookie", 
                                            String.format("session_id=%s; Path=/; HttpOnly", sessionId));
            exchange.sendResponseHeaders(200, response.getBytes().length);
            OutputStream os = exchange.getResponseBody();
            os.write(response.getBytes());
            os.close();
            
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
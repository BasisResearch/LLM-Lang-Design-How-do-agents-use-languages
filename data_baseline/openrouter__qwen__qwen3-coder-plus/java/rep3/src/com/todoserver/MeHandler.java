package com.todoserver;

import java.io.IOException;
import java.io.OutputStream;
import java.util.List;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

public class MeHandler implements HttpHandler {
    
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!"GET".equals(exchange.getRequestMethod())) {
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
        
        // Get user from storage
        User user = Main.storage.getUserById(userId);
        if (user == null) {
            String errorJson = "{\"error\": \"Authentication required\"}";
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(401, errorJson.getBytes().length);
            OutputStream os = exchange.getResponseBody();
            os.write(errorJson.getBytes());
            os.close();
            return;
        }
        
        // Create a response object without password
        JsonObject responseObj = new JsonObject();
        responseObj.addProperty("id", user.getId());
        responseObj.addProperty("username", user.getUsername());
        String response = responseObj.toString();
        
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, response.getBytes().length);
        OutputStream os = exchange.getResponseBody();
        os.write(response.getBytes());
        os.close();
    }
}
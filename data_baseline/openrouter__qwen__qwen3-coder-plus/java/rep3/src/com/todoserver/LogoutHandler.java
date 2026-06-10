package com.todoserver;

import java.io.IOException;
import java.io.OutputStream;
import java.util.List;

import com.google.gson.Gson;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

public class LogoutHandler implements HttpHandler {
    
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) {
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
        
        // Invalidate session
        Main.sessionManager.invalidateSession(sessionId);
        
        // Send successful response  
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, 2);  // "{}".length() = 2  
        OutputStream os = exchange.getResponseBody();
        os.write(new byte[]{'{', '}'});
        os.close();
    }
}
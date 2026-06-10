package com.todoserver;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.regex.Pattern;

import com.sun.net.httpserver.HttpServer;

public class Main {
    public static void main(String[] args) throws IOException {
        // Parse command line arguments
        int port = 8080; // default
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                try {
                    port = Integer.parseInt(args[i + 1]);
                    break;
                } catch (NumberFormatException e) {
                    System.err.println("Invalid port number: " + args[i + 1]);
                    System.exit(1);
                }
            }
        }
        
        // Create HTTP server
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.setExecutor(null); // creates a default executor
        
        // Register all handlers
        SessionManager sessionManager = new SessionManager();
        Database db = new Database();
        RequestHandler handler = new RequestHandler(db, sessionManager);
        
        server.createContext("/register", handler::handleRegister);
        server.createContext("/login", handler::handleLogin);
        server.createContext("/logout", handler::handleLogout);
        server.createContext("/me", handler::handleMe);
        server.createContext("/password", handler::handlePassword);
        server.createContext("/todos", handler::handleTodos);
        
        System.out.println("Server starting on port " + port);
        server.start();
    }
}
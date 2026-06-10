package com.todoserver;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.regex.Pattern;
import java.util.concurrent.ConcurrentHashMap;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;

public class Main {
    public static InMemoryStorage storage = new InMemoryStorage();
    public static SessionManager sessionManager = new SessionManager();
    
    public static void main(String[] args) throws IOException {
        int port = 8080; // Default port
        
        // Parse command line arguments
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                try {
                    port = Integer.parseInt(args[i + 1]);
                    i++; // Skip the next argument since we just read it
                } catch (NumberFormatException e) {
                    System.err.println("Invalid port number: " + args[i + 1]);
                    System.exit(1);
                }
            }
        }
        
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/register", new RegisterHandler());
        server.createContext("/login", new LoginHandler());
        server.createContext("/logout", new LogoutHandler());
        server.createContext("/me", new MeHandler());
        server.createContext("/password", new PasswordHandler());
        server.createContext("/todos", new TodosHandler());
        
        server.setExecutor(null); // Creates a default executor
        System.out.println("Server started on port " + port);
        server.start();
    }
}
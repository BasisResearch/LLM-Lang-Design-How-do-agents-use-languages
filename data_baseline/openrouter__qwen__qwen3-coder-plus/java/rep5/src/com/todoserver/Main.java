package com.todoserver;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.regex.Pattern;

public class Main {
    public static void main(String[] args) {
        int port = 8080; // Default port
        
        // Parse command line arguments
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                try {
                    port = Integer.parseInt(args[i + 1]);
                    i++; // Skip next argument as it's used as port value
                } catch (NumberFormatException e) {
                    System.err.println("Invalid port number: " + args[i + 1]);
                    System.exit(1);
                }
            }
        }

        try {
            // Start the HTTP server
            TodoServer server = new TodoServer();
            server.start(port);
            
            System.out.println("Server started on port " + port);
            
            // Keep the server running
            Thread.currentThread().join();
        } catch (IOException e) {
            System.err.println("Failed to start server: " + e.getMessage());
            System.exit(1);
        } catch (InterruptedException e) {
            System.out.println("Server interrupted");
        }
    }
}
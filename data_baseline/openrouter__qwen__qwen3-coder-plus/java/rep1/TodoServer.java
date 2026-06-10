import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;

import java.io.IOException;
import java.net.InetSocketAddress;

public class TodoServer {
    public static void main(String[] args) throws IOException {
        int port = 8000; // default port
        
        // Parse command line arguments
        for (int i = 0; i < args.length; i += 2) {
            if (args[i].equals("--port")) {
                port = Integer.parseInt(args[i + 1]);
                break;
            }
        }
        
        // Create services (in-memory storage since no persistence is required)
        UserService userService = new UserService();
        TodoService todoService = new TodoService();
        SessionService sessionService = new SessionService();
        
        // Create HTTP server instance
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        
        // Add context and handler
        server.createContext("/", new HttpRequestHandler(userService, todoService, sessionService));
        server.setExecutor(null); // creates a default executor
        
        System.out.println("Server starting on 0.0.0.0:" + port);
        server.start();
    }
}
import java.net.InetSocketAddress;
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

public class Server {
    static final Gson gson = new Gson();
    static final DateTimeFormatter formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);
    
    static class User {
        int id;
        String username;
        String passwordHash;
        User(int id, String username, String passwordHash) {
            this.id = id;
            this.username = username;
            this.passwordHash = passwordHash;
        }
    }
    
    static class Todo {
        int id;
        int userId;
        String title;
        String description;
        boolean completed;
        String createdAt;
        String updatedAt;
        Todo(int id, int userId, String title, String description, boolean completed, String createdAt, String updatedAt) {
            this.id = id;
            this.userId = userId;
            this.title = title;
            this.description = description;
            this.completed = completed;
            this.createdAt = createdAt;
            this.updatedAt = updatedAt;
        }
    }
    
    static class UserResponse {
        int id;
        String username;
        UserResponse(User u) {
            this.id = u.id;
            this.username = u.username;
        }
    }
    
    static class TodoResponse {
        int id;
        String title;
        String description;
        boolean completed;
        String created_at;
        String updated_at;
        TodoResponse(Todo t) {
            this.id = t.id;
            this.title = t.title;
            this.description = t.description;
            this.completed = t.completed;
            this.created_at = t.createdAt;
            this.updated_at = t.updatedAt;
        }
    }

    static class ErrorResponse {
        String error;
        ErrorResponse(String error) { this.error = error; }
    }

    static final Map<Integer, User> users = new ConcurrentHashMap<>();
    static final Map<Integer, Todo> todos = new ConcurrentHashMap<>();
    static final Map<String, Integer> sessions = new ConcurrentHashMap<>();
    
    static final AtomicInteger userIdCounter = new AtomicInteger(0);
    static final AtomicInteger todoIdCounter = new AtomicInteger(0);

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--port") && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
            }
        }
        
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/", new TodoHandler());
        server.setExecutor(null);
        server.start();
        System.out.println("Server started on port " + port);
    }
    
    static String getNow() {
        return ZonedDateTime.now(ZoneOffset.UTC).format(formatter);
    }
    
    static String hashPassword(String password) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(password.getBytes(StandardCharsets.UTF_8));
            StringBuilder hexString = new StringBuilder(2 * hash.length);
            for (byte b : hash) {
                String hex = Integer.toHexString(0xff & b);
                if (hex.length() == 1) hexString.append('0');
                hexString.append(hex);
            }
            return hexString.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException(e);
        }
    }
    
    static String readBody(HttpExchange exchange) throws IOException {
        InputStream is = exchange.getRequestBody();
        return new String(is.readAllBytes(), StandardCharsets.UTF_8);
    }
    
    static void sendError(HttpExchange exchange, int code, String message) throws IOException {
        String json = gson.toJson(new ErrorResponse(message));
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(code, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }
    
    static Integer getAuthenticatedUser(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader == null) return null;
        
        String token = null;
        String[] cookies = cookieHeader.split(";");
        for (String cookie : cookies) {
            String[] parts = cookie.trim().split("=", 2);
            if (parts.length == 2 && parts[0].equals("session_id")) {
                token = parts[1];
                break;
            }
        }
        if (token == null) return null;
        return sessions.get(token);
    }
    
    static String getSessionToken(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader == null) return null;
        
        String[] cookies = cookieHeader.split(";");
        for (String cookie : cookies) {
            String[] parts = cookie.trim().split("=", 2);
            if (parts.length == 2 && parts[0].equals("session_id")) {
                return parts[1];
            }
        }
        return null;
    }

    static class TodoHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) {
            String method = exchange.getRequestMethod();
            String path = exchange.getRequestURI().getPath();
            
            try {
                if (path.equals("/register") && method.equals("POST")) {
                    handleRegister(exchange);
                } else if (path.equals("/login") && method.equals("POST")) {
                    handleLogin(exchange);
                } else if (path.equals("/logout") && method.equals("POST")) {
                    handleLogout(exchange);
                } else if (path.equals("/me") && method.equals("GET")) {
                    handleMe(exchange);
                } else if (path.equals("/password") && method.equals("PUT")) {
                    handlePassword(exchange);
                } else if (path.equals("/todos") && method.equals("GET")) {
                    handleGetTodos(exchange);
                } else if (path.equals("/todos") && method.equals("POST")) {
                    handleCreateTodo(exchange);
                } else if (path.matches("^/todos/\\d+$")) {
                    int id = Integer.parseInt(path.substring(7));
                    if (method.equals("GET")) {
                        handleGetTodo(exchange, id);
                    } else if (method.equals("PUT")) {
                        handleUpdateTodo(exchange, id);
                    } else if (method.equals("DELETE")) {
                        handleDeleteTodo(exchange, id);
                    } else {
                        sendError(exchange, 405, "Method not allowed");
                    }
                } else {
                    sendError(exchange, 404, "Not found");
                }
            } catch (Exception e) {
                e.printStackTrace();
                try {
                    sendError(exchange, 500, "Internal server error");
                } catch (IOException ioEx) {
                    ioEx.printStackTrace();
                }
            }
        }

        void handleRegister(HttpExchange exchange) throws IOException {
            String body = readBody(exchange);
            JsonObject json;
            try {
                json = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                sendError(exchange, 400, "Invalid JSON");
                return;
            }
            
            if (!json.has("username") || json.get("username").isJsonNull() || !json.has("password") || json.get("password").isJsonNull()) {
                sendError(exchange, 400, "Missing username or password");
                return;
            }
            
            String username = json.get("username").getAsString();
            String password = json.get("password").getAsString();
            
            if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
                sendError(exchange, 400, "Invalid username");
                return;
            }
            
            if (password.length() < 8) {
                sendError(exchange, 400, "Password too short");
                return;
            }
            
            for (User u : users.values()) {
                if (u.username.equals(username)) {
                    sendError(exchange, 409, "Username already exists");
                    return;
                }
            }
            
            int id = userIdCounter.incrementAndGet();
            User newUser = new User(id, username, hashPassword(password));
            users.put(id, newUser);
            
            String resp = gson.toJson(new UserResponse(newUser));
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(201, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        void handleLogin(HttpExchange exchange) throws IOException {
            String body = readBody(exchange);
            JsonObject json;
            try {
                json = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                sendError(exchange, 400, "Invalid JSON");
                return;
            }
            
            if (!json.has("username") || json.get("username").isJsonNull() || !json.has("password") || json.get("password").isJsonNull()) {
                sendError(exchange, 400, "Missing username or password");
                return;
            }
            
            String username = json.get("username").getAsString();
            String password = json.get("password").getAsString();
            String hashedPassword = hashPassword(password);
            
            User foundUser = null;
            for (User u : users.values()) {
                if (u.username.equals(username) && u.passwordHash.equals(hashedPassword)) {
                    foundUser = u;
                    break;
                }
            }
            
            if (foundUser == null) {
                sendError(exchange, 401, "Invalid credentials");
                return;
            }
            
            String token = UUID.randomUUID().toString().replace("-", "");
            sessions.put(token, foundUser.id);
            
            String resp = gson.toJson(new UserResponse(foundUser));
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.getResponseHeaders().set("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        void handleLogout(HttpExchange exchange) throws IOException {
            Integer userId = getAuthenticatedUser(exchange);
            if (userId == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            
            String token = getSessionToken(exchange);
            if (token != null) {
                sessions.remove(token);
            }
            
            String resp = "{}";
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        void handleMe(HttpExchange exchange) throws IOException {
            Integer userId = getAuthenticatedUser(exchange);
            if (userId == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            
            User u = users.get(userId);
            if (u == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            
            String resp = gson.toJson(new UserResponse(u));
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        void handlePassword(HttpExchange exchange) throws IOException {
            Integer userId = getAuthenticatedUser(exchange);
            if (userId == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            
            String body = readBody(exchange);
            JsonObject json;
            try {
                json = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                sendError(exchange, 400, "Invalid JSON");
                return;
            }
            
            if (!json.has("old_password") || json.get("old_password").isJsonNull() || !json.has("new_password") || json.get("new_password").isJsonNull()) {
                sendError(exchange, 400, "Missing old_password or new_password");
                return;
            }
            
            String oldPassword = json.get("old_password").getAsString();
            String newPassword = json.get("new_password").getAsString();
            
            if (newPassword.length() < 8) {
                sendError(exchange, 400, "Password too short");
                return;
            }
            
            User u = users.get(userId);
            if (!u.passwordHash.equals(hashPassword(oldPassword))) {
                sendError(exchange, 401, "Invalid credentials");
                return;
            }
            
            u.passwordHash = hashPassword(newPassword);
            
            String resp = "{}";
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        void handleGetTodos(HttpExchange exchange) throws IOException {
            Integer userId = getAuthenticatedUser(exchange);
            if (userId == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            
            List<Todo> userTodos = new ArrayList<>();
            for (Todo t : todos.values()) {
                if (t.userId == userId) {
                    userTodos.add(t);
                }
            }
            userTodos.sort(Comparator.comparingInt(t -> t.id));
            
            List<TodoResponse> responses = new ArrayList<>();
            for (Todo t : userTodos) {
                responses.add(new TodoResponse(t));
            }
            
            String resp = gson.toJson(responses);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        void handleCreateTodo(HttpExchange exchange) throws IOException {
            Integer userId = getAuthenticatedUser(exchange);
            if (userId == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            
            String body = readBody(exchange);
            JsonObject json;
            try {
                json = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                sendError(exchange, 400, "Invalid JSON");
                return;
            }
            
            if (!json.has("title") || json.get("title").isJsonNull() || json.get("title").getAsString().isEmpty()) {
                sendError(exchange, 400, "Title is required");
                return;
            }
            
            String title = json.get("title").getAsString();
            String description = "";
            if (json.has("description") && !json.get("description").isJsonNull()) {
                description = json.get("description").getAsString();
            }
            
            int id = todoIdCounter.incrementAndGet();
            String now = getNow();
            Todo newTodo = new Todo(id, userId, title, description, false, now, now);
            todos.put(id, newTodo);
            
            String resp = gson.toJson(new TodoResponse(newTodo));
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(201, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        void handleGetTodo(HttpExchange exchange, int id) throws IOException {
            Integer userId = getAuthenticatedUser(exchange);
            if (userId == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            
            Todo t = todos.get(id);
            if (t == null || t.userId != userId) {
                sendError(exchange, 404, "Todo not found");
                return;
            }
            
            String resp = gson.toJson(new TodoResponse(t));
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }

        void handleUpdateTodo(HttpExchange exchange, int id) throws IOException {
            Integer userId = getAuthenticatedUser(exchange);
            if (userId == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            
            synchronized (todos) {
                Todo t = todos.get(id);
                if (t == null || t.userId != userId) {
                    sendError(exchange, 404, "Todo not found");
                    return;
                }
                
                String body = readBody(exchange);
                JsonObject json;
                try {
                    json = JsonParser.parseString(body).getAsJsonObject();
                } catch (Exception e) {
                    sendError(exchange, 400, "Invalid JSON");
                    return;
                }
                
                if (json.has("title")) {
                    if (json.get("title").isJsonNull()) {
                        sendError(exchange, 400, "Title is required");
                        return;
                    }
                    String title = json.get("title").getAsString();
                    if (title.isEmpty()) {
                        sendError(exchange, 400, "Title is required");
                        return;
                    }
                    t.title = title;
                }
                
                if (json.has("description") && !json.get("description").isJsonNull()) {
                    t.description = json.get("description").getAsString();
                }
                
                if (json.has("completed") && !json.get("completed").isJsonNull()) {
                    t.completed = json.get("completed").getAsBoolean();
                }
                
                t.updatedAt = getNow();
                
                String resp = gson.toJson(new TodoResponse(t));
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
                exchange.sendResponseHeaders(200, bytes.length);
                try (OutputStream os = exchange.getResponseBody()) {
                    os.write(bytes);
                }
            }
        }

        void handleDeleteTodo(HttpExchange exchange, int id) throws IOException {
            Integer userId = getAuthenticatedUser(exchange);
            if (userId == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            
            synchronized (todos) {
                Todo t = todos.get(id);
                if (t == null || t.userId != userId) {
                    sendError(exchange, 404, "Todo not found");
                    return;
                }
                todos.remove(id);
            }
            
            exchange.sendResponseHeaders(204, 0);
            exchange.getResponseBody().close();
        }
    }
}
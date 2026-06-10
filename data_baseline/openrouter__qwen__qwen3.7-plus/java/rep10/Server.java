import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.annotations.SerializedName;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.*;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

public class Server {
    static class State {
        int nextUserId = 1;
        int nextTodoId = 1;
        Map<String, User> usersByUsername = new ConcurrentHashMap<>();
        Map<Integer, User> usersById = new ConcurrentHashMap<>();
        Map<String, User> sessions = new ConcurrentHashMap<>();
        Map<Integer, Todo> todos = new ConcurrentHashMap<>();
    }

    static class User {
        int id;
        String username;
        String password;
    }

    static class Todo {
        int id;
        int userId;
        String title;
        String description;
        boolean completed;
        @SerializedName("created_at")
        String createdAt;
        @SerializedName("updated_at")
        String updatedAt;
    }

    static class UserResponse {
        int id;
        String username;
        UserResponse(int id, String username) {
            this.id = id;
            this.username = username;
        }
    }

    static class ErrorResponse {
        String error;
        ErrorResponse(String error) {
            this.error = error;
        }
    }

    static class EmptyResponse {}

    static State state = new State();
    static Gson gson = new Gson();
    static DateTimeFormatter formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--port") && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
            }
        }

        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/register", new RegisterHandler());
        server.createContext("/login", new LoginHandler());
        server.createContext("/logout", new LogoutHandler());
        server.createContext("/me", new MeHandler());
        server.createContext("/password", new PasswordHandler());
        server.createContext("/todos", new TodosHandler());
        server.start();
        System.out.println("Server started on port " + port);
    }

    static String getTimestamp() {
        return formatter.format(Instant.now());
    }

    static User getUser(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader != null) {
            for (String cookie : cookieHeader.split(";")) {
                cookie = cookie.trim();
                if (cookie.startsWith("session_id=")) {
                    String sessionId = cookie.substring("session_id=".length());
                    return state.sessions.get(sessionId);
                }
            }
        }
        return null;
    }

    static void sendJson(HttpExchange exchange, int code, Object obj) throws IOException {
        String json = gson.toJson(obj);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(code, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    static void sendError(HttpExchange exchange, int code, String message) throws IOException {
        sendJson(exchange, code, new ErrorResponse(message));
    }

    static JsonObject parseBody(HttpExchange exchange) throws IOException {
        try (InputStream is = exchange.getRequestBody();
             Reader reader = new InputStreamReader(is, StandardCharsets.UTF_8)) {
            return gson.fromJson(reader, JsonObject.class);
        }
    }

    static class RegisterHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("POST")) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            JsonObject body = parseBody(exchange);
            if (body == null || !body.has("username") || !body.has("password")) {
                sendError(exchange, 400, "Invalid request");
                return;
            }
            String username = body.get("username").getAsString();
            String password = body.get("password").getAsString();

            if (!Pattern.matches("^[a-zA-Z0-9_]{3,50}$", username)) {
                sendError(exchange, 400, "Invalid username");
                return;
            }
            if (password.length() < 8) {
                sendError(exchange, 400, "Password too short");
                return;
            }
            synchronized (state) {
                if (state.usersByUsername.containsKey(username)) {
                    sendError(exchange, 409, "Username already exists");
                    return;
                }
                User user = new User();
                user.id = state.nextUserId++;
                user.username = username;
                user.password = password;
                state.usersByUsername.put(username, user);
                state.usersById.put(user.id, user);
                sendJson(exchange, 201, new UserResponse(user.id, user.username));
            }
        }
    }

    static class LoginHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("POST")) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            JsonObject body = parseBody(exchange);
            if (body == null || !body.has("username") || !body.has("password")) {
                sendError(exchange, 400, "Invalid request");
                return;
            }
            String username = body.get("username").getAsString();
            String password = body.get("password").getAsString();

            User user = state.usersByUsername.get(username);
            if (user == null || !user.password.equals(password)) {
                sendError(exchange, 401, "Invalid credentials");
                return;
            }

            String sessionId = UUID.randomUUID().toString();
            state.sessions.put(sessionId, user);

            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.getResponseHeaders().set("Set-Cookie", "session_id=" + sessionId + "; Path=/; HttpOnly");
            byte[] bytes = gson.toJson(new UserResponse(user.id, user.username)).getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(bytes);
            }
        }
    }

    static class LogoutHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("POST")) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            User user = getUser(exchange);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
            if (cookieHeader != null) {
                for (String cookie : cookieHeader.split(";")) {
                    cookie = cookie.trim();
                    if (cookie.startsWith("session_id=")) {
                        String sessionId = cookie.substring("session_id=".length());
                        state.sessions.remove(sessionId);
                        break;
                    }
                }
            }
            sendJson(exchange, 200, new EmptyResponse());
        }
    }

    static class MeHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("GET")) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            User user = getUser(exchange);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            sendJson(exchange, 200, new UserResponse(user.id, user.username));
        }
    }

    static class PasswordHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!exchange.getRequestMethod().equals("PUT")) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }
            User user = getUser(exchange);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            JsonObject body = parseBody(exchange);
            if (body == null || !body.has("old_password") || !body.has("new_password")) {
                sendError(exchange, 400, "Invalid request");
                return;
            }
            String oldPassword = body.get("old_password").getAsString();
            String newPassword = body.get("new_password").getAsString();

            synchronized (state) {
                if (!user.password.equals(oldPassword)) {
                    sendError(exchange, 401, "Invalid credentials");
                    return;
                }
                if (newPassword.length() < 8) {
                    sendError(exchange, 400, "Password too short");
                    return;
                }
                user.password = newPassword;
            }
            sendJson(exchange, 200, new EmptyResponse());
        }
    }

    static class TodosHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            String path = exchange.getRequestURI().getPath();
            if (path.equals("/todos")) {
                if (exchange.getRequestMethod().equals("GET")) {
                    handleGetTodos(exchange);
                } else if (exchange.getRequestMethod().equals("POST")) {
                    handlePostTodo(exchange);
                } else {
                    exchange.sendResponseHeaders(405, -1);
                }
            } else if (path.startsWith("/todos/")) {
                String idStr = path.substring(7);
                if (exchange.getRequestMethod().equals("GET")) {
                    handleGetTodo(exchange, idStr);
                } else if (exchange.getRequestMethod().equals("PUT")) {
                    handlePutTodo(exchange, idStr);
                } else if (exchange.getRequestMethod().equals("DELETE")) {
                    handleDeleteTodo(exchange, idStr);
                } else {
                    exchange.sendResponseHeaders(405, -1);
                }
            } else {
                exchange.sendResponseHeaders(404, -1);
            }
        }

        void handleGetTodos(HttpExchange exchange) throws IOException {
            User user = getUser(exchange);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            List<Todo> userTodos = new ArrayList<>();
            for (Todo t : state.todos.values()) {
                if (t.userId == user.id) {
                    userTodos.add(t);
                }
            }
            userTodos.sort(Comparator.comparingInt(t -> t.id));
            sendJson(exchange, 200, userTodos);
        }

        void handlePostTodo(HttpExchange exchange) throws IOException {
            User user = getUser(exchange);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            JsonObject body = parseBody(exchange);
            if (body == null || !body.has("title")) {
                sendError(exchange, 400, "Title is required");
                return;
            }
            String title = body.get("title").getAsString();
            if (title == null || title.isEmpty()) {
                sendError(exchange, 400, "Title is required");
                return;
            }
            String description = "";
            if (body.has("description") && !body.get("description").isJsonNull()) {
                description = body.get("description").getAsString();
            }

            synchronized (state) {
                Todo todo = new Todo();
                todo.id = state.nextTodoId++;
                todo.userId = user.id;
                todo.title = title;
                todo.description = description;
                todo.completed = false;
                todo.createdAt = getTimestamp();
                todo.updatedAt = getTimestamp();
                state.todos.put(todo.id, todo);
                sendJson(exchange, 201, todo);
            }
        }

        void handleGetTodo(HttpExchange exchange, String idStr) throws IOException {
            User user = getUser(exchange);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            try {
                int id = Integer.parseInt(idStr);
                Todo todo = state.todos.get(id);
                if (todo == null || todo.userId != user.id) {
                    sendError(exchange, 404, "Todo not found");
                    return;
                }
                sendJson(exchange, 200, todo);
            } catch (NumberFormatException e) {
                sendError(exchange, 404, "Todo not found");
            }
        }

        void handlePutTodo(HttpExchange exchange, String idStr) throws IOException {
            User user = getUser(exchange);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            try {
                int id = Integer.parseInt(idStr);
                JsonObject body = parseBody(exchange);
                synchronized (state) {
                    Todo todo = state.todos.get(id);
                    if (todo == null || todo.userId != user.id) {
                        sendError(exchange, 404, "Todo not found");
                        return;
                    }
                    if (body != null) {
                        if (body.has("title")) {
                            String title = body.get("title").getAsString();
                            if (title == null || title.isEmpty()) {
                                sendError(exchange, 400, "Title is required");
                                return;
                            }
                            todo.title = title;
                        }
                        if (body.has("description")) {
                            todo.description = body.get("description").getAsString();
                        }
                        if (body.has("completed")) {
                            todo.completed = body.get("completed").getAsBoolean();
                        }
                    }
                    todo.updatedAt = getTimestamp();
                    sendJson(exchange, 200, todo);
                }
            } catch (NumberFormatException e) {
                sendError(exchange, 404, "Todo not found");
            }
        }

        void handleDeleteTodo(HttpExchange exchange, String idStr) throws IOException {
            User user = getUser(exchange);
            if (user == null) {
                sendError(exchange, 401, "Authentication required");
                return;
            }
            try {
                int id = Integer.parseInt(idStr);
                synchronized (state) {
                    Todo todo = state.todos.get(id);
                    if (todo == null || todo.userId != user.id) {
                        sendError(exchange, 404, "Todo not found");
                        return;
                    }
                    state.todos.remove(id);
                }
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(204, -1);
            } catch (NumberFormatException e) {
                sendError(exchange, 404, "Todo not found");
            }
        }
    }
}
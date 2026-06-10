import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

public class Server {
    static Database db = new Database();

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
        server.setExecutor(null);
        server.start();
        System.out.println("Server started on port " + port);
    }

    static String getUtcNow() {
        return ZonedDateTime.now(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }

    static String getSessionToken(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader == null) return null;
        String[] cookies = cookieHeader.split(";");
        for (String cookie : cookies) {
            cookie = cookie.trim();
            if (cookie.startsWith("session_id=")) {
                return cookie.substring(11);
            }
        }
        return null;
    }

    static Integer getAuthenticatedUser(HttpExchange exchange) {
        String token = getSessionToken(exchange);
        if (token == null) return null;
        return db.sessions.get(token);
    }

    static JsonObject parseJson(HttpExchange exchange) throws IOException {
        InputStream is = exchange.getRequestBody();
        StringBuilder sb = new StringBuilder();
        byte[] buffer = new byte[1024];
        int len;
        while ((len = is.read(buffer)) != -1) {
            sb.append(new String(buffer, 0, len, StandardCharsets.UTF_8));
        }
        String jsonStr = sb.toString().trim();
        if (jsonStr.isEmpty()) return new JsonObject();
        try {
            return JsonParser.parseString(jsonStr).getAsJsonObject();
        } catch (Exception e) {
            return new JsonObject();
        }
    }

    static void sendError(HttpExchange exchange, int code, String message) throws IOException {
        JsonObject err = new JsonObject();
        err.addProperty("error", message);
        sendJson(exchange, code, err);
    }

    static void sendJson(HttpExchange exchange, int code, JsonElement json) throws IOException {
        String body = json.toString();
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(code, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
        exchange.close();
    }
}

class Database {
    int nextUserId = 1;
    int nextTodoId = 1;
    Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    Map<Integer, User> usersById = new ConcurrentHashMap<>();
    Map<String, Integer> sessions = new ConcurrentHashMap<>();
    Map<Integer, Map<Integer, Todo>> userTodos = new ConcurrentHashMap<>();
}

class User {
    int id;
    String username;
    String password;

    User(int id, String username, String password) {
        this.id = id;
        this.username = username;
        this.password = password;
    }
}

class Todo {
    int id;
    int userId;
    String title;
    String description;
    boolean completed;
    String createdAt;
    String updatedAt;
}

class RegisterHandler implements HttpHandler {
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("POST")) {
            Server.sendError(exchange, 405, "Method Not Allowed");
            return;
        }
        JsonObject req = Server.parseJson(exchange);
        String username = req.has("username") && req.get("username").isJsonPrimitive() ? req.get("username").getAsString() : "";
        String password = req.has("password") && req.get("password").isJsonPrimitive() ? req.get("password").getAsString() : "";

        if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
            Server.sendError(exchange, 400, "Invalid username");
            return;
        }
        if (password.length() < 8) {
            Server.sendError(exchange, 400, "Password too short");
            return;
        }
        if (Server.db.usersByUsername.containsKey(username)) {
            Server.sendError(exchange, 409, "Username already exists");
            return;
        }

        User user = new User(Server.db.nextUserId++, username, password);
        Server.db.usersByUsername.put(username, user);
        Server.db.usersById.put(user.id, user);

        JsonObject res = new JsonObject();
        res.addProperty("id", user.id);
        res.addProperty("username", user.username);
        Server.sendJson(exchange, 201, res);
    }
}

class LoginHandler implements HttpHandler {
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("POST")) {
            Server.sendError(exchange, 405, "Method Not Allowed");
            return;
        }
        JsonObject req = Server.parseJson(exchange);
        String username = req.has("username") && req.get("username").isJsonPrimitive() ? req.get("username").getAsString() : "";
        String password = req.has("password") && req.get("password").isJsonPrimitive() ? req.get("password").getAsString() : "";

        User user = Server.db.usersByUsername.get(username);
        if (user == null || !user.password.equals(password)) {
            Server.sendError(exchange, 401, "Invalid credentials");
            return;
        }

        String token = UUID.randomUUID().toString().replace("-", "");
        Server.db.sessions.put(token, user.id);

        exchange.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");

        JsonObject res = new JsonObject();
        res.addProperty("id", user.id);
        res.addProperty("username", user.username);
        Server.sendJson(exchange, 200, res);
    }
}

class LogoutHandler implements HttpHandler {
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("POST")) {
            Server.sendError(exchange, 405, "Method Not Allowed");
            return;
        }
        Integer userId = Server.getAuthenticatedUser(exchange);
        if (userId == null) {
            Server.sendError(exchange, 401, "Authentication required");
            return;
        }
        String token = Server.getSessionToken(exchange);
        if (token != null) {
            Server.db.sessions.remove(token);
        }
        Server.sendJson(exchange, 200, new JsonObject());
    }
}

class MeHandler implements HttpHandler {
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("GET")) {
            Server.sendError(exchange, 405, "Method Not Allowed");
            return;
        }
        Integer userId = Server.getAuthenticatedUser(exchange);
        if (userId == null) {
            Server.sendError(exchange, 401, "Authentication required");
            return;
        }
        User user = Server.db.usersById.get(userId);
        JsonObject res = new JsonObject();
        res.addProperty("id", user.id);
        res.addProperty("username", user.username);
        Server.sendJson(exchange, 200, res);
    }
}

class PasswordHandler implements HttpHandler {
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("PUT")) {
            Server.sendError(exchange, 405, "Method Not Allowed");
            return;
        }
        Integer userId = Server.getAuthenticatedUser(exchange);
        if (userId == null) {
            Server.sendError(exchange, 401, "Authentication required");
            return;
        }
        JsonObject req = Server.parseJson(exchange);
        String oldPass = req.has("old_password") && req.get("old_password").isJsonPrimitive() ? req.get("old_password").getAsString() : "";
        String newPass = req.has("new_password") && req.get("new_password").isJsonPrimitive() ? req.get("new_password").getAsString() : "";

        User user = Server.db.usersById.get(userId);
        if (!user.password.equals(oldPass)) {
            Server.sendError(exchange, 401, "Invalid credentials");
            return;
        }
        if (newPass.length() < 8) {
            Server.sendError(exchange, 400, "Password too short");
            return;
        }

        user.password = newPass;
        Server.sendJson(exchange, 200, new JsonObject());
    }
}

class TodosHandler implements HttpHandler {
    @Override
    public void handle(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod();
        String path = exchange.getRequestURI().getPath();

        if (path.equals("/todos")) {
            if (method.equals("GET")) handleGetTodos(exchange);
            else if (method.equals("POST")) handlePostTodo(exchange);
            else Server.sendError(exchange, 405, "Method Not Allowed");
        } else if (path.startsWith("/todos/")) {
            String idStr = path.substring(7);
            try {
                int id = Integer.parseInt(idStr);
                if (method.equals("GET")) handleGetTodo(exchange, id);
                else if (method.equals("PUT")) handlePutTodo(exchange, id);
                else if (method.equals("DELETE")) handleDeleteTodo(exchange, id);
                else Server.sendError(exchange, 405, "Method Not Allowed");
            } catch (NumberFormatException e) {
                Server.sendError(exchange, 404, "Todo not found");
            }
        } else {
            Server.sendError(exchange, 404, "Not found");
        }
    }

    private void handleGetTodos(HttpExchange exchange) throws IOException {
        Integer userId = Server.getAuthenticatedUser(exchange);
        if (userId == null) {
            Server.sendError(exchange, 401, "Authentication required");
            return;
        }
        Map<Integer, Todo> todosMap = Server.db.userTodos.get(userId);
        List<Todo> list = new ArrayList<>();
        if (todosMap != null) {
            list.addAll(todosMap.values());
            list.sort(Comparator.comparingInt(t -> t.id));
        }
        JsonArray arr = new JsonArray();
        for (Todo t : list) {
            arr.add(todoToJson(t));
        }
        Server.sendJson(exchange, 200, arr);
    }

    private void handlePostTodo(HttpExchange exchange) throws IOException {
        Integer userId = Server.getAuthenticatedUser(exchange);
        if (userId == null) {
            Server.sendError(exchange, 401, "Authentication required");
            return;
        }
        JsonObject req = Server.parseJson(exchange);
        String title = req.has("title") && req.get("title").isJsonPrimitive() ? req.get("title").getAsString() : "";
        String description = req.has("description") && req.get("description").isJsonPrimitive() ? req.get("description").getAsString() : "";

        if (title == null || title.isEmpty()) {
            Server.sendError(exchange, 400, "Title is required");
            return;
        }

        Todo t = new Todo();
        t.id = Server.db.nextTodoId++;
        t.userId = userId;
        t.title = title;
        t.description = description == null ? "" : description;
        t.completed = false;
        String now = Server.getUtcNow();
        t.createdAt = now;
        t.updatedAt = now;

        Server.db.userTodos.computeIfAbsent(userId, k -> new ConcurrentHashMap<>()).put(t.id, t);
        Server.sendJson(exchange, 201, todoToJson(t));
    }

    private void handleGetTodo(HttpExchange exchange, int todoId) throws IOException {
        Integer userId = Server.getAuthenticatedUser(exchange);
        if (userId == null) {
            Server.sendError(exchange, 401, "Authentication required");
            return;
        }
        Map<Integer, Todo> todos = Server.db.userTodos.get(userId);
        Todo t = todos != null ? todos.get(todoId) : null;
        if (t == null) {
            Server.sendError(exchange, 404, "Todo not found");
            return;
        }
        Server.sendJson(exchange, 200, todoToJson(t));
    }

    private void handlePutTodo(HttpExchange exchange, int todoId) throws IOException {
        Integer userId = Server.getAuthenticatedUser(exchange);
        if (userId == null) {
            Server.sendError(exchange, 401, "Authentication required");
            return;
        }
        JsonObject req = Server.parseJson(exchange);
        Map<Integer, Todo> todos = Server.db.userTodos.get(userId);
        Todo t = todos != null ? todos.get(todoId) : null;
        if (t == null) {
            Server.sendError(exchange, 404, "Todo not found");
            return;
        }

        if (req.has("title")) {
            String newTitle = req.get("title").getAsString();
            if (newTitle == null || newTitle.isEmpty()) {
                Server.sendError(exchange, 400, "Title is required");
                return;
            }
            t.title = newTitle;
        }
        if (req.has("description")) {
            t.description = req.get("description").getAsString();
        }
        if (req.has("completed")) {
            t.completed = req.get("completed").getAsBoolean();
        }
        t.updatedAt = Server.getUtcNow();

        Server.sendJson(exchange, 200, todoToJson(t));
    }

    private void handleDeleteTodo(HttpExchange exchange, int todoId) throws IOException {
        Integer userId = Server.getAuthenticatedUser(exchange);
        if (userId == null) {
            Server.sendError(exchange, 401, "Authentication required");
            return;
        }
        Map<Integer, Todo> todos = Server.db.userTodos.get(userId);
        if (todos == null || !todos.containsKey(todoId)) {
            Server.sendError(exchange, 404, "Todo not found");
            return;
        }
        todos.remove(todoId);
        exchange.sendResponseHeaders(204, -1);
        exchange.close();
    }

    private JsonObject todoToJson(Todo t) {
        JsonObject obj = new JsonObject();
        obj.addProperty("id", t.id);
        obj.addProperty("title", t.title);
        obj.addProperty("description", t.description);
        obj.addProperty("completed", t.completed);
        obj.addProperty("created_at", t.createdAt);
        obj.addProperty("updated_at", t.updatedAt);
        return obj;
    }
}

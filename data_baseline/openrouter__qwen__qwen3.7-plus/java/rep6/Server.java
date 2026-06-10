import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.nio.charset.StandardCharsets;
import org.json.*;

public class Server {
    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i+1]);
            }
        }
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/register", new RegisterHandler());
        server.createContext("/login", new LoginHandler());
        server.createContext("/logout", new AuthHandler(new LogoutHandler()));
        server.createContext("/me", new AuthHandler(new MeHandler()));
        server.createContext("/password", new AuthHandler(new PasswordHandler()));
        server.createContext("/todos", new AuthHandler(new TodosHandler()));
        server.createContext("/todos/", new AuthHandler(new TodoByIdHandler()));
        server.setExecutor(null);
        server.start();
        System.out.println("Server started on port " + port);
    }

    static void sendJson(HttpExchange ex, int code, Map<String, Object> map) throws IOException {
        sendJson(ex, code, map != null ? new JSONObject(map).toString() : "{}");
    }

    static void sendJson(HttpExchange ex, int code, List<Map<String, Object>> list) throws IOException {
        List<JSONObject> jsonList = new ArrayList<>();
        for (Map<String, Object> map : list) {
            jsonList.add(new JSONObject(map));
        }
        sendJson(ex, code, new JSONArray(jsonList).toString());
    }

    static void sendJson(HttpExchange ex, int code, String json) throws IOException {
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(code, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }

    static void sendNoContent(HttpExchange ex) throws IOException {
        ex.sendResponseHeaders(204, -1);
    }

    static String readBody(HttpExchange ex) throws IOException {
        InputStream is = ex.getRequestBody();
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        byte[] buffer = new byte[1024];
        int length;
        while ((length = is.read(buffer)) != -1) {
            result.write(buffer, 0, length);
        }
        return result.toString(StandardCharsets.UTF_8.name());
    }
}

class DB {
    static Map<Integer, User> users = new HashMap<>();
    static Map<String, User> userByUsername = new HashMap<>();
    static int nextUserId = 1;
    
    static Map<String, Integer> sessions = new HashMap<>();
    
    static Map<Integer, Todo> todos = new HashMap<>();
    static int nextTodoId = 1;
    
    static synchronized User register(String username, String password) {
        if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) return null;
        if (password == null || password.length() < 8) return null;
        if (userByUsername.containsKey(username)) return null;
        
        User u = new User(nextUserId++, username, password);
        users.put(u.id, u);
        userByUsername.put(u.username, u);
        return u;
    }
    
    static synchronized User getUserByUsername(String username) {
        return userByUsername.get(username);
    }
    
    static synchronized String createSession(int userId) {
        String token = UUID.randomUUID().toString().replace("-", "");
        sessions.put(token, userId);
        return token;
    }
    
    static synchronized void destroySession(String token) {
        sessions.remove(token);
    }
    
    static synchronized Integer getUserId(String token) {
        return sessions.get(token);
    }
    
    static synchronized Todo createTodo(int userId, String title, String description) {
        Todo t = new Todo(nextTodoId++, userId, title, description);
        todos.put(t.id, t);
        return t;
    }
    
    static synchronized Todo getTodo(int id, int userId) {
        Todo t = todos.get(id);
        if (t != null && t.userId == userId) return t;
        return null;
    }
    
    static synchronized List<Todo> getTodos(int userId) {
        List<Todo> list = new ArrayList<>();
        for (Todo t : todos.values()) {
            if (t.userId == userId) list.add(t);
        }
        list.sort(Comparator.comparingInt(t -> t.id));
        return list;
    }
    
    static synchronized boolean deleteTodo(int id, int userId) {
        Todo t = todos.get(id);
        if (t != null && t.userId == userId) {
            todos.remove(id);
            return true;
        }
        return false;
    }
    
    static synchronized User getUser(int id) {
        return users.get(id);
    }
    
    static synchronized void updatePasswordSuccess(int id, String newPass) {
        User u = users.get(id);
        if (u != null) {
            u.password = newPass;
        }
    }

    static Map<String, Object> map(Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) {
            m.put((String)kv[i], kv[i+1]);
        }
        return m;
    }

    static Map<String, Object> toMap(Todo t) {
        return map(
            "id", t.id,
            "title", t.title,
            "description", t.description,
            "completed", t.completed,
            "created_at", t.createdAt,
            "updated_at", t.updatedAt
        );
    }
}

class User {
    int id;
    String username;
    String password;
    public User(int id, String username, String password) {
        this.id = id; this.username = username; this.password = password;
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
    
    public Todo(int id, int userId, String title, String description) {
        this.id = id;
        this.userId = userId;
        this.title = title;
        this.description = description != null ? description : "";
        this.completed = false;
        this.createdAt = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
        this.updatedAt = this.createdAt;
    }
}

class AuthHandler implements HttpHandler {
    private HttpHandler delegate;
    public AuthHandler(HttpHandler delegate) { this.delegate = delegate; }
    
    public void handle(HttpExchange ex) throws IOException {
        String cookieHeader = ex.getRequestHeaders().getFirst("Cookie");
        String sessionId = null;
        if (cookieHeader != null) {
            for (String cookie : cookieHeader.split(";")) {
                cookie = cookie.trim();
                if (cookie.startsWith("session_id=")) {
                    sessionId = cookie.substring("session_id=".length());
                }
            }
        }
        
        Integer userId = DB.getUserId(sessionId);
        if (userId == null) {
            Server.sendJson(ex, 401, DB.map("error", "Authentication required"));
            return;
        }
        
        ex.setAttribute("userId", userId);
        ex.setAttribute("sessionId", sessionId);
        delegate.handle(ex);
    }
}

class RegisterHandler implements HttpHandler {
    public void handle(HttpExchange ex) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) {
            Server.sendJson(ex, 405, DB.map("error", "Method not allowed"));
            return;
        }
        String body = Server.readBody(ex);
        try {
            JSONObject req = new JSONObject(body);
            String username = req.optString("username", null);
            String password = req.optString("password", null);
            
            if (username == null) {
                Server.sendJson(ex, 400, DB.map("error", "Invalid username"));
                return;
            }
            if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
                Server.sendJson(ex, 400, DB.map("error", "Invalid username"));
                return;
            }
            if (password == null || password.length() < 8) {
                Server.sendJson(ex, 400, DB.map("error", "Password too short"));
                return;
            }
            
            User u = DB.register(username, password);
            if (u == null) {
                Server.sendJson(ex, 409, DB.map("error", "Username already exists"));
                return;
            }
            
            Server.sendJson(ex, 201, DB.map("id", u.id, "username", u.username));
        } catch (JSONException e) {
            Server.sendJson(ex, 400, DB.map("error", "Invalid JSON"));
        }
    }
}

class LoginHandler implements HttpHandler {
    public void handle(HttpExchange ex) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) {
            Server.sendJson(ex, 405, DB.map("error", "Method not allowed"));
            return;
        }
        String body = Server.readBody(ex);
        try {
            JSONObject req = new JSONObject(body);
            String username = req.optString("username", null);
            String password = req.optString("password", null);
            
            User u = DB.getUserByUsername(username);
            if (u == null || !u.password.equals(password)) {
                Server.sendJson(ex, 401, DB.map("error", "Invalid credentials"));
                return;
            }
            
            String token = DB.createSession(u.id);
            ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
            Server.sendJson(ex, 200, DB.map("id", u.id, "username", u.username));
        } catch (JSONException e) {
            Server.sendJson(ex, 400, DB.map("error", "Invalid JSON"));
        }
    }
}

class LogoutHandler implements HttpHandler {
    public void handle(HttpExchange ex) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) {
            Server.sendJson(ex, 405, DB.map("error", "Method not allowed"));
            return;
        }
        String token = (String) ex.getAttribute("sessionId");
        if (token != null) {
            DB.destroySession(token);
        }
        Server.sendJson(ex, 200, DB.map());
    }
}

class MeHandler implements HttpHandler {
    public void handle(HttpExchange ex) throws IOException {
        if (!"GET".equals(ex.getRequestMethod())) {
            Server.sendJson(ex, 405, DB.map("error", "Method not allowed"));
            return;
        }
        Integer userId = (Integer) ex.getAttribute("userId");
        User u = DB.getUser(userId);
        Server.sendJson(ex, 200, DB.map("id", u.id, "username", u.username));
    }
}

class PasswordHandler implements HttpHandler {
    public void handle(HttpExchange ex) throws IOException {
        if (!"PUT".equals(ex.getRequestMethod())) {
            Server.sendJson(ex, 405, DB.map("error", "Method not allowed"));
            return;
        }
        String body = Server.readBody(ex);
        try {
            JSONObject req = new JSONObject(body);
            String oldPass = req.optString("old_password", null);
            String newPass = req.optString("new_password", null);
            
            Integer userId = (Integer) ex.getAttribute("userId");
            User u = DB.getUser(userId);
            
            if (u == null || !u.password.equals(oldPass)) {
                Server.sendJson(ex, 401, DB.map("error", "Invalid credentials"));
                return;
            }
            if (newPass == null || newPass.length() < 8) {
                Server.sendJson(ex, 400, DB.map("error", "Password too short"));
                return;
            }
            
            DB.updatePasswordSuccess(userId, newPass);
            Server.sendJson(ex, 200, DB.map());
        } catch (JSONException e) {
            Server.sendJson(ex, 400, DB.map("error", "Invalid JSON"));
        }
    }
}

class TodosHandler implements HttpHandler {
    public void handle(HttpExchange ex) throws IOException {
        if ("GET".equals(ex.getRequestMethod())) {
            Integer userId = (Integer) ex.getAttribute("userId");
            List<Todo> list = DB.getTodos(userId);
            List<Map<String, Object>> result = new ArrayList<>();
            for (Todo t : list) {
                result.add(DB.toMap(t));
            }
            Server.sendJson(ex, 200, result);
        } else if ("POST".equals(ex.getRequestMethod())) {
            Integer userId = (Integer) ex.getAttribute("userId");
            String body = Server.readBody(ex);
            try {
                JSONObject req = new JSONObject(body);
                if (!req.has("title")) {
                     Server.sendJson(ex, 400, DB.map("error", "Title is required"));
                     return;
                }
                String title = req.optString("title", null);
                if (title == null || title.isEmpty()) {
                    Server.sendJson(ex, 400, DB.map("error", "Title is required"));
                    return;
                }
                String description = req.optString("description", "");
                
                Todo t = DB.createTodo(userId, title, description);
                Server.sendJson(ex, 201, DB.toMap(t));
            } catch (JSONException e) {
                Server.sendJson(ex, 400, DB.map("error", "Invalid JSON"));
            }
        } else {
            Server.sendJson(ex, 405, DB.map("error", "Method not allowed"));
        }
    }
}

class TodoByIdHandler implements HttpHandler {
    public void handle(HttpExchange ex) throws IOException {
        String path = ex.getRequestURI().getPath();
        if (!path.matches("^/todos/\\d+$")) {
            Server.sendJson(ex, 404, DB.map("error", "Todo not found"));
            return;
        }
        int id = Integer.parseInt(path.substring(7));
        Integer userId = (Integer) ex.getAttribute("userId");
        Todo t = DB.getTodo(id, userId);
        
        if ("GET".equals(ex.getRequestMethod())) {
            if (t == null) {
                Server.sendJson(ex, 404, DB.map("error", "Todo not found"));
                return;
            }
            Server.sendJson(ex, 200, DB.toMap(t));
        } else if ("PUT".equals(ex.getRequestMethod())) {
            if (t == null) {
                Server.sendJson(ex, 404, DB.map("error", "Todo not found"));
                return;
            }
            String body = Server.readBody(ex);
            try {
                JSONObject req = new JSONObject(body);
                if (req.has("title")) {
                    String title = req.optString("title", null);
                    if (title == null || title.isEmpty()) {
                        Server.sendJson(ex, 400, DB.map("error", "Title is required"));
                        return;
                    }
                    t.title = title;
                }
                if (req.has("description")) {
                    t.description = req.optString("description", "");
                }
                if (req.has("completed")) {
                    t.completed = req.getBoolean("completed");
                }
                t.updatedAt = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
                
                Server.sendJson(ex, 200, DB.toMap(t));
            } catch (JSONException e) {
                Server.sendJson(ex, 400, DB.map("error", "Invalid JSON"));
            }
        } else if ("DELETE".equals(ex.getRequestMethod())) {
            if (t == null) {
                Server.sendJson(ex, 404, DB.map("error", "Todo not found"));
                return;
            }
            DB.deleteTodo(id, userId);
            Server.sendNoContent(ex);
        } else {
            Server.sendJson(ex, 405, DB.map("error", "Method not allowed"));
        }
    }
}
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;
import java.net.InetSocketAddress;
import java.util.concurrent.Executors;
import java.util.concurrent.ConcurrentHashMap;
import java.io.IOException;
import java.util.*;
import java.util.regex.*;
import java.nio.charset.StandardCharsets;

public class Main {
    public static void main(String[] args) {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--port") && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
            }
        }
        try {
            HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
            DataStore store = new DataStore();
            
            server.createContext("/register", new RegisterHandler(store));
            server.createContext("/login", new LoginHandler(store));
            server.createContext("/logout", new LogoutHandler(store));
            server.createContext("/me", new MeHandler(store));
            server.createContext("/password", new PasswordHandler(store));
            server.createContext("/todos", new TodosHandler(store));
            
            server.setExecutor(Executors.newFixedThreadPool(10));
            server.start();
            System.out.println("Server started on port " + port);
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}

class JsonHelper {
    public static String object(Object... kv) {
        StringBuilder sb = new StringBuilder("{");
        for (int i = 0; i < kv.length; i += 2) {
            if (i > 0) sb.append(",");
            sb.append("\"").append(escape(kv[i].toString())).append("\":");
            Object v = kv[i+1];
            if (v instanceof String) {
                sb.append("\"").append(escape(v.toString())).append("\"");
            } else if (v instanceof Boolean || v instanceof Number) {
                sb.append(v.toString());
            } else if (v == null) {
                sb.append("null");
            }
        }
        sb.append("}");
        return sb.toString();
    }
    
    public static String array(List<String> items) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append(items.get(i));
        }
        sb.append("]");
        return sb.toString();
    }

    public static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }
    
    public static Map<String, Object> parse(String json) {
        Map<String, Object> map = new LinkedHashMap<>();
        if (json == null) return map;
        String inner = json.trim();
        if (inner.startsWith("{") && inner.endsWith("}")) {
            inner = inner.substring(1, inner.length() - 1).trim();
        }
        if (inner.isEmpty()) return map;
        
        Pattern p = Pattern.compile("\"([^\"]+)\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|true|false|null|-?\\d+(?:\\.\\d+)?)");
        Matcher m = p.matcher(inner);
        while (m.find()) {
            String key = m.group(1);
            String val = m.group(2);
            if (val.startsWith("\"") && val.endsWith("\"")) {
                val = val.substring(1, val.length() - 1);
                val = val.replace("\\\\", "\\").replace("\\\"", "\"").replace("\\n", "\n").replace("\\t", "\t").replace("\\r", "\r");
                map.put(key, val);
            } else if (val.equals("true")) {
                map.put(key, true);
            } else if (val.equals("false")) {
                map.put(key, false);
            } else if (val.equals("null")) {
                map.put(key, null);
            } else {
                try {
                    if (val.contains(".")) {
                        map.put(key, Double.parseDouble(val));
                    } else {
                        map.put(key, Long.parseLong(val));
                    }
                } catch (NumberFormatException e) {
                    map.put(key, val);
                }
            }
        }
        return map;
    }
}

class DataStore {
    private int nextUserId = 1;
    private int nextTodoId = 1;
    private final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    private final Map<Integer, User> usersById = new ConcurrentHashMap<>();
    private final Map<Integer, Todo> todos = new ConcurrentHashMap<>();
    private final Map<String, Integer> sessions = new ConcurrentHashMap<>();

    public synchronized User register(String username, String password) {
        if (usersByUsername.containsKey(username)) {
            return null;
        }
        User user = new User(nextUserId++, username, password);
        usersByUsername.put(username, user);
        usersById.put(user.id, user);
        return user;
    }

    public User login(String username, String password) {
        User user = usersByUsername.get(username);
        if (user != null && user.password.equals(password)) {
            return user;
        }
        return null;
    }

    public String createSession(int userId) {
        String token = UUID.randomUUID().toString().replace("-", "");
        sessions.put(token, userId);
        return token;
    }

    public void invalidateSession(String token) {
        sessions.remove(token);
    }

    public Integer getSessionUser(String token) {
        return sessions.get(token);
    }

    public User getUserById(int id) {
        return usersById.get(id);
    }

    public synchronized Todo createTodo(int userId, String title, String description) {
        String now = getIsoNow();
        Todo todo = new Todo(nextTodoId++, userId, title, description, false, now, now);
        todos.put(todo.id, todo);
        return todo;
    }

    public Todo getTodo(int id) {
        return todos.get(id);
    }

    public List<Todo> getTodosByUser(int userId) {
        List<Todo> result = new ArrayList<>();
        for (Todo todo : todos.values()) {
            if (todo.userId == userId) {
                result.add(todo);
            }
        }
        result.sort(Comparator.comparingInt(t -> t.id));
        return result;
    }

    public synchronized Todo updateTodo(int id, int userId, String title, String description, Boolean completed) {
        Todo todo = todos.get(id);
        if (todo != null && todo.userId == userId) {
            if (title != null) todo.title = title;
            if (description != null) todo.description = description;
            if (completed != null) todo.completed = completed;
            todo.updatedAt = getIsoNow();
            return todo;
        }
        return null;
    }

    public synchronized boolean deleteTodo(int id, int userId) {
        Todo todo = todos.get(id);
        if (todo != null && todo.userId == userId) {
            todos.remove(id);
            return true;
        }
        return false;
    }

    public boolean checkPassword(int userId, String password) {
        User user = usersById.get(userId);
        return user != null && user.password.equals(password);
    }

    public synchronized void updatePassword(int userId, String newPassword) {
        User user = usersById.get(userId);
        if (user != null) {
            user.password = newPassword;
        }
    }

    private String getIsoNow() {
        return java.time.ZonedDateTime.now(java.time.ZoneOffset.UTC)
                .format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }
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
    Todo(int id, int userId, String title, String description, boolean completed, String createdAt, String updatedAt) {
        this.id = id;
        this.userId = userId;
        this.title = title;
        this.description = description;
        this.completed = completed;
        this.createdAt = createdAt;
        this.updatedAt = updatedAt;
    }
    public String toJson() {
        return JsonHelper.object(
            "id", id,
            "title", title,
            "description", description,
            "completed", completed,
            "created_at", createdAt,
            "updated_at", updatedAt
        );
    }
}

abstract class BaseHandler implements HttpHandler {
    protected final DataStore store;
    protected BaseHandler(DataStore store) {
        this.store = store;
    }

    protected String getCookie(HttpExchange exchange, String name) {
        String cookies = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookies != null) {
            for (String cookie : cookies.split(";")) {
                String[] parts = cookie.trim().split("=", 2);
                if (parts.length == 2 && parts[0].equals(name)) {
                    return parts[1];
                }
            }
        }
        return null;
    }

    protected Integer requireAuth(HttpExchange exchange) throws IOException {
        String token = getCookie(exchange, "session_id");
        if (token == null) {
            sendJson(exchange, 401, JsonHelper.object("error", "Authentication required"));
            return null;
        }
        Integer userId = store.getSessionUser(token);
        if (userId == null) {
            sendJson(exchange, 401, JsonHelper.object("error", "Authentication required"));
            return null;
        }
        return userId;
    }

    protected void sendJson(HttpExchange exchange, int code, String json) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(code, bytes.length);
        exchange.getResponseBody().write(bytes);
        exchange.getResponseBody().close();
    }
    
    protected void sendNoContent(HttpExchange exchange, int code) throws IOException {
        exchange.sendResponseHeaders(code, -1);
        exchange.getResponseBody().close();
    }

    protected String readBody(HttpExchange exchange) throws IOException {
        java.io.InputStream is = exchange.getRequestBody();
        java.util.Scanner s = new java.util.Scanner(is).useDelimiter("\\A");
        return s.hasNext() ? s.next() : "";
    }
}

class RegisterHandler extends BaseHandler {
    public RegisterHandler(DataStore store) { super(store); }
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("POST")) {
            sendJson(exchange, 405, JsonHelper.object("error", "Method not allowed"));
            return;
        }
        String body = readBody(exchange);
        Map<String, Object> req = JsonHelper.parse(body);
        Object u = req.get("username");
        Object p = req.get("password");
        
        if (!(u instanceof String) || !((String)u).matches("^[a-zA-Z0-9_]{3,50}$")) {
            sendJson(exchange, 400, JsonHelper.object("error", "Invalid username"));
            return;
        }
        String username = (String) u;
        
        if (!(p instanceof String) || ((String)p).length() < 8) {
            sendJson(exchange, 400, JsonHelper.object("error", "Password too short"));
            return;
        }
        String password = (String) p;
        
        User user = store.register(username, password);
        if (user == null) {
            sendJson(exchange, 409, JsonHelper.object("error", "Username already exists"));
            return;
        }
        sendJson(exchange, 201, JsonHelper.object("id", user.id, "username", user.username));
    }
}

class LoginHandler extends BaseHandler {
    public LoginHandler(DataStore store) { super(store); }
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("POST")) {
            sendJson(exchange, 405, JsonHelper.object("error", "Method not allowed"));
            return;
        }
        String body = readBody(exchange);
        Map<String, Object> req = JsonHelper.parse(body);
        Object u = req.get("username");
        Object p = req.get("password");
        
        if (u instanceof String && p instanceof String) {
            User user = store.login((String)u, (String)p);
            if (user != null) {
                String token = store.createSession(user.id);
                exchange.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
                sendJson(exchange, 200, JsonHelper.object("id", user.id, "username", user.username));
                return;
            }
        }
        sendJson(exchange, 401, JsonHelper.object("error", "Invalid credentials"));
    }
}

class LogoutHandler extends BaseHandler {
    public LogoutHandler(DataStore store) { super(store); }
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("POST")) {
            sendJson(exchange, 405, JsonHelper.object("error", "Method not allowed"));
            return;
        }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        String token = getCookie(exchange, "session_id");
        if (token != null) {
            store.invalidateSession(token);
        }
        sendJson(exchange, 200, JsonHelper.object());
    }
}

class MeHandler extends BaseHandler {
    public MeHandler(DataStore store) { super(store); }
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("GET")) {
            sendJson(exchange, 405, JsonHelper.object("error", "Method not allowed"));
            return;
        }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        User user = store.getUserById(userId);
        sendJson(exchange, 200, JsonHelper.object("id", user.id, "username", user.username));
    }
}

class PasswordHandler extends BaseHandler {
    public PasswordHandler(DataStore store) { super(store); }
    public void handle(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("PUT")) {
            sendJson(exchange, 405, JsonHelper.object("error", "Method not allowed"));
            return;
        }
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        String body = readBody(exchange);
        Map<String, Object> req = JsonHelper.parse(body);
        Object oldP = req.get("old_password");
        Object newP = req.get("new_password");
        
        if (!(oldP instanceof String) || !(newP instanceof String)) {
            sendJson(exchange, 400, JsonHelper.object("error", "Invalid request"));
            return;
        }
        
        if (!store.checkPassword(userId, (String)oldP)) {
            sendJson(exchange, 401, JsonHelper.object("error", "Invalid credentials"));
            return;
        }
        
        if (((String)newP).length() < 8) {
            sendJson(exchange, 400, JsonHelper.object("error", "Password too short"));
            return;
        }
        
        store.updatePassword(userId, (String)newP);
        sendJson(exchange, 200, JsonHelper.object());
    }
}

class TodosHandler extends BaseHandler {
    public TodosHandler(DataStore store) { super(store); }
    public void handle(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod();
        String path = exchange.getRequestURI().getPath();
        
        if (path.equals("/todos")) {
            if (method.equals("GET")) {
                Integer userId = requireAuth(exchange);
                if (userId == null) return;
                List<Todo> todos = store.getTodosByUser(userId);
                List<String> jsonTodos = new ArrayList<>();
                for (Todo t : todos) jsonTodos.add(t.toJson());
                sendJson(exchange, 200, JsonHelper.array(jsonTodos));
            } else if (method.equals("POST")) {
                Integer userId = requireAuth(exchange);
                if (userId == null) return;
                String body = readBody(exchange);
                Map<String, Object> req = JsonHelper.parse(body);
                Object titleObj = req.get("title");
                
                if (!(titleObj instanceof String) || ((String)titleObj).isEmpty()) {
                    sendJson(exchange, 400, JsonHelper.object("error", "Title is required"));
                    return;
                }
                String title = (String) titleObj;
                String desc = req.containsKey("description") && req.get("description") instanceof String ? (String) req.get("description") : "";
                
                Todo todo = store.createTodo(userId, title, desc);
                sendJson(exchange, 201, todo.toJson());
            } else {
                sendJson(exchange, 405, JsonHelper.object("error", "Method not allowed"));
            }
        } else if (path.startsWith("/todos/")) {
            new TodoIdHandler(store).handle(exchange);
        } else {
            sendJson(exchange, 404, JsonHelper.object("error", "Not found"));
        }
    }
}

class TodoIdHandler extends BaseHandler {
    public TodoIdHandler(DataStore store) { super(store); }
    public void handle(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod();
        String path = exchange.getRequestURI().getPath();
        
        String[] parts = path.split("/");
        if (parts.length != 3) {
            sendJson(exchange, 404, JsonHelper.object("error", "Not found"));
            return;
        }
        
        int id;
        try {
            id = Integer.parseInt(parts[2]);
        } catch (NumberFormatException e) {
            sendJson(exchange, 404, JsonHelper.object("error", "Not found"));
            return;
        }
        
        Integer userId = requireAuth(exchange);
        if (userId == null) return;
        
        if (method.equals("GET")) {
            Todo todo = store.getTodo(id);
            if (todo == null || todo.userId != userId) {
                sendJson(exchange, 404, JsonHelper.object("error", "Todo not found"));
                return;
            }
            sendJson(exchange, 200, todo.toJson());
        } else if (method.equals("PUT")) {
            Todo todo = store.getTodo(id);
            if (todo == null || todo.userId != userId) {
                sendJson(exchange, 404, JsonHelper.object("error", "Todo not found"));
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> req = JsonHelper.parse(body);
            
            String title = null;
            if (req.containsKey("title")) {
                if (!(req.get("title") instanceof String)) {
                    sendJson(exchange, 400, JsonHelper.object("error", "Title is required"));
                    return;
                }
                title = (String) req.get("title");
                if (title.isEmpty()) {
                    sendJson(exchange, 400, JsonHelper.object("error", "Title is required"));
                    return;
                }
            }
            
            String desc = null;
            if (req.containsKey("description")) {
                desc = req.get("description") instanceof String ? (String) req.get("description") : "";
            }
            
            Boolean completed = null;
            if (req.containsKey("completed")) {
                completed = req.get("completed") instanceof Boolean ? (Boolean) req.get("completed") : null;
            }
            
            Todo updated = store.updateTodo(id, userId, title, desc, completed);
            sendJson(exchange, 200, updated.toJson());
        } else if (method.equals("DELETE")) {
            boolean deleted = store.deleteTodo(id, userId);
            if (!deleted) {
                sendJson(exchange, 404, JsonHelper.object("error", "Todo not found"));
                return;
            }
            sendNoContent(exchange, 204);
        } else {
            sendJson(exchange, 405, JsonHelper.object("error", "Method not allowed"));
        }
    }
}
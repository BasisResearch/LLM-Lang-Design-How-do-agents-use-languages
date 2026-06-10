import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import com.sun.net.httpserver.*;

public class TodoServer {
    
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
        String createdAt;
        String updatedAt;
    }
    
    private final List<User> users = new ArrayList<>();
    private final List<Todo> todos = new ArrayList<>();
    private final Map<String, Integer> sessions = new ConcurrentHashMap<>();
    private int nextUserId = 1;
    private int nextTodoId = 1;
    
    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
            }
        }
        
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        TodoServer app = new TodoServer();
        server.createContext("/register", app::handleRegister);
        server.createContext("/login", app::handleLogin);
        server.createContext("/logout", app::handleLogout);
        server.createContext("/me", app::handleMe);
        server.createContext("/password", app::handlePassword);
        server.createContext("/todos", app::handleTodos);
        server.createContext("/todos/", app::handleTodoById);
        
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server started on port " + port);
    }
    
    private String getTimestamp() {
        return java.time.ZonedDateTime.now(java.time.ZoneOffset.UTC)
            .format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }
    
    private Integer getUserId(HttpExchange ex) {
        List<String> cookies = ex.getRequestHeaders().get("Cookie");
        if (cookies == null) return null;
        for (String cookie : cookies) {
            String[] parts = cookie.split(";");
            for (String part : parts) {
                part = part.trim();
                if (part.startsWith("session_id=")) {
                    String token = part.substring("session_id=".length());
                    return sessions.get(token);
                }
            }
        }
        return null;
    }
    
    private boolean requireAuth(HttpExchange ex) throws IOException {
        Integer userId = getUserId(ex);
        if (userId == null) {
            sendJsonError(ex, 401, "Authentication required");
            return false;
        }
        return true;
    }
    
    private User getUserById(int id) {
        for (User u : users) {
            if (u.id == id) return u;
        }
        return null;
    }
    
    private Todo getTodoById(int id) {
        for (Todo t : todos) {
            if (t.id == id) return t;
        }
        return null;
    }
    
    private Map<String, Object> todoToMap(Todo t) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", t.id);
        m.put("title", t.title);
        m.put("description", t.description);
        m.put("completed", t.completed);
        m.put("created_at", t.createdAt);
        m.put("updated_at", t.updatedAt);
        return m;
    }
    
    private void sendJson(HttpExchange ex, int status, Object body) throws IOException {
        byte[] bytes = Json.stringify(body).getBytes("UTF-8");
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }
    
    private void sendJsonError(HttpExchange ex, int status, String error) throws IOException {
        Map<String, String> err = new LinkedHashMap<>();
        err.put("error", error);
        sendJson(ex, status, err);
    }
    
    private Map<String, Object> parseBody(HttpExchange ex) throws IOException {
        String body = new String(ex.getRequestBody().readAllBytes(), "UTF-8");
        if (body == null || body.trim().isEmpty()) {
            return new LinkedHashMap<>();
        }
        try {
            JsonParser parser = new JsonParser(body);
            Object parsed = parser.parse();
            if (parsed instanceof Map) {
                return (Map<String, Object>) parsed;
            }
        } catch (Exception e) {
            // Ignore and return empty map or handle as error
        }
        return new LinkedHashMap<>();
    }
    
    public void handleRegister(HttpExchange ex) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) {
            sendJsonError(ex, 405, "Method not allowed");
            return;
        }
        Map<String, Object> req = parseBody(ex);
        String username = (String) req.get("username");
        String password = (String) req.get("password");
        
        if (username == null || !username.matches("^[a-zA-Z0-9_]{3,50}$")) {
            sendJsonError(ex, 400, "Invalid username");
            return;
        }
        if (password == null || password.length() < 8) {
            sendJsonError(ex, 400, "Password too short");
            return;
        }
        
        synchronized (this) {
            for (User u : users) {
                if (u.username.equals(username)) {
                    sendJsonError(ex, 409, "Username already exists");
                    return;
                }
            }
            User newUser = new User();
            newUser.id = nextUserId++;
            newUser.username = username;
            newUser.password = password;
            users.add(newUser);
            
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("id", newUser.id);
            resp.put("username", newUser.username);
            sendJson(ex, 201, resp);
        }
    }
    
    public void handleLogin(HttpExchange ex) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) {
            sendJsonError(ex, 405, "Method not allowed");
            return;
        }
        Map<String, Object> req = parseBody(ex);
        String username = (String) req.get("username");
        String password = (String) req.get("password");
        
        User found = null;
        for (User u : users) {
            if (u.username.equals(username) && u.password.equals(password)) {
                found = u;
                break;
            }
        }
        
        if (found == null) {
            sendJsonError(ex, 401, "Invalid credentials");
            return;
        }
        
        String token = UUID.randomUUID().toString();
        sessions.put(token, found.id);
        
        ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        
        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("id", found.id);
        resp.put("username", found.username);
        sendJson(ex, 200, resp);
    }
    
    public void handleLogout(HttpExchange ex) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) {
            sendJsonError(ex, 405, "Method not allowed");
            return;
        }
        if (!requireAuth(ex)) return;
        
        List<String> cookies = ex.getRequestHeaders().get("Cookie");
        if (cookies != null) {
            for (String cookie : cookies) {
                String[] parts = cookie.split(";");
                for (String part : parts) {
                    part = part.trim();
                    if (part.startsWith("session_id=")) {
                        String token = part.substring("session_id=".length());
                        sessions.remove(token);
                    }
                }
            }
        }
        
        sendJson(ex, 200, new LinkedHashMap<>());
    }
    
    public void handleMe(HttpExchange ex) throws IOException {
        if (!"GET".equals(ex.getRequestMethod())) {
            sendJsonError(ex, 405, "Method not allowed");
            return;
        }
        if (!requireAuth(ex)) return;
        Integer userId = getUserId(ex);
        User found = getUserById(userId);
        
        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("id", found.id);
        resp.put("username", found.username);
        sendJson(ex, 200, resp);
    }
    
    public void handlePassword(HttpExchange ex) throws IOException {
        if (!"PUT".equals(ex.getRequestMethod())) {
            sendJsonError(ex, 405, "Method not allowed");
            return;
        }
        if (!requireAuth(ex)) return;
        Integer userId = getUserId(ex);
        User user = getUserById(userId);
        
        Map<String, Object> req = parseBody(ex);
        String oldPassword = (String) req.get("old_password");
        String newPassword = (String) req.get("new_password");
        
        if (!user.password.equals(oldPassword)) {
            sendJsonError(ex, 401, "Invalid credentials");
            return;
        }
        if (newPassword == null || newPassword.length() < 8) {
            sendJsonError(ex, 400, "Password too short");
            return;
        }
        
        user.password = newPassword;
        sendJson(ex, 200, new LinkedHashMap<>());
    }
    
    public void handleTodos(HttpExchange ex) throws IOException {
        if ("GET".equals(ex.getRequestMethod())) {
            if (!requireAuth(ex)) return;
            Integer userId = getUserId(ex);
            List<Map<String, Object>> list = new ArrayList<>();
            synchronized (this) {
                for (Todo t : todos) {
                    if (t.userId == userId) {
                        list.add(todoToMap(t));
                    }
                }
            }
            list.sort((a, b) -> Integer.compare(((Number)a.get("id")).intValue(), ((Number)b.get("id")).intValue()));
            sendJson(ex, 200, list);
        } else if ("POST".equals(ex.getRequestMethod())) {
            if (!requireAuth(ex)) return;
            Integer userId = getUserId(ex);
            
            Map<String, Object> req = parseBody(ex);
            String title = (String) req.get("title");
            if (title == null || title.trim().isEmpty()) {
                sendJsonError(ex, 400, "Title is required");
                return;
            }
            String description = (String) req.getOrDefault("description", "");
            if (description == null) description = "";
            
            Todo newTodo = new Todo();
            synchronized (this) {
                newTodo.id = nextTodoId++;
                newTodo.userId = userId;
                newTodo.title = title;
                newTodo.description = description;
                newTodo.completed = false;
                String now = getTimestamp();
                newTodo.createdAt = now;
                newTodo.updatedAt = now;
                todos.add(newTodo);
            }
            sendJson(ex, 201, todoToMap(newTodo));
        } else {
            sendJsonError(ex, 405, "Method not allowed");
        }
    }
    
    public void handleTodoById(HttpExchange ex) throws IOException {
        String path = ex.getRequestURI().getPath();
        String[] parts = path.split("/");
        if (parts.length < 3 || parts[2].isEmpty()) {
            sendJsonError(ex, 404, "Todo not found");
            return;
        }
        
        int todoId;
        try {
            todoId = Integer.parseInt(parts[2]);
        } catch (NumberFormatException e) {
            sendJsonError(ex, 404, "Todo not found");
            return;
        }
        
        if ("GET".equals(ex.getRequestMethod())) {
            if (!requireAuth(ex)) return;
            Integer userId = getUserId(ex);
            Todo t = getTodoById(todoId);
            if (t == null || t.userId != userId) {
                sendJsonError(ex, 404, "Todo not found");
                return;
            }
            sendJson(ex, 200, todoToMap(t));
        } else if ("PUT".equals(ex.getRequestMethod())) {
            if (!requireAuth(ex)) return;
            Integer userId = getUserId(ex);
            Todo t = getTodoById(todoId);
            if (t == null || t.userId != userId) {
                sendJsonError(ex, 404, "Todo not found");
                return;
            }
            
            Map<String, Object> req = parseBody(ex);
            if (req.containsKey("title")) {
                String title = (String) req.get("title");
                if (title == null || title.trim().isEmpty()) {
                    sendJsonError(ex, 400, "Title is required");
                    return;
                }
                t.title = title;
            }
            if (req.containsKey("description")) {
                t.description = (String) req.get("description");
                if (t.description == null) t.description = "";
            }
            if (req.containsKey("completed")) {
                Object comp = req.get("completed");
                if (comp instanceof Boolean) {
                    t.completed = (Boolean) comp;
                } else if (comp instanceof Number) {
                    t.completed = ((Number) comp).intValue() != 0;
                } else {
                    t.completed = Boolean.parseBoolean(comp.toString());
                }
            }
            
            t.updatedAt = getTimestamp();
            sendJson(ex, 200, todoToMap(t));
        } else if ("DELETE".equals(ex.getRequestMethod())) {
            if (!requireAuth(ex)) return;
            Integer userId = getUserId(ex);
            Todo t = getTodoById(todoId);
            if (t == null || t.userId != userId) {
                sendJsonError(ex, 404, "Todo not found");
                return;
            }
            
            synchronized (this) {
                todos.removeIf(todo -> todo.id == todoId);
            }
            
            ex.sendResponseHeaders(204, -1);
        } else {
            sendJsonError(ex, 405, "Method not allowed");
        }
    }
    
    static class Json {
        public static String stringify(Object obj) {
            if (obj == null) return "null";
            if (obj instanceof String) {
                String s = (String) obj;
                StringBuilder sb = new StringBuilder("\"");
                for (int i = 0; i < s.length(); i++) {
                    char c = s.charAt(i);
                    if (c == '"') sb.append("\\\"");
                    else if (c == '\\') sb.append("\\\\");
                    else if (c == '\n') sb.append("\\n");
                    else if (c == '\r') sb.append("\\r");
                    else if (c == '\t') sb.append("\\t");
                    else sb.append(c);
                }
                return sb.append("\"").toString();
            }
            if (obj instanceof Number || obj instanceof Boolean) return obj.toString();
            if (obj instanceof Map) {
                StringBuilder sb = new StringBuilder("{");
                boolean first = true;
                for (Map.Entry<?, ?> entry : ((Map<?, ?>) obj).entrySet()) {
                    if (!first) sb.append(",");
                    sb.append(stringify(entry.getKey())).append(":").append(stringify(entry.getValue()));
                    first = false;
                }
                return sb.append("}").toString();
            }
            if (obj instanceof List) {
                StringBuilder sb = new StringBuilder("[");
                boolean first = true;
                for (Object item : (List<?>) obj) {
                    if (!first) sb.append(",");
                    sb.append(stringify(item));
                    first = false;
                }
                return sb.append("]").toString();
            }
            return "null";
        }
    }
    
    static class JsonParser {
        private String s;
        private int pos;
        
        public JsonParser(String s) {
            this.s = s;
            this.pos = 0;
        }
        
        public Object parse() {
            skipWhitespace();
            return parseValue();
        }
        
        private void skipWhitespace() {
            while (pos < s.length() && Character.isWhitespace(s.charAt(pos))) pos++;
        }
        
        private Object parseValue() {
            skipWhitespace();
            if (pos >= s.length()) return null;
            char c = s.charAt(pos);
            if (c == '{') return parseObject();
            if (c == '[') return parseArray();
            if (c == '"') return parseString();
            if (c == 't') { pos += 4; return true; }
            if (c == 'f') { pos += 5; return false; }
            if (c == 'n') { pos += 4; return null; }
            return parseNumber();
        }
        
        private Map<String, Object> parseObject() {
            pos++;
            Map<String, Object> map = new LinkedHashMap<>();
            skipWhitespace();
            if (pos < s.length() && s.charAt(pos) == '}') {
                pos++;
                return map;
            }
            while (true) {
                skipWhitespace();
                String key = parseString();
                skipWhitespace();
                if (pos < s.length() && s.charAt(pos) == ':') pos++;
                skipWhitespace();
                Object value = parseValue();
                map.put(key, value);
                skipWhitespace();
                if (pos < s.length() && s.charAt(pos) == ',') {
                    pos++;
                } else {
                    break;
                }
            }
            skipWhitespace();
            if (pos < s.length() && s.charAt(pos) == '}') pos++;
            return map;
        }
        
        private List<Object> parseArray() {
            pos++;
            List<Object> list = new ArrayList<>();
            skipWhitespace();
            if (pos < s.length() && s.charAt(pos) == ']') {
                pos++;
                return list;
            }
            while (true) {
                skipWhitespace();
                list.add(parseValue());
                skipWhitespace();
                if (pos < s.length() && s.charAt(pos) == ',') {
                    pos++;
                } else {
                    break;
                }
            }
            skipWhitespace();
            if (pos < s.length() && s.charAt(pos) == ']') pos++;
            return list;
        }
        
        private String parseString() {
            pos++;
            StringBuilder sb = new StringBuilder();
            while (pos < s.length()) {
                char c = s.charAt(pos);
                if (c == '"') {
                    pos++;
                    return sb.toString();
                } else if (c == '\\') {
                    pos++;
                    if (pos < s.length()) {
                        char esc = s.charAt(pos);
                        if (esc == 'n') sb.append('\n');
                        else if (esc == 't') sb.append('\t');
                        else if (esc == 'r') sb.append('\r');
                        else if (esc == '\\') sb.append('\\');
                        else if (esc == '"') sb.append('"');
                        else if (esc == 'u') {
                            pos++;
                            if (pos + 4 <= s.length()) {
                                String hex = s.substring(pos, pos + 4);
                                pos += 3;
                                sb.append((char) Integer.parseInt(hex, 16));
                            }
                        } else sb.append(esc);
                        pos++;
                    }
                } else {
                    sb.append(c);
                    pos++;
                }
            }
            return sb.toString();
        }
        
        private Object parseNumber() {
            int start = pos;
            if (pos < s.length() && s.charAt(pos) == '-') pos++;
            while (pos < s.length()) {
                char c = s.charAt(pos);
                if (Character.isWhitespace(c) || c == ',' || c == '}' || c == ']') {
                    break;
                }
                pos++;
            }
            String numStr = s.substring(start, pos);
            if (numStr.contains(".") || numStr.contains("e") || numStr.contains("E")) {
                return Double.parseDouble(numStr);
            }
            return Long.parseLong(numStr);
        }
    }
}
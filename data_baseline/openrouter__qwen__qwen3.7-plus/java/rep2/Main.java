import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.time.format.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import com.sun.net.httpserver.*;

public class Main {
    static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);
    
    static String now() {
        return FORMATTER.format(Instant.now());
    }

    static Map<String, Object> mapOf(Object... args) {
        Map<String, Object> map = new LinkedHashMap<>();
        for (int i = 0; i < args.length; i += 2) {
            map.put((String) args[i], args[i + 1]);
        }
        return map;
    }

    static class User {
        int id;
        String username;
        String password;
        User(int id, String username, String password) {
            this.id = id;
            this.username = username;
            this.password = password;
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
        
        Map<String, Object> toJson() {
            Map<String, Object> map = new LinkedHashMap<>();
            map.put("id", id);
            map.put("title", title);
            map.put("description", description);
            map.put("completed", completed);
            map.put("created_at", createdAt);
            map.put("updated_at", updatedAt);
            return map;
        }
    }

    static final AtomicInteger nextUserId = new AtomicInteger(1);
    static final AtomicInteger nextTodoId = new AtomicInteger(1);
    static final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    static final Map<Integer, User> usersById = new ConcurrentHashMap<>();
    static final Map<String, Integer> sessions = new ConcurrentHashMap<>();
    static final Map<Integer, Todo> todos = new ConcurrentHashMap<>();

    static String generateToken() {
        return UUID.randomUUID().toString().replace("-", "");
    }

    static Integer getUserId(HttpExchange exchange) {
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader != null) {
            String[] cookies = cookieHeader.split(";");
            for (String cookie : cookies) {
                cookie = cookie.trim();
                if (cookie.startsWith("session_id=")) {
                    String token = cookie.substring("session_id=".length()).trim();
                    return sessions.get(token);
                }
            }
        }
        return null;
    }

    static String readBody(HttpExchange exchange) throws IOException {
        InputStream is = exchange.getRequestBody();
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        int nRead;
        byte[] data = new byte[1024];
        while ((nRead = is.read(data, 0, data.length)) != -1) {
            buffer.write(data, 0, nRead);
        }
        return buffer.toString(StandardCharsets.UTF_8.name());
    }

    static void sendJson(HttpExchange exchange, int status, Object data) throws IOException {
        String json = JsonParser.stringify(data);
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    static void sendNoContent(HttpExchange exchange, int status) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, -1);
    }

    static void handleRegister(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("POST")) {
            sendJson(exchange, 405, mapOf("error", "Method not allowed"));
            return;
        }
        String body = readBody(exchange);
        Map<String, Object> req;
        try {
            req = JsonParser.parseObject(body);
        } catch (Exception e) {
            sendJson(exchange, 400, mapOf("error", "Invalid request"));
            return;
        }
        
        Object usernameObj = req.get("username");
        Object passwordObj = req.get("password");
        
        if (!(usernameObj instanceof String) || !(passwordObj instanceof String)) {
            sendJson(exchange, 400, mapOf("error", "Invalid request"));
            return;
        }
        String username = (String) usernameObj;
        String password = (String) passwordObj;
        
        if (!username.matches("^[a-zA-Z0-9_]{3,50}$")) {
            sendJson(exchange, 400, mapOf("error", "Invalid username"));
            return;
        }
        if (password.length() < 8) {
            sendJson(exchange, 400, mapOf("error", "Password too short"));
            return;
        }
        
        synchronized (usersByUsername) {
            if (usersByUsername.containsKey(username)) {
                sendJson(exchange, 409, mapOf("error", "Username already exists"));
                return;
            }
            int id = nextUserId.getAndIncrement();
            User user = new User(id, username, password);
            usersByUsername.put(username, user);
            usersById.put(id, user);
            sendJson(exchange, 201, mapOf("id", id, "username", username));
        }
    }

    static void handleLogin(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("POST")) {
            sendJson(exchange, 405, mapOf("error", "Method not allowed"));
            return;
        }
        String body = readBody(exchange);
        Map<String, Object> req;
        try {
            req = JsonParser.parseObject(body);
        } catch (Exception e) {
            sendJson(exchange, 400, mapOf("error", "Invalid request"));
            return;
        }
        
        Object usernameObj = req.get("username");
        Object passwordObj = req.get("password");
        
        if (!(usernameObj instanceof String) || !(passwordObj instanceof String)) {
            sendJson(exchange, 401, mapOf("error", "Invalid credentials"));
            return;
        }
        
        String username = (String) usernameObj;
        String password = (String) passwordObj;
        
        User user = usersByUsername.get(username);
        if (user == null || !user.password.equals(password)) {
            sendJson(exchange, 401, mapOf("error", "Invalid credentials"));
            return;
        }
        
        String token = generateToken();
        sessions.put(token, user.id);
        
        exchange.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        sendJson(exchange, 200, mapOf("id", user.id, "username", user.username));
    }

    static void handleLogout(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("POST")) {
            sendJson(exchange, 405, mapOf("error", "Method not allowed"));
            return;
        }
        Integer userId = getUserId(exchange);
        if (userId == null) {
            sendJson(exchange, 401, mapOf("error", "Authentication required"));
            return;
        }
        
        String cookieHeader = exchange.getRequestHeaders().getFirst("Cookie");
        if (cookieHeader != null) {
            String[] cookies = cookieHeader.split(";");
            for (String cookie : cookies) {
                cookie = cookie.trim();
                if (cookie.startsWith("session_id=")) {
                    String token = cookie.substring("session_id=".length()).trim();
                    sessions.remove(token);
                }
            }
        }
        
        sendJson(exchange, 200, mapOf());
    }

    static void handleMe(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("GET")) {
            sendJson(exchange, 405, mapOf("error", "Method not allowed"));
            return;
        }
        Integer userId = getUserId(exchange);
        if (userId == null) {
            sendJson(exchange, 401, mapOf("error", "Authentication required"));
            return;
        }
        User user = usersById.get(userId);
        if (user == null) {
            sendJson(exchange, 401, mapOf("error", "Authentication required"));
            return;
        }
        sendJson(exchange, 200, mapOf("id", user.id, "username", user.username));
    }

    static void handlePassword(HttpExchange exchange) throws IOException {
        if (!exchange.getRequestMethod().equals("PUT")) {
            sendJson(exchange, 405, mapOf("error", "Method not allowed"));
            return;
        }
        Integer userId = getUserId(exchange);
        if (userId == null) {
            sendJson(exchange, 401, mapOf("error", "Authentication required"));
            return;
        }
        User user = usersById.get(userId);
        if (user == null) {
            sendJson(exchange, 401, mapOf("error", "Authentication required"));
            return;
        }
        
        String body = readBody(exchange);
        Map<String, Object> req;
        try {
            req = JsonParser.parseObject(body);
        } catch (Exception e) {
            sendJson(exchange, 400, mapOf("error", "Invalid request"));
            return;
        }
        
        Object oldPassObj = req.get("old_password");
        Object newPassObj = req.get("new_password");
        
        if (!(oldPassObj instanceof String) || !(newPassObj instanceof String)) {
            sendJson(exchange, 400, mapOf("error", "Invalid request"));
            return;
        }
        
        String oldPassword = (String) oldPassObj;
        String newPassword = (String) newPassObj;
        
        if (!user.password.equals(oldPassword)) {
            sendJson(exchange, 401, mapOf("error", "Invalid credentials"));
            return;
        }
        
        if (newPassword.length() < 8) {
            sendJson(exchange, 400, mapOf("error", "Password too short"));
            return;
        }
        
        user.password = newPassword;
        sendJson(exchange, 200, mapOf());
    }

    static void handleTodos(HttpExchange exchange) throws IOException {
        String method = exchange.getRequestMethod();
        if (method.equals("GET")) {
            Integer userId = getUserId(exchange);
            if (userId == null) {
                sendJson(exchange, 401, mapOf("error", "Authentication required"));
                return;
            }
            List<Map<String, Object>> result = new ArrayList<>();
            List<Todo> userTodos = new ArrayList<>();
            for (Todo todo : todos.values()) {
                if (todo.userId == userId) {
                    userTodos.add(todo);
                }
            }
            userTodos.sort(Comparator.comparingInt(t -> t.id));
            for (Todo todo : userTodos) {
                result.add(todo.toJson());
            }
            sendJson(exchange, 200, result);
        } else if (method.equals("POST")) {
            Integer userId = getUserId(exchange);
            if (userId == null) {
                sendJson(exchange, 401, mapOf("error", "Authentication required"));
                return;
            }
            
            String body = readBody(exchange);
            Map<String, Object> req;
            try {
                req = JsonParser.parseObject(body);
            } catch (Exception e) {
                sendJson(exchange, 400, mapOf("error", "Invalid request"));
                return;
            }
            
            Object titleObj = req.get("title");
            if (!(titleObj instanceof String) || ((String) titleObj).isEmpty()) {
                sendJson(exchange, 400, mapOf("error", "Title is required"));
                return;
            }
            
            String description = req.containsKey("description") && req.get("description") instanceof String 
                ? (String) req.get("description") 
                : "";
                
            int id = nextTodoId.getAndIncrement();
            String nowStr = now();
            Todo todo = new Todo();
            todo.id = id;
            todo.userId = userId;
            todo.title = (String) titleObj;
            todo.description = description;
            todo.completed = false;
            todo.createdAt = nowStr;
            todo.updatedAt = nowStr;
            
            todos.put(id, todo);
            sendJson(exchange, 201, todo.toJson());
        } else {
            sendJson(exchange, 405, mapOf("error", "Method not allowed"));
        }
    }

    static void handleTodoById(HttpExchange exchange, String idStr) throws IOException {
        int id;
        try {
            id = Integer.parseInt(idStr);
        } catch (NumberFormatException e) {
            sendJson(exchange, 404, mapOf("error", "Todo not found"));
            return;
        }
        
        Integer userId = getUserId(exchange);
        if (userId == null) {
            sendJson(exchange, 401, mapOf("error", "Authentication required"));
            return;
        }
        
        Todo todo = todos.get(id);
        if (todo == null || todo.userId != userId) {
            sendJson(exchange, 404, mapOf("error", "Todo not found"));
            return;
        }
        
        String method = exchange.getRequestMethod();
        if (method.equals("GET")) {
            sendJson(exchange, 200, todo.toJson());
        } else if (method.equals("PUT")) {
            String body = readBody(exchange);
            Map<String, Object> req;
            try {
                req = JsonParser.parseObject(body);
            } catch (Exception e) {
                sendJson(exchange, 400, mapOf("error", "Invalid request"));
                return;
            }
            
            if (req.containsKey("title")) {
                Object titleObj = req.get("title");
                if (!(titleObj instanceof String) || ((String) titleObj).isEmpty()) {
                    sendJson(exchange, 400, mapOf("error", "Title is required"));
                    return;
                }
                todo.title = (String) titleObj;
            }
            
            if (req.containsKey("description")) {
                todo.description = req.get("description") instanceof String ? (String) req.get("description") : "";
            }
            
            if (req.containsKey("completed")) {
                todo.completed = req.get("completed") instanceof Boolean ? (Boolean) req.get("completed") : false;
            }
            
            todo.updatedAt = now();
            sendJson(exchange, 200, todo.toJson());
        } else if (method.equals("DELETE")) {
            todos.remove(id);
            sendNoContent(exchange, 204);
        } else {
            sendJson(exchange, 405, mapOf("error", "Method not allowed"));
        }
    }

    static class JsonParser {
        static Map<String, Object> parseObject(String s) {
            Map<String, Object> res = new LinkedHashMap<>();
            s = s.trim();
            if (s.isEmpty() || s.equals("{}")) return res;
            if (!s.startsWith("{") || !s.endsWith("}")) throw new RuntimeException("Invalid JSON");
            s = s.substring(1, s.length() - 1).trim();
            
            int i = 0;
            while (i < s.length()) {
                while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
                if (i >= s.length()) break;
                
                if (s.charAt(i) != '"') throw new RuntimeException("Expected '\"' at " + i);
                i++;
                int keyStart = i;
                while (i < s.length() && s.charAt(i) != '"') {
                    if (s.charAt(i) == '\\') i++;
                    i++;
                }
                String key = unescape(s.substring(keyStart, i));
                i++; 
                
                while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
                if (i >= s.length() || s.charAt(i) != ':') throw new RuntimeException("Expected ':'");
                i++;
                
                while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
                
                Object value;
                if (i < s.length() && s.charAt(i) == '"') {
                    i++;
                    int valStart = i;
                    while (i < s.length() && s.charAt(i) != '"') {
                        if (s.charAt(i) == '\\') i++;
                        i++;
                    }
                    value = unescape(s.substring(valStart, i));
                    i++;
                } else if (s.startsWith("true", i)) {
                    value = true;
                    i += 4;
                } else if (s.startsWith("false", i)) {
                    value = false;
                    i += 5;
                } else if (s.startsWith("null", i)) {
                    value = null;
                    i += 4;
                } else {
                    int valStart = i;
                    while (i < s.length() && s.charAt(i) != ',' && s.charAt(i) != '}') i++;
                    String numStr = s.substring(valStart, i).trim();
                    if (numStr.isEmpty()) {
                        value = null;
                    } else if (numStr.contains(".") || numStr.toLowerCase().contains("e")) {
                        value = Double.parseDouble(numStr);
                    } else {
                        value = Long.parseLong(numStr);
                    }
                }
                
                res.put(key, value);
                
                while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
                if (i < s.length() && s.charAt(i) == ',') {
                    i++;
                }
            }
            return res;
        }
        
        static String unescape(String s) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c == '\\' && i + 1 < s.length()) {
                    char next = s.charAt(i + 1);
                    if (next == '"') { sb.append('"'); i++; }
                    else if (next == '\\') { sb.append('\\'); i++; }
                    else if (next == 'n') { sb.append('\n'); i++; }
                    else if (next == 'r') { sb.append('\r'); i++; }
                    else if (next == 't') { sb.append('\t'); i++; }
                    else { sb.append(c); }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }
        
        static String stringify(Object obj) {
            if (obj instanceof Map) {
                StringBuilder sb = new StringBuilder("{");
                boolean first = true;
                for (Map.Entry<?, ?> entry : ((Map<?, ?>) obj).entrySet()) {
                    if (!first) sb.append(",");
                    first = false;
                    sb.append("\"").append(escape(entry.getKey().toString())).append("\":");
                    sb.append(stringify(entry.getValue()));
                }
                sb.append("}");
                return sb.toString();
            } else if (obj instanceof List) {
                StringBuilder sb = new StringBuilder("[");
                boolean first = true;
                for (Object item : (List<?>) obj) {
                    if (!first) sb.append(",");
                    first = false;
                    sb.append(stringify(item));
                }
                sb.append("]");
                return sb.toString();
            } else if (obj instanceof String) {
                return "\"" + escape((String) obj) + "\"";
            } else if (obj instanceof Boolean) {
                return obj.toString();
            } else if (obj instanceof Number) {
                return obj.toString();
            } else if (obj == null) {
                return "null";
            } else {
                return "\"" + escape(obj.toString()) + "\"";
            }
        }
        
        static String escape(String s) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c == '"') sb.append("\\\"");
                else if (c == '\\') sb.append("\\\\");
                else if (c == '\n') sb.append("\\n");
                else if (c == '\r') sb.append("\\r");
                else if (c == '\t') sb.append("\\t");
                else sb.append(c);
            }
            return sb.toString();
        }
    }

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--port") && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
            }
        }
        
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        
        server.createContext("/register", Main::handleRegister);
        server.createContext("/login", Main::handleLogin);
        server.createContext("/logout", Main::handleLogout);
        server.createContext("/me", Main::handleMe);
        server.createContext("/password", Main::handlePassword);
        server.createContext("/todos", exchange -> {
            String path = exchange.getRequestURI().getPath();
            if (path.equals("/todos")) {
                if (exchange.getRequestMethod().equals("GET")) handleTodos(exchange);
                else if (exchange.getRequestMethod().equals("POST")) handleTodos(exchange);
                else sendJson(exchange, 405, mapOf("error", "Method not allowed"));
            } else if (path.startsWith("/todos/")) {
                String idStr = path.substring(7);
                handleTodoById(exchange, idStr);
            } else {
                sendJson(exchange, 404, mapOf("error", "Not found"));
            }
        });
        
        server.setExecutor(Executors.newFixedThreadPool(10));
        server.start();
        System.out.println("Server started on port " + port);
    }
}
import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;

public class Server {
    // Data models
    static class User {
        int id;
        String username;
        String password; // store in plaintext for this exercise (in-memory); in real world, hash it.
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

    // In-memory stores
    private static final Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    private static final Map<Integer, User> usersById = new ConcurrentHashMap<>();
    private static final Map<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId

    private static final Map<Integer, Todo> todosById = new ConcurrentHashMap<>();
    private static final Map<Integer, List<Integer>> userTodoIds = new ConcurrentHashMap<>();

    private static final Object USER_ID_LOCK = new Object();
    private static final Object TODO_ID_LOCK = new Object();
    private static int nextUserId = 1;
    private static int nextTodoId = 1;

    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");

    private static final DateTimeFormatter ISO_INSTANT_SECONDS = DateTimeFormatter.ISO_INSTANT;

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i + 1]);
                i++;
            }
        }
        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer server = HttpServer.create(addr, 0);
        server.createContext("/", new RootHandler());
        server.setExecutor(Executors.newCachedThreadPool());
        System.out.println("Server listening on 0.0.0.0:" + port);
        server.start();
    }

    static class RootHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            try {
                String method = exchange.getRequestMethod();
                URI uri = exchange.getRequestURI();
                String path = uri.getPath();

                if (path.equals("/register") && method.equals("POST")) {
                    handleRegister(exchange);
                    return;
                }
                if (path.equals("/login") && method.equals("POST")) {
                    handleLogin(exchange);
                    return;
                }
                if (path.equals("/logout") && method.equals("POST")) {
                    handleLogout(exchange);
                    return;
                }
                if (path.equals("/me") && method.equals("GET")) {
                    handleMe(exchange);
                    return;
                }
                if (path.equals("/password") && method.equals("PUT")) {
                    handlePassword(exchange);
                    return;
                }
                if (path.equals("/todos") && method.equals("GET")) {
                    handleTodosList(exchange);
                    return;
                }
                if (path.equals("/todos") && method.equals("POST")) {
                    handleTodosCreate(exchange);
                    return;
                }
                if (path.startsWith("/todos/") && method.equals("GET")) {
                    handleTodosGet(exchange, path);
                    return;
                }
                if (path.startsWith("/todos/") && method.equals("PUT")) {
                    handleTodosUpdate(exchange, path);
                    return;
                }
                if (path.startsWith("/todos/") && method.equals("DELETE")) {
                    handleTodosDelete(exchange, path);
                    return;
                }

                // Not found for other routes
                sendJson(exchange, 404, jsonError("Not found"));
            } catch (Exception e) {
                // Internal Server Error
                e.printStackTrace();
                sendJson(exchange, 500, jsonError("Internal server error"));
            } finally {
                // ensure request body is fully consumed
                try { exchange.getRequestBody().close(); } catch (Exception ignore) {}
            }
        }
    }

    // Handlers
    private static void handleRegister(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Map<String, String> fields = parseJsonObjectStrings(body);
        String username = fields.get("username");
        String password = fields.get("password");

        if (username == null || !USERNAME_PATTERN.matcher(username).matches()) {
            sendJson(ex, 400, jsonError("Invalid username"));
            return;
        }
        if (password == null || password.length() < 8) {
            sendJson(ex, 400, jsonError("Password too short"));
            return;
        }
        synchronized (usersByUsername) {
            if (usersByUsername.containsKey(username)) {
                sendJson(ex, 409, jsonError("Username already exists"));
                return;
            }
            int id;
            synchronized (USER_ID_LOCK) {
                id = nextUserId++;
            }
            User user = new User(id, username, password);
            usersByUsername.put(username, user);
            usersById.put(id, user);
            String resp = "{" +
                    "\"id\":" + id + "," +
                    "\"username\":\"" + escapeJson(username) + "\"" +
                    "}";
            sendJson(ex, 201, resp);
        }
    }

    private static void handleLogin(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        Map<String, String> fields = parseJsonObjectStrings(body);
        String username = fields.get("username");
        String password = fields.get("password");
        if (username == null || password == null) {
            sendJson(ex, 401, jsonError("Invalid credentials"));
            return;
        }
        User user = usersByUsername.get(username);
        if (user == null || !Objects.equals(user.password, password)) {
            sendJson(ex, 401, jsonError("Invalid credentials"));
            return;
        }
        String token = UUID.randomUUID().toString().replace("-", "");
        sessions.put(token, user.id);
        // Set-Cookie header
        ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        String resp = "{" +
                "\"id\":" + user.id + "," +
                "\"username\":\"" + escapeJson(user.username) + "\"" +
                "}";
        sendJson(ex, 200, resp);
    }

    private static void handleLogout(HttpExchange ex) throws IOException {
        Integer userId = authenticate(ex);
        if (userId == null) return; // authenticate already sent 401
        String token = getCookie(ex, "session_id");
        if (token != null) {
            sessions.remove(token);
        }
        sendJson(ex, 200, "{}");
    }

    private static void handleMe(HttpExchange ex) throws IOException {
        Integer userId = authenticate(ex);
        if (userId == null) return;
        User user = usersById.get(userId);
        String resp = "{" +
                "\"id\":" + user.id + "," +
                "\"username\":\"" + escapeJson(user.username) + "\"" +
                "}";
        sendJson(ex, 200, resp);
    }

    private static void handlePassword(HttpExchange ex) throws IOException {
        Integer userId = authenticate(ex);
        if (userId == null) return;
        String body = readBody(ex);
        Map<String, String> fields = parseJsonObjectStrings(body);
        String oldPassword = fields.get("old_password");
        String newPassword = fields.get("new_password");
        User user = usersById.get(userId);
        if (oldPassword == null || !Objects.equals(user.password, oldPassword)) {
            sendJson(ex, 401, jsonError("Invalid credentials"));
            return;
        }
        if (newPassword == null || newPassword.length() < 8) {
            sendJson(ex, 400, jsonError("Password too short"));
            return;
        }
        user.password = newPassword;
        sendJson(ex, 200, "{}");
    }

    private static void handleTodosList(HttpExchange ex) throws IOException {
        Integer userId = authenticate(ex);
        if (userId == null) return;
        List<Integer> ids = userTodoIds.getOrDefault(userId, Collections.emptyList());
        // ensure ascending order
        List<Integer> sorted = new ArrayList<>(ids);
        Collections.sort(sorted);
        StringBuilder sb = new StringBuilder();
        sb.append("[");
        boolean first = true;
        for (Integer id : sorted) {
            Todo t = todosById.get(id);
            if (t == null) continue;
            if (!first) sb.append(",");
            first = false;
            sb.append(todoToJson(t));
        }
        sb.append("]");
        sendJson(ex, 200, sb.toString());
    }

    private static void handleTodosCreate(HttpExchange ex) throws IOException {
        Integer userId = authenticate(ex);
        if (userId == null) return;
        String body = readBody(ex);
        Map<String, String> fields = parseJsonObjectStrings(body);
        String title = fields.get("title");
        String description = fields.getOrDefault("description", "");
        if (title == null || title.trim().isEmpty()) {
            sendJson(ex, 400, jsonError("Title is required"));
            return;
        }
        int id;
        synchronized (TODO_ID_LOCK) {
            id = nextTodoId++;
        }
        String now = ISO_INSTANT_SECONDS.format(Instant.now().truncatedTo(ChronoUnit.SECONDS));
        Todo todo = new Todo(id, userId, title, description == null ? "" : description, false, now, now);
        todosById.put(id, todo);
        userTodoIds.computeIfAbsent(userId, k -> Collections.synchronizedList(new ArrayList<>())).add(id);
        sendJson(ex, 201, todoToJson(todo));
    }

    private static void handleTodosGet(HttpExchange ex, String path) throws IOException {
        Integer userId = authenticate(ex);
        if (userId == null) return;
        Integer id = parseTodoId(path);
        if (id == null) {
            sendJson(ex, 404, jsonError("Todo not found"));
            return;
        }
        Todo t = todosById.get(id);
        if (t == null || t.userId != userId) {
            sendJson(ex, 404, jsonError("Todo not found"));
            return;
        }
        sendJson(ex, 200, todoToJson(t));
    }

    private static void handleTodosUpdate(HttpExchange ex, String path) throws IOException {
        Integer userId = authenticate(ex);
        if (userId == null) return;
        Integer id = parseTodoId(path);
        if (id == null) {
            sendJson(ex, 404, jsonError("Todo not found"));
            return;
        }
        Todo t = todosById.get(id);
        if (t == null || t.userId != userId) {
            sendJson(ex, 404, jsonError("Todo not found"));
            return;
        }
        String body = readBody(ex);
        Map<String, String> strFields = parseJsonObjectStrings(body);
        Boolean completed = parseJsonBooleanField(body, "completed");
        if (strFields.containsKey("title")) {
            String title = strFields.get("title");
            if (title == null || title.trim().isEmpty()) {
                sendJson(ex, 400, jsonError("Title is required"));
                return;
            }
            t.title = title;
        }
        if (strFields.containsKey("description")) {
            t.description = strFields.get("description") == null ? "" : strFields.get("description");
        }
        if (completed != null) {
            t.completed = completed.booleanValue();
        }
        t.updatedAt = ISO_INSTANT_SECONDS.format(Instant.now().truncatedTo(ChronoUnit.SECONDS));
        sendJson(ex, 200, todoToJson(t));
    }

    private static void handleTodosDelete(HttpExchange ex, String path) throws IOException {
        Integer userId = authenticate(ex);
        if (userId == null) return;
        Integer id = parseTodoId(path);
        if (id == null) {
            sendStatusNoBody(ex, 404);
            return;
        }
        Todo t = todosById.get(id);
        if (t == null || t.userId != userId) {
            sendStatusNoBody(ex, 404);
            return;
        }
        todosById.remove(id);
        List<Integer> ids = userTodoIds.get(userId);
        if (ids != null) ids.remove(Integer.valueOf(id));
        sendStatusNoBody(ex, 204);
    }

    // Helpers
    private static Integer authenticate(HttpExchange ex) throws IOException {
        String token = getCookie(ex, "session_id");
        if (token == null) {
            sendJson(ex, 401, jsonError("Authentication required"));
            return null;
        }
        Integer userId = sessions.get(token);
        if (userId == null) {
            sendJson(ex, 401, jsonError("Authentication required"));
            return null;
        }
        return userId;
    }

    private static String getCookie(HttpExchange ex, String name) {
        List<String> cookies = ex.getRequestHeaders().get("Cookie");
        if (cookies == null) return null;
        for (String header : cookies) {
            String[] parts = header.split(";\\s*");
            for (String part : parts) {
                int eq = part.indexOf('=');
                if (eq > 0) {
                    String k = part.substring(0, eq).trim();
                    String v = part.substring(eq + 1).trim();
                    if (k.equals(name)) return v;
                }
            }
        }
        return null;
    }

    private static Integer parseTodoId(String path) {
        // path like /todos/123
        String[] parts = path.split("/");
        if (parts.length != 3) return null;
        try {
            return Integer.parseInt(parts[2]);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static String todoToJson(Todo t) {
        StringBuilder sb = new StringBuilder();
        sb.append("{");
        sb.append("\"id\":").append(t.id).append(",");
        sb.append("\"title\":\"").append(escapeJson(t.title)).append("\",");
        sb.append("\"description\":\"").append(escapeJson(t.description == null ? "" : t.description)).append("\",");
        sb.append("\"completed\":").append(t.completed ? "true" : "false").append(",");
        sb.append("\"created_at\":\"").append(escapeJson(t.createdAt)).append("\",");
        sb.append("\"updated_at\":\"").append(escapeJson(t.updatedAt)).append("\"");
        sb.append("}");
        return sb.toString();
    }

    private static void sendJson(HttpExchange ex, int status, String body) throws IOException {
        if (body == null) body = "";
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        Headers h = ex.getResponseHeaders();
        h.set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static void sendStatusNoBody(HttpExchange ex, int status) throws IOException {
        ex.sendResponseHeaders(status, -1);
        try (OutputStream os = ex.getResponseBody()) {
            // no body
        }
    }

    private static String jsonError(String msg) {
        return "{\"error\":\"" + escapeJson(msg) + "\"}";
    }

    private static String readBody(HttpExchange ex) throws IOException {
        try (InputStream is = ex.getRequestBody()) {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int r;
            while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
            return baos.toString(StandardCharsets.UTF_8);
        }
    }

    // Minimal JSON field parsing for string values at the top level
    private static Map<String, String> parseJsonObjectStrings(String json) {
        Map<String, String> map = new HashMap<>();
        if (json == null) return map;
        // Find pairs of "key" : "value" OR "key": null OR booleans etc. For strings only, we capture the value.
        Pattern p = Pattern.compile("\\\"(.*?)\\\"\\s*:\\s*(\\\"(.*?)\\\"|null|true|false|[0-9.+-]+)", Pattern.DOTALL);
        Matcher m = p.matcher(json);
        while (m.find()) {
            String key = m.group(1);
            String rawVal = m.group(2);
            String strVal = null;
            if (rawVal != null && rawVal.startsWith("\"")) {
                strVal = unescapeJson(rawVal.substring(1, rawVal.length() - 1));
            }
            map.put(key, strVal);
        }
        return map;
    }

    private static Boolean parseJsonBooleanField(String json, String key) {
        if (json == null) return null;
        Pattern p = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*(true|false)", Pattern.CASE_INSENSITIVE);
        Matcher m = p.matcher(json);
        if (m.find()) {
            return Boolean.parseBoolean(m.group(1));
        }
        return null;
    }

    private static String escapeJson(String s) {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) {
                        String hex = Integer.toHexString(c);
                        sb.append("\\u");
                        for (int j = hex.length(); j < 4; j++) sb.append('0');
                        sb.append(hex);
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.toString();
    }

    private static String unescapeJson(String s) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' && i + 1 < s.length()) {
                char n = s.charAt(i + 1);
                switch (n) {
                    case '"': sb.append('"'); i++; break;
                    case '\\': sb.append('\\'); i++; break;
                    case '/': sb.append('/'); i++; break;
                    case 'b': sb.append('\b'); i++; break;
                    case 'f': sb.append('\f'); i++; break;
                    case 'n': sb.append('\n'); i++; break;
                    case 'r': sb.append('\r'); i++; break;
                    case 't': sb.append('\t'); i++; break;
                    case 'u':
                        if (i + 5 < s.length()) {
                            String hex = s.substring(i + 2, i + 6);
                            try {
                                int cp = Integer.parseInt(hex, 16);
                                sb.append((char) cp);
                                i += 5;
                            } catch (NumberFormatException e) {
                                sb.append('u');
                                i++;
                            }
                        } else {
                            sb.append('u');
                            i++;
                        }
                        break;
                    default:
                        sb.append(n);
                        i++;
                        break;
                }
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }
}

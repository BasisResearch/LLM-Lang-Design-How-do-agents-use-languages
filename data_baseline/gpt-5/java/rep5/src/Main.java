import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.*;

public class Main {
    public static void main(String[] args) throws Exception {
        int port = parsePort(args);
        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer server = HttpServer.create(addr, 0);
        server.createContext("/", new Router());
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server started on 0.0.0.0:" + port);
    }

    private static int parsePort(String[] args) {
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                try {
                    return Integer.parseInt(args[i + 1]);
                } catch (NumberFormatException e) {
                    throw new IllegalArgumentException("Invalid port");
                }
            }
        }
        throw new IllegalArgumentException("Usage: --port PORT");
    }
}

class Router implements HttpHandler {
    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");

    public void handle(HttpExchange ex) throws IOException {
        String method = ex.getRequestMethod();
        String path = ex.getRequestURI().getPath();
        try {
            if (path.equals("/register")) {
                if (!method.equals("POST")) { methodNotAllowed(ex, Arrays.asList("POST")); return; }
                handleRegister(ex);
                return;
            } else if (path.equals("/login")) {
                if (!method.equals("POST")) { methodNotAllowed(ex, Arrays.asList("POST")); return; }
                handleLogin(ex);
                return;
            } else if (path.equals("/logout")) {
                if (!method.equals("POST")) { methodNotAllowed(ex, Arrays.asList("POST")); return; }
                User u = requireAuth(ex); if (u == null) return; // response already sent
                handleLogout(ex, u);
                return;
            } else if (path.equals("/me")) {
                if (!method.equals("GET")) { methodNotAllowed(ex, Arrays.asList("GET")); return; }
                User u = requireAuth(ex); if (u == null) return;
                sendJson(ex, 200, userToJson(u));
                return;
            } else if (path.equals("/password")) {
                if (!method.equals("PUT")) { methodNotAllowed(ex, Arrays.asList("PUT")); return; }
                User u = requireAuth(ex); if (u == null) return;
                handlePasswordChange(ex, u);
                return;
            } else if (path.equals("/todos")) {
                if (method.equals("GET")) {
                    User u = requireAuth(ex); if (u == null) return;
                    handleTodosList(ex, u);
                    return;
                } else if (method.equals("POST")) {
                    User u = requireAuth(ex); if (u == null) return;
                    handleTodosCreate(ex, u);
                    return;
                } else {
                    methodNotAllowed(ex, Arrays.asList("GET","POST")); return;
                }
            } else if (path.startsWith("/todos/")) {
                String idStr = path.substring("/todos/".length());
                Integer id = parseId(idStr);
                if (id == null) { sendJson(ex, 404, errorJson("Todo not found")); return; }
                if (method.equals("GET")) {
                    User u = requireAuth(ex); if (u == null) return;
                    handleTodoGet(ex, u, id);
                    return;
                } else if (method.equals("PUT")) {
                    User u = requireAuth(ex); if (u == null) return;
                    handleTodoUpdate(ex, u, id);
                    return;
                } else if (method.equals("DELETE")) {
                    User u = requireAuth(ex); if (u == null) return;
                    handleTodoDelete(ex, u, id);
                    return;
                } else {
                    methodNotAllowed(ex, Arrays.asList("GET","PUT","DELETE")); return;
                }
            } else {
                sendJson(ex, 404, errorJson("Not found"));
                return;
            }
        } catch (BadRequestException bre) {
            sendJson(ex, 400, errorJson(bre.getMessage()));
        } catch (UnauthorizedException ue) {
            sendJson(ex, 401, errorJson(ue.getMessage()));
        } catch (ConflictException ce) {
            sendJson(ex, 409, errorJson(ce.getMessage()));
        } catch (Exception e) {
            e.printStackTrace();
            sendJson(ex, 500, errorJson("Internal server error"));
        }
    }

    private void handleRegister(HttpExchange ex) throws IOException {
        Map<String,Object> body = readJsonObject(ex);
        String username = asString(body.get("username"));
        String password = asString(body.get("password"));
        if (username == null || !USERNAME_PATTERN.matcher(username).matches()) {
            throw new BadRequestException("Invalid username");
        }
        if (password == null) {
            throw new BadRequestException("Password too short");
        }
        if (password.length() < 8) {
            throw new BadRequestException("Password too short");
        }
        User u = DataStore.createUser(username, password);
        sendJson(ex, 201, userToJson(u));
    }

    private void handleLogin(HttpExchange ex) throws IOException {
        Map<String,Object> body = readJsonObject(ex);
        String username = asString(body.get("username"));
        String password = asString(body.get("password"));
        if (username == null || password == null) {
            throw new UnauthorizedException("Invalid credentials");
        }
        User u = DataStore.getUserByUsername(username);
        if (u == null || !u.password.equals(password)) {
            throw new UnauthorizedException("Invalid credentials");
        }
        String token = DataStore.createSession(u.id);
        ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        sendJson(ex, 200, userToJson(u));
    }

    private void handleLogout(HttpExchange ex, User u) throws IOException {
        String token = getSessionTokenFromRequest(ex);
        if (token != null) {
            DataStore.invalidateSession(token);
        }
        sendJson(ex, 200, new LinkedHashMap<>());
    }

    private void handlePasswordChange(HttpExchange ex, User u) throws IOException {
        Map<String,Object> body = readJsonObject(ex);
        String oldp = asString(body.get("old_password"));
        String newp = asString(body.get("new_password"));
        if (oldp == null || !oldp.equals(u.password)) {
            throw new UnauthorizedException("Invalid credentials");
        }
        if (newp == null || newp.length() < 8) {
            throw new BadRequestException("Password too short");
        }
        u.password = newp;
        sendJson(ex, 200, new LinkedHashMap<>());
    }

    private void handleTodosList(HttpExchange ex, User u) throws IOException {
        List<Todo> list = DataStore.getTodosByUser(u.id);
        // sort by id ascending
        list.sort(Comparator.comparingInt(t -> t.id));
        List<Object> arr = new ArrayList<>();
        for (Todo t : list) arr.add(todoToJsonObj(t));
        sendJson(ex, 200, arr);
    }

    private void handleTodosCreate(HttpExchange ex, User u) throws IOException {
        Map<String,Object> body = readJsonObject(ex);
        String title = asString(body.get("title"));
        if (title == null || title.trim().isEmpty()) {
            throw new BadRequestException("Title is required");
        }
        String description = asString(body.get("description"));
        if (description == null) description = "";
        Todo t = DataStore.createTodo(u.id, title, description);
        sendJson(ex, 201, todoToJsonObj(t));
    }

    private void handleTodoGet(HttpExchange ex, User u, int id) throws IOException {
        Todo t = DataStore.getTodo(id);
        if (t == null || t.userId != u.id) { sendJson(ex, 404, errorJson("Todo not found")); return; }
        sendJson(ex, 200, todoToJsonObj(t));
    }

    private void handleTodoUpdate(HttpExchange ex, User u, int id) throws IOException {
        Todo t = DataStore.getTodo(id);
        if (t == null || t.userId != u.id) { sendJson(ex, 404, errorJson("Todo not found")); return; }
        Map<String,Object> body = readJsonObject(ex);
        boolean modified = false;
        if (body.containsKey("title")) {
            String title = asString(body.get("title"));
            if (title == null || title.trim().isEmpty()) {
                throw new BadRequestException("Title is required");
            }
            t.title = title;
            modified = true;
        }
        if (body.containsKey("description")) {
            String description = asString(body.get("description"));
            if (description == null) description = "";
            t.description = description;
            modified = true;
        }
        if (body.containsKey("completed")) {
            Boolean completed = asBoolean(body.get("completed"));
            if (completed == null) {
                throw new BadRequestException("Invalid JSON");
            }
            t.completed = completed.booleanValue();
            modified = true;
        }
        if (modified) {
            t.updatedAt = nowIso();
        }
        sendJson(ex, 200, todoToJsonObj(t));
    }

    private void handleTodoDelete(HttpExchange ex, User u, int id) throws IOException {
        Todo t = DataStore.getTodo(id);
        if (t == null || t.userId != u.id) { sendJson(ex, 404, errorJson("Todo not found")); return; }
        DataStore.deleteTodo(id);
        sendNoContent(ex);
    }

    private static Map<String,Object> userToJson(User u) {
        Map<String,Object> m = new LinkedHashMap<>();
        m.put("id", u.id);
        m.put("username", u.username);
        return m;
    }

    private static Map<String,Object> todoToJsonObj(Todo t) {
        Map<String,Object> m = new LinkedHashMap<>();
        m.put("id", t.id);
        m.put("title", t.title);
        m.put("description", t.description);
        m.put("completed", t.completed);
        m.put("created_at", t.createdAt);
        m.put("updated_at", t.updatedAt);
        return m;
    }

    private User requireAuth(HttpExchange ex) throws IOException {
        String token = getSessionTokenFromRequest(ex);
        if (token == null) {
            sendJson(ex, 401, errorJson("Authentication required"));
            return null;
        }
        Integer uid = DataStore.getUserIdBySession(token);
        if (uid == null) {
            sendJson(ex, 401, errorJson("Authentication required"));
            return null;
        }
        User u = DataStore.getUserById(uid);
        if (u == null) {
            sendJson(ex, 401, errorJson("Authentication required"));
            return null;
        }
        return u;
    }

    private String getSessionTokenFromRequest(HttpExchange ex) {
        List<String> cookieHeaders = ex.getRequestHeaders().get("Cookie");
        if (cookieHeaders == null) return null;
        for (String h : cookieHeaders) {
            String[] parts = h.split(";\\s*");
            for (String p : parts) {
                int eq = p.indexOf('=');
                if (eq > 0) {
                    String name = p.substring(0, eq).trim();
                    String val = p.substring(eq + 1).trim();
                    if (name.equals("session_id")) {
                        return val;
                    }
                }
            }
        }
        return null;
    }

    private static Integer parseId(String s) {
        try {
            if (s == null || s.isEmpty()) return null;
            // avoid paths with slashes after id
            if (s.contains("/")) return null;
            return Integer.parseInt(s);
        } catch (NumberFormatException e) { return null; }
    }

    private Map<String,Object> readJsonObject(HttpExchange ex) throws IOException {
        String body = readRequestBody(ex);
        Object parsed;
        try {
            parsed = Json.parse(body);
        } catch (RuntimeException re) {
            throw new BadRequestException("Invalid JSON");
        }
        if (!(parsed instanceof Map)) {
            throw new BadRequestException("Invalid JSON");
        }
        @SuppressWarnings("unchecked")
        Map<String,Object> map = (Map<String,Object>) parsed;
        return map;
    }

    private static String readRequestBody(HttpExchange ex) throws IOException {
        InputStream is = ex.getRequestBody();
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = is.read(buf)) != -1) baos.write(buf,0,n);
        return baos.toString(StandardCharsets.UTF_8);
    }

    private static void sendJson(HttpExchange ex, int status, Object obj) throws IOException {
        byte[] data = Json.stringify(obj).getBytes(StandardCharsets.UTF_8);
        Headers h = ex.getResponseHeaders();
        h.set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, data.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(data);
        }
    }

    private static void sendNoContent(HttpExchange ex) throws IOException {
        ex.sendResponseHeaders(204, -1); // no body
        ex.close();
    }

    private static Map<String,Object> errorJson(String msg) {
        Map<String,Object> m = new LinkedHashMap<>();
        m.put("error", msg);
        return m;
    }

    private static String nowIso() {
        return Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
    }

    private static String asString(Object o) {
        return (o instanceof String) ? (String) o : null;
    }

    private static Boolean asBoolean(Object o) {
        return (o instanceof Boolean) ? (Boolean) o : null;
    }

    private static void methodNotAllowed(HttpExchange ex, List<String> allow) throws IOException {
        ex.getResponseHeaders().set("Allow", String.join(", ", allow));
        sendJson(ex, 405, errorJson("Method not allowed"));
    }
}

class User {
    public final int id;
    public final String username;
    public String password;
    public User(int id, String username, String password) {
        this.id = id; this.username = username; this.password = password;
    }
}

class Todo {
    public final int id;
    public final int userId;
    public String title;
    public String description;
    public boolean completed;
    public String createdAt;
    public String updatedAt;

    public Todo(int id, int userId, String title, String description, boolean completed, String createdAt, String updatedAt) {
        this.id = id; this.userId = userId; this.title = title; this.description = description; this.completed = completed; this.createdAt = createdAt; this.updatedAt = updatedAt;
    }
}

class DataStore {
    private static final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, User> usersByUsername = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>();
    private static final AtomicInteger nextUserId = new AtomicInteger(1);
    private static final AtomicInteger nextTodoId = new AtomicInteger(1);

    public static User createUser(String username, String password) {
        // Ensure uniqueness
        synchronized (usersByUsername) {
            if (usersByUsername.containsKey(username)) {
                throw new ConflictException("Username already exists");
            }
            int id = nextUserId.getAndIncrement();
            User u = new User(id, username, password);
            usersById.put(id, u);
            usersByUsername.put(username, u);
            return u;
        }
    }

    public static User getUserById(int id) { return usersById.get(id); }
    public static User getUserByUsername(String username) { return usersByUsername.get(username); }

    public static String createSession(int userId) {
        String token = UUID.randomUUID().toString().replace("-", "");
        sessions.put(token, userId);
        return token;
    }

    public static Integer getUserIdBySession(String token) { return sessions.get(token); }
    public static void invalidateSession(String token) { sessions.remove(token); }

    public static Todo createTodo(int userId, String title, String description) {
        int id = nextTodoId.getAndIncrement();
        String now = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
        Todo t = new Todo(id, userId, title, description, false, now, now);
        todosById.put(id, t);
        return t;
    }

    public static Todo getTodo(int id) { return todosById.get(id); }

    public static void deleteTodo(int id) { todosById.remove(id); }

    public static List<Todo> getTodosByUser(int userId) {
        List<Todo> res = new ArrayList<>();
        for (Todo t : todosById.values()) if (t.userId == userId) res.add(t);
        return res;
    }
}

class BadRequestException extends RuntimeException { public BadRequestException(String m){super(m);} }
class UnauthorizedException extends RuntimeException { public UnauthorizedException(String m){super(m);} }
class ConflictException extends RuntimeException { public ConflictException(String m){super(m);} }

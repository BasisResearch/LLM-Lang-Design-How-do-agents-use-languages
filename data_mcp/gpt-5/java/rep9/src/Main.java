import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import com.google.gson.*;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;

public class Main {
    // Data models
    static class User {
        final int id;
        final String username;
        String password; // stored as plain for simplicity in this in-memory demo
        User(int id, String username, String password) {
            this.id = id; this.username = username; this.password = password;
        }
    }
    static class Todo {
        final int id;
        final int userId;
        String title;
        String description;
        boolean completed;
        String created_at;
        String updated_at;
        Todo(int id, int userId, String title, String description, boolean completed, String ts) {
            this.id = id; this.userId = userId; this.title = title; this.description = description;
            this.completed = completed; this.created_at = ts; this.updated_at = ts;
        }
    }

    static class State {
        final ConcurrentHashMap<Integer, User> usersById = new ConcurrentHashMap<>();
        final ConcurrentHashMap<String, Integer> userIdByUsername = new ConcurrentHashMap<>();
        final ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>();
        final ConcurrentHashMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
        final AtomicInteger userIdSeq = new AtomicInteger(0);
        final AtomicInteger todoIdSeq = new AtomicInteger(0);
    }

    static final Gson gson = new GsonBuilder().disableHtmlEscaping().create();
    static final Pattern USERNAME_RE = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if ("--port".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[i+1]);
                i++;
            }
        }
        State state = new State();
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/", new Router(state));
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server listening on 0.0.0.0:" + port);
    }

    static class Router implements HttpHandler {
        private final State state;
        Router(State state) { this.state = state; }
        @Override public void handle(HttpExchange ex) throws IOException {
            try {
                String method = ex.getRequestMethod();
                URI uri = ex.getRequestURI();
                String path = uri.getPath();

                // Normalize: remove trailing slash except root
                if (path.length() > 1 && path.endsWith("/")) {
                    path = path.substring(0, path.length()-1);
                }

                if (method.equals("POST") && path.equals("/register")) { handleRegister(ex, state); return; }
                if (method.equals("POST") && path.equals("/login")) { handleLogin(ex, state); return; }
                if (method.equals("POST") && path.equals("/logout")) { handleLogout(ex, state); return; }
                if (method.equals("GET") && path.equals("/me")) { handleMe(ex, state); return; }
                if (method.equals("PUT") && path.equals("/password")) { handlePassword(ex, state); return; }
                if (path.equals("/todos")) {
                    if (method.equals("GET")) { handleTodosList(ex, state); return; }
                    if (method.equals("POST")) { handleTodosCreate(ex, state); return; }
                }
                if (path.startsWith("/todos/")) {
                    String idStr = path.substring("/todos/".length());
                    Integer id = parseId(idStr);
                    if (id == null) {
                        sendError(ex, 404, "Not found");
                        return;
                    }
                    if (method.equals("GET")) { handleTodosGet(ex, state, id); return; }
                    if (method.equals("PUT")) { handleTodosUpdate(ex, state, id); return; }
                    if (method.equals("DELETE")) { handleTodosDelete(ex, state, id); return; }
                }
                sendError(ex, 404, "Not found");
            } catch (Exception e) {
                // Log and return 500
                e.printStackTrace();
                sendError(ex, 500, "Internal server error");
            } finally {
                ex.close();
            }
        }
    }

    static void handleRegister(HttpExchange ex, State state) throws IOException {
        JsonObject body = parseJsonObject(ex);
        if (body == null) { sendError(ex, 400, "Invalid JSON"); return; }
        String username = getAsString(body, "username");
        String password = getAsString(body, "password");
        if (username == null || !USERNAME_RE.matcher(username).matches()) {
            sendError(ex, 400, "Invalid username"); return;
        }
        if (password == null || password.length() < 8) {
            sendError(ex, 400, "Password too short"); return;
        }
        // Uniqueness
        if (state.userIdByUsername.putIfAbsent(username, -1) != null) { // temp mark to avoid race
            sendError(ex, 409, "Username already exists");
            return;
        }
        try {
            int id = state.userIdSeq.incrementAndGet();
            User user = new User(id, username, password);
            state.usersById.put(id, user);
            state.userIdByUsername.put(username, id);
            JsonObject resp = new JsonObject();
            resp.addProperty("id", id);
            resp.addProperty("username", username);
            sendJson(ex, 201, resp);
        } finally {
            // nothing to cleanup
        }
    }

    static void handleLogin(HttpExchange ex, State state) throws IOException {
        JsonObject body = parseJsonObject(ex);
        if (body == null) { sendError(ex, 400, "Invalid JSON"); return; }
        String username = getAsString(body, "username");
        String password = getAsString(body, "password");
        if (username == null || password == null) {
            sendError(ex, 401, "Invalid credentials"); return;
        }
        Integer uid = state.userIdByUsername.get(username);
        if (uid == null || uid <= 0) {
            sendError(ex, 401, "Invalid credentials"); return;
        }
        User u = state.usersById.get(uid);
        if (u == null || !u.password.equals(password)) {
            sendError(ex, 401, "Invalid credentials"); return;
        }
        String token = UUID.randomUUID().toString().replace("-", "");
        state.sessions.put(token, u.id);
        ex.getResponseHeaders().add("Set-Cookie", "session_id=" + token + "; Path=/; HttpOnly");
        JsonObject resp = new JsonObject();
        resp.addProperty("id", u.id);
        resp.addProperty("username", u.username);
        sendJson(ex, 200, resp);
    }

    static void handleLogout(HttpExchange ex, State state) throws IOException {
        User u = requireAuth(ex, state);
        if (u == null) return; // response already sent
        String token = getSessionToken(ex);
        if (token != null) {
            state.sessions.remove(token);
        }
        // Return empty object per spec
        JsonObject obj = new JsonObject();
        sendJson(ex, 200, obj);
    }

    static void handleMe(HttpExchange ex, State state) throws IOException {
        User u = requireAuth(ex, state);
        if (u == null) return;
        JsonObject resp = new JsonObject();
        resp.addProperty("id", u.id);
        resp.addProperty("username", u.username);
        sendJson(ex, 200, resp);
    }

    static void handlePassword(HttpExchange ex, State state) throws IOException {
        User u = requireAuth(ex, state);
        if (u == null) return;
        JsonObject body = parseJsonObject(ex);
        if (body == null) { sendError(ex, 400, "Invalid JSON"); return; }
        String oldp = getAsString(body, "old_password");
        String newp = getAsString(body, "new_password");
        if (oldp == null || !u.password.equals(oldp)) {
            sendError(ex, 401, "Invalid credentials"); return;
        }
        if (newp == null || newp.length() < 8) {
            sendError(ex, 400, "Password too short"); return;
        }
        u.password = newp;
        sendJson(ex, 200, new JsonObject());
    }

    static void handleTodosList(HttpExchange ex, State state) throws IOException {
        User u = requireAuth(ex, state);
        if (u == null) return;
        List<Todo> list = new ArrayList<>();
        for (Todo t : state.todosById.values()) {
            if (t.userId == u.id) list.add(t);
        }
        list.sort(Comparator.comparingInt(a -> a.id));
        JsonArray arr = new JsonArray();
        for (Todo t : list) arr.add(todoToJson(t));
        sendJson(ex, 200, arr);
    }

    static void handleTodosCreate(HttpExchange ex, State state) throws IOException {
        User u = requireAuth(ex, state);
        if (u == null) return;
        JsonObject body = parseJsonObject(ex);
        if (body == null) { sendError(ex, 400, "Invalid JSON"); return; }
        String title = getAsString(body, "title");
        if (title == null || title.trim().isEmpty()) {
            sendError(ex, 400, "Title is required"); return;
        }
        String description = getAsString(body, "description");
        if (description == null) description = "";
        int id = state.todoIdSeq.incrementAndGet();
        String ts = nowIso();
        Todo t = new Todo(id, u.id, title, description, false, ts);
        state.todosById.put(id, t);
        sendJson(ex, 201, todoToJson(t));
    }

    static void handleTodosGet(HttpExchange ex, State state, int id) throws IOException {
        User u = requireAuth(ex, state);
        if (u == null) return;
        Todo t = state.todosById.get(id);
        if (t == null || t.userId != u.id) {
            sendError(ex, 404, "Todo not found"); return;
        }
        sendJson(ex, 200, todoToJson(t));
    }

    static void handleTodosUpdate(HttpExchange ex, State state, int id) throws IOException {
        User u = requireAuth(ex, state);
        if (u == null) return;
        Todo t = state.todosById.get(id);
        if (t == null || t.userId != u.id) {
            sendError(ex, 404, "Todo not found"); return;
        }
        JsonObject body = parseJsonObject(ex);
        if (body == null) { sendError(ex, 400, "Invalid JSON"); return; }
        if (body.has("title") && !body.get("title").isJsonNull()) {
            String title = getAsString(body, "title");
            if (title == null || title.trim().isEmpty()) {
                sendError(ex, 400, "Title is required"); return;
            }
            t.title = title;
        }
        if (body.has("description")) {
            String desc = null;
            if (!body.get("description").isJsonNull()) desc = getAsString(body, "description");
            t.description = desc == null ? "" : desc;
        }
        if (body.has("completed") && !body.get("completed").isJsonNull()) {
            JsonElement ce = body.get("completed");
            if (ce.isJsonPrimitive() && ((JsonPrimitive)ce).isBoolean()) {
                t.completed = ce.getAsBoolean();
            } else {
                // if provided but not boolean, treat as error? Not specified; ignore or error. We'll coerce error 400.
                sendError(ex, 400, "Invalid JSON"); return;
            }
        }
        t.updated_at = nowIso();
        sendJson(ex, 200, todoToJson(t));
    }

    static void handleTodosDelete(HttpExchange ex, State state, int id) throws IOException {
        User u = requireAuth(ex, state);
        if (u == null) return;
        Todo t = state.todosById.get(id);
        if (t == null || t.userId != u.id) {
            sendError(ex, 404, "Todo not found"); return;
        }
        state.todosById.remove(id);
        // DELETE should return 204 no body and no Content-Type per spec
        ex.getResponseHeaders().remove("Content-Type");
        ex.sendResponseHeaders(204, -1);
    }

    // Helpers
    static String nowIso() {
        return Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
    }

    static Integer parseId(String s) {
        try { return Integer.parseInt(s); } catch (Exception e) { return null; }
    }

    static JsonObject todoToJson(Todo t) {
        JsonObject o = new JsonObject();
        o.addProperty("id", t.id);
        o.addProperty("title", t.title);
        o.addProperty("description", t.description);
        o.addProperty("completed", t.completed);
        o.addProperty("created_at", t.created_at);
        o.addProperty("updated_at", t.updated_at);
        return o;
    }

    static JsonObject parseJsonObject(HttpExchange ex) throws IOException {
        String body = readBody(ex);
        if (body == null) return null;
        try {
            JsonElement el = JsonParser.parseString(body);
            if (!el.isJsonObject()) return null;
            return el.getAsJsonObject();
        } catch (JsonSyntaxException e) {
            return null;
        }
    }

    static String readBody(HttpExchange ex) throws IOException {
        InputStream is = ex.getRequestBody();
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int r;
        while ((r = is.read(buf)) != -1) baos.write(buf, 0, r);
        return baos.toString(StandardCharsets.UTF_8);
    }

    static String getAsString(JsonObject obj, String key) {
        if (!obj.has(key)) return null;
        JsonElement el = obj.get(key);
        if (el == null || el.isJsonNull()) return null;
        if (!el.isJsonPrimitive()) return null;
        return el.getAsString();
    }

    static void sendJson(HttpExchange ex, int status, JsonElement el) throws IOException {
        byte[] bytes = gson.toJson(el).getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }
    static void sendJson(HttpExchange ex, int status, JsonObject obj) throws IOException {
        sendJson(ex, status, (JsonElement) obj);
    }
    static void sendJson(HttpExchange ex, int status, JsonArray obj) throws IOException {
        sendJson(ex, status, (JsonElement) obj);
    }

    static void sendError(HttpExchange ex, int status, String message) throws IOException {
        JsonObject err = new JsonObject();
        err.addProperty("error", message);
        sendJson(ex, status, err);
    }

    static String getSessionToken(HttpExchange ex) {
        List<String> cookies = ex.getRequestHeaders().get("Cookie");
        if (cookies == null) return null;
        for (String header : cookies) {
            String[] parts = header.split(";\\s*");
            for (String part : parts) {
                int eq = part.indexOf('=');
                if (eq <= 0) continue;
                String name = part.substring(0, eq).trim();
                String value = part.substring(eq+1).trim();
                if (name.equals("session_id")) return value;
            }
        }
        return null;
    }

    static User requireAuth(HttpExchange ex, State state) throws IOException {
        String token = getSessionToken(ex);
        if (token == null) { sendError(ex, 401, "Authentication required"); return null; }
        Integer uid = state.sessions.get(token);
        if (uid == null) { sendError(ex, 401, "Authentication required"); return null; }
        User u = state.usersById.get(uid);
        if (u == null) { sendError(ex, 401, "Authentication required"); return null; }
        return u;
    }
}

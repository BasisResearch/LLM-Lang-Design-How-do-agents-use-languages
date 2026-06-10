import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import com.google.gson.*;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.Pattern;

public class Main {
    // Data models
    static class User {
        final int id;
        final String username;
        String passwordHash; // stored as plain for this exercise
        User(int id, String username, String passwordHash) {
            this.id = id; this.username = username; this.passwordHash = passwordHash;
        }
    }
    static class Todo {
        final int id;
        final int userId;
        String title;
        String description;
        boolean completed;
        String createdAt;
        String updatedAt;
        Todo(int id, int userId, String title, String description, boolean completed, String ts) {
            this.id=id; this.userId=userId; this.title=title; this.description=description; this.completed=completed; this.createdAt=ts; this.updatedAt=ts;
        }
        JsonObject toJson() {
            JsonObject o = new JsonObject();
            o.addProperty("id", id);
            o.addProperty("title", title);
            o.addProperty("description", description);
            o.addProperty("completed", completed);
            o.addProperty("created_at", createdAt);
            o.addProperty("updated_at", updatedAt);
            return o;
        }
    }

    static class State {
        final ConcurrentMap<String, Integer> sessions = new ConcurrentHashMap<>(); // token -> userId
        final ConcurrentMap<String, User> usersByName = new ConcurrentHashMap<>();
        final ConcurrentMap<Integer, User> usersById = new ConcurrentHashMap<>();
        final ConcurrentMap<Integer, Todo> todosById = new ConcurrentHashMap<>();
        final java.util.concurrent.atomic.AtomicInteger userSeq = new java.util.concurrent.atomic.AtomicInteger(0);
        final java.util.concurrent.atomic.AtomicInteger todoSeq = new java.util.concurrent.atomic.AtomicInteger(0);
    }

    static final Gson gson = new GsonBuilder().serializeNulls().create();
    static final Pattern USERNAME_RE = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");
    static final DateTimeFormatter TS_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);

    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i=0;i<args.length;i++) {
            if ("--port".equals(args[i]) && i+1<args.length) {
                port = Integer.parseInt(args[i+1]);
            }
        }
        InetSocketAddress addr = new InetSocketAddress("0.0.0.0", port);
        HttpServer server = HttpServer.create(addr, 0);
        State state = new State();
        server.createContext("/register", exchange -> handleRegister(exchange, state));
        server.createContext("/login", exchange -> handleLogin(exchange, state));
        server.createContext("/logout", exchange -> withAuth(exchange, state, (ex, user)-> handleLogout(ex, state, user)));
        server.createContext("/me", exchange -> withAuth(exchange, state, (ex, user)-> handleMe(ex, user)));
        server.createContext("/password", exchange -> withAuth(exchange, state, (ex, user)-> handlePassword(ex, state, user)));
        server.createContext("/todos", exchange -> withAuth(exchange, state, (ex, user)-> handleTodos(ex, state, user)));
        server.createContext("/todos/", exchange -> withAuth(exchange, state, (ex, user)-> handleTodoById(ex, state, user)));
        server.createContext("/", exchange -> {
            // Unknown endpoint
            sendJson(exchange, 404, error("Not found"));
        });
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("Server started on 0.0.0.0:"+port);
    }

    interface AuthedHandler { void handle(HttpExchange ex, User user) throws IOException; }

    static void withAuth(HttpExchange ex, State state, AuthedHandler next) throws IOException {
        Optional<String> sidOpt = readSessionCookie(ex);
        if (!sidOpt.isPresent()) {
            sendAuthRequired(ex); return;
        }
        Integer uid = state.sessions.get(sidOpt.get());
        if (uid == null) { sendAuthRequired(ex); return; }
        User user = state.usersById.get(uid);
        if (user == null) { sendAuthRequired(ex); return; }
        next.handle(ex, user);
    }

    static void handleRegister(HttpExchange ex, State state) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) { sendJson(ex, 405, error("Method not allowed")); return; }
        JsonObject body = readJson(ex);
        if (body == null) return; // error already sent
        String username = optString(body, "username");
        String password = optString(body, "password");
        if (username == null || !USERNAME_RE.matcher(username).matches()) {
            sendJson(ex, 400, error("Invalid username")); return;
        }
        if (password == null || password.length() < 8) {
            sendJson(ex, 400, error("Password too short")); return;
        }
        // enforce unique
        synchronized (state.usersByName) {
            if (state.usersByName.containsKey(username)) {
                sendJson(ex, 409, error("Username already exists")); return;
            }
            int id = state.userSeq.incrementAndGet();
            User u = new User(id, username, password);
            state.usersByName.put(username, u);
            state.usersById.put(id, u);
            JsonObject resp = new JsonObject();
            resp.addProperty("id", id);
            resp.addProperty("username", username);
            sendJson(ex, 201, resp);
        }
    }

    static void handleLogin(HttpExchange ex, State state) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) { sendJson(ex, 405, error("Method not allowed")); return; }
        JsonObject body = readJson(ex);
        if (body == null) return;
        String username = optString(body, "username");
        String password = optString(body, "password");
        if (username == null || password == null) { sendJson(ex, 401, error("Invalid credentials")); return; }
        User u = state.usersByName.get(username);
        if (u == null || !Objects.equals(u.passwordHash, password)) {
            sendJsonWithSetCookie(ex, 401, error("Invalid credentials"), null); return;
        }
        String token = UUID.randomUUID().toString().replace("-", "");
        state.sessions.put(token, u.id);
        JsonObject resp = new JsonObject();
        resp.addProperty("id", u.id);
        resp.addProperty("username", u.username);
        String setCookie = "session_id="+token+"; Path=/; HttpOnly";
        sendJsonWithSetCookie(ex, 200, resp, setCookie);
    }

    static void handleLogout(HttpExchange ex, State state, User user) throws IOException {
        if (!"POST".equals(ex.getRequestMethod())) { sendJson(ex, 405, error("Method not allowed")); return; }
        Optional<String> sid = readSessionCookie(ex);
        sid.ifPresent(token -> state.sessions.remove(token));
        sendJson(ex, 200, new JsonObject());
    }

    static void handleMe(HttpExchange ex, User user) throws IOException {
        if (!"GET".equals(ex.getRequestMethod())) { sendJson(ex, 405, error("Method not allowed")); return; }
        JsonObject resp = new JsonObject();
        resp.addProperty("id", user.id);
        resp.addProperty("username", user.username);
        sendJson(ex, 200, resp);
    }

    static void handlePassword(HttpExchange ex, State state, User user) throws IOException {
        if (!"PUT".equals(ex.getRequestMethod())) { sendJson(ex, 405, error("Method not allowed")); return; }
        JsonObject body = readJson(ex);
        if (body == null) return;
        String oldp = optString(body, "old_password");
        String newp = optString(body, "new_password");
        if (oldp == null || !Objects.equals(oldp, user.passwordHash)) { sendJson(ex, 401, error("Invalid credentials")); return; }
        if (newp == null || newp.length() < 8) { sendJson(ex, 400, error("Password too short")); return; }
        user.passwordHash = newp;
        sendJson(ex, 200, new JsonObject());
    }

    static void handleTodos(HttpExchange ex, State state, User user) throws IOException {
        String method = ex.getRequestMethod();
        if ("GET".equals(method)) {
            List<Todo> list = new ArrayList<>();
            for (Todo t : state.todosById.values()) if (t.userId == user.id) list.add(t);
            list.sort(Comparator.comparingInt(t -> t.id));
            JsonArray arr = new JsonArray();
            for (Todo t : list) arr.add(t.toJson());
            sendJson(ex, 200, arr);
            return;
        } else if ("POST".equals(method)) {
            JsonObject body = readJson(ex);
            if (body == null) return;
            String title = optString(body, "title");
            if (title == null || title.trim().isEmpty()) { sendJson(ex, 400, error("Title is required")); return; }
            String description = optString(body, "description");
            if (description == null) description = "";
            int id = state.todoSeq.incrementAndGet();
            String ts = TS_FMT.format(Instant.now());
            Todo t = new Todo(id, user.id, title, description, false, ts);
            state.todosById.put(id, t);
            sendJson(ex, 201, t.toJson());
            return;
        } else {
            sendJson(ex, 405, error("Method not allowed")); return;
        }
    }

    static void handleTodoById(HttpExchange ex, State state, User user) throws IOException {
        String path = ex.getRequestURI().getPath();
        // path like /todos/123
        String[] parts = path.split("/");
        if (parts.length < 3) { sendJson(ex, 404, error("Not found")); return; }
        int id;
        try { id = Integer.parseInt(parts[2]); } catch (Exception e) { sendJson(ex, 404, error("Todo not found")); return; }
        Todo t = state.todosById.get(id);
        if (t == null || t.userId != user.id) { sendJson(ex, 404, error("Todo not found")); return; }
        String method = ex.getRequestMethod();
        switch (method) {
            case "GET":
                sendJson(ex, 200, t.toJson());
                return;
            case "PUT":
                JsonObject body = readJson(ex);
                if (body == null) return;
                if (body.has("title")) {
                    String title = optString(body, "title");
                    if (title == null || title.trim().isEmpty()) { sendJson(ex, 400, error("Title is required")); return; }
                    t.title = title;
                }
                if (body.has("description")) {
                    String description = optString(body, "description");
                    t.description = description == null ? "" : description;
                }
                if (body.has("completed")) {
                    JsonElement c = body.get("completed");
                    if (c != null && !c.isJsonNull() && c.isJsonPrimitive() && ((JsonPrimitive)c).isBoolean()) {
                        t.completed = c.getAsBoolean();
                    }
                }
                t.updatedAt = TS_FMT.format(Instant.now());
                sendJson(ex, 200, t.toJson());
                return;
            case "DELETE":
                state.todosById.remove(id);
                sendNoContent(ex);
                return;
            default:
                sendJson(ex, 405, error("Method not allowed"));
        }
    }

    // Utilities
    static JsonObject readJson(HttpExchange ex) throws IOException {
        try (InputStream is = ex.getRequestBody()) {
            String body = new String(is.readAllBytes(), StandardCharsets.UTF_8);
            if (body == null || body.isEmpty()) return new JsonObject();
            try {
                JsonElement el = JsonParser.parseString(body);
                if (!el.isJsonObject()) { sendJson(ex, 400, error("Invalid JSON")); return null; }
                return el.getAsJsonObject();
            } catch (JsonSyntaxException e) {
                sendJson(ex, 400, error("Invalid JSON")); return null;
            }
        }
    }

    static String optString(JsonObject o, String key) {
        if (o == null || !o.has(key)) return null;
        JsonElement v = o.get(key);
        if (v == null || v.isJsonNull()) return null;
        if (v.isJsonPrimitive()) return v.getAsString();
        return null;
    }

    static JsonObject error(String msg) {
        JsonObject o = new JsonObject();
        o.addProperty("error", msg);
        return o;
    }

    static Optional<String> readSessionCookie(HttpExchange ex) {
        List<String> cookies = ex.getRequestHeaders().get("Cookie");
        if (cookies == null) return Optional.empty();
        for (String c : cookies) {
            String[] parts = c.split(";\\s*");
            for (String p : parts) {
                int eq = p.indexOf('=');
                if (eq <= 0) continue;
                String name = p.substring(0, eq).trim();
                String val = p.substring(eq+1).trim();
                if ("session_id".equals(name)) return Optional.of(val);
            }
        }
        return Optional.empty();
    }

    static void sendAuthRequired(HttpExchange ex) throws IOException {
        sendJson(ex, 401, error("Authentication required"));
    }

    static void sendJson(HttpExchange ex, int status, JsonElement body) throws IOException {
        byte[] data = gson.toJson(body).getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, data.length);
        try (OutputStream os = ex.getResponseBody()) { os.write(data); }
    }

    static void sendJsonWithSetCookie(HttpExchange ex, int status, JsonElement body, String setCookie) throws IOException {
        byte[] data = gson.toJson(body).getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        if (setCookie != null) ex.getResponseHeaders().add("Set-Cookie", setCookie);
        ex.sendResponseHeaders(status, data.length);
        try (OutputStream os = ex.getResponseBody()) { os.write(data); }
    }

    static void sendNoContent(HttpExchange ex) throws IOException {
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(204, -1); // no body
        ex.close();
    }
}

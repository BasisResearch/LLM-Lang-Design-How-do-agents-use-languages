import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class HttpRequestHandler implements HttpHandler {
    private UserService userService;
    private TodoService todoService;
    private SessionService sessionService;
    
    public HttpRequestHandler(UserService userService, TodoService todoService, SessionService sessionService) {
        this.userService = userService;
        this.todoService = todoService;
        this.sessionService = sessionService;
    }

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        try {
            String method = exchange.getRequestMethod();
            String path = exchange.getRequestURI().getPath();
            
            switch (method) {
                case "POST":
                    if ("/register".equals(path)) {
                        handleRegister(exchange);
                    } else if ("/login".equals(path)) {
                        handleLogin(exchange);
                    } else if ("/logout".equals(path)) {
                        handleLogout(exchange);
                    } else if ("/todos".equals(path)) {
                        handleCreateTodo(exchange);
                    } else if ("/password".equals(path)) {
                        handleChangePassword(exchange);
                    }
                    break;
                case "GET":
                    if ("/me".equals(path)) {
                        handleGetMe(exchange);
                    } else if ("/todos".equals(path)) {
                        handleGetTodos(exchange);
                    } else {
                        // Check for todo-get pattern: GET /todos/{id}
                        Pattern todoIdPattern = Pattern.compile("^/todos/(\\d+)$");
                        Matcher matcher = todoIdPattern.matcher(path);
                        if (matcher.matches()) {
                            int todoId = Integer.parseInt(matcher.group(1));
                            handleGetTodo(exchange, todoId);
                        } else {
                            sendResponse(exchange, 404, "{ \"error\": \"Endpoint not found\" }");
                        }
                    }
                    break;
                case "PUT":
                    if ("/password".equals(path)) {
                        handleChangePassword(exchange);
                    } else {
                        // Check for todo-update pattern: PUT /todos/{id}
                        Pattern todoIdPattern = Pattern.compile("^/todos/(\\d+)$");
                        Matcher matcher = todoIdPattern.matcher(path);
                        if (matcher.matches()) {
                            int todoId = Integer.parseInt(matcher.group(1));
                            handleUpdateTodo(exchange, todoId);
                        } else {
                            sendResponse(exchange, 404, "{ \"error\": \"Endpoint not found\" }");
                        }
                    }
                    break;
                case "DELETE":
                    // Check for todo-delete pattern: DELETE /todos/{id}
                    Pattern todoIdPattern = Pattern.compile("^/todos/(\\d+)$");
                    Matcher matcher = todoIdPattern.matcher(path);
                    if (matcher.matches()) {
                        int todoId = Integer.parseInt(matcher.group(1));
                        handleDeleteTodo(exchange, todoId);
                    } else {
                        sendResponse(exchange, 404, "{ \"error\": \"Endpoint not found\" }");
                    }
                    break;
                default:
                    sendResponse(exchange, 405, "{ \"error\": \"Method not allowed\" }");
            }
        } catch (Exception e) {
            e.printStackTrace();
            sendResponse(exchange, 500, "{ \"error\": \"Internal server error\" }");
        }
    }
    
    private void handleRegister(HttpExchange exchange) throws IOException {
        String requestBody = getBody(exchange);
        Map<String, Object> req = JsonUtil.parseJson(requestBody);
        
        String username = (String) ((Map<String, Object>) req).get("username");
        String password = (String) ((Map<String, Object>) req).get("password");
        
        if (password == null || password.length() < 8) {
            sendResponse(exchange, 400, "{ \"error\": \"Password too short\" }");
            return;
        }
        
        if (username == null || username.trim().isEmpty() || 
            username.length() < 3 || username.length() > 50 || 
            !username.matches("^[a-zA-Z0-9_]+$")) {
            sendResponse(exchange, 400, "{ \"error\": \"Invalid username\" }");
            return;
        }
        
        if (userService.isUsernameTaken(username)) {
            sendResponse(exchange, 409, "{ \"error\": \"Username already exists\" }");
            return;
        }
        
        User user = userService.createUser(username, password);
        String response = String.format("{ \"id\": %d, \"username\": \"%s\" }", user.id, user.username);
        sendResponse(exchange, 201, response);
    }
    
    private void handleLogin(HttpExchange exchange) throws IOException {
        String requestBody = getBody(exchange);
        Map<String, Object> req = JsonUtil.parseJson(requestBody);
        
        String username = (String) ((Map<String, Object>) req).get("username");
        String password = (String) ((Map<String, Object>) req).get("password");
        
        User user = userService.findUserByUsername(username);
        if (user == null || !userService.validatePassword(user.id, password)) {
            sendResponse(exchange, 401, "{ \"error\": \"Invalid credentials\" }");
            return;
        }
        
        String sessionId = sessionService.createSession(user.id);
        String response = String.format("{ \"id\": %d, \"username\": \"%s\" }", user.id, user.username);
        
        exchange.getResponseHeaders().set("Set-Cookie", 
            String.format("session_id=%s; Path=/; HttpOnly", sessionId));
        sendResponse(exchange, 200, response);
    }
    
    private void handleLogout(HttpExchange exchange) throws IOException {
        String sessionId = getSessionIdFromCookie(exchange);
        
        if (sessionId == null || !sessionService.isValid(sessionId)) {
            sendResponse(exchange, 401, "{ \"error\": \"Authentication required\" }");
            return;
        }
        
        sessionService.removeSession(sessionId);
        sendResponse(exchange, 200, "{}");
    }
    
    private void handleGetMe(HttpExchange exchange) throws IOException {
        Integer userId = getCurrentUserId(exchange);
        if (userId == null) {
            sendResponse(exchange, 401, "{ \"error\": \"Authentication required\" }");
            return;
        }
        
        User user = userService.findUserById(userId);
        if (user == null) {
            sendResponse(exchange, 401, "{ \"error\": \"Authentication required\" }");
            return;
        }
        
        String response = String.format("{ \"id\": %d, \"username\": \"%s\" }", user.id, user.username);
        sendResponse(exchange, 200, response);
    }
    
    private void handleChangePassword(HttpExchange exchange) throws IOException {
        Integer userId = getCurrentUserId(exchange);
        if (userId == null) {
            sendResponse(exchange, 401, "{ \"error\": \"Authentication required\" }");
            return;
        }
        
        String requestBody = getBody(exchange);
        Map<String, Object> req = JsonUtil.parseJson(requestBody);
        
        String oldPassword = (String) ((Map<String, Object>) req).get("old_password");
        String newPassword = (String) ((Map<String, Object>) req).get("new_password");
        
        if (!userService.validatePassword(userId, oldPassword)) {
            sendResponse(exchange, 401, "{ \"error\": \"Invalid credentials\" }");
            return;
        }
        
        if (newPassword == null || newPassword.length() < 8) {
            sendResponse(exchange, 400, "{ \"error\": \"Password too short\" }");
            return;
        }
        
        userService.setPasswordForUser(userId, newPassword);
        sendResponse(exchange, 200, "{}");
    }
    
    private void handleGetTodos(HttpExchange exchange) throws IOException {
        Integer userId = getCurrentUserId(exchange);
        if (userId == null) {
            sendResponse(exchange, 401, "{ \"error\": \"Authentication required\" }");
            return;
        }
        
        List<Todo> todos = todoService.getTodosForUser(userId);
        
        StringBuilder sb = new StringBuilder();
        sb.append("[");
        for (int i = 0; i < todos.size(); i++) {
            if (i > 0) sb.append(",");
            Todo t = todos.get(i);
            sb.append(String.format(
                "{ \"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %b, \"created_at\": \"%s\", \"updated_at\": \"%s\" }",
                t.id, esc(t.title), esc(t.description), t.completed, esc(t.created_at), esc(t.updated_at)
            ));
        }
        sb.append("]");
        
        sendResponse(exchange, 200, sb.toString());
    }
    
    private void handleCreateTodo(HttpExchange exchange) throws IOException {
        Integer userId = getCurrentUserId(exchange);
        if (userId == null) {
            sendResponse(exchange, 401, "{ \"error\": \"Authentication required\" }");
            return;
        }
        
        String requestBody = getBody(exchange);
        Map<String, Object> req = JsonUtil.parseJson(requestBody);
        
        String title = (String) ((Map<String, Object>) req).get("title");
        String description = (String) ((Map<String, Object>) req).get("description");
        
        if (title == null || title.trim().isEmpty()) {
            sendResponse(exchange, 400, "{ \"error\": \"Title is required\" }");
            return;
        }
        
        Todo todo = todoService.createTodo(userId, title, description);
        String response = String.format(
            "{ \"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %b, \"created_at\": \"%s\", \"updated_at\": \"%s\" }",
            todo.id, esc(todo.title), esc(todo.description), todo.completed, esc(todo.created_at), esc(todo.updated_at)
        );
        sendResponse(exchange, 201, response);
    }
    
    private void handleGetTodo(HttpExchange exchange, int todoId) throws IOException {
        Integer userId = getCurrentUserId(exchange);
        if (userId == null) {
            sendResponse(exchange, 401, "{ \"error\": \"Authentication required\" }");
            return;
        }
        
        Todo todo = todoService.getTodoById(todoId);
        if (todo == null || !todoService.isTodoOwnedByUser(todoId, userId)) {
            sendResponse(exchange, 404, "{ \"error\": \"Todo not found\" }");
            return;
        }
        
        String response = String.format(
            "{ \"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %b, \"created_at\": \"%s\", \"updated_at\": \"%s\" }",
            todo.id, esc(todo.title), esc(todo.description), todo.completed, esc(todo.created_at), esc(todo.updated_at)
        );
        sendResponse(exchange, 200, response);
    }
    
    private void handleUpdateTodo(HttpExchange exchange, int todoId) throws IOException {
        Integer userId = getCurrentUserId(exchange);
        if (userId == null) {
            sendResponse(exchange, 401, "{ \"error\": \"Authentication required\" }");
            return;
        }
        
        Todo existingTodo = todoService.getTodoById(todoId);
        if (existingTodo == null || !todoService.isTodoOwnedByUser(todoId, userId)) {
            sendResponse(exchange, 404, "{ \"error\": \"Todo not found\" }");
            return;
        }
        
        String requestBody = getBody(exchange);
        Map<String, Object> req = JsonUtil.parseJson(requestBody);
        
        String title = (String) req.get("title");
        String description = (String) req.get("description");
        Boolean completed = (Boolean) req.get("completed");
        
        if (title != null && title.trim().isEmpty()) {
            sendResponse(exchange, 400, "{ \"error\": \"Title is required\" }");
            return;
        }
        
        try {
            todoService.updateTodo(todoId, title, description, completed);
        } catch (IllegalArgumentException e) {
            sendResponse(exchange, 400, "{ \"error\": \"Title is required\" }");
            return;
        }
        
        Todo updatedTodo = todoService.getTodoById(todoId);
        String response = String.format(
            "{ \"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %b, \"created_at\": \"%s\", \"updated_at\": \"%s\" }",
            updatedTodo.id, esc(updatedTodo.title), esc(updatedTodo.description), updatedTodo.completed, esc(updatedTodo.created_at), esc(updatedTodo.updated_at)
        );
        sendResponse(exchange, 200, response);
    }
    
    private void handleDeleteTodo(HttpExchange exchange, int todoId) throws IOException {
        Integer userId = getCurrentUserId(exchange);
        if (userId == null) {
            sendResponse(exchange, 401, "{ \"error\": \"Authentication required\" }");
            return;
        }
        
        Todo existingTodo = todoService.getTodoById(todoId);
        if (existingTodo == null || !todoService.isTodoOwnedByUser(todoId, userId)) {
            sendResponse(exchange, 404, "{ \"error\": \"Todo not found\" }");
            return;
        }
        
        todoService.deleteTodo(todoId);
        exchange.sendResponseHeaders(204, -1); // No content
    }
    
    // Helper methods
    private Integer getCurrentUserId(HttpExchange exchange) {
        String sessionId = getSessionIdFromCookie(exchange);
        if (sessionId == null) return null;
        return sessionService.getUserIdFromSession(sessionId);
    }
    
    private String getSessionIdFromCookie(HttpExchange exchange) {
        List<String> cookies = exchange.getRequestHeaders().get("Cookie");
        if (cookies == null) return null;
        
        for (String cookieHeader : cookies) {
            String[] cookiesArray = cookieHeader.split(";");
            for (String cookie : cookiesArray) {
                cookie = cookie.trim();
                if (cookie.startsWith("session_id=")) {
                    return cookie.substring("session_id=".length());
                }
            }
        }
        
        return null;
    }
    
    private String getBody(HttpExchange exchange) throws IOException {
        byte[] input = exchange.getRequestBody().readAllBytes();
        return new String(input, StandardCharsets.UTF_8);
    }
    
    private String esc(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
    
    private void sendResponse(HttpExchange exchange, int status, String responseBody) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        byte[] responseByte = responseBody.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, responseByte.length);
        OutputStream os = exchange.getResponseBody();
        os.write(responseByte);
        os.close();
    }
}
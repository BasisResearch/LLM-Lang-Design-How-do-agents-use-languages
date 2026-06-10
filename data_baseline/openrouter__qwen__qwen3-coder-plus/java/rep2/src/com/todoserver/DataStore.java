package com.todoserver;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

// A singleton to hold all in-memory data
public class DataStore {
    private static final AtomicInteger userIdCounter = new AtomicInteger(1);
    private static final AtomicInteger todoIdCounter = new AtomicInteger(1);

    // Map to store users by their id
    private final Map<Integer, User> users = new ConcurrentHashMap<>();
    
    // Map to store users by their username
    private final Map<String, User> usersByUsername = new ConcurrentHashMap<>();

    // Map to store todos by their id
    private final Map<Integer, Todo> todos = new ConcurrentHashMap<>();

    // Map to store active session IDs
    private final Map<String, Integer> activeSessions = new ConcurrentHashMap<>();

    private static final DataStore INSTANCE = new DataStore();

    public static DataStore getInstance() {
        return INSTANCE;
    }

    // Methods for managing users
    public User createUser(String username, String password) {
        int id = userIdCounter.getAndIncrement();
        String hashedPassword = PasswordUtil.hashPassword(password);
        User newUser = new User(id, username, hashedPassword);
        
        users.put(id, newUser);
        usersByUsername.put(username, newUser);
        
        return newUser;
    }

    public User getUserById(int id) {
        return users.get(id);
    }

    public User getUserByUsername(String username) {
        return usersByUsername.get(username);
    }

    public boolean usernameExists(String username) {
        return usersByUsername.containsKey(username);
    }

    // Methods for managing todos
    public Todo createTodo(int userId, String title, String description) {
        int id = todoIdCounter.getAndIncrement();
        Todo newTodo = new Todo(id, title, description, false, userId);  // Default completed is false
        todos.put(id, newTodo);
        return newTodo;
    }

    public Todo getTodoById(int id) {
        return todos.get(id);
    }

    public List<Todo> getTodosByUserId(int userId) {
        List<Todo> userTodos = new ArrayList<>();
        for (Todo todo : todos.values()) {
            if (todo.getUserId() == userId) {
                userTodos.add(todo);
            }
        }
        // Sort by ID ascending as specified
        userTodos.sort((t1, t2) -> Integer.compare(t1.getId(), t2.getId()));
        return userTodos;
    }

    public boolean updateTodo(int todoId, String title, String description, Boolean completed) {
        Todo todo = todos.get(todoId);
        if (todo == null) {
            return false;
        }

        if (title != null) {
            if (title.isEmpty()) {
                return false; // Title cannot be empty
            }
            todo.setTitle(title);
        }

        if (description != null) {
            todo.setDescription(description);
        }

        if (completed != null) {
            todo.setCompleted(completed);
        }

        // Update timestamp
        todo.updateTimestamp();
        return true;
    }

    public boolean deleteTodo(int todoId) {
        Todo removed = todos.remove(todoId);
        return removed != null;
    }

    public boolean isTodoBelongToUser(int todoId, int userId) {
        Todo todo = todos.get(todoId);
        return todo != null && todo.getUserId() == userId;
    }

    // Methods for managing sessions
    public String createSession(int userId) {
        String sessionId = UUID.randomUUID().toString();
        activeSessions.put(sessionId, userId);
        return sessionId;
    }

    public Integer getUserIdBySessionId(String sessionId) {
        return activeSessions.get(sessionId);
    }

    public void invalidateSession(String sessionId) {
        activeSessions.remove(sessionId);
    }

    public boolean validateSession(String sessionId) {
        return activeSessions.containsKey(sessionId);
    }

    public boolean changeUserPassword(int userId, String oldPassword, String newPassword) {
        User user = users.get(userId);
        if (user != null) {
            if (PasswordUtil.checkPassword(oldPassword, user.getPasswordHash())) {
                user.setPasswordHash(PasswordUtil.hashPassword(newPassword));
                return true;
            }
        }
        return false;
    }
}
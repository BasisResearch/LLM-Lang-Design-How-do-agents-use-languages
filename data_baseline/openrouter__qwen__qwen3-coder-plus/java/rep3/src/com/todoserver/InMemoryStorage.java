package com.todoserver;

import java.time.Instant;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.List;
import java.util.ArrayList;
import java.util.Collections;
import java.util.stream.Collectors;

public class InMemoryStorage {
    private AtomicInteger userIdCounter = new AtomicInteger(1);
    private AtomicInteger todoIdCounter = new AtomicInteger(1);
    private ConcurrentHashMap<Integer, User> users = new ConcurrentHashMap<>();
    private ConcurrentHashMap<String, User> usernames = new ConcurrentHashMap<>();
    private ConcurrentHashMap<Integer, Todo> todos = new ConcurrentHashMap<>();
    private ConcurrentHashMap<Integer, List<Integer>> userTodos = new ConcurrentHashMap<>(); // user_id -> [todo_ids]
    
    public int generateUserId() {
        return userIdCounter.getAndIncrement();
    }
    
    public int generateTodoId() {
        return todoIdCounter.getAndIncrement();
    }
    
    public boolean createUser(String username, String passwordHash) {
        if (!usernames.containsKey(username)) {
            int id = generateUserId();
            User user = new User(id, username, passwordHash);
            users.put(id, user);
            usernames.put(username, user);
            return true;
        }
        return false;
    }
    
    public User getUserById(int id) {
        return users.get(id);
    }
    
    public User getUserByUsername(String username) {
        return usernames.get(username);
    }
    
    public User authenticateUser(String username, String password) {
        User user = usernames.get(username);
        if (user != null && PasswordUtils.verifyPassword(password, user.getPassword())) {
            return user;
        }
        return null;
    }
    
    public boolean updatePassword(int userId, String newPasswordHash) {
        User user = users.get(userId);
        if (user != null) {
            user.setPassword(newPasswordHash);
            return true;
        }
        return false;
    }
    
    public Todo createTodo(int userId, String title, String description) {
        int id = generateTodoId();
        String timestamp = getCurrentTimestamp();
        Todo todo = new Todo(id, title, description, false, timestamp, timestamp);
        todos.put(id, todo);
        
        // Add to user's todos
        userTodos.computeIfAbsent(userId, k -> Collections.synchronizedList(new ArrayList<>())).add(id);
        
        return todo;
    }
    
    public Todo getTodoById(int todoId) {
        return todos.get(todoId);
    }
    
    public List<Todo> getUserTodos(int userId) {
        List<Integer> todoIds = userTodos.get(userId);
        if (todoIds == null) {
            return new ArrayList<>();
        }
        
        return todoIds.stream()
                .map(this::getTodoById)
                .filter(todo -> todo != null) // Make sure todo exists
                .sorted((t1, t2) -> ((Integer) t1.getId()).compareTo(t2.getId())) // Order by id ascending
                .collect(Collectors.toList());
    }
    
    public Todo updateTodo(int todoId, String title, String description, Boolean completed) {
        Todo todo = todos.get(todoId);
        if (todo != null) {
            if (title != null) {
                if (title.isEmpty()) {
                    throw new IllegalArgumentException("Title is required");
                }
                todo.setTitle(title);
            }
            if (description != null) {
                todo.setDescription(description);
            }
            if (completed != null) {
                todo.setCompleted(completed);
            }
            // Update the updated_at timestamp
            todo.setUpdatedAt(getCurrentTimestamp());
            return todo;
        }
        return null;
    }
    
    public boolean deleteTodo(int todoId) {
        Todo todo = todos.remove(todoId);
        if (todo != null) {
            // Remove from user's todo list
            for (List<Integer> userTodoList : userTodos.values()) {
                synchronized (userTodoList) {
                    userTodoList.removeIf(id -> id == todoId);
                }
            }
            return true;
        }
        return false;
    }
    
    public boolean isTodoOwnedByUser(int todoId, int userId) {
        List<Integer> userTodoIds = userTodos.get(userId);
        return userTodoIds != null && userTodoIds.contains(todoId);
    }
    
    private String getCurrentTimestamp() {
        return Instant.now().toString().substring(0, 19).replace("T", "T") + "Z";
    }
}
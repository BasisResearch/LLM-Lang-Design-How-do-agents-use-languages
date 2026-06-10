package com.todoserver;

import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;

public class Database {
    private final Map<String, User> usernames = new ConcurrentHashMap<>();
    private final Map<Integer, User> users = new ConcurrentHashMap<>();
    private final AtomicInteger userIdCounter = new AtomicInteger(1);
    
    private final Map<Integer, List<Todo>> userTodos = new ConcurrentHashMap<>();
    private final AtomicInteger todoIdCounter = new AtomicInteger(1);
    
    // Pattern for valid usernames: alphanumeric and underscores only, length 3-50
    private static final Pattern USERNAME_PATTERN = Pattern.compile("^[a-zA-Z0-9_]{3,50}$");
    
    public synchronized boolean isValidUsername(String username) {
        return username != null && USERNAME_PATTERN.matcher(username).matches();
    }
    
    public synchronized boolean isUsernameTaken(String username) {
        return usernames.containsKey(username);
    }
    
    public synchronized User createUser(String username, String password) {
        User user = new User();
        user.id = userIdCounter.getAndIncrement();
        user.username = username;
        user.password = BCrypt.hashpw(password, BCrypt.gensalt());
        
        users.put(user.id, user);
        usernames.put(user.username, user);
        
        // Initialize the list for storing user's todos
        userTodos.put(user.id, new ArrayList<>());
        
        return user;
    }
    
    public synchronized User findUserByUsername(String username) {
        return usernames.get(username);
    }
    
    public synchronized User findUserById(int id) {
        return users.get(id);
    }
    
    public synchronized boolean checkPassword(User user, String password) {
        return BCrypt.checkpw(password, user.password);
    }
    
    public synchronized Todo addTodo(int userId, String title, String description) {
        Todo todo = new Todo();
        todo.id = todoIdCounter.getAndIncrement();
        todo.title = title;
        todo.description = description;
        todo.completed = false;
        ZonedDateTime now = ZonedDateTime.now(ZoneOffset.UTC);
        String timestamp = now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
        todo.created_at = timestamp;
        todo.updated_at = timestamp;
        
        List<Todo> todos = userTodos.get(userId);
        if (todos == null) {
            todos = new ArrayList<>();
            userTodos.put(userId, todos);
        }
        todos.add(todo);
        
        return todo;
    }
    
    public synchronized Todo getTodo(int userId, int todoId) {
        List<Todo> todos = userTodos.get(userId);
        if (todos == null) {
            return null;
        }
        
        for (Todo todo : todos) {
            if (todo.id == todoId) {
                return todo;
            }
        }
        return null;
    }
    
    public synchronized List<Todo> getTodos(int userId) {
        List<Todo> todos = userTodos.get(userId);
        if (todos == null) {
            return new ArrayList<>();
        }
        return new ArrayList<>(todos);
    }
    
    public synchronized boolean updateTodo(int userId, int todoId, String title, String description, Boolean completed) {
        List<Todo> todos = userTodos.get(userId);
        if (todos == null) {
            return false;
        }
        
        for (int i = 0; i < todos.size(); i++) {
            Todo todo = todos.get(i);
            if (todo.id == todoId) {
                if (title != null) {
                    todo.title = title;
                }
                if (description != null) {
                    todo.description = description;
                }
                if (completed != null) {
                    todo.completed = completed;
                }
                
                ZonedDateTime now = ZonedDateTime.now(ZoneOffset.UTC);
                String timestamp = now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
                todo.updated_at = timestamp;
                
                todos.set(i, todo);
                return true;
            }
        }
        return false;
    }
    
    public synchronized boolean deleteTodo(int userId, int todoId) {
        List<Todo> todos = userTodos.get(userId);
        if (todos == null) {
            return false;
        }
        
        return todos.removeIf(todo -> todo.id == todoId);
    }
    
    public synchronized boolean changeUserPassword(int userId, String oldPassword, String newPassword) {
        User user = users.get(userId);
        if (user == null || !BCrypt.checkpw(oldPassword, user.password)) {
            return false;
        }
        
        user.password = BCrypt.hashpw(newPassword, BCrypt.gensalt());
        return true;
    }
    
    public synchronized void deleteUserTodos(int userId) {
        userTodos.remove(userId);
    }
    
    static class User {
        int id;
        String username;
        String password;
    }
    
    static class Todo {
        int id;
        String title;
        String description;
        boolean completed;
        String created_at;
        String updated_at;
    }
}
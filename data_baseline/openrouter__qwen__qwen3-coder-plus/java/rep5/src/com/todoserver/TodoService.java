package com.todoserver;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.ArrayList;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Collectors;

public class TodoService {
    private Map<Integer, Todo> todosById;
    private AtomicInteger todoIdCounter;
    
    public TodoService() {
        this.todosById = new ConcurrentHashMap<>();
        this.todoIdCounter = new AtomicInteger(1);
    }
    
    public Todo addTodo(int userId, String title, String description) {
        String createdTime = getCurrentTimestamp();
        Todo todo = new Todo(
            todoIdCounter.getAndIncrement(),
            userId,
            title,
            description,
            false, // completed: false initially
            createdTime,
            createdTime  // Also set updated_at to initial time
        );
        
        todosById.put(todo.getId(), todo);
        return todo;
    }
    
    public Todo getTodoById(int id) {
        return todosById.get(id);
    }
    
    public List<Todo> getTodosForUser(int userId) {
        return todosById.values().stream()
            .filter(todo -> todo.getUserId() == userId)
            .sorted((a, b) -> Integer.compare(a.getId(), b.getId()))
            .collect(Collectors.toList());
    }
    
    public Todo updateTodo(int id, String title, String description, Boolean completed) {
        Todo todo = todosById.get(id);
        if (todo == null) {
            return null; // Or throw exception
        }
        
        // Only update provided fields
        if (title != null) {
            todo.setTitle(title);
        }
        if (description != null) {
            todo.setDescription(description);
        }
        if (completed != null) {
            todo.setCompleted(completed);
        }
        
        // Always update updated_at field
        todo.setUpdatedAt(getCurrentTimestamp());
        
        return todo;
    }
    
    public boolean deleteTodo(int id) {
        Todo removed = todosById.remove(id);
        return removed != null;
    }
    
    private String getCurrentTimestamp() {
        return Instant.now()
            .atOffset(ZoneOffset.UTC)
            .format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }
}
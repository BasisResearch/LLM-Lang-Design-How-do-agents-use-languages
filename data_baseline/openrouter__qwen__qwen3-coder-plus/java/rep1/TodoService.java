import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeFormatterBuilder;
import java.time.temporal.ChronoField;

public class TodoService {
    private final Map<Integer, Todo> todosById = new ConcurrentHashMap<>();
    private final Map<Integer, List<Todo>> userTodosMap = new ConcurrentHashMap<>(); // userId -> todos
    private Integer nextTodoId = 1;
    
    private static final DateTimeFormatter FORMATTER = new DateTimeFormatterBuilder()
        .appendPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
        .toFormatter();
    
    public synchronized int getNextTodoId() {
        return nextTodoId++;
    }
    
    public Todo createTodo(int userId, String title, String description) {
        Todo todo = new Todo();
        todo.id = getNextTodoId();
        todo.title = title;
        todo.description = description != null ? description : "";
        todo.completed = false;
        Instant now = Instant.now();
        todo.created_at = FORMATTER.format(now.atOffset(ZoneOffset.UTC));
        todo.updated_at = FORMATTER.format(now.atOffset(ZoneOffset.UTC));
        
        todosById.put(todo.id, todo);
        
        // Register this todo under the user who owns it
        userTodosMap.computeIfAbsent(userId, k -> new ArrayList<>()).add(todo);
        
        return todo;
    }
    
    public Todo getTodoById(int todoId) {
        return todosById.get(todoId);
    }
    
    public List<Todo> getTodosForUser(int userId) {
        List<Todo> userTodos = userTodosMap.getOrDefault(userId, new ArrayList<>());
        // Sort by ID ascending
        userTodos.sort(Comparator.comparingInt(t -> t.id));
        return new ArrayList<>(userTodos); // Return a copy for thread safety
    }
    
    public Todo updateTodo(int todoId, String title, String description, Boolean completed) {
        Todo todo = todosById.get(todoId);
        if (todo != null) {
            if (title != null) {
                if (title.trim().isEmpty()) {
                    throw new IllegalArgumentException("Title cannot be empty");
                }
                todo.title = title;
            }
            if (description != null) {
                todo.description = description;
            }
            if (completed != null) {
                todo.completed = completed;
            }
            
            // Update the timestamp
            Instant now = Instant.now();
            todo.updated_at = FORMATTER.format(now.atOffset(ZoneOffset.UTC));
        }
        return todo;
    }
    
    public boolean deleteTodo(int todoId) {
        Todo todo = todosById.remove(todoId);
        if (todo != null) {
            // Remove from user's todo list
            for (List<Todo> userList : userTodosMap.values()) {
                userList.removeIf(t -> t.id == todoId);
            }
            return true;
        }
        return false;
    }
    
    public boolean isTodoOwnedByUser(int todoId, int userId) {
        List<Todo> userTodos = userTodosMap.get(userId);
        if (userTodos == null) return false;
        return userTodos.stream().anyMatch(todo -> todo.id == todoId);
    }
}
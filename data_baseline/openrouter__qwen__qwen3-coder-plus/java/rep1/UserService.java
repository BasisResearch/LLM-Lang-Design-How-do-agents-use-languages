import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.Base64;

public class UserService {
    private Map<String, User> usersByUsername = new ConcurrentHashMap<>();
    private Map<Integer, User> usersById = new ConcurrentHashMap<>();
    private Map<Integer, String> passwordsByUser = new ConcurrentHashMap<>(); // userId -> hashed password
    private Integer nextUserId = 1;
    
    public synchronized int getNextUserId() {
        return nextUserId++;
    }
    
    public User createUser(String username, String password) {
        User user = new User();
        user.id = getNextUserId();
        user.username = username;
        usersByUsername.put(username, user);
        usersById.put(user.id, user);
        setPasswordForUser(user.id, password);
        return user;
    }
    
    public User findUserById(int userId) {
        return usersById.get(userId);
    }
    
    public User findUserByUsername(String username) {
        return usersByUsername.get(username);
    }
    
    public boolean validatePassword(int userId, String password) {
        String expectedHash = passwordsByUser.get(userId);
        if (expectedHash == null) return false;
        return expectedHash.equals(hashPassword(password));
    }
    
    public void setPasswordForUser(int userId, String password) {
        passwordsByUser.put(userId, hashPassword(password));
    }
    
    public boolean isUsernameTaken(String username) {
        return usersByUsername.containsKey(username);
    }

    private String hashPassword(String password) {
        // For simplicity, just use basic hashing. In production we'd use bcrypt/scrypt/argon2
        return Base64.getEncoder().encodeToString(password.getBytes());
    }
}
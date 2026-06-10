package com.todoserver;

import java.util.concurrent.ConcurrentHashMap;
import java.util.Map;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.concurrent.atomic.AtomicInteger;

public class UserService {
    private Map<String, User> usersByUsername;
    private Map<Integer, User> usersById;
    private AtomicInteger userIdCounter;
    private MessageDigest digest;

    public UserService() {
        this.usersByUsername = new ConcurrentHashMap<>();
        this.usersById = new ConcurrentHashMap<>();
        this.userIdCounter = new AtomicInteger(1);
        
        try {
            this.digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException("SHA-256 algorithm not available", e);
        }
    }

    public User registerUser(String username, String password) {
        String hashedPassword = hashPassword(password);
        int id = userIdCounter.getAndIncrement();
        User user = new User(id, username, hashedPassword);
        
        usersByUsername.put(username, user);
        usersById.put(id, user);
        
        return user;
    }

    public User authenticateUser(String username, String password) {
        User user = usersByUsername.get(username);
        if (user != null && user.getPasswordHash().equals(hashPassword(password))) {
            return user;
        }
        return null;
    }

    public User getUserById(int id) {
        return usersById.get(id);
    }

    public User getUserByUsername(String username) {
        return usersByUsername.get(username);
    }

    public boolean updatePassword(int userId, String oldPassword, String newPassword) {
        User user = usersById.get(userId);
        if (user != null && user.getPasswordHash().equals(hashPassword(oldPassword))) {
            user.setPasswordHash(hashPassword(newPassword));
            return true;
        }
        return false;
    }

    private String hashPassword(String password) {
        byte[] hashBytes = digest.digest(password.getBytes());
        
        // Convert to hexadecimal representation
        StringBuilder hexString = new StringBuilder();
        for (byte b : hashBytes) {
            String hex = Integer.toHexString(0xff & b);
            if (hex.length() == 1) {
                hexString.append('0');
            }
            hexString.append(hex);
        }
        return hexString.toString();
    }
}
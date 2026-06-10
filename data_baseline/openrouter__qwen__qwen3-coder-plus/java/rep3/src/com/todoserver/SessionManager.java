package com.todoserver;

import java.util.concurrent.ConcurrentHashMap;
import java.util.UUID;

public class SessionManager {
    private ConcurrentHashMap<String, Integer> sessions = new ConcurrentHashMap<>();
    
    public String createSession(int userId) {
        String sessionId = UUID.randomUUID().toString();
        sessions.put(sessionId, userId);
        return sessionId;
    }
    
    public Integer getUserIdFromSession(String sessionId) {
        return sessions.get(sessionId);
    }
    
    public boolean invalidateSession(String sessionId) {
        return sessions.remove(sessionId) != null;
    }
    
    public boolean isValidSession(String sessionId) {
        return sessions.containsKey(sessionId);
    }
}
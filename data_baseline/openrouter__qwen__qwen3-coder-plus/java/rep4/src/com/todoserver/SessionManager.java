package com.todoserver;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

public class SessionManager {
    private final Map<String, Session> sessions = new ConcurrentHashMap<>();
    
    public String createSession(int userId) {
        String sessionId = generateSessionToken();
        sessions.put(sessionId, new Session(userId));
        return sessionId;
    }
    
    public Session getSession(String sessionId) {
        if (sessionId == null) {
            return null;
        }
        return sessions.get(sessionId);
    }
    
    public boolean logoutSession(String sessionId) {
        if (sessionId == null) {
            return false;
        }
        return sessions.remove(sessionId) != null;
    }
    
    private String generateSessionToken() {
        return UUID.randomUUID().toString();
    }
    
    static class Session {
        final int userId;
        
        Session(int userId) {
            this.userId = userId;
        }
    }
}
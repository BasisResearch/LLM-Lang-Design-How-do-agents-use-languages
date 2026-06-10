package com.todoserver;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.UUID;

public class SessionManager {
    private Map<String, Session> sessions;
    
    public SessionManager() {
        this.sessions = new ConcurrentHashMap<>();
    }
    
    public String createSession(int userId) {
        String sessionId = generateSessionId();
        Session session = new Session(userId, System.currentTimeMillis());
        sessions.put(sessionId, session);
        return sessionId;
    }
    
    public Integer getUserIdBySession(String sessionId) {
        Session session = sessions.get(sessionId);
        if (session != null) {
            return session.getUserId();
        }
        return null;
    }
    
    public void destroySession(String sessionId) {
        sessions.remove(sessionId);
    }
    
    private String generateSessionId() {
        return UUID.randomUUID().toString();
    }
    
    private static class Session {
        private final int userId;
        private final long createdAt;
        
        public Session(int userId, long createdAt) {
            this.userId = userId;
            this.createdAt = createdAt;
        }
        
        public int getUserId() {
            return userId;
        }
        
        public long getCreatedAt() {
            return createdAt;
        }
    }
}
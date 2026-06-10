import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.UUID;

public class SessionService {
    private Map<String, Integer> sessions = new ConcurrentHashMap<>(); // sessionId -> userId
    
    public String createSession(int userId) {
        String sessionId = UUID.randomUUID().toString();
        sessions.put(sessionId, userId);
        return sessionId;
    }
    
    public Integer getUserIdFromSession(String sessionId) {
        return sessions.get(sessionId);
    }
    
    public void removeSession(String sessionId) {
        sessions.remove(sessionId);
    }
    
    public boolean isValid(String sessionId) {
        return sessions.containsKey(sessionId);
    }
}
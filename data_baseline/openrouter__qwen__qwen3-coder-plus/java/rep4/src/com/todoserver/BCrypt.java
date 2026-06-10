package com.todoserver;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;

/**
 * Simple bcrypt-like password hashing implementation
 * NOTE: This is not a real bcrypt implementation just for this context
 * In production, use an actual bcrypt library like jBcrypt
 */
public class BCrypt {
    private static final String ALGORITHM = "SHA-256";
    private static final SecureRandom random = new SecureRandom();

    public static String gensalt() {
        byte[] salt = new byte[16];
        random.nextBytes(salt);
        return Base64.getEncoder().encodeToString(salt);
    }

    public static String hashpw(String password, String salt) {
        try {
            MessageDigest md = MessageDigest.getInstance(ALGORITHM);
            md.update(Base64.getDecoder().decode(salt));
            byte[] hashed = md.digest(password.getBytes());
            
            // Combine salt and hash for storage
            return salt + "$" + Base64.getEncoder().encodeToString(hashed);
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException("Algorithm not available", e);
        }
    }

    public static boolean checkpw(String password, String hashed) {
        try {
            String[] parts = hashed.split("\\$");
            if (parts.length != 2) {
                return false;
            }
            
            String salt = parts[0];
            String expectedHash = parts[1];
            
            String actualHash = hashpw(password, salt).split("\\$")[1]; // Get just the hash part
            
            return constantTimeEquals(expectedHash, actualHash);
        } catch (Exception e) {
            return false;
        }
    }

    // To prevent timing attacks
    private static boolean constantTimeEquals(String a, String b) {
        if (a.length() != b.length()) {
            return false;
        }
        
        int result = 0;
        for (int i = 0; i < a.length(); i++) {
            result |= a.charAt(i) ^ b.charAt(i);
        }
        
        return result == 0;
    }
}
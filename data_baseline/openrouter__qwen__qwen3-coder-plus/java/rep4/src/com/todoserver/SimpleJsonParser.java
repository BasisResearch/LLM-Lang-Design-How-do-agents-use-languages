package com.todoserver;

import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * A simple JSON parser specifically for our use cases
 */
public class SimpleJsonParser {
    
    public static Map<String, String> parseJsonObject(String json) {
        Map<String, String> map = new HashMap<>();
        json = json.trim();
        
        if (!json.startsWith("{") || !json.endsWith("}")) {
            throw new IllegalArgumentException("Not a valid JSON object");
        }
        
        // Remove outer braces
        json = json.substring(1, json.length() - 1).trim();
        
        // This is a simple implementation assuming well-formed JSON
        int braceCount = 0;
        StringBuilder keyBuilder = new StringBuilder();
        StringBuilder valueBuilder = new StringBuilder();
        char state = 'k'; // 'k' for key, 'v' for value
        int start = 0;
        
        for (int i = 0; i < json.length(); i++) {
            char c = json.charAt(i);
            
            if (c == '{' || c == '[') {
                braceCount++;
            } else if (c == '}' || c == ']') {
                braceCount--;
            }
            
            if (state == 'k') {
                if (c == '"') {
                    start = i + 1;
                    state = 'K';  // inside key quotes
                } else if (c != ' ' && c != ':') {
                    // Key should be in quotes
                    break; // Invalid format
                }
            } else if (state == 'K') {  // inside key quotes
                if (c == '"') {
                    keyBuilder = new StringBuilder(json.substring(start, i));
                    state = 'c'; // colon
                }
            } else if (state == 'c') {  // colon
                if (c == ':') {
                    state = 'w';  // after colon, waiting for value
                } else if (c != ' ') {
                    break; // malformed
                }
            } else if (state == 'w') {  // waiting for value
                if (c == '"') {
                    start = i + 1;
                    state = 'V';  // inside value quote
                } else if (c == '{') {
                    // Find matching closing brace
                    int braceStart = i;
                    int count = 1;
                    i++;
                    while (i < json.length() && count > 0) {
                        if (json.charAt(i) == '{' || json.charAt(i) == '[') {
                            count++;
                        } else if (json.charAt(i) == '}' || json.charAt(i) == ']') {
                            count--;
                        }
                        i++;
                    }
                    if (count == 0) {
                        map.put(keyBuilder.toString(), json.substring(braceStart, i));
                        keyBuilder.setLength(0);
                        state = 'a'; // comma or end
                        i--; // go back one position to process the current character in next iteration
                    } else {
                        throw new IllegalArgumentException("Unmatched braces");
                    }
                } else if (c == '[') {
                    // Find matching closing bracket
                    int bracketStart = i;
                    int count = 1;
                    i++;
                    while (i < json.length() && count > 0) {
                        if (json.charAt(i) == '{' || json.charAt(i) == '[') {
                            count++;
                        } else if (json.charAt(i) == '}' || json.charAt(i) == ']') {
                            count--;
                        }
                        i++;
                    }
                    if (count == 0) {
                        map.put(keyBuilder.toString(), json.substring(bracketStart, i));
                        keyBuilder.setLength(0);
                        state = 'a'; // comma or end
                        i--; // go back one position to process the current character in next iteration
                    } else {
                        throw new IllegalArgumentException("Unmatched brackets");
                    }
                } else if (c == 't' || c == 'f' || c == 'n' || (c >= '0' && c <= '9')) {
                    // boolean/null/number - find the end
                    start = i;
                    if (c == 't') {
                        if (i + 3 < json.length() && json.substring(i, i+4).equals("true")) {
                            i += 3;
                        } else {
                            throw new IllegalArgumentException("Expected 'true'");
                        }
                    } else if (c == 'f') {
                        if (i + 4 < json.length() && json.substring(i, i+5).equals("false")) {
                            i += 4;
                        } else {
                            throw new IllegalArgumentException("Expected 'false'");
                        }
                    } else if (c == 'n') {
                        if (i + 3 < json.length() && json.substring(i, i+4).equals("null")) {
                            i += 3;
                        } else {
                            throw new IllegalArgumentException("Expected 'null'");
                        }
                    } else {
                        // number
                        while (i < json.length() && (Character.isDigit(json.charAt(i)) || json.charAt(i) == '.' || json.charAt(i) == '-' || json.charAt(i) == '+' || json.charAt(i) == 'e' || json.charAt(i) == 'E')) {
                            i++;
                        }
                        i--; // compensate for ++ in for loop
                    }
                    map.put(keyBuilder.toString(), json.substring(start, i + 1));
                    keyBuilder.setLength(0);
                    state = 'a';
                } else if (c != ' ') {
                    break; // unexpected char
                }
            } else if (state == 'V') {  // inside value quotes
                if (c == '"') {
                    // Handle escape sequence before adding value
                    valueBuilder.setLength(0);
                    for (int j = start; j < i; j++) {
                        if (json.charAt(j) == '\\' && j + 1 < i) {
                            char nextChar = json.charAt(j + 1);
                            switch (nextChar) {
                                case '"': valueBuilder.append('"'); j++; break;
                                case '\\': valueBuilder.append('\\'); j++; break;
                                case '/': valueBuilder.append('/'); j++; break;
                                case 'b': valueBuilder.append('\b'); j++; break;
                                case 'f': valueBuilder.append('\f'); j++; break;
                                case 'n': valueBuilder.append('\n'); j++; break;
                                case 'r': valueBuilder.append('\r'); j++; break;
                                case 't': valueBuilder.append('\t'); j++; break;
                                default:
                                    valueBuilder.append(nextChar);
                                    j++;
                                    break;
                            }
                        } else {
                            valueBuilder.append(json.charAt(j));
                        }
                    }
                    
                    map.put(keyBuilder.toString(), valueBuilder.toString());
                    keyBuilder.setLength(0);
                    state = 'a'; // comma or end
                }
            } else if (state == 'a') {  // expect comma or end
                if (c == ',') {
                    state = 'k'; // back to key
                } else if (c == '}') {
                    break; // shouldn't happen normally, but handle
                } else if (c != ' ') {
                    // unexpected character
                    break;
                }
            }
        }
        
        return map;
    }
    
    /**
     * Parse simple string value from a string representation that may contain quotes
     */
    public static String parseStringValue(String value) {
        if (value == null) return null;
        value = value.trim();
        if (value.startsWith("\"") && value.endsWith("\"")) {
            // Remove quotes and handle escapes inside
            StringBuilder sb = new StringBuilder();
            for (int i = 1; i < value.length() - 1; i++) {
                char c = value.charAt(i);
                if (c == '\\' && i + 1 < value.length() - 1) {
                    char next = value.charAt(i + 1);
                    switch (next) {
                        case '"': sb.append('"'); i++; break;
                        case '\\': sb.append('\\'); i++; break;
                        case '/': sb.append('/'); i++; break;
                        case 'b': sb.append('\b'); i++; break;
                        case 'f': sb.append('\f'); i++; break;
                        case 'n': sb.append('\n'); i++; break;
                        case 'r': sb.append('\r'); i++; break;
                        case 't': sb.append('\t'); i++; break;
                        default:
                            sb.append(next);
                            i++;
                            break;
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }
        return value;
    }
    
    public static boolean parseBooleanValue(String value) {
        return "true".equals(value);
    }
    
    public static int parseIntValue(String value) {
        return Integer.parseInt(value);
    }
}
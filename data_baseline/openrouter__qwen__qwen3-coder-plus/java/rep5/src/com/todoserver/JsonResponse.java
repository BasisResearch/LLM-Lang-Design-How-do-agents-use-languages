package com.todoserver;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.ArrayList;

// A simple JSON parser/generator for our needs
public class JsonResponse {
    private Map<String, Object> map;

    public JsonResponse() {
        this.map = new HashMap<>();
    }

    public JsonResponse(Object obj) {
        this();
        if (obj instanceof User) {
            User user = (User) obj;
            map.put("id", user.getId());
            map.put("username", user.getUsername());
        } else if (obj instanceof Todo) {
            Todo todo = (Todo) obj;
            map.put("id", todo.getId());
            map.put("title", todo.getTitle());
            map.put("description", todo.getDescription());
            map.put("completed", todo.isCompleted());
            map.put("created_at", todo.getCreatedAt());
            map.put("updated_at", todo.getUpdatedAt());
        } else if (obj instanceof List<?>) {
            List<?> list = (List<?>) obj;
            List<Object> convertedList = new ArrayList<>();
            for (Object item : list) {
                if (item instanceof User || item instanceof Todo) {
                    convertedList.add(new JsonResponse(item).map);
                } else {
                    convertedList.add(item);
                }
            }
            this.map = new HashMap<>();
            // This case returns the array as the root object
            this.map.put("$array$", convertedList);
        }
    }

    public void put(String key, Object value) {
        map.put(key, value);
    }

    public String getString(String key) {
        Object value = map.get(key);
        if (value == null) return null;
        return value.toString();
    }

    public Boolean getBoolean(String key) {
        Object value = map.get(key);
        if (value == null) return null;
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        if (value instanceof String) {
            return Boolean.parseBoolean((String) value);
        }
        return null;
    }

    @Override
    public String toString() {
        if (map.containsKey("$array$")) {
            // Root object was actually an array
            List<Object> list = (List<Object>) map.get("$array$");
            StringBuilder sb = new StringBuilder();
            sb.append("[");
            for (int i = 0; i < list.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(objectToJSON(list.get(i)));
            }
            sb.append("]");
            return sb.toString();
        }

        StringBuilder sb = new StringBuilder();
        sb.append("{");
        boolean first = true;
        for (Map.Entry<String, Object> entry : map.entrySet()) {
            if (!first) {
                sb.append(",");
            }
            sb.append("\"").append(escapeJson(entry.getKey())).append("\":");
            sb.append(objectToJSON(entry.getValue()));
            first = false;
        }
        sb.append("}");
        return sb.toString();
    }

    private String objectToJSON(Object obj) {
        if (obj instanceof String) {
            return "\"" + escapeJson((String) obj) + "\"";
        } else if (obj instanceof Integer || obj instanceof Long) {
            return obj.toString();
        } else if (obj instanceof Boolean) {
            return obj.toString();
        } else if (obj == null) {
            return "null";
        } else if (obj instanceof Double || obj instanceof Float) {
            return obj.toString();
        } else if (obj instanceof Map) {
            JsonResponse rsp = new JsonResponse();
            rsp.map = (Map<String, Object>) obj;
            return rsp.toString();
        } else {
            // Handle objects by trying to convert them properly
            JsonResponse rsp = new JsonResponse(obj);
            Map<String, Object> innerMap = rsp.map;
            if (innerMap.size() > 0) {  // Not empty - meaning conversion happened properly
                rsp = new JsonResponse();
                rsp.map = innerMap;
                return rsp.toString();
            } else {
                // Just treat as string representation
                return "\"" + escapeJson(obj.toString()) + "\"";
            }
        }
    }

    private String escapeJson(String s) {
        if (s == null) return null;
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\b", "\\b")
                .replace("\f", "\\f")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }

    // Simple JSON parser to convert strings back to objects
    public static JsonResponse parseJson(String jsonString) {
        try {
            if (jsonString == null || jsonString.trim().isEmpty()) {
                return null;
            }
            
            JsonResponse response = new JsonResponse();
            Map<String, Object> parsed = parseJsonObject(jsonString.trim());
            if (parsed != null) {
                response.map = parsed;
            } else {
                return null;
            }
            
            return response;
        } catch (Exception e) {
            e.printStackTrace();
            return null;
        }
    }

    private static Map<String, Object> parseJsonObject(String json) {
        json = json.trim();
        if (!json.startsWith("{") || !json.endsWith("}")) {
            // Could be an array
            return null; // Let's handle arrays separately
        }
        
        json = json.substring(1, json.length() - 1); // Remove outer {}
        Map<String, Object> result = new java.util.LinkedHashMap<>();
        
        // Find pairs: "key": value
        int pos = 0;
        while (pos < json.length()) {
            pos = skipWhitespace(json, pos);
            
            if (pos >= json.length()) {
                break;
            }
            
            // Read key
            if (json.charAt(pos) != '"') {
                return null; // Expected key
            }
            
            pos++;
            int keyStart = pos;
            pos = json.indexOf('"', pos);
            if (pos == -1) {
                return null; // Malformed
            }
            String key = json.substring(keyStart, pos);
            pos++; // Skip closing quote
            
            // Skip whitespace and colon
            pos = skipWhitespace(json, pos);
            if (pos >= json.length() || json.charAt(pos) != ':') {
                return null; // Expected colon
            }
            pos++;
            
            pos = skipWhitespace(json, pos);
            
            // Parse value
            ParseResult valueResult = parseValue(json, pos);
            if (valueResult == null) {
                return null; // Failed to parse
            }
            
            result.put(key, valueResult.value);
            pos = valueResult.nextPos;
            
            // Skip potential comma
            pos = skipWhitespace(json, pos);
            if (pos < json.length() && json.charAt(pos) == ',') {
                pos++;
            }
        }
        
        return result;
    }

    private static ParseResult parseValue(String json, int startPos) {
        int pos = startPos;
        pos = skipWhitespace(json, pos);
        
        if (pos >= json.length()) {
            return null;
        }
        
        char c = json.charAt(pos);
        
        if (c == '"') {  // String
            pos++;
            int start = pos;
            int end = findStringEnd(json, pos);
            if (end == -1) {
                return null; // Malformed string
            }
            String value = json.substring(start, end);
            value = unescapeString(value);
            return new ParseResult(value, end + 1);
        } else if (Character.isDigit(c) || c == '-') {  // Number
            int end = pos;
            while (end < json.length() && 
                   (Character.isDigit(json.charAt(end)) || json.charAt(end) == '.' || json.charAt(end) == '-')) {
                end++;
            }
            String numStr = json.substring(pos, end);
            if (numStr.contains(".")) {
                return new ParseResult(Double.parseDouble(numStr), end);
            } else {
                return new ParseResult(Integer.parseInt(numStr), end);
            }
        } else if (json.startsWith("true", pos)) {  // Boolean true
            return new ParseResult(true, pos + 4);
        } else if (json.startsWith("false", pos)) {  // Boolean false
            return new ParseResult(false, pos + 5);
        } else if (json.startsWith("null", pos)) {  // Null
            return new ParseResult(null, pos + 4);
        } else if (json.charAt(pos) == '{') {  // Nested object
            int objEnd = findMatchingBrace(json, pos);
            if (objEnd == -1) {
                return null;
            }
            String nestedObj = json.substring(pos, objEnd + 1);
            Map<String, Object> nested = parseJsonObject(nestedObj);
            return new ParseResult(nested, objEnd + 1);
        } else {
            return null; // Unsupported type
        }
    }

    private static int findStringEnd(String json, int startPos) {
        int pos = startPos;
        while (pos < json.length()) {
            char c = json.charAt(pos);
            if (c == '"') {
                // Check if it's escaped
                int backslashes = 0;
                int temp = pos - 1;
                while (temp >= 0 && json.charAt(temp) == '\\') {
                    backslashes++;
                    temp--;
                }
                if (backslashes % 2 == 0) {  // Even number of backslashes means quote isn't escaped
                    return pos;
                }
            }
            pos++;
        }
        return -1; // Not found
    }

    private static String unescapeString(String str) {
        return str.replace("\\\"", "\"")
                 .replace("\\\\", "\\")
                 .replace("\\b", "\b")
                 .replace("\\f", "\f")
                 .replace("\\n", "\n")
                 .replace("\\r", "\r")
                 .replace("\\t", "\t");
    }

    private static int findMatchingBrace(String json, int startPos) {
        int braceCount = 0;
        int pos = startPos;
        
        while (pos < json.length()) {
            char c = json.charAt(pos);
            if (c == '{') {
                braceCount++;
            } else if (c == '}') {
                braceCount--;
                if (braceCount == 0) {
                    return pos;
                }
            }
            pos++;
        }
        
        return -1; // Not found
    }

    private static int skipWhitespace(String json, int pos) {
        while (pos < json.length() && Character.isWhitespace(json.charAt(pos))) {
            pos++;
        }
        return pos;
    }

    private static class ParseResult {
        Object value;
        int nextPos;

        ParseResult(Object value, int nextPos) {
            this.value = value;
            this.nextPos = nextPos;
        }
    }

    // For debugging/testing purposes
    public Map<String, Object> getMap() {
        return map;
    }
}
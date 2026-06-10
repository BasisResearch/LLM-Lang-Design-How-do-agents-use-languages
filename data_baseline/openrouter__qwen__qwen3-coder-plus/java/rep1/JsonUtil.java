import java.util.*;

// Very simple JSON parser that handles our specific needs (no recursion handling or complex cases)
public class JsonUtil {
    public static Map<String, Object> parseJson(String jsonString) {
        jsonString = jsonString.trim();
        
        if (jsonString.startsWith("{") && jsonString.endsWith("}")) {
            return parseObject(jsonString.substring(1, jsonString.length() - 1).trim());
        } else if (jsonString.startsWith("[") && jsonString.endsWith("]")) {
            return Collections.singletonMap("array_data", parseArray(jsonString.substring(1, jsonString.length() - 1)));
        }
        
        throw new RuntimeException("Invalid JSON");
    }
    
    private static Map<String, Object> parseObject(String objStr) {
        Map<String, Object> map = new HashMap<>();
        
        // Handle empty object
        if (objStr.trim().isEmpty()) {
            return map;
        }
        
        int braceCount = 0;
        int bracketCount = 0;
        int startIdx = 0;
        int idx = 0;
        
        while (idx < objStr.length()) {
            char c = objStr.charAt(idx);
            if (c == '{') {
                braceCount++;
            } else if (c == '}') {
                braceCount--;
            } else if (c == '[') {
                bracketCount++;
            } else if (c == ']') {
                bracketCount--;
            } else if (c == '"' && idx > 0 && objStr.charAt(idx - 1) != '\\') {
                // Skip values inside strings when looking for commas
                idx++; // Move past first quote
                while (idx < objStr.length() && (objStr.charAt(idx) != '"' || (idx > 0 && objStr.charAt(idx - 1) == '\\'))) {
                    idx++;
                }
                idx++; // move past closing quote
                continue; // Continue loop without incrementing further
            } else if (c == ',' && braceCount == 0 && bracketCount == 0) {
                processKeyValuePair(objStr.substring(startIdx, idx), map);
                idx++; 
                while (idx < objStr.length() && Character.isWhitespace(objStr.charAt(idx))) idx++;
                startIdx = idx;
                continue;
            }
            idx++;
        }
        
        if (startIdx < idx) {
            processKeyValuePair(objStr.substring(startIdx, idx), map);
        }
        
        return map;
    }
    
    private static void processKeyValuePair(String pair, Map<String, Object> map) {
        pair = pair.trim();
        if (pair.isEmpty()) return;
        
        // Find the colon that separates key from value
        int colonIndex = -1;
        int braceCount = 0;
        int bracketCount = 0;
        
        for (int i = 0; i < pair.length(); i++) {
            char c = pair.charAt(i);
            if (c == '{') {
                braceCount++;
            } else if (c == '}') {
                braceCount--;
            } else if (c == '[') {
                bracketCount++;
            } else if (c == ']') {
                bracketCount--;
            } else if (c == '"' && i > 0 && pair.charAt(i - 1) != '\\') {
                // Skip string context when considering colon position
                i++; // Move to after opening quote
                while (i < pair.length() && (pair.charAt(i) != '"' || (i > 0 && pair.charAt(i - 1) == '\\'))) {
                    i++;
                }
            } else if (c == ':' && braceCount == 0 && bracketCount == 0) {
                colonIndex = i;
                break;
            }
        }
        
        if (colonIndex == -1) return;
        
        String keyPart = pair.substring(0, colonIndex).trim();
        String valuePart = pair.substring(colonIndex + 1).trim();
        
        String key = parseString(keyPart);
        Object value = parseValue(valuePart);
        
        map.put(key, value);
    }
    
    private static Object parseValue(String val) {
        val = val.trim();
        if (val.startsWith("\"") && val.endsWith("\"")) {
            return parseString(val);
        } else if (val.equals("true")) {
            return true;
        } else if (val.equals("false")) {
            return false;
        } else if (val.equals("null")) {
            return null;
        } else if (Character.isDigit(val.charAt(0)) || val.charAt(0) == '-') {
            if (val.contains(".")) {
                return Double.parseDouble(val);
            } else {
                return Long.parseLong(val);
            }
        } else if (val.startsWith("{") && val.endsWith("}")) {
            return parseObject(val.substring(1, val.length() - 1));
        } else if (val.startsWith("[") && val.endsWith("]")) {
            return parseArray(val.substring(1, val.length() - 1));
        }
        return val; // Default fallback
    }
    
    private static String parseString(String str) {
        if (str.startsWith("\"") && str.endsWith("\"")) {
            String unquoted = str.substring(1, str.length() - 1);
            // Properly unescape string
            return unquoted.replace("\\\"", "\"")
                          .replace("\\\\", "\\")
                          .replace("\\n", "\n")
                          .replace("\\r", "\r")
                          .replace("\\t", "\t");
        }
        throw new RuntimeException("Invalid string format: " + str);
    }
    
    private static List<Object> parseArray(String arrayStr) {
        List<Object> list = new ArrayList<>();
        
        // Handle empty array
        if (arrayStr.trim().isEmpty()) {
            return list;
        }
        
        int braceCount = 0;
        int bracketCount = 0;
        int startIdx = 0;
        int idx = 0;
        
        while (idx < arrayStr.length()) {
            char c = arrayStr.charAt(idx);
            if (c == '{') {
                braceCount++;
            } else if (c == '}') {
                braceCount--;
            } else if (c == '[') {
                bracketCount++;
            } else if (c == ']') {
                bracketCount--;
            } else if (c == '"' && idx > 0 && arrayStr.charAt(idx - 1) != '\\') {
                // Skip values inside strings when looking for commas
                idx++; // Move past first quote
                while (idx < arrayStr.length() && (arrayStr.charAt(idx) != '"' || (idx > 0 && arrayStr.charAt(idx - 1) == '\\'))) {
                    idx++;
                }
                idx++; // move past closing quote
                continue; // Continue loop without incrementing further
            } else if (c == ',' && braceCount == 0 && bracketCount == 0) {
                String item = arrayStr.substring(startIdx, idx).trim();
                list.add(parseValue(item));
                idx++; 
                while (idx < arrayStr.length() && Character.isWhitespace(arrayStr.charAt(idx))) idx++;
                startIdx = idx;
                continue;
            }
            idx++;
        }
        
        if (startIdx < idx) {
            String item = arrayStr.substring(startIdx, idx).trim();
            list.add(parseValue(item));
        }
        
        return list;
    }
}
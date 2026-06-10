import java.util.*;

public class Json {
    // Very small JSON parser/serializer for our limited needs
    // Parses into Map<String,Object>, List<Object>, String, Double (numbers), Boolean, or null

    public static Object parse(String s) {
        if (s == null) return null;
        Parser p = new Parser(s);
        Object val = p.parseValue();
        p.skipWhitespace();
        if (!p.eof()) throw new RuntimeException("Trailing data");
        return val;
    }

    public static String stringify(Object obj) {
        StringBuilder sb = new StringBuilder();
        writeValue(sb, obj);
        return sb.toString();
    }

    private static void writeValue(StringBuilder sb, Object obj) {
        if (obj == null) {
            sb.append("null");
        } else if (obj instanceof String) {
            writeString(sb, (String) obj);
        } else if (obj instanceof Number) {
            sb.append(((Number) obj).toString());
        } else if (obj instanceof Boolean) {
            sb.append(((Boolean)obj).booleanValue() ? "true" : "false");
        } else if (obj instanceof Map) {
            @SuppressWarnings("unchecked")
            Map<String,Object> m = (Map<String,Object>) obj;
            sb.append('{');
            boolean first = true;
            for (Map.Entry<String,Object> e : m.entrySet()) {
                if (!first) sb.append(',');
                first = false;
                writeString(sb, e.getKey());
                sb.append(':');
                writeValue(sb, e.getValue());
            }
            sb.append('}');
        } else if (obj instanceof List) {
            @SuppressWarnings("unchecked")
            List<Object> list = (List<Object>) obj;
            sb.append('[');
            boolean first = true;
            for (Object v : list) {
                if (!first) sb.append(',');
                first = false;
                writeValue(sb, v);
            }
            sb.append(']');
        } else {
            // Fallback to string
            writeString(sb, String.valueOf(obj));
        }
    }

    private static void writeString(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int)c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        sb.append('"');
    }

    private static class Parser {
        private final String s;
        private int i = 0;
        Parser(String s) { this.s = s; }
        boolean eof() { return i >= s.length(); }
        void skipWhitespace() {
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c==' '||c=='\n'||c=='\r'||c=='\t') i++; else break;
            }
        }
        char peek() { return s.charAt(i); }
        char next() { return s.charAt(i++); }

        Object parseValue() {
            skipWhitespace();
            if (eof()) return null;
            char c = peek();
            if (c == '{') return parseObject();
            if (c == '[') return parseArray();
            if (c == '"') return parseString();
            if (c == 't' || c == 'f') return parseBoolean();
            if (c == 'n') return parseNull();
            return parseNumberOrError();
        }

        Object parseObject() {
            Map<String,Object> m = new LinkedHashMap<>();
            next(); // {
            skipWhitespace();
            if (!eof() && peek() == '}') { next(); return m; }
            while (true) {
                skipWhitespace();
                if (eof() || peek() != '"') throw new RuntimeException("Expected string key");
                String key = parseString();
                skipWhitespace();
                if (eof() || next() != ':') throw new RuntimeException("Expected colon");
                Object val = parseValue();
                m.put(key, val);
                skipWhitespace();
                if (eof()) throw new RuntimeException("Unterminated object");
                char c = next();
                if (c == '}') break;
                if (c != ',') throw new RuntimeException("Expected comma");
            }
            return m;
        }

        List<Object> parseArray() {
            List<Object> list = new ArrayList<>();
            next(); // [
            skipWhitespace();
            if (!eof() && peek() == ']') { next(); return list; }
            while (true) {
                Object v = parseValue();
                list.add(v);
                skipWhitespace();
                if (eof()) throw new RuntimeException("Unterminated array");
                char c = next();
                if (c == ']') break;
                if (c != ',') throw new RuntimeException("Expected comma");
            }
            return list;
        }

        String parseString() {
            StringBuilder sb = new StringBuilder();
            if (next() != '"') throw new RuntimeException("Expected quote");
            while (!eof()) {
                char c = next();
                if (c == '"') break;
                if (c == '\\') {
                    if (eof()) throw new RuntimeException("Bad escape");
                    char e = next();
                    switch (e) {
                        case '"': sb.append('"'); break;
                        case '\\': sb.append('\\'); break;
                        case '/': sb.append('/'); break;
                        case 'b': sb.append('\b'); break;
                        case 'f': sb.append('\f'); break;
                        case 'n': sb.append('\n'); break;
                        case 'r': sb.append('\r'); break;
                        case 't': sb.append('\t'); break;
                        case 'u':
                            if (i + 4 > s.length()) throw new RuntimeException("Bad unicode");
                            String hex = s.substring(i, i + 4);
                            i += 4;
                            char uc = (char) Integer.parseInt(hex, 16);
                            sb.append(uc);
                            break;
                        default: throw new RuntimeException("Bad escape");
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }

        Object parseBoolean() {
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
            throw new RuntimeException("Invalid boolean");
        }

        Object parseNull() {
            if (s.startsWith("null", i)) { i += 4; return null; }
            throw new RuntimeException("Invalid null");
        }

        Object parseNumberOrError() {
            int start = i;
            boolean hasDot = false;
            if (peek() == '-') i++;
            while (!eof()) {
                char c = peek();
                if (c >= '0' && c <= '9') { i++; }
                else if (c == '.' && !hasDot) { hasDot = true; i++; }
                else break;
            }
            if (start == i) throw new RuntimeException("Invalid value");
            String num = s.substring(start, i);
            try {
                if (hasDot) return Double.parseDouble(num);
                return Long.parseLong(num);
            } catch (NumberFormatException e) {
                throw new RuntimeException("Invalid number");
            }
        }
    }
}

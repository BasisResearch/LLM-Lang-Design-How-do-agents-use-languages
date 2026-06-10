import java.util.*;

public class SimpleJson {
    public static class ParseException extends Exception {
        public ParseException(String msg) { super(msg); }
    }

    // Very small JSON parser for objects/arrays/strings/numbers/booleans/null
    public static Map<String, Object> parseObject(String s) throws ParseException {
        Parser p = new Parser(s);
        Object o = p.parseValue();
        if (!(o instanceof Map)) throw new ParseException("Expected JSON object");
        p.skipWhitespace();
        if (!p.isEnd()) throw new ParseException("Trailing data");
        return (Map<String, Object>) o;
    }

    public static List<Object> parseArray(String s) throws ParseException {
        Parser p = new Parser(s);
        Object o = p.parseValue();
        if (!(o instanceof List)) throw new ParseException("Expected JSON array");
        p.skipWhitespace();
        if (!p.isEnd()) throw new ParseException("Trailing data");
        return (List<Object>) o;
    }

    public static String stringify(Object o) {
        StringBuilder sb = new StringBuilder();
        writeJson(sb, o);
        return sb.toString();
    }

    private static void writeJson(StringBuilder sb, Object o) {
        if (o == null) {
            sb.append("null");
        } else if (o instanceof String) {
            sb.append('"').append(escape((String)o)).append('"');
        } else if (o instanceof Number) {
            sb.append(o.toString());
        } else if (o instanceof Boolean) {
            sb.append(((Boolean)o) ? "true" : "false");
        } else if (o instanceof Map) {
            sb.append('{');
            boolean first = true;
            for (Object entryObj : ((Map<?,?>)o).entrySet()) {
                Map.Entry<?,?> e = (Map.Entry<?,?>) entryObj;
                if (!first) sb.append(',');
                first = false;
                sb.append('"').append(escape(String.valueOf(e.getKey()))).append('"').append(':');
                writeJson(sb, e.getValue());
            }
            sb.append('}');
        } else if (o instanceof List) {
            sb.append('[');
            boolean first = true;
            for (Object v : (List<?>)o) {
                if (!first) sb.append(',');
                first = false;
                writeJson(sb, v);
            }
            sb.append(']');
        } else {
            sb.append('"').append(escape(o.toString())).append('"');
        }
    }

    private static String escape(String s) {
        StringBuilder sb = new StringBuilder();
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
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int)c));
                    else sb.append(c);
            }
        }
        return sb.toString();
    }

    private static class Parser {
        private final String s;
        private int i = 0;
        Parser(String s) { this.s = s == null ? "" : s; }
        boolean isEnd() { return i >= s.length(); }
        void skipWhitespace() {
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c == ' ' || c == '\n' || c == '\r' || c == '\t') i++;
                else break;
            }
        }
        Object parseValue() throws ParseException {
            skipWhitespace();
            if (isEnd()) throw new ParseException("Unexpected end of input");
            char c = s.charAt(i);
            if (c == '"') return parseString();
            if (c == '{') return parseObject();
            if (c == '[') return parseArray();
            if (c == 't' || c == 'f') return parseBoolean();
            if (c == 'n') return parseNull();
            if (c == '-' || (c >= '0' && c <= '9')) return parseNumber();
            throw new ParseException("Unexpected char: " + c);
        }
        private Object parseObject() throws ParseException {
            Map<String, Object> map = new LinkedHashMap<>();
            expect('{');
            skipWhitespace();
            if (peek('}')) { expect('}'); return map; }
            while (true) {
                skipWhitespace();
                String key = parseString();
                skipWhitespace();
                expect(':');
                Object value = parseValue();
                map.put(key, value);
                skipWhitespace();
                if (peek('}')) { expect('}'); break; }
                expect(',');
            }
            return map;
        }
        private List<Object> parseArray() throws ParseException {
            List<Object> list = new ArrayList<>();
            expect('[');
            skipWhitespace();
            if (peek(']')) { expect(']'); return list; }
            while (true) {
                Object v = parseValue();
                list.add(v);
                skipWhitespace();
                if (peek(']')) { expect(']'); break; }
                expect(',');
            }
            return list;
        }
        private String parseString() throws ParseException {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (i < s.length()) {
                char c = s.charAt(i++);
                if (c == '"') break;
                if (c == '\\') {
                    if (i >= s.length()) throw new ParseException("Invalid escape");
                    char e = s.charAt(i++);
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
                            if (i + 4 > s.length()) throw new ParseException("Invalid unicode escape");
                            String hex = s.substring(i, i+4);
                            i += 4;
                            try { sb.append((char)Integer.parseInt(hex, 16)); }
                            catch (NumberFormatException ex) { throw new ParseException("Invalid unicode: "+hex); }
                            break;
                        default: throw new ParseException("Invalid escape: " + e);
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }
        private Object parseBoolean() throws ParseException {
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
            throw new ParseException("Invalid boolean");
        }
        private Object parseNull() throws ParseException {
            if (s.startsWith("null", i)) { i += 4; return null; }
            throw new ParseException("Invalid null");
        }
        private Number parseNumber() throws ParseException {
            int start = i;
            if (s.charAt(i) == '-') i++;
            while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
            if (i < s.length() && s.charAt(i) == '.') {
                i++;
                while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
            }
            if (i < s.length() && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
                i++;
                if (i < s.length() && (s.charAt(i) == '+' || s.charAt(i) == '-')) i++;
                while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
            }
            try {
                String num = s.substring(start, i);
                if (num.indexOf('.') >= 0 || num.indexOf('e') >= 0 || num.indexOf('E') >= 0) {
                    return Double.parseDouble(num);
                } else {
                    long val = Long.parseLong(num);
                    if (val <= Integer.MAX_VALUE && val >= Integer.MIN_VALUE) return (int)val;
                    return val;
                }
            } catch (Exception e) {
                throw new ParseException("Invalid number");
            }
        }
        private void expect(char c) throws ParseException {
            if (i >= s.length() || s.charAt(i) != c) throw new ParseException("Expected '"+c+"'");
            i++;
        }
        private boolean peek(char c) {
            return i < s.length() && s.charAt(i) == c;
        }
    }
}

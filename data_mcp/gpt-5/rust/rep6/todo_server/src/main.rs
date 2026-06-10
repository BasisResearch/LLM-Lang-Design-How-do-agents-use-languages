use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::str;
use std::sync::{Arc, Mutex};
use std::thread;

// Minimal libc bindings for time formatting
#[allow(non_camel_case_types)]
type time_t = i64;
#[repr(C)]
#[derive(Default, Clone, Copy)]
struct tm {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
    tm_gmtoff: i64,
    tm_zone: *const i8,
}
extern "C" {
    fn time(tloc: *mut time_t) -> time_t;
    fn gmtime_r(timer: *const time_t, result: *mut tm) -> *mut tm;
    fn strftime(s: *mut i8, max: usize, format: *const i8, tm: *const tm) -> usize;
}

fn now_iso_seconds() -> String {
    // Format: YYYY-MM-DDTHH:MM:SSZ
    let mut t: time_t = 0;
    unsafe { time(&mut t as *mut time_t) };
    let mut out_tm = tm::default();
    unsafe { gmtime_r(&t as *const time_t, &mut out_tm as *mut tm) };
    let fmt = b"%Y-%m-%dT%H:%M:%SZ\0";
    let mut buf = [0i8; 32];
    let n = unsafe { strftime(buf.as_mut_ptr(), buf.len(), fmt.as_ptr() as *const i8, &out_tm as *const tm) };
    let bytes = &buf[..n.min(buf.len())];
    let mut s = String::new();
    for &c in bytes { if c == 0 { break; } s.push(c as u8 as char); }
    s
}

// Data models
#[derive(Clone, Debug)]
struct User { id: i64, username: String, password: String }

#[derive(Clone, Debug)]
struct Todo {
    id: i64,
    user_id: i64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Default)]
struct AppState {
    users: HashMap<i64, User>,
    username_index: HashMap<String, i64>,
    sessions: HashMap<String, i64>, // session_id -> user_id
    todos: HashMap<i64, Todo>,
    next_user_id: i64, // start at 1
    next_todo_id: i64, // start at 1
}

impl AppState {
    fn alloc_user_id(&mut self) -> i64 { if self.next_user_id == 0 { self.next_user_id = 1; } let id = self.next_user_id; self.next_user_id += 1; id }
    fn alloc_todo_id(&mut self) -> i64 { if self.next_todo_id == 0 { self.next_todo_id = 1; } let id = self.next_todo_id; self.next_todo_id += 1; id }
}

// Simple JSON utilities
fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c as u32 <= 0x1F => { out.push_str(&format!("\\u{:04x}", c as u32)); }
            c => out.push(c),
        }
    }
    out
}

fn json_error(message: &str) -> String { format!("{{\"error\": \"{}\"}}", json_escape(message)) }

fn json_user(u: &User) -> String {
    format!("{{\"id\": {}, \"username\": \"{}\"}}", u.id, json_escape(&u.username))
}

fn json_todo(t: &Todo) -> String {
    format!(
        "{{\"id\": {}, \"title\": \"{}\", \"description\": \"{}\", \"completed\": {}, \"created_at\": \"{}\", \"updated_at\": \"{}\"}}",
        t.id, json_escape(&t.title), json_escape(&t.description), if t.completed { "true" } else { "false" }, t.created_at, t.updated_at
    )
}

// Minimal JSON parser for object with string/bool values
#[derive(Debug, Clone)]
enum JVal { Str(String), Bool(bool) }

fn skip_ws(bytes: &[u8], mut i: usize) -> usize { while i < bytes.len() && bytes[i].is_ascii_whitespace() { i += 1; } i }

fn parse_string(bytes: &[u8], mut i: usize) -> Option<(String, usize)> {
    if i >= bytes.len() || bytes[i] != b'"' { return None; }
    i += 1;
    let mut out = String::new();
    while i < bytes.len() {
        let c = bytes[i];
        i += 1;
        match c {
            b'"' => return Some((out, i)),
            b'\\' => {
                if i >= bytes.len() { return None; }
                let e = bytes[i]; i += 1;
                match e {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{0008}'),
                    b'f' => out.push('\u{000C}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        // Expect 4 hex digits
                        if i + 4 > bytes.len() { return None; }
                        let hex = &bytes[i..i+4]; i += 4;
                        let hex_str = str::from_utf8(hex).ok()?;
                        let code = u16::from_str_radix(hex_str, 16).ok()?;
                        if let Some(ch) = char::from_u32(code as u32) { out.push(ch); } else { return None; }
                    }
                    _ => return None,
                }
            }
            _ => out.push(c as char),
        }
    }
    None
}

fn parse_bool(bytes: &[u8], i: usize) -> Option<(bool, usize)> {
    if bytes.get(i..i+4).map(|s| s == b"true").unwrap_or(false) { return Some((true, i+4)); }
    if bytes.get(i..i+5).map(|s| s == b"false").unwrap_or(false) { return Some((false, i+5)); }
    None
}

fn parse_json_object(body: &[u8]) -> Option<HashMap<String, JVal>> {
    let mut i = skip_ws(body, 0);
    if *body.get(i)? != b'{' { return None; }
    i += 1;
    let mut map = HashMap::new();
    loop {
        i = skip_ws(body, i);
        if i >= body.len() { return None; }
        if body[i] == b'}' { break; }
        let (key, ni) = parse_string(body, i)?; i = ni;
        i = skip_ws(body, i);
        if *body.get(i)? != b':' { return None; }
        i += 1;
        i = skip_ws(body, i);
        if i >= body.len() { return None; }
        let (val, ni) = if body[i] == b'"' {
            let (s, ni) = parse_string(body, i)?; (JVal::Str(s), ni)
        } else if body[i] == b't' || body[i] == b'f' {
            let (b, ni) = parse_bool(body, i)?; (JVal::Bool(b), ni)
        } else { return None; };
        map.insert(key, val);
        i = skip_ws(body, ni);
        if i >= body.len() { return None; }
        if body[i] == b',' { i += 1; continue; }
        if body[i] == b'}' { break; }
        return None;
    }
    Some(map)
}

// HTTP helpers
fn reason_phrase(code: u16) -> &'static str {
    match code { 200 => "OK", 201 => "Created", 204 => "No Content", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found", 409 => "Conflict", 500 => "Internal Server Error", _ => "OK" }
}

fn write_response(stream: &mut TcpStream, code: u16, headers: &[(&str, String)], body: Option<&[u8]>) -> std::io::Result<()> {
    let reason = reason_phrase(code);
    let mut resp = Vec::new();
    resp.extend_from_slice(format!("HTTP/1.1 {} {}\r\n", code, reason).as_bytes());

    // Collect headers
    let mut has_ct = false;
    let mut has_cl = false;
    for (k, v) in headers {
        if k.eq_ignore_ascii_case("content-type") { has_ct = true; }
        if k.eq_ignore_ascii_case("content-length") { has_cl = true; }
        resp.extend_from_slice(format!("{}: {}\r\n", k, v).as_bytes());
    }

    if let Some(b) = body {
        if !has_ct { resp.extend_from_slice(b"Content-Type: application/json\r\n"); }
        if !has_cl { resp.extend_from_slice(format!("Content-Length: {}\r\n", b.len()).as_bytes()); }
    } else {
        if !has_cl { resp.extend_from_slice(b"Content-Length: 0\r\n"); }
    }
    resp.extend_from_slice(b"Connection: close\r\n\r\n");
    if let Some(b) = body { resp.extend_from_slice(b); }

    stream.write_all(&resp)
}

fn json_resp(stream: &mut TcpStream, code: u16, body_str: String, headers: &[(&str, String)]) -> std::io::Result<()> { write_response(stream, code, headers, Some(body_str.as_bytes())) }

fn get_cookie(headers: &HashMap<String, String>, name: &str) -> Option<String> {
    let cookie_header = headers.get("cookie")?;
    for part in cookie_header.split(';') {
        let p = part.trim();
        if let Some((k, v)) = p.split_once('=') { if k.trim() == name { return Some(v.trim().to_string()); } }
    }
    None
}

fn find_header_end(buf: &[u8]) -> Option<usize> { if buf.len() < 4 { return None; } for i in 0..=buf.len().saturating_sub(4) { if &buf[i..i + 4] == b"\r\n\r\n" { return Some(i + 4); } } None }

fn read_request(stream: &mut TcpStream) -> Option<(String, String, HashMap<String, String>, Vec<u8>)> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    let mut header_end: Option<usize> = None;
    // Read until CRLFCRLF
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => { buf.extend_from_slice(&tmp[..n]); if let Some(pos) = find_header_end(&buf) { header_end = Some(pos); break; } }
            Err(_) => return None,
        }
        if buf.len() > 1024 * 64 { return None; }
    }
    let header_end = header_end?;

    let head = &buf[..header_end];
    let head_str = str::from_utf8(head).ok()?;
    let mut lines = head_str.split("\r\n");
    let request_line = lines.next()?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();
    let _httpver = parts.next().unwrap_or("");

    let mut headers = HashMap::new();
    for line in lines { if line.is_empty() { continue; } if let Some((k, v)) = line.split_once(":") { headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string()); } }

    let mut body = Vec::new();
    let content_length = headers.get("content-length").and_then(|v| v.parse::<usize>().ok()).unwrap_or(0);
    let already = buf.len() - header_end;
    if already >= content_length { body.extend_from_slice(&buf[header_end..header_end + content_length]); }
    else { body.extend_from_slice(&buf[header_end..]); let mut remaining = content_length - already; while remaining > 0 { match stream.read(&mut tmp) { Ok(0) => break, Ok(n) => { let take = n.min(remaining); body.extend_from_slice(&tmp[..take]); remaining -= take; }, Err(_) => return None } } }
    Some((method, path, headers, body))
}

fn validate_username(username: &str) -> Result<(), &'static str> { let len = username.len(); if len < 3 || len > 50 { return Err("Invalid username"); } if !username.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') { return Err("Invalid username"); } Ok(()) }
fn validate_password_len(pwd: &str) -> Result<(), &'static str> { if pwd.len() < 8 { Err("Password too short") } else { Ok(()) } }

fn respond_401(stream: &mut TcpStream) { let _ = json_resp(stream, 401, json_error("Authentication required"), &[]); }

fn generate_token_hex32() -> String {
    // Read 16 bytes from /dev/urandom, fallback to timestamp-based if fails
    let mut buf = [0u8; 16];
    if let Ok(mut f) = File::open("/dev/urandom") { let _ = f.read_exact(&mut buf); } else { let t = unsafe { time(std::ptr::null_mut()) } as u128; for (i, b) in buf.iter_mut().enumerate() { *b = ((t >> ((i%8)*8)) & 0xFF) as u8; } }
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(32);
    for &b in &buf { out.push(HEX[(b >> 4) as usize] as char); out.push(HEX[(b & 0x0F) as usize] as char); }
    out
}

fn handle_connection(mut stream: TcpStream, state: Arc<Mutex<AppState>>) {
    if let Some((method, path, headers, body)) = read_request(&mut stream) {
        // Public endpoints: register, login
        if method == "POST" && path == "/register" {
            if let Some(map) = parse_json_object(&body) {
                let username = match map.get("username") { Some(JVal::Str(s)) => s.clone(), _ => String::new() };
                let password = match map.get("password") { Some(JVal::Str(s)) => s.clone(), _ => String::new() };
                if let Err(msg) = validate_username(&username) { let _ = json_resp(&mut stream, 400, json_error(msg), &[]); return; }
                if let Err(msg) = validate_password_len(&password) { let _ = json_resp(&mut stream, 400, json_error(msg), &[]); return; }
                let mut st = state.lock().unwrap();
                if st.username_index.contains_key(&username) { let _ = json_resp(&mut stream, 409, json_error("Username already exists"), &[]); return; }
                let id = st.alloc_user_id();
                let user = User { id, username: username.clone(), password };
                st.username_index.insert(username, id);
                st.users.insert(id, user.clone());
                let _ = json_resp(&mut stream, 201, json_user(&user), &[]);
            } else {
                let _ = json_resp(&mut stream, 400, json_error("Bad Request"), &[]);
            }
            return;
        }
        if method == "POST" && path == "/login" {
            if let Some(map) = parse_json_object(&body) {
                let username = match map.get("username") { Some(JVal::Str(s)) => s.clone(), _ => String::new() };
                let password = match map.get("password") { Some(JVal::Str(s)) => s.clone(), _ => String::new() };
                let (uid, user_ok) = {
                    let st = state.lock().unwrap();
                    if let Some(uid) = st.username_index.get(&username).cloned() {
                        if let Some(u) = st.users.get(&uid) { if u.password == password { (uid, Some(u.clone())) } else { (0, None) } } else { (0, None) }
                    } else { (0, None) }
                };
                if let Some(user) = user_ok {
                    let token = generate_token_hex32();
                    {
                        let mut st = state.lock().unwrap();
                        st.sessions.insert(token.clone(), uid);
                    }
                    let hdrs = vec![("Set-Cookie", format!("session_id={}; Path=/; HttpOnly", token))];
                    let _ = json_resp(&mut stream, 200, json_user(&user), &hdrs);
                } else {
                    let _ = json_resp(&mut stream, 401, json_error("Invalid credentials"), &[]);
                }
            } else { let _ = json_resp(&mut stream, 400, json_error("Bad Request"), &[]); }
            return;
        }

        // Protected endpoints
        let maybe_token = get_cookie(&headers, "session_id");
        let uid = if let Some(tok) = maybe_token.as_ref() { let st = state.lock().unwrap(); st.sessions.get(tok).cloned() } else { None };
        let uid = match uid { Some(u) => u, None => { respond_401(&mut stream); return; } };

        if method == "POST" && path == "/logout" {
            if let Some(token) = maybe_token { let mut st = state.lock().unwrap(); if st.sessions.remove(&token).is_none() { respond_401(&mut stream); return; } }
            let _ = json_resp(&mut stream, 200, "{}".to_string(), &[]);
            return;
        }

        if method == "GET" && path == "/me" {
            let st = state.lock().unwrap();
            if let Some(user) = st.users.get(&uid) { let _ = json_resp(&mut stream, 200, json_user(user), &[]); } else { respond_401(&mut stream); }
            return;
        }

        if method == "PUT" && path == "/password" {
            if let Some(map) = parse_json_object(&body) {
                let old_password = match map.get("old_password") { Some(JVal::Str(s)) => s.clone(), _ => String::new() };
                let new_password = match map.get("new_password") { Some(JVal::Str(s)) => s.clone(), _ => String::new() };
                let mut st = state.lock().unwrap();
                if let Some(user) = st.users.get(&uid).cloned() {
                    if user.password != old_password { let _ = json_resp(&mut stream, 401, json_error("Invalid credentials"), &[]); return; }
                    if let Err(msg) = validate_password_len(&new_password) { let _ = json_resp(&mut stream, 400, json_error(msg), &[]); return; }
                    if let Some(u) = st.users.get_mut(&uid) { u.password = new_password; }
                    let _ = json_resp(&mut stream, 200, "{}".to_string(), &[]);
                } else { respond_401(&mut stream); }
            } else { let _ = json_resp(&mut stream, 400, json_error("Bad Request"), &[]); }
            return;
        }

        if method == "GET" && path == "/todos" {
            let st = state.lock().unwrap();
            let mut items: Vec<&Todo> = st.todos.values().filter(|t| t.user_id == uid).collect();
            items.sort_by_key(|t| t.id);
            let mut s = String::from("[");
            for (i, t) in items.iter().enumerate() { if i > 0 { s.push(','); } s.push_str(&json_todo(t)); }
            s.push(']');
            let _ = json_resp(&mut stream, 200, s, &[]);
            return;
        }

        if method == "POST" && path == "/todos" {
            if let Some(map) = parse_json_object(&body) {
                let title = match map.get("title") { Some(JVal::Str(s)) => s.clone(), _ => String::new() };
                if title.trim().is_empty() { let _ = json_resp(&mut stream, 400, json_error("Title is required"), &[]); return; }
                let description = match map.get("description") { Some(JVal::Str(s)) => s.clone(), _ => String::from("") };
                let created_at = now_iso_seconds();
                let mut st = state.lock().unwrap();
                let id = st.alloc_todo_id();
                let todo = Todo { id, user_id: uid, title, description, completed: false, created_at: created_at.clone(), updated_at: created_at.clone() };
                st.todos.insert(id, todo.clone());
                let _ = json_resp(&mut stream, 201, json_todo(&todo), &[]);
            } else { let _ = json_resp(&mut stream, 400, json_error("Bad Request"), &[]); }
            return;
        }

        if path.starts_with("/todos/") {
            let id_str = &path[7..];
            if let Ok(id) = id_str.parse::<i64>() {
                if method == "GET" {
                    let st = state.lock().unwrap();
                    if let Some(todo) = st.todos.get(&id) { if todo.user_id != uid { let _ = json_resp(&mut stream, 404, json_error("Todo not found"), &[]); } else { let _ = json_resp(&mut stream, 200, json_todo(todo), &[]); } }
                    else { let _ = json_resp(&mut stream, 404, json_error("Todo not found"), &[]); }
                    return;
                }
                if method == "PUT" {
                    if let Some(map) = parse_json_object(&body) {
                        let mut st = state.lock().unwrap();
                        if let Some(todo) = st.todos.get_mut(&id) {
                            if todo.user_id != uid { let _ = json_resp(&mut stream, 404, json_error("Todo not found"), &[]); return; }
                            if let Some(JVal::Str(t)) = map.get("title").cloned() { if t.trim().is_empty() { let _ = json_resp(&mut stream, 400, json_error("Title is required"), &[]); return; } else { todo.title = t; } }
                            if let Some(JVal::Str(d)) = map.get("description").cloned() { todo.description = d; }
                            if let Some(JVal::Bool(c)) = map.get("completed").cloned() { todo.completed = c; }
                            todo.updated_at = now_iso_seconds();
                            let _ = json_resp(&mut stream, 200, json_todo(todo), &[]);
                        } else { let _ = json_resp(&mut stream, 404, json_error("Todo not found"), &[]); }
                    } else { let _ = json_resp(&mut stream, 400, json_error("Bad Request"), &[]); }
                    return;
                }
                if method == "DELETE" {
                    let mut st = state.lock().unwrap();
                    if let Some(todo) = st.todos.get(&id) {
                        if todo.user_id != uid { let _ = write_response(&mut stream, 404, &[], None); } else { st.todos.remove(&id); let _ = write_response(&mut stream, 204, &[], None); }
                    } else { let _ = json_resp(&mut stream, 404, json_error("Todo not found"), &[]); }
                    return;
                }
            }
        }

        // Fallback
        let _ = json_resp(&mut stream, 404, json_error("Not Found"), &[]);
    }
}

fn parse_port_arg() -> u16 {
    let mut args = std::env::args().skip(1);
    let mut port: u16 = 3000;
    while let Some(arg) = args.next() { if arg == "--port" { if let Some(p) = args.next() { port = p.parse().unwrap_or(3000); } } }
    port
}

fn bind_addr(port: u16) -> SocketAddr { SocketAddr::from(([0,0,0,0], port)) }

fn main() -> std::io::Result<()> {
    let port = parse_port_arg();
    let addr = bind_addr(port);
    let listener = TcpListener::bind(addr)?;
    eprintln!("listening on {}", addr);

    let state = Arc::new(Mutex::new(AppState::default()));

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = state.clone();
                stream.set_nodelay(true).ok();
                thread::spawn(move || { handle_connection(stream, state); });
            }
            Err(e) => eprintln!("accept error: {}", e),
        }
    }
    Ok(())
}

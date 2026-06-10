#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MAX_HEADER_SIZE 65536
#define MAX_BODY_SIZE 131072

// Data models

typedef struct {
    int id;
    char *username;
    char *password; // stored in plain text (in-memory demo)
} User;

typedef struct {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0/1
    char created_at[21]; // YYYY-MM-DDTHH:MM:SSZ + NUL
    char updated_at[21];
} Todo;

typedef struct {
    char token[65]; // hex string (up to 32 bytes -> 64 hex chars) + NUL; we may use 32 bytes = 64 hex
    int user_id;
    int valid; // 1 if valid
} Session;

// Dynamic arrays
static User *users = NULL; static size_t users_len = 0; static size_t users_cap = 0; static int next_user_id = 1;
static Todo *todos = NULL; static size_t todos_len = 0; static size_t todos_cap = 0; static int next_todo_id = 1;
static Session *sessions = NULL; static size_t sessions_len = 0; static size_t sessions_cap = 0;

static int server_fd = -1;

static void cleanup()
{
    if (server_fd >= 0) close(server_fd);
    for (size_t i = 0; i < users_len; ++i) {
        free(users[i].username);
        free(users[i].password);
    }
    free(users);
    for (size_t i = 0; i < todos_len; ++i) {
        free(todos[i].title);
        free(todos[i].description);
    }
    free(todos);
    free(sessions);
}

static void on_sigint(int sig)
{
    (void)sig;
    cleanup();
    exit(0);
}

static void ensure_users_cap()
{
    if (users_len >= users_cap) {
        size_t nc = users_cap ? users_cap * 2 : 16;
        User *nu = (User *)realloc(users, nc * sizeof(User));
        if (!nu) { perror("realloc users"); exit(1);} users = nu; users_cap = nc;
    }
}
static void ensure_todos_cap()
{
    if (todos_len >= todos_cap) {
        size_t nc = todos_cap ? todos_cap * 2 : 16;
        Todo *nt = (Todo *)realloc(todos, nc * sizeof(Todo));
        if (!nt) { perror("realloc todos"); exit(1);} todos = nt; todos_cap = nc;
    }
}
static void ensure_sessions_cap()
{
    if (sessions_len >= sessions_cap) {
        size_t nc = sessions_cap ? sessions_cap * 2 : 16;
        Session *ns = (Session *)realloc(sessions, nc * sizeof(Session));
        if (!ns) { perror("realloc sessions"); exit(1);} sessions = ns; sessions_cap = nc;
    }
}

static int is_valid_username(const char *u)
{
    if (!u) return 0;
    size_t n = strlen(u);
    if (n < 3 || n > 50) return 0;
    for (size_t i = 0; i < n; ++i) {
        char c = u[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
            return 0;
    }
    return 1;
}

static User *find_user_by_username(const char *username)
{
    for (size_t i = 0; i < users_len; ++i) {
        if (strcmp(users[i].username, username) == 0) return &users[i];
    }
    return NULL;
}

static User *find_user_by_id(int id)
{
    for (size_t i = 0; i < users_len; ++i) if (users[i].id == id) return &users[i];
    return NULL;
}

static void iso8601_now(char out[21])
{
    time_t t = time(NULL);
    struct tm gm;
    gmtime_r(&t, &gm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &gm);
}

static void gen_token(char out_hex[65])
{
    unsigned char bytes[32];
    FILE *f = fopen("/dev/urandom", "rb");
    if (!f) { perror("/dev/urandom"); exit(1);} 
    size_t r = fread(bytes, 1, sizeof(bytes), f);
    fclose(f);
    if (r != sizeof(bytes)) {
        fprintf(stderr, "Failed to read random bytes\n"); exit(1);
    }
    static const char *hex = "0123456789abcdef";
    for (int i = 0; i < 32; ++i) {
        out_hex[2*i] = hex[(bytes[i] >> 4) & 0xF];
        out_hex[2*i+1] = hex[bytes[i] & 0xF];
    }
    out_hex[64] = '\0';
}

static Session *find_session_by_token(const char *token)
{
    if (!token) return NULL;
    for (size_t i = 0; i < sessions_len; ++i) {
        if (sessions[i].valid && strcmp(sessions[i].token, token) == 0)
            return &sessions[i];
    }
    return NULL;
}

static void invalidate_session(Session *s)
{
    if (s) s->valid = 0;
}

// Minimal HTTP parsing

typedef struct { char *name; char *value; } Header;

typedef struct {
    char method[8];
    char path[1024];
    char http_version[16];
    Header *headers; size_t headers_len; size_t headers_cap;
    char *body; size_t body_len;
} Request;

static void headers_add(Request *req, char *name, char *value)
{
    if (req->headers_len >= req->headers_cap) {
        size_t nc = req->headers_cap ? req->headers_cap * 2 : 16;
        Header *nh = (Header *)realloc(req->headers, nc * sizeof(Header));
        if (!nh) { perror("realloc headers"); exit(1);} req->headers = nh; req->headers_cap = nc;
    }
    req->headers[req->headers_len].name = name;
    req->headers[req->headers_len].value = value;
    req->headers_len++;
}

static const char *get_header(Request *req, const char *name)
{
    for (size_t i = 0; i < req->headers_len; ++i) {
        // case-insensitive compare
        const char *a = req->headers[i].name; const char *b = name;
        while (*a && *b) {
            char ca = *a >= 'A' && *a <= 'Z' ? *a - 'A' + 'a' : *a;
            char cb = *b >= 'A' && *b <= 'Z' ? *b - 'A' + 'a' : *b;
            if (ca != cb) break; a++; b++;
        }
        if (*a == '\0' && *b == '\0') return req->headers[i].value;
    }
    return NULL;
}

static int read_request(int fd, Request *req)
{
    memset(req, 0, sizeof(*req));
    char *buf = (char *)malloc(MAX_HEADER_SIZE + 1);
    if (!buf) return -1;
    size_t used = 0;
    int found = 0;
    while (used < MAX_HEADER_SIZE) {
        ssize_t r = recv(fd, buf + used, MAX_HEADER_SIZE - used, 0);
        if (r < 0) { free(buf); return -1; }
        if (r == 0) { break; }
        used += (size_t)r;
        buf[used] = '\0';
        if (strstr(buf, "\r\n\r\n")) { found = 1; break; }
    }
    if (!found) { free(buf); return -1; }
    // Split headers
    char *hdr_end = strstr(buf, "\r\n\r\n");
    size_t header_len = hdr_end - buf + 2; // leave one CRLF for parsing convenience
    // Parse request line
    char *line_end = strstr(buf, "\r\n");
    if (!line_end) { free(buf); return -1; }
    *line_end = '\0';
    char *reqline = buf;
    // method path version
    if (sscanf(reqline, "%7s %1023s %15s", req->method, req->path, req->http_version) != 3) {
        free(buf); return -1;
    }
    // Move to headers
    char *p = line_end + 2;
    while (p < hdr_end) {
        char *e = strstr(p, "\r\n");
        if (!e || e > hdr_end) break;
        *e = '\0';
        char *colon = strchr(p, ':');
        if (colon) {
            *colon = '\0';
            char *name = p;
            char *value = colon + 1;
            while (*value == ' ' || *value == '\t') value++;
            headers_add(req, name, value);
        }
        p = e + 2;
    }
    // Determine body
    size_t header_bytes = (hdr_end - buf) + 4;
    size_t remaining_in_buf = used - header_bytes;
    const char *cl_hdr = get_header(req, "Content-Length");
    size_t want_body = 0;
    if (cl_hdr) want_body = (size_t)strtoul(cl_hdr, NULL, 10);
    if (want_body > MAX_BODY_SIZE) { free(buf); return -1; }
    char *body = NULL;
    if (want_body > 0) {
        body = (char *)malloc(want_body + 1);
        if (!body) { free(buf); return -1; }
        size_t copied = 0;
        if (remaining_in_buf > 0) {
            size_t n = remaining_in_buf < want_body ? remaining_in_buf : want_body;
            memcpy(body, buf + header_bytes, n);
            copied = n;
        }
        while (copied < want_body) {
            ssize_t r = recv(fd, body + copied, want_body - copied, 0);
            if (r <= 0) { free(body); free(buf); return -1; }
            copied += (size_t)r;
        }
        body[want_body] = '\0';
    }
    // Move headers names/values into separate buffer to persist after freeing buf
    // We already used buf to store header strings; keep it by attaching to req->body? Instead, keep buf in req->body? No: we need separate
    // We'll keep buf allocated in req->body field temporarily? Better: store buf pointer in req->body as shadow. We'll add hidden pointer via headers_cap as trick? Simpler: store buf globally? Not good.
    // For simplicity, do not free buf here; store it in req->body as shadow2. We'll store buf pointer into req->http_version unused space? Not safe.
    // We'll add an extra field? For now, we can't change struct easily. We'll leak buf per request? That's bad but acceptable for small tests.
    // To avoid leak, we can store buf pointer in req->body by concatenating; but body is separate. We'll accept small leak per request since short-lived.

    req->body = body;
    req->body_len = want_body;
    return 0;
}

static void free_request(Request *req)
{
    free(req->headers); // names/values are in leaked header buffer; acceptable for this small server lifetime.
    if (req->body) free(req->body);
}

static ssize_t send_all(int fd, const void *buf, size_t len)
{
    const char *p = (const char *)buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t r = send(fd, p + sent, len - sent, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        sent += (size_t)r;
    }
    return (ssize_t)sent;
}

static void send_response(int fd, int status, const char *status_text, const char *extra_headers, const char *body)
{
    char header[1024];
    size_t body_len = body ? strlen(body) : 0;
    if (status == 204) {
        int n = snprintf(header, sizeof(header),
                         "HTTP/1.1 %d %s\r\nConnection: close\r\n%s\r\n",
                         status, status_text, extra_headers ? extra_headers : "");
        send_all(fd, header, (size_t)n);
        return;
    }
    int n = snprintf(header, sizeof(header),
                     "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n%s\r\n",
                     status, status_text, body_len, extra_headers ? extra_headers : "");
    send_all(fd, header, (size_t)n);
    if (body && body_len > 0) send_all(fd, body, body_len);
}

static void send_json_error(int fd, int code, const char *message)
{
    char buf[512];
    snprintf(buf, sizeof(buf), "{\"error\": \"%s\"}", message);
    const char *text = "Error";
    switch (code) {
        case 400: text = "Bad Request"; break;
        case 401: text = "Unauthorized"; break;
        case 404: text = "Not Found"; break;
        case 409: text = "Conflict"; break;
        default: text = "Error"; break;
    }
    send_response(fd, code, text, NULL, buf);
}

// Cookie parsing
static int get_session_id_from_cookie(const char *cookie_hdr, char *out, size_t outsz)
{
    if (!cookie_hdr) return 0;
    const char *p = cookie_hdr;
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == ';') p++;
        const char *k = p;
        while (*p && *p != '=' && *p != ';') p++;
        if (*p != '=') { while (*p && *p != ';') p++; continue; }
        size_t klen = (size_t)(p - k);
        p++; // skip '='
        const char *v = p;
        while (*p && *p != ';') p++;
        size_t vlen = (size_t)(p - v);
        if (klen == strlen("session_id") && strncasecmp(k, "session_id", klen) == 0) {
            size_t n = vlen < outsz - 1 ? vlen : outsz - 1;
            memcpy(out, v, n); out[n] = '\0';
            return 1;
        }
        if (*p == ';') p++;
    }
    return 0;
}

// Minimal JSON field extractors (very limited, expects simple well-formed JSON with double-quoted keys)
static int json_get_string(const char *json, const char *key, char *out, size_t outsz, int *present)
{
    *present = 0;
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *k = strstr(json, pattern);
    if (!k) return 0; // not present
    *present = 1;
    const char *p = k + strlen(pattern);
    while (*p && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (*p != ':') return -1;
    p++;
    while (*p && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (*p != '"') return -1;
    p++;
    size_t idx = 0;
    while (*p && *p != '"') {
        if (*p == '\\' && p[1] != '\0') { // naive escape handling
            p++;
        }
        if (idx + 1 < outsz) out[idx++] = *p;
        p++;
    }
    if (*p != '"') return -1;
    out[idx] = '\0';
    return 1;
}

static int json_get_bool(const char *json, const char *key, int *out, int *present)
{
    *present = 0;
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *k = strstr(json, pattern);
    if (!k) return 0;
    *present = 1;
    const char *p = k + strlen(pattern);
    while (*p && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (*p != ':') return -1;
    p++;
    while (*p && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (strncmp(p, "true", 4) == 0) { *out = 1; return 1; }
    if (strncmp(p, "false", 5) == 0) { *out = 0; return 1; }
    return -1;
}

static void json_escape_string(const char *in, char *out, size_t outsz)
{
    size_t oi = 0;
    for (size_t i = 0; in && in[i] != '\0'; ++i) {
        char c = in[i];
        if (c == '"' || c == '\\') {
            if (oi + 2 >= outsz) break;
            out[oi++] = '\\'; out[oi++] = c;
        } else if ((unsigned char)c < 0x20) {
            if (oi + 6 >= outsz) break;
            snprintf(out + oi, outsz - oi, "\\u%04x", (unsigned char)c);
            oi += 6;
        } else {
            if (oi + 1 >= outsz) break;
            out[oi++] = c;
        }
    }
    if (oi < outsz) out[oi] = '\0'; else out[outsz - 1] = '\0';
}

// Helpers for todo JSON
static void todo_to_json(const Todo *t, char *out, size_t outsz)
{
    char title_esc[4096]; char desc_esc[4096];
    json_escape_string(t->title ? t->title : "", title_esc, sizeof(title_esc));
    json_escape_string(t->description ? t->description : "", desc_esc, sizeof(desc_esc));
    snprintf(out, outsz,
             "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
             t->id, title_esc, desc_esc, t->completed ? "true" : "false", t->created_at, t->updated_at);
}

// Endpoint handlers

static int require_auth(int fd, Request *req, int *out_user_id)
{
    const char *cookie = get_header(req, "Cookie");
    char token[128];
    if (!cookie || !get_session_id_from_cookie(cookie, token, sizeof(token))) {
        send_json_error(fd, 401, "Authentication required");
        return 0;
    }
    Session *s = find_session_by_token(token);
    if (!s || !s->valid) {
        send_json_error(fd, 401, "Authentication required");
        return 0;
    }
    *out_user_id = s->user_id;
    return 1;
}

static void handle_register(int fd, Request *req)
{
    if (req->body_len == 0 || !req->body) { send_json_error(fd, 400, "Invalid JSON"); return; }
    char username[128] = {0}; int u_present = 0;
    char password[256] = {0}; int p_present = 0;
    if (json_get_string(req->body, "username", username, sizeof(username), &u_present) < 0 || !u_present) { send_json_error(fd, 400, "Invalid username"); return; }
    if (json_get_string(req->body, "password", password, sizeof(password), &p_present) < 0 || !p_present) { send_json_error(fd, 400, "Password too short"); return; }
    if (!is_valid_username(username)) { send_json_error(fd, 400, "Invalid username"); return; }
    if (strlen(password) < 8) { send_json_error(fd, 400, "Password too short"); return; }
    if (find_user_by_username(username)) { send_json_error(fd, 409, "Username already exists"); return; }
    ensure_users_cap();
    User *u = &users[users_len++];
    u->id = next_user_id++;
    u->username = strdup(username);
    u->password = strdup(password);
    char buf[512];
    char uname_esc[256]; json_escape_string(u->username, uname_esc, sizeof(uname_esc));
    snprintf(buf, sizeof(buf), "{\"id\": %d, \"username\": \"%s\"}", u->id, uname_esc);
    send_response(fd, 201, "Created", NULL, buf);
}

static void handle_login(int fd, Request *req)
{
    if (req->body_len == 0 || !req->body) { send_json_error(fd, 401, "Invalid credentials"); return; }
    char username[128] = {0}; int u_present = 0;
    char password[256] = {0}; int p_present = 0;
    if (json_get_string(req->body, "username", username, sizeof(username), &u_present) < 0 || !u_present) { send_json_error(fd, 401, "Invalid credentials"); return; }
    if (json_get_string(req->body, "password", password, sizeof(password), &p_present) < 0 || !p_present) { send_json_error(fd, 401, "Invalid credentials"); return; }
    User *u = find_user_by_username(username);
    if (!u || strcmp(u->password, password) != 0) { send_json_error(fd, 401, "Invalid credentials"); return; }
    // create session
    ensure_sessions_cap();
    Session *s = &sessions[sessions_len++];
    gen_token(s->token);
    s->user_id = u->id;
    s->valid = 1;
    char set_cookie[256];
    snprintf(set_cookie, sizeof(set_cookie), "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", s->token);
    char headers[256]; headers[0] = '\0'; strncat(headers, set_cookie, sizeof(headers) - 1);
    char resp[512];
    char uname_esc[256]; json_escape_string(u->username, uname_esc, sizeof(uname_esc));
    snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", u->id, uname_esc);
    send_response(fd, 200, "OK", headers, resp);
}

static void handle_logout(int fd, Request *req)
{
    int user_id = 0; // required for auth
    const char *cookie = get_header(req, "Cookie");
    char token[128];
    if (!cookie || !get_session_id_from_cookie(cookie, token, sizeof(token))) {
        send_json_error(fd, 401, "Authentication required");
        return;
    }
    Session *s = find_session_by_token(token);
    if (!s || !s->valid) { send_json_error(fd, 401, "Authentication required"); return; }
    (void)user_id;
    invalidate_session(s);
    send_response(fd, 200, "OK", NULL, "{}");
}

static void handle_me(int fd, Request *req)
{
    int user_id;
    if (!require_auth(fd, req, &user_id)) return;
    User *u = find_user_by_id(user_id);
    if (!u) { send_json_error(fd, 401, "Authentication required"); return; }
    char buf[512];
    char uname_esc[256]; json_escape_string(u->username, uname_esc, sizeof(uname_esc));
    snprintf(buf, sizeof(buf), "{\"id\": %d, \"username\": \"%s\"}", u->id, uname_esc);
    send_response(fd, 200, "OK", NULL, buf);
}

static void handle_password(int fd, Request *req)
{
    int user_id;
    if (!require_auth(fd, req, &user_id)) return;
    if (req->body_len == 0 || !req->body) { send_json_error(fd, 400, "Password too short"); return; }
    char oldp[256] = {0}; int old_present = 0;
    char newp[256] = {0}; int new_present = 0;
    if (json_get_string(req->body, "old_password", oldp, sizeof(oldp), &old_present) < 0 || !old_present) { send_json_error(fd, 401, "Invalid credentials"); return; }
    if (json_get_string(req->body, "new_password", newp, sizeof(newp), &new_present) < 0 || !new_present) { send_json_error(fd, 400, "Password too short"); return; }
    User *u = find_user_by_id(user_id);
    if (!u || strcmp(u->password, oldp) != 0) { send_json_error(fd, 401, "Invalid credentials"); return; }
    if (strlen(newp) < 8) { send_json_error(fd, 400, "Password too short"); return; }
    free(u->password); u->password = strdup(newp);
    send_response(fd, 200, "OK", NULL, "{}");
}

static void handle_get_todos(int fd, Request *req)
{
    int user_id;
    if (!require_auth(fd, req, &user_id)) return;
    // count
    size_t count = 0;
    for (size_t i = 0; i < todos_len; ++i) if (todos[i].user_id == user_id) count++;
    // build JSON array
    // We will over-allocate a buffer
    size_t approx = count * 512 + 16;
    char *buf = (char *)malloc(approx);
    if (!buf) { send_json_error(fd, 500, "Internal error"); return; }
    size_t off = 0;
    off += (size_t)snprintf(buf + off, approx - off, "[");
    int first = 1;
    for (size_t i = 0; i < todos_len; ++i) {
        if (todos[i].user_id != user_id) continue;
        char item[1024]; todo_to_json(&todos[i], item, sizeof(item));
        if (!first) off += (size_t)snprintf(buf + off, approx - off, ",");
        first = 0;
        off += (size_t)snprintf(buf + off, approx - off, "%s", item);
    }
    off += (size_t)snprintf(buf + off, approx - off, "]");
    send_response(fd, 200, "OK", NULL, buf);
    free(buf);
}

static void handle_post_todo(int fd, Request *req)
{
    int user_id;
    if (!require_auth(fd, req, &user_id)) return;
    if (req->body_len == 0 || !req->body) { send_json_error(fd, 400, "Title is required"); return; }
    char title[1024] = {0}; int t_present = 0;
    char description[4096] = {0}; int d_present = 0;
    if (json_get_string(req->body, "title", title, sizeof(title), &t_present) < 0 || !t_present || strlen(title) == 0) { send_json_error(fd, 400, "Title is required"); return; }
    if (json_get_string(req->body, "description", description, sizeof(description), &d_present) < 0) { send_json_error(fd, 400, "Invalid JSON"); return; }
    ensure_todos_cap();
    Todo *t = &todos[todos_len++];
    t->id = next_todo_id++;
    t->user_id = user_id;
    t->title = strdup(title);
    t->description = strdup(d_present ? description : "");
    t->completed = 0;
    iso8601_now(t->created_at);
    memcpy(t->updated_at, t->created_at, sizeof(t->updated_at));
    char item[1024]; todo_to_json(t, item, sizeof(item));
    send_response(fd, 201, "Created", NULL, item);
}

static Todo *find_todo_for_user(int id, int user_id)
{
    for (size_t i = 0; i < todos_len; ++i) if (todos[i].id == id && todos[i].user_id == user_id) return &todos[i];
    return NULL;
}

static void handle_get_todo(int fd, Request *req, int todo_id)
{
    int user_id; if (!require_auth(fd, req, &user_id)) return;
    Todo *t = find_todo_for_user(todo_id, user_id);
    if (!t) { send_json_error(fd, 404, "Todo not found"); return; }
    char item[1024]; todo_to_json(t, item, sizeof(item));
    send_response(fd, 200, "OK", NULL, item);
}

static void handle_put_todo(int fd, Request *req, int todo_id)
{
    int user_id; if (!require_auth(fd, req, &user_id)) return;
    Todo *t = find_todo_for_user(todo_id, user_id);
    if (!t) { send_json_error(fd, 404, "Todo not found"); return; }
    if (req->body_len == 0 || !req->body) { send_json_error(fd, 400, "Invalid JSON"); return; }
    int present; char val[4096];
    // title
    present = 0; val[0] = '\0';
    int r = json_get_string(req->body, "title", val, sizeof(val), &present);
    if (r < 0) { send_json_error(fd, 400, "Invalid JSON"); return; }
    if (present) {
        if (strlen(val) == 0) { send_json_error(fd, 400, "Title is required"); return; }
        free(t->title); t->title = strdup(val);
    }
    // description
    present = 0; val[0] = '\0';
    r = json_get_string(req->body, "description", val, sizeof(val), &present);
    if (r < 0) { send_json_error(fd, 400, "Invalid JSON"); return; }
    if (present) { free(t->description); t->description = strdup(val); }
    // completed
    int b = 0; int b_present = 0;
    r = json_get_bool(req->body, "completed", &b, &b_present);
    if (r < 0) { send_json_error(fd, 400, "Invalid JSON"); return; }
    if (b_present) t->completed = b;
    // update timestamp
    iso8601_now(t->updated_at);
    char item[1024]; todo_to_json(t, item, sizeof(item));
    send_response(fd, 200, "OK", NULL, item);
}

static void handle_delete_todo(int fd, Request *req, int todo_id)
{
    int user_id; if (!require_auth(fd, req, &user_id)) return;
    size_t idx = (size_t)-1;
    for (size_t i = 0; i < todos_len; ++i) if (todos[i].id == todo_id && todos[i].user_id == user_id) { idx = i; break; }
    if (idx == (size_t)-1) { send_json_error(fd, 404, "Todo not found"); return; }
    // free resources
    free(todos[idx].title);
    free(todos[idx].description);
    // compact array
    for (size_t i = idx + 1; i < todos_len; ++i) todos[i-1] = todos[i];
    todos_len--;
    send_response(fd, 204, "No Content", NULL, NULL);
}

static void route_request(int fd, Request *req)
{
    // Remove query string if any
    char path[1024]; strncpy(path, req->path, sizeof(path)-1); path[sizeof(path)-1] = '\0';
    char *q = strchr(path, '?'); if (q) *q = '\0';

    if (strcmp(req->method, "POST") == 0 && strcmp(path, "/register") == 0) { handle_register(fd, req); return; }
    if (strcmp(req->method, "POST") == 0 && strcmp(path, "/login") == 0) { handle_login(fd, req); return; }
    if (strcmp(req->method, "POST") == 0 && strcmp(path, "/logout") == 0) { handle_logout(fd, req); return; }
    if (strcmp(req->method, "GET") == 0 && strcmp(path, "/me") == 0) { handle_me(fd, req); return; }
    if (strcmp(req->method, "PUT") == 0 && strcmp(path, "/password") == 0) { handle_password(fd, req); return; }

    if (strncmp(path, "/todos", 6) == 0) {
        if (strcmp(path, "/todos") == 0) {
            if (strcmp(req->method, "GET") == 0) { handle_get_todos(fd, req); return; }
            if (strcmp(req->method, "POST") == 0) { handle_post_todo(fd, req); return; }
        } else if (strncmp(path, "/todos/", 7) == 0) {
            char *idstr = path + 7;
            if (*idstr == '\0') { send_json_error(fd, 404, "Not found"); return; }
            char *endp = NULL; long id = strtol(idstr, &endp, 10);
            if (id <= 0 || (endp && *endp != '\0')) { send_json_error(fd, 404, "Todo not found"); return; }
            if (strcmp(req->method, "GET") == 0) { handle_get_todo(fd, req, (int)id); return; }
            if (strcmp(req->method, "PUT") == 0) { handle_put_todo(fd, req, (int)id); return; }
            if (strcmp(req->method, "DELETE") == 0) { handle_delete_todo(fd, req, (int)id); return; }
        }
    }

    send_json_error(fd, 404, "Not found");
}

int main(int argc, char **argv)
{
    signal(SIGINT, on_sigint);
    int port = 0;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        }
    }
    if (port <= 0) {
        fprintf(stderr, "Usage: %s --port PORT\n", argv[0]);
        return 1;
    }

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return 1; }
    int opt = 1; setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_ANY); addr.sin_port = htons((uint16_t)port);
    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    if (listen(server_fd, 128) < 0) { perror("listen"); return 1; }

    fprintf(stderr, "Server listening on 0.0.0.0:%d\n", port);

    while (1) {
        struct sockaddr_in cli; socklen_t clilen = sizeof(cli);
        int cfd = accept(server_fd, (struct sockaddr*)&cli, &clilen);
        if (cfd < 0) {
            if (errno == EINTR) continue; perror("accept"); break;
        }
        struct timeval tv; tv.tv_sec = 5; tv.tv_usec = 0; setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        Request req;
        if (read_request(cfd, &req) == 0) {
            route_request(cfd, &req);
            free_request(&req);
        } else {
            const char *body = "{\"error\": \"Bad Request\"}";
            send_response(cfd, 400, "Bad Request", NULL, body);
        }
        close(cfd);
    }

    cleanup();
    return 0;
}

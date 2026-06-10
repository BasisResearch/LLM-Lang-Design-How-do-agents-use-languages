#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <openssl/sha.h>
#include <jansson.h>

#define MAX_HEADER_SIZE 8192
#define MAX_PATH_LEN 512
#define READ_TIMEOUT_SEC 30

// Data structures

typedef struct {
    int id;
    char *username;
    char password_hash_hex[65];
} User;

typedef struct {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0/1
    char created_at[21];
    char updated_at[21];
} Todo;

typedef struct {
    char token[65];
    int user_id;
    int valid; // 1 valid, 0 invalidated
} Session;

static User *users = NULL; static size_t users_len = 0; static size_t users_cap = 0; static int next_user_id = 1;
static Todo *todos = NULL; static size_t todos_len = 0; static size_t todos_cap = 0; static int next_todo_id = 1;
static Session *sessions = NULL; static size_t sessions_len = 0; static size_t sessions_cap = 0;

static volatile sig_atomic_t keep_running = 1;

static void handle_sigint(int sig) { (void)sig; keep_running = 0; }

static void to_hex(const unsigned char *in, size_t inlen, char *out_hex, size_t outlen) {
    static const char *hex = "0123456789abcdef";
    if (outlen < inlen * 2 + 1) return;
    for (size_t i = 0; i < inlen; ++i) {
        out_hex[2*i] = hex[(in[i] >> 4) & 0xF];
        out_hex[2*i+1] = hex[in[i] & 0xF];
    }
    out_hex[inlen*2] = '\0';
}

static void sha256_hex(const char *input, char out_hex[65]) {
    unsigned char hash[SHA256_DIGEST_LENGTH];
    SHA256_CTX ctx;
    SHA256_Init(&ctx);
    SHA256_Update(&ctx, input, strlen(input));
    SHA256_Final(hash, &ctx);
    to_hex(hash, SHA256_DIGEST_LENGTH, out_hex, 65);
}

static int gen_token_hex(char out_hex[65]) {
    unsigned char buf[32];
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    ssize_t r = read(fd, buf, sizeof(buf));
    close(fd);
    if (r != (ssize_t)sizeof(buf)) return -1;
    to_hex(buf, sizeof(buf), out_hex, 65);
    return 0;
}

static void iso8601_utc_now(char out[21]) {
    time_t t = time(NULL);
    struct tm gm;
    gmtime_r(&t, &gm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &gm);
}

static void send_response_json(int client_fd, int status, const char *status_text, const char *body_json, const char *extra_headers) {
    char header[1024];
    size_t body_len = body_json ? strlen(body_json) : 0;
    int n = snprintf(header, sizeof(header),
                     "HTTP/1.1 %d %s\r\n"
                     "Content-Type: application/json\r\n"
                     "Content-Length: %zu\r\n"
                     "Connection: close\r\n" ,
                     status, status_text, body_len);
    (void)n;
    send(client_fd, header, strlen(header), 0);
    if (extra_headers && *extra_headers) {
        send(client_fd, extra_headers, strlen(extra_headers), 0);
    }
    const char *crlf = "\r\n";
    send(client_fd, crlf, 2, 0);
    if (body_len > 0) {
        send(client_fd, body_json, body_len, 0);
    }
}

static void send_response_no_body(int client_fd, int status, const char *status_text) {
    char header[256];
    int n = snprintf(header, sizeof(header),
                     "HTTP/1.1 %d %s\r\n"
                     "Content-Length: 0\r\n"
                     "Connection: close\r\n"
                     "\r\n",
                     status, status_text);
    (void)n;
    send(client_fd, header, strlen(header), 0);
}

static void ensure_capacity_users() {
    if (users_len >= users_cap) {
        size_t newcap = users_cap ? users_cap * 2 : 16;
        User *nu = realloc(users, newcap * sizeof(User));
        if (!nu) { perror("realloc users"); exit(1);} users = nu; users_cap = newcap;
    }
}

static void ensure_capacity_todos() {
    if (todos_len >= todos_cap) {
        size_t newcap = todos_cap ? todos_cap * 2 : 16;
        Todo *nt = realloc(todos, newcap * sizeof(Todo));
        if (!nt) { perror("realloc todos"); exit(1);} todos = nt; todos_cap = newcap;
    }
}

static void ensure_capacity_sessions() {
    if (sessions_len >= sessions_cap) {
        size_t newcap = sessions_cap ? sessions_cap * 2 : 16;
        Session *ns = realloc(sessions, newcap * sizeof(Session));
        if (!ns) { perror("realloc sessions"); exit(1);} sessions = ns; sessions_cap = newcap;
    }
}

static User* find_user_by_username(const char *username) {
    for (size_t i = 0; i < users_len; ++i) {
        if (strcmp(users[i].username, username) == 0) return &users[i];
    }
    return NULL;
}

static User* find_user_by_id(int id) {
    for (size_t i = 0; i < users_len; ++i) {
        if (users[i].id == id) return &users[i];
    }
    return NULL;
}

static int username_valid(const char *username) {
    size_t n = strlen(username);
    if (n < 3 || n > 50) return 0;
    for (size_t i = 0; i < n; ++i) {
        char c = username[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) return 0;
    }
    return 1;
}

static int parse_int(const char *s, int *out) {
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (s[0] == '\0' || (end && *end != '\0')) return 0;
    if (v < -2147483648L || v > 2147483647L) return 0;
    *out = (int)v;
    return 1;
}

static Session* find_session(const char *token) {
    for (size_t i = 0; i < sessions_len; ++i) {
        if (sessions[i].valid && strcmp(sessions[i].token, token) == 0) return &sessions[i];
    }
    return NULL;
}

static void invalidate_session_token(const char *token) {
    for (size_t i = 0; i < sessions_len; ++i) {
        if (strcmp(sessions[i].token, token) == 0) sessions[i].valid = 0;
    }
}

static Todo* find_todo_by_id_for_user(int todo_id, int user_id) {
    for (size_t i = 0; i < todos_len; ++i) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id) return &todos[i];
    }
    return NULL;
}

static Todo* find_todo_by_id_any(int todo_id) {
    for (size_t i = 0; i < todos_len; ++i) {
        if (todos[i].id == todo_id) return &todos[i];
    }
    return NULL;
}

static void delete_todo_by_id_for_user(int todo_id, int user_id) {
    for (size_t i = 0; i < todos_len; ++i) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id) {
            // free strings
            free(todos[i].title);
            free(todos[i].description);
            // shift
            for (size_t j = i + 1; j < todos_len; ++j) {
                todos[j-1] = todos[j];
            }
            todos_len--;
            return;
        }
    }
}

// HTTP parsing helpers

typedef struct {
    char method[8];
    char path[MAX_PATH_LEN];
    int content_length;
    char *cookie; // malloced string or NULL
    char *body;   // malloced body of length content_length
} HttpRequest;

static void http_request_free(HttpRequest *req) {
    if (req->cookie) free(req->cookie);
    if (req->body) free(req->body);
}

static int starts_with(const char *s, const char *prefix) {
    size_t n = strlen(prefix);
    return strncmp(s, prefix, n) == 0;
}

static int read_all(int fd, char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t r = recv(fd, buf + off, len - off, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) break;
        off += (size_t)r;
    }
    return (int)off;
}

static int read_http_request(int client_fd, HttpRequest *out_req) {
    memset(out_req, 0, sizeof(*out_req));
    out_req->content_length = 0;
    char headerbuf[MAX_HEADER_SIZE+1];
    size_t used = 0;
    // Read until we find \r\n\r\n or exceed MAX_HEADER_SIZE
    while (used < MAX_HEADER_SIZE) {
        ssize_t r = recv(client_fd, headerbuf + used, MAX_HEADER_SIZE - used, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) break; // connection closed
        used += (size_t)r;
        headerbuf[used] = '\0';
        char *end = strstr(headerbuf, "\r\n\r\n");
        if (end) {
            size_t header_len = (size_t)(end - headerbuf) + 4;
            // Parse request line
            char *line_end = strstr(headerbuf, "\r\n");
            if (!line_end) return -1;
            *line_end = '\0';
            if (sscanf(headerbuf, "%7s %511s", out_req->method, out_req->path) != 2) return -1;
            *line_end = '\r';
            // Parse headers line by line
            char *p = line_end + 2;
            while (p < headerbuf + header_len - 2) {
                char *nl = strstr(p, "\r\n");
                if (!nl) break;
                *nl = '\0';
                // Header line in p
                if (strncasecmp(p, "Content-Length:", 15) == 0) {
                    const char *v = p + 15;
                    while (*v == ' ' || *v == '\t') v++;
                    out_req->content_length = atoi(v);
                } else if (strncasecmp(p, "Cookie:", 7) == 0) {
                    const char *v = p + 7;
                    while (*v == ' ' || *v == '\t') v++;
                    out_req->cookie = strdup(v);
                }
                *nl = '\r';
                p = nl + 2;
            }
            // Move any remaining bytes (body start) to a body buffer
            size_t remain = used - header_len;
            if (out_req->content_length > 0) {
                out_req->body = (char*)malloc((size_t)out_req->content_length + 1);
                if (!out_req->body) return -1;
                size_t tocopy = remain < (size_t)out_req->content_length ? remain : (size_t)out_req->content_length;
                if (tocopy > 0) memcpy(out_req->body, end + 4, tocopy);
                size_t need_more = (size_t)out_req->content_length - tocopy;
                if (need_more > 0) {
                    int rr = read_all(client_fd, out_req->body + tocopy, need_more);
                    if (rr < 0 || (size_t)rr != need_more) return -1;
                }
                out_req->body[out_req->content_length] = '\0';
            }
            return 0;
        }
    }
    return -1;
}

static char* json_error(const char *msg) {
    json_t *obj = json_object();
    json_object_set_new(obj, "error", json_string(msg));
    char *dump = json_dumps(obj, JSON_COMPACT);
    json_decref(obj);
    return dump; // must free with free()
}

static char* user_to_json(const User *u) {
    json_t *obj = json_object();
    json_object_set_new(obj, "id", json_integer(u->id));
    json_object_set_new(obj, "username", json_string(u->username));
    char *dump = json_dumps(obj, JSON_COMPACT);
    json_decref(obj);
    return dump;
}

static json_t* todo_to_json_obj(const Todo *t) {
    json_t *obj = json_object();
    json_object_set_new(obj, "id", json_integer(t->id));
    json_object_set_new(obj, "title", json_string(t->title));
    json_object_set_new(obj, "description", json_string(t->description ? t->description : ""));
    json_object_set_new(obj, "completed", t->completed ? json_true() : json_false());
    json_object_set_new(obj, "created_at", json_string(t->created_at));
    json_object_set_new(obj, "updated_at", json_string(t->updated_at));
    return obj;
}

static int cmp_todo_ptr_by_id(const void *a, const void *b) {
    const Todo *ta = *(const Todo* const*)a; const Todo *tb = *(const Todo* const*)b;
    if (ta->id < tb->id) return -1;
    if (ta->id > tb->id) return 1;
    return 0;
}

static char* todos_list_for_user_json(int user_id) {
    // collect pointers to todos belonging to user
    size_t count = 0;
    for (size_t i = 0; i < todos_len; ++i) if (todos[i].user_id == user_id) count++;
    Todo **arr = (Todo**)malloc(count * sizeof(Todo*));
    size_t idx = 0;
    for (size_t i = 0; i < todos_len; ++i) if (todos[i].user_id == user_id) arr[idx++] = &todos[i];
    // sort by id ascending
    qsort(arr, count, sizeof(Todo*), cmp_todo_ptr_by_id);
    json_t *list = json_array();
    for (size_t i = 0; i < count; ++i) {
        json_t *obj = todo_to_json_obj(arr[i]);
        json_array_append_new(list, obj);
    }
    char *dump = json_dumps(list, JSON_COMPACT);
    json_decref(list);
    free(arr);
    return dump;
}

static int extract_session_token(const char *cookie_header, char out_token[65]) {
    if (!cookie_header) return 0;
    // parse semi-colon separated cookies
    const char *p = cookie_header;
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == ';') p++;
        const char *eq = strchr(p, '=');
        if (!eq) break;
        const char *name_start = p;
        const char *name_end = eq;
        while (name_end > name_start && (*(name_end-1) == ' ' || *(name_end-1) == '\t')) name_end--;
        const char *val_start = eq + 1;
        const char *val_end = val_start;
        while (*val_end && *val_end != ';') val_end++;
        // trim trailing spaces
        const char *v_end_trim = val_end;
        while (v_end_trim > val_start && (*(v_end_trim-1) == ' ' || *(v_end_trim-1) == '\t')) v_end_trim--;
        size_t name_len = (size_t)(name_end - name_start);
        size_t val_len = (size_t)(v_end_trim - val_start);
        if (name_len == strlen("session_id") && strncmp(name_start, "session_id", name_len) == 0 && val_len > 0 && val_len < 65) {
            memcpy(out_token, val_start, val_len);
            out_token[val_len] = '\0';
            return 1;
        }
        p = val_end;
        if (*p == ';') p++;
    }
    return 0;
}

static void route_request(int client_fd, HttpRequest *req) {
    // Authentication
    int authed_user_id = 0;
    char token[65];
    if (extract_session_token(req->cookie, token)) {
        Session *s = find_session(token);
        if (s && s->valid) authed_user_id = s->user_id;
    }

    // Routing
    if (strcmp(req->method, "POST") == 0 && strcmp(req->path, "/register") == 0) {
        // Parse JSON body
        json_error_t jerr;
        json_t *root = NULL;
        if (!req->body) {
            char *err = json_error("Invalid JSON");
            send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return;
        }
        root = json_loads(req->body, 0, &jerr);
        if (!root || !json_is_object(root)) {
            if (root) json_decref(root);
            char *err = json_error("Invalid JSON");
            send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return;
        }
        json_t *juser = json_object_get(root, "username");
        json_t *jpass = json_object_get(root, "password");
        if (!juser || !json_is_string(juser) || !username_valid(json_string_value(juser))) {
            json_decref(root);
            char *err = json_error("Invalid username");
            send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return;
        }
        if (!jpass || !json_is_string(jpass) || strlen(json_string_value(jpass)) < 8) {
            json_decref(root);
            char *err = json_error("Password too short");
            send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return;
        }
        const char *uname = json_string_value(juser);
        if (find_user_by_username(uname)) {
            json_decref(root);
            char *err = json_error("Username already exists");
            send_response_json(client_fd, 409, "Conflict", err, NULL); free(err); return;
        }
        ensure_capacity_users();
        User *u = &users[users_len++];
        u->id = next_user_id++;
        u->username = strdup(uname);
        const char *pwd = json_string_value(jpass);
        sha256_hex(pwd, u->password_hash_hex);
        char *resp = user_to_json(u);
        send_response_json(client_fd, 201, "Created", resp, NULL);
        free(resp);
        json_decref(root);
        return;
    }
    else if (strcmp(req->method, "POST") == 0 && strcmp(req->path, "/login") == 0) {
        json_error_t jerr; json_t *root = NULL;
        if (!req->body) { char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
        root = json_loads(req->body, 0, &jerr);
        if (!root || !json_is_object(root)) { if (root) json_decref(root); char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
        json_t *juser = json_object_get(root, "username");
        json_t *jpass = json_object_get(root, "password");
        if (!juser || !json_is_string(juser) || !jpass || !json_is_string(jpass)) {
            json_decref(root); char *err = json_error("Invalid credentials"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return;
        }
        const char *uname = json_string_value(juser);
        const char *pwd = json_string_value(jpass);
        User *u = find_user_by_username(uname);
        char pwdhash[65]; sha256_hex(pwd, pwdhash);
        if (!u || strcmp(u->password_hash_hex, pwdhash) != 0) {
            json_decref(root); char *err = json_error("Invalid credentials"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return;
        }
        // Create session
        ensure_capacity_sessions();
        Session *s = &sessions[sessions_len++];
        if (gen_token_hex(s->token) != 0) { json_decref(root); char *err = json_error("Server error"); send_response_json(client_fd, 500, "Internal Server Error", err, NULL); free(err); return; }
        s->user_id = u->id; s->valid = 1;
        char set_cookie[256];
        snprintf(set_cookie, sizeof(set_cookie), "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", s->token);
        char *resp = user_to_json(u);
        send_response_json(client_fd, 200, "OK", resp, set_cookie);
        free(resp);
        json_decref(root);
        return;
    }
    else if (strcmp(req->method, "POST") == 0 && strcmp(req->path, "/logout") == 0) {
        if (!authed_user_id) { char *err = json_error("Authentication required"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        if (extract_session_token(req->cookie, token)) {
            invalidate_session_token(token);
        }
        json_t *obj = json_object(); char *dump = json_dumps(obj, JSON_COMPACT); json_decref(obj);
        send_response_json(client_fd, 200, "OK", dump, NULL); free(dump);
        return;
    }
    else if (strcmp(req->method, "GET") == 0 && strcmp(req->path, "/me") == 0) {
        if (!authed_user_id) { char *err = json_error("Authentication required"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        User *u = find_user_by_id(authed_user_id);
        if (!u) { char *err = json_error("Authentication required"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        char *resp = user_to_json(u);
        send_response_json(client_fd, 200, "OK", resp, NULL);
        free(resp);
        return;
    }
    else if (strcmp(req->method, "PUT") == 0 && strcmp(req->path, "/password") == 0) {
        if (!authed_user_id) { char *err = json_error("Authentication required"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        User *u = find_user_by_id(authed_user_id);
        if (!u) { char *err = json_error("Authentication required"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        if (!req->body) { char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
        json_error_t jerr; json_t *root = json_loads(req->body, 0, &jerr);
        if (!root || !json_is_object(root)) { if (root) json_decref(root); char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
        json_t *jold = json_object_get(root, "old_password");
        json_t *jnew = json_object_get(root, "new_password");
        if (!jold || !json_is_string(jold)) { json_decref(root); char *err = json_error("Invalid credentials"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        if (!jnew || !json_is_string(jnew) || strlen(json_string_value(jnew)) < 8) { json_decref(root); char *err = json_error("Password too short"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
        const char *oldp = json_string_value(jold); char oldhash[65]; sha256_hex(oldp, oldhash);
        if (strcmp(u->password_hash_hex, oldhash) != 0) { json_decref(root); char *err = json_error("Invalid credentials"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        const char *newp = json_string_value(jnew); sha256_hex(newp, u->password_hash_hex);
        json_decref(root);
        json_t *obj = json_object(); char *dump = json_dumps(obj, JSON_COMPACT); json_decref(obj);
        send_response_json(client_fd, 200, "OK", dump, NULL); free(dump);
        return;
    }
    else if (strcmp(req->method, "GET") == 0 && strcmp(req->path, "/todos") == 0) {
        if (!authed_user_id) { char *err = json_error("Authentication required"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        char *dump = todos_list_for_user_json(authed_user_id);
        send_response_json(client_fd, 200, "OK", dump, NULL); free(dump); return;
    }
    else if (strcmp(req->method, "POST") == 0 && strcmp(req->path, "/todos") == 0) {
        if (!authed_user_id) { char *err = json_error("Authentication required"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        if (!req->body) { char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
        json_error_t jerr; json_t *root = json_loads(req->body, 0, &jerr);
        if (!root || !json_is_object(root)) { if (root) json_decref(root); char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
        json_t *jtitle = json_object_get(root, "title");
        json_t *jdesc = json_object_get(root, "description");
        if (!jtitle || !json_is_string(jtitle) || strlen(json_string_value(jtitle)) == 0) {
            json_decref(root); char *err = json_error("Title is required"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return;
        }
        const char *title = json_string_value(jtitle);
        const char *desc = (jdesc && json_is_string(jdesc)) ? json_string_value(jdesc) : "";
        ensure_capacity_todos();
        Todo *t = &todos[todos_len++];
        t->id = next_todo_id++;
        t->user_id = authed_user_id;
        t->title = strdup(title);
        t->description = strdup(desc);
        t->completed = 0;
        iso8601_utc_now(t->created_at);
        strcpy(t->updated_at, t->created_at);
        json_t *obj = todo_to_json_obj(t);
        char *dump = json_dumps(obj, JSON_COMPACT); json_decref(obj);
        send_response_json(client_fd, 201, "Created", dump, NULL); free(dump);
        json_decref(root); return;
    }
    else if (starts_with(req->path, "/todos/") && (strcmp(req->method, "GET") == 0 || strcmp(req->method, "PUT") == 0 || strcmp(req->method, "DELETE") == 0)) {
        if (!authed_user_id) { char *err = json_error("Authentication required"); send_response_json(client_fd, 401, "Unauthorized", err, NULL); free(err); return; }
        const char *idstr = req->path + strlen("/todos/");
        int tid;
        if (!parse_int(idstr, &tid) || tid <= 0) {
            char *err = json_error("Todo not found"); send_response_json(client_fd, 404, "Not Found", err, NULL); free(err); return;
        }
        if (strcmp(req->method, "GET") == 0) {
            Todo *t = find_todo_by_id_for_user(tid, authed_user_id);
            if (!t) { char *err = json_error("Todo not found"); send_response_json(client_fd, 404, "Not Found", err, NULL); free(err); return; }
            json_t *obj = todo_to_json_obj(t); char *dump = json_dumps(obj, JSON_COMPACT); json_decref(obj);
            send_response_json(client_fd, 200, "OK", dump, NULL); free(dump); return;
        } else if (strcmp(req->method, "PUT") == 0) {
            Todo *t_any = find_todo_by_id_any(tid);
            if (!t_any || t_any->user_id != authed_user_id) { char *err = json_error("Todo not found"); send_response_json(client_fd, 404, "Not Found", err, NULL); free(err); return; }
            if (!req->body) { char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
            json_error_t jerr; json_t *root = json_loads(req->body, 0, &jerr);
            if (!root || !json_is_object(root)) { if (root) json_decref(root); char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
            json_t *jtitle = json_object_get(root, "title");
            json_t *jdesc = json_object_get(root, "description");
            json_t *jcomp = json_object_get(root, "completed");
            if (jtitle) {
                if (!json_is_string(jtitle) || strlen(json_string_value(jtitle)) == 0) { json_decref(root); char *err = json_error("Title is required"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
                free(t_any->title); t_any->title = strdup(json_string_value(jtitle));
            }
            if (jdesc) {
                if (!json_is_string(jdesc)) { json_decref(root); char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return; }
                free(t_any->description); t_any->description = strdup(json_string_value(jdesc));
            }
            if (jcomp) {
                if (json_is_boolean(jcomp)) {
                    t_any->completed = json_is_true(jcomp) ? 1 : 0;
                } else {
                    json_decref(root); char *err = json_error("Invalid JSON"); send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err); return;
                }
            }
            iso8601_utc_now(t_any->updated_at);
            json_t *obj = todo_to_json_obj(t_any); char *dump = json_dumps(obj, JSON_COMPACT); json_decref(obj);
            send_response_json(client_fd, 200, "OK", dump, NULL); free(dump); json_decref(root); return;
        } else if (strcmp(req->method, "DELETE") == 0) {
            Todo *t = find_todo_by_id_any(tid);
            if (!t || t->user_id != authed_user_id) { char *err = json_error("Todo not found");
                send_response_json(client_fd, 404, "Not Found", err, NULL); free(err); return; }
            delete_todo_by_id_for_user(tid, authed_user_id);
            send_response_no_body(client_fd, 204, "No Content"); return;
        }
    }

    // Not found
    char *err = json_error("Not found");
    send_response_json(client_fd, 404, "Not Found", err, NULL); free(err);
}

int main(int argc, char **argv) {
    int port = 8000;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i+1]);
            i++;
        }
    }

    signal(SIGINT, handle_sigint);

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return 1; }
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_ANY); addr.sin_port = htons((uint16_t)port);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { perror("bind"); close(server_fd); return 1; }
    if (listen(server_fd, 16) < 0) { perror("listen"); close(server_fd); return 1; }

    fprintf(stderr, "Server listening on 0.0.0.0:%d\n", port);

    while (keep_running) {
        struct sockaddr_in cli; socklen_t clilen = sizeof(cli);
        int client_fd = accept(server_fd, (struct sockaddr*)&cli, &clilen);
        if (client_fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("accept");
            break;
        }
        // set a receive timeout to avoid hanging
        struct timeval tv; tv.tv_sec = READ_TIMEOUT_SEC; tv.tv_usec = 0;
        setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        HttpRequest req;
        if (read_http_request(client_fd, &req) == 0) {
            route_request(client_fd, &req);
            http_request_free(&req);
        } else {
            char *err = json_error("Bad Request");
            send_response_json(client_fd, 400, "Bad Request", err, NULL); free(err);
        }
        close(client_fd);
    }

    close(server_fd);

    // cleanup
    for (size_t i = 0; i < users_len; ++i) free(users[i].username);
    for (size_t i = 0; i < todos_len; ++i) { free(todos[i].title); free(todos[i].description); }
    free(users); free(todos); free(sessions);
    return 0;
}

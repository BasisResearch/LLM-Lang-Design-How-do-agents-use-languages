#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <fcntl.h>
#include <jansson.h>

#define BACKLOG 64
#define READ_BUF_SIZE 65536
#define MAX_HEADER_LINES 200

typedef struct {
    int id;
    char username[64]; // allow up to 63 + null
    char password[256];
} User;

typedef struct {
    char token[65]; // 64 hex chars + null
    int user_id;
    int valid; // 1 valid, 0 invalid
} Session;

typedef struct {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0/1
    char created_at[21];
    char updated_at[21];
} Todo;

static User *users = NULL; size_t users_count = 0; size_t users_cap = 0; int next_user_id = 1;
static Session *sessions = NULL; size_t sessions_count = 0; size_t sessions_cap = 0;
static Todo *todos = NULL; size_t todos_count = 0; size_t todos_cap = 0; int next_todo_id = 1;

static void fatal(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    exit(1);
}

static void *xrealloc(void *p, size_t sz){
    void *q = realloc(p, sz);
    if(!q) fatal("Out of memory");
    return q;
}
static void *xmalloc(size_t sz){
    void *q = malloc(sz);
    if(!q) fatal("Out of memory");
    return q;
}

static void vec_reserve_users(size_t need){
    if(users_cap >= need) return;
    size_t nc = users_cap? users_cap*2: 8; if(nc < need) nc = need;
    users = xrealloc(users, nc * sizeof(User)); users_cap = nc;
}
static void vec_reserve_sessions(size_t need){
    if(sessions_cap >= need) return;
    size_t nc = sessions_cap? sessions_cap*2: 8; if(nc < need) nc = need;
    sessions = xrealloc(sessions, nc * sizeof(Session)); sessions_cap = nc;
}
static void vec_reserve_todos(size_t need){
    if(todos_cap >= need) return;
    size_t nc = todos_cap? todos_cap*2: 16; if(nc < need) nc = need;
    todos = xrealloc(todos, nc * sizeof(Todo)); todos_cap = nc;
}

static void http_send_all(int fd, const char *buf, size_t len){
    size_t off = 0; ssize_t n;
    while(off < len){
        n = send(fd, buf+off, len-off, 0);
        if(n < 0){ if(errno == EINTR) continue; break; }
        if(n == 0) break;
        off += (size_t)n;
    }
}

static void send_response(int fd, int status, const char *reason, const char *body, const char *extra_headers, int include_content_type){
    char header[1024];
    size_t body_len = body ? strlen(body) : 0;
    int n = 0;
    if(include_content_type){
        n = snprintf(header, sizeof(header),
            "HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n%s\r\n",
            status, reason, body_len, (extra_headers? extra_headers: ""));
    } else {
        n = snprintf(header, sizeof(header),
            "HTTP/1.1 %d %s\r\nConnection: close\r\n%s\r\n",
            status, reason, (extra_headers? extra_headers: ""));
    }
    if(n < 0) n = 0;
    if((size_t)n > sizeof(header)) n = (int)sizeof(header);
    http_send_all(fd, header, (size_t)n);
    if(include_content_type && body_len > 0){
        http_send_all(fd, body, body_len);
    }
}

static void send_json_error(int fd, int status, const char *reason, const char *msg){
    json_t *o = json_object();
    json_object_set_new(o, "error", json_string(msg));
    char *s = json_dumps(o, JSON_COMPACT);
    json_decref(o);
    send_response(fd, status, reason, s, NULL, 1);
    free(s);
}

static void trim(char *s){
    if(!s) return;
    char *p = s; while(isspace((unsigned char)*p)) p++;
    if(p != s) memmove(s, p, strlen(p)+1);
    size_t len = strlen(s);
    while(len>0 && isspace((unsigned char)s[len-1])){ s[len-1] = '\0'; len--; }
}

static int iequals(const char *a, const char *b){
    for(; *a && *b; a++, b++){
        if(tolower((unsigned char)*a) != tolower((unsigned char)*b)) return 0;
    }
    return *a == '\0' && *b == '\0';
}

typedef struct { char name[64]; char *value; } Header;

typedef struct {
    char method[8];
    char path[1024];
    Header headers[MAX_HEADER_LINES];
    int header_count;
    char *body; size_t body_len;
} HttpRequest;

static const char *get_header(HttpRequest *req, const char *name){
    for(int i=0;i<req->header_count;i++){
        if(iequals(req->headers[i].name, name)) return req->headers[i].value;
    }
    return NULL;
}

static int parse_request(int fd, HttpRequest *req){
    memset(req, 0, sizeof(*req));
    char *buf = xmalloc(READ_BUF_SIZE);
    size_t cap = READ_BUF_SIZE; size_t len = 0;
    int header_end = -1;
    size_t last_scan = 0;
    while(1){
        if(len+4096 > cap){ cap *= 2; buf = xrealloc(buf, cap); }
        ssize_t n = recv(fd, buf+len, cap-len, 0);
        if(n < 0){ if(errno==EINTR) continue; free(buf); return -1; }
        if(n == 0){ break; }
        len += (size_t)n;
        size_t start = (last_scan >= 3) ? last_scan - 3 : 0;
        for(size_t i=start; i+3 < len; i++){
            if(buf[i]=='\r' && buf[i+1]=='\n' && buf[i+2]=='\r' && buf[i+3]=='\n'){ header_end = (int)(i+4); break; }
        }
        last_scan = len;
        if(header_end != -1) break;
        if(len > 1024*1024){ free(buf); return -1; }
    }
    if(header_end == -1){ free(buf); return -1; }

    // Parse request line
    char *p = buf;
    char *line_end = strstr(p, "\r\n");
    if(!line_end){ free(buf); return -1; }
    *line_end = '\0';
    // method SP path SP HTTP/1.1
    char httpver[16];
    if(sscanf(p, "%7s %1023s %15s", req->method, req->path, httpver) != 3){ free(buf); return -1; }

    // Parse headers
    p = line_end + 2;
    req->header_count = 0;
    while(p < buf + header_end - 2){
        char *e = strstr(p, "\r\n");
        if(!e) break; *e = '\0';
        char *colon = strchr(p, ':');
        if(colon){
            *colon = '\0';
            char namebuf[64];
            strncpy(namebuf, p, sizeof(namebuf)-1); namebuf[sizeof(namebuf)-1]='\0';
            // trim value
            char *val = colon+1; while(*val && isspace((unsigned char)*val)) val++;
            if(req->header_count < MAX_HEADER_LINES){
                strncpy(req->headers[req->header_count].name, namebuf, sizeof(req->headers[req->header_count].name)-1);
                req->headers[req->header_count].name[sizeof(req->headers[req->header_count].name)-1]='\0';
                req->headers[req->header_count].value = strdup(val?val:"");
                req->header_count++;
            }
        }
        p = e + 2;
    }

    // Body
    size_t body_len = 0; char *body_start = buf + header_end;
    const char *cl = NULL;
    for(int i=0;i<req->header_count;i++){
        if(iequals(req->headers[i].name, "Content-Length")) { cl = req->headers[i].value; break; }
    }
    if(cl){ body_len = (size_t) strtoul(cl, NULL, 10); }
    size_t have = len - (size_t)header_end;
    char *body = NULL;
    if(body_len > 0){
        body = xmalloc(body_len+1);
        if(have >= body_len){
            memcpy(body, body_start, body_len);
        } else {
            memcpy(body, body_start, have);
            size_t rem = body_len - have;
            size_t off = have;
            while(rem>0){
                ssize_t n = recv(fd, body+off, rem, 0);
                if(n < 0){ if(errno==EINTR) continue; free(body); free(buf); return -1; }
                if(n == 0){ break; }
                off += (size_t)n; rem -= (size_t)n;
            }
        }
        body[body_len] = '\0';
    }

    req->body = body; req->body_len = body_len;

    free(buf);
    return 0;
}

static void free_request(HttpRequest *req){
    for(int i=0;i<req->header_count;i++){
        free(req->headers[i].value);
    }
    free(req->body);
}

static int username_valid(const char *u){
    if(!u) return 0;
    size_t L = strlen(u);
    if(L < 3 || L > 50) return 0;
    for(size_t i=0;i<L;i++){
        char c = u[i];
        if(!(isalnum((unsigned char)c) || c=='_')) return 0;
    }
    return 1;
}

static char *current_time_iso8601(){
    time_t t = time(NULL);
    struct tm g;
    gmtime_r(&t, &g);
    char *s = xmalloc(21);
    strftime(s, 21, "%Y-%m-%dT%H:%M:%SZ", &g);
    return s;
}

static void random_bytes(unsigned char *buf, size_t n){
    int fd = open("/dev/urandom", O_RDONLY);
    if(fd < 0){ fatal("Failed to open /dev/urandom"); }
    size_t off=0; while(off<n){ ssize_t r = read(fd, buf+off, n-off); if(r<0){ if(errno==EINTR) continue; fatal("urandom read"); } if(r==0) break; off += (size_t)r; }
    close(fd);
}

static void gen_token(char out[65]){
    unsigned char b[32]; random_bytes(b, sizeof(b));
    static const char *hex = "0123456789abcdef";
    for(int i=0;i<32;i++){ out[i*2] = hex[(b[i]>>4)&0xF]; out[i*2+1] = hex[b[i]&0xF]; }
    out[64] = '\0';
}

static User* find_user_by_username(const char *u){
    for(size_t i=0;i<users_count;i++){
        if(strcmp(users[i].username, u)==0) return &users[i];
    }
    return NULL;
}

static User* find_user_by_id(int id){
    for(size_t i=0;i<users_count;i++) if(users[i].id == id) return &users[i];
    return NULL;
}

static Session* find_session(const char *token){
    if(!token) return NULL;
    for(size_t i=0;i<sessions_count;i++){
        if(sessions[i].valid && strcmp(sessions[i].token, token)==0) return &sessions[i];
    }
    return NULL;
}

static void invalidate_session(const char *token){
    for(size_t i=0;i<sessions_count;i++){
        if(strcmp(sessions[i].token, token)==0){ sessions[i].valid = 0; }
    }
}

static Todo* find_todo_by_id(int id){
    for(size_t i=0;i<todos_count;i++) if(todos[i].id == id) return &todos[i];
    return NULL;
}

static void json_user(json_t *o, const User *u){
    json_object_set_new(o, "id", json_integer(u->id));
    json_object_set_new(o, "username", json_string(u->username));
}

static json_t* json_todo_obj(const Todo *t){
    json_t *o = json_object();
    json_object_set_new(o, "id", json_integer(t->id));
    json_object_set_new(o, "title", json_string(t->title?t->title:""));
    json_object_set_new(o, "description", json_string(t->description?t->description:""));
    json_object_set_new(o, "completed", json_boolean(t->completed));
    json_object_set_new(o, "created_at", json_string(t->created_at));
    json_object_set_new(o, "updated_at", json_string(t->updated_at));
    return o;
}

static int parse_id_from_path(const char *path){
    // path like /todos/123
    if(strncmp(path, "/todos/", 7) != 0) return -1;
    const char *p = path + 7;
    if(*p == '\0') return -1;
    char *end;
    long v = strtol(p, &end, 10);
    if(end==p || *end != '\0' || v <= 0 || v > 2147483647L) return -1;
    return (int)v;
}

static char* extract_session_id(HttpRequest *req){
    const char *cookie = get_header(req, "Cookie");
    if(!cookie) return NULL;
    // parse cookie string
    char *tmp = strdup(cookie);
    char *saveptr = NULL;
    char *token = strtok_r(tmp, ";", &saveptr);
    char *result = NULL;
    while(token){
        while(*token && isspace((unsigned char)*token)) token++;
        char *eq = strchr(token, '=');
        if(eq){
            *eq = '\0';
            char *name = token; char *val = eq+1; trim(name); trim(val);
            if(strcmp(name, "session_id") == 0){
                result = strdup(val);
                break;
            }
        }
        token = strtok_r(NULL, ";", &saveptr);
    }
    free(tmp);
    return result;
}

static void handle_register(int fd, HttpRequest *req){
    json_error_t jerr; json_t *root = NULL;
    if(req->body_len == 0){ send_json_error(fd, 400, "Bad Request", "Invalid username"); return; }
    root = json_loadb(req->body, req->body_len, 0, &jerr);
    if(!root || !json_is_object(root)){
        if(root) json_decref(root);
        send_json_error(fd, 400, "Bad Request", "Invalid username");
        return;
    }
    const char *username = NULL; const char *password = NULL;
    json_t *ju = json_object_get(root, "username");
    json_t *jp = json_object_get(root, "password");
    if(json_is_string(ju)) username = json_string_value(ju);
    if(json_is_string(jp)) password = json_string_value(jp);

    if(!username_valid(username)){
        json_decref(root);
        send_json_error(fd, 400, "Bad Request", "Invalid username");
        return;
    }
    if(!password || strlen(password) < 8){
        json_decref(root);
        send_json_error(fd, 400, "Bad Request", "Password too short");
        return;
    }
    if(find_user_by_username(username)){
        json_decref(root);
        send_json_error(fd, 409, "Conflict", "Username already exists");
        return;
    }
    vec_reserve_users(users_count+1);
    User *u = &users[users_count++];
    u->id = next_user_id++;
    strncpy(u->username, username, sizeof(u->username)-1); u->username[sizeof(u->username)-1] = '\0';
    strncpy(u->password, password, sizeof(u->password)-1); u->password[sizeof(u->password)-1] = '\0';

    json_t *out = json_object(); json_user(out, u);
    char *s = json_dumps(out, JSON_COMPACT);
    json_decref(out); json_decref(root);
    send_response(fd, 201, "Created", s, NULL, 1);
    free(s);
}

static void handle_login(int fd, HttpRequest *req){
    json_error_t jerr; json_t *root = NULL;
    root = (req->body_len>0)? json_loadb(req->body, req->body_len, 0, &jerr): NULL;
    const char *username = NULL; const char *password = NULL;
    if(root && json_is_object(root)){
        json_t *ju = json_object_get(root, "username");
        json_t *jp = json_object_get(root, "password");
        if(json_is_string(ju)) username = json_string_value(ju);
        if(json_is_string(jp)) password = json_string_value(jp);
    }
    User *u = NULL;
    if(username) u = find_user_by_username(username);
    if(!u || !password || strcmp(u->password, password) != 0){
        if(root) json_decref(root);
        send_json_error(fd, 401, "Unauthorized", "Invalid credentials");
        return;
    }
    // create session
    vec_reserve_sessions(sessions_count+1);
    Session *s = &sessions[sessions_count++];
    gen_token(s->token); s->user_id = u->id; s->valid = 1;

    // response headers
    char setcookie[256];
    snprintf(setcookie, sizeof(setcookie), "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", s->token);

    json_t *out = json_object(); json_user(out, u);
    char *body = json_dumps(out, JSON_COMPACT);
    json_decref(out); if(root) json_decref(root);
    send_response(fd, 200, "OK", body, setcookie, 1);
    free(body);
}

static int require_auth(int fd, HttpRequest *req, User **out_user, char **out_token){
    char *token = extract_session_id(req);
    Session *s = token? find_session(token) : NULL;
    if(!s){
        if(token) free(token);
        send_json_error(fd, 401, "Unauthorized", "Authentication required");
        return 0;
    }
    User *u = find_user_by_id(s->user_id);
    if(!u){
        if(token) free(token);
        send_json_error(fd, 401, "Unauthorized", "Authentication required");
        return 0;
    }
    if(out_user) *out_user = u;
    if(out_token) *out_token = token; else free(token);
    return 1;
}

static void handle_logout(int fd, HttpRequest *req){
    User *u = NULL; char *token = NULL;
    if(!require_auth(fd, req, &u, &token)) return;
    (void)u;
    invalidate_session(token);
    free(token);
    json_t *out = json_object();
    char *s = json_dumps(out, JSON_COMPACT);
    json_decref(out);
    send_response(fd, 200, "OK", s, NULL, 1);
    free(s);
}

static void handle_me(int fd, HttpRequest *req){
    User *u = NULL; if(!require_auth(fd, req, &u, NULL)) return;
    json_t *out = json_object(); json_user(out, u);
    char *s = json_dumps(out, JSON_COMPACT);
    json_decref(out);
    send_response(fd, 200, "OK", s, NULL, 1);
    free(s);
}

static void handle_password(int fd, HttpRequest *req){
    User *u = NULL; if(!require_auth(fd, req, &u, NULL)) return;
    json_error_t jerr; json_t *root = NULL;
    root = (req->body_len>0)? json_loadb(req->body, req->body_len, 0, &jerr): NULL;
    const char *oldp=NULL,*newp=NULL;
    if(root && json_is_object(root)){
        json_t *jo = json_object_get(root, "old_password");
        json_t *jn = json_object_get(root, "new_password");
        if(json_is_string(jo)) oldp = json_string_value(jo);
        if(json_is_string(jn)) newp = json_string_value(jn);
    }
    if(!oldp || strcmp(oldp, u->password)!=0){ if(root) json_decref(root); send_json_error(fd, 401, "Unauthorized", "Invalid credentials"); return; }
    if(!newp || strlen(newp)<8){ if(root) json_decref(root); send_json_error(fd, 400, "Bad Request", "Password too short"); return; }
    strncpy(u->password, newp, sizeof(u->password)-1); u->password[sizeof(u->password)-1]='\0';
    if(root) json_decref(root);
    json_t *out = json_object(); char *s = json_dumps(out, JSON_COMPACT); json_decref(out);
    send_response(fd, 200, "OK", s, NULL, 1); free(s);
}

static int cmp_todo_ptr_by_id_asc(const void *a, const void *b){
    const Todo *ta = *(const Todo * const *)a;
    const Todo *tb = *(const Todo * const *)b;
    if(ta->id < tb->id) return -1;
    if(ta->id > tb->id) return 1;
    return 0;
}

static void handle_todos_list(int fd, HttpRequest *req){
    User *u = NULL; if(!require_auth(fd, req, &u, NULL)) return;
    // Collect and sort by id ascending
    size_t n=0; for(size_t i=0;i<todos_count;i++) if(todos[i].user_id==u->id) n++;
    Todo **arrptr = NULL; if(n>0){ arrptr = xmalloc(n * sizeof(Todo*)); }
    size_t j=0; for(size_t i=0;i<todos_count;i++) if(todos[i].user_id==u->id) arrptr[j++]=&todos[i];
    if(n>1) qsort(arrptr, n, sizeof(Todo*), cmp_todo_ptr_by_id_asc);

    json_t *arr = json_array();
    for(size_t k=0;k<n;k++){
        json_t *o = json_todo_obj(arrptr[k]);
        json_array_append_new(arr, o);
    }
    char *s = json_dumps(arr, JSON_COMPACT);
    json_decref(arr);
    if(arrptr) free(arrptr);
    send_response(fd, 200, "OK", s, NULL, 1);
    free(s);
}

static void handle_todos_create(int fd, HttpRequest *req){
    User *u = NULL; if(!require_auth(fd, req, &u, NULL)) return;
    json_error_t jerr; json_t *root = NULL;
    root = (req->body_len>0)? json_loadb(req->body, req->body_len, 0, &jerr): NULL;
    const char *title=NULL; const char *description="";
    if(root && json_is_object(root)){
        json_t *jt = json_object_get(root, "title");
        json_t *jd = json_object_get(root, "description");
        if(json_is_string(jt)) title = json_string_value(jt);
        if(json_is_string(jd)) description = json_string_value(jd);
    }
    if(!title || strlen(title)==0){ if(root) json_decref(root); send_json_error(fd, 400, "Bad Request", "Title is required"); return; }
    vec_reserve_todos(todos_count+1);
    Todo *t = &todos[todos_count++];
    t->id = next_todo_id++; t->user_id = u->id;
    t->title = strdup(title);
    t->description = strdup(description?description:"");
    t->completed = 0;
    char *now = current_time_iso8601();
    strncpy(t->created_at, now, sizeof(t->created_at)); t->created_at[20]='\0';
    strncpy(t->updated_at, now, sizeof(t->updated_at)); t->updated_at[20]='\0';
    free(now);
    json_t *o = json_todo_obj(t);
    char *s = json_dumps(o, JSON_COMPACT);
    json_decref(o); if(root) json_decref(root);
    send_response(fd, 201, "Created", s, NULL, 1);
    free(s);
}

static void handle_todos_get(int fd, HttpRequest *req, int id){
    User *u = NULL; if(!require_auth(fd, req, &u, NULL)) return;
    Todo *t = find_todo_by_id(id);
    if(!t || t->user_id != u->id){ send_json_error(fd, 404, "Not Found", "Todo not found"); return; }
    json_t *o = json_todo_obj(t);
    char *s = json_dumps(o, JSON_COMPACT);
    json_decref(o);
    send_response(fd, 200, "OK", s, NULL, 1);
    free(s);
}

static void handle_todos_update(int fd, HttpRequest *req, int id){
    User *u = NULL; if(!require_auth(fd, req, &u, NULL)) return;
    Todo *t = find_todo_by_id(id);
    if(!t || t->user_id != u->id){ send_json_error(fd, 404, "Not Found", "Todo not found"); return; }
    json_error_t jerr; json_t *root = NULL;
    root = (req->body_len>0)? json_loadb(req->body, req->body_len, 0, &jerr): NULL;
    if(root && json_is_object(root)){
        json_t *jt = json_object_get(root, "title");
        if(jt){
            if(json_is_string(jt)){
                const char *nt = json_string_value(jt);
                if(strlen(nt)==0){ if(root) json_decref(root); send_json_error(fd, 400, "Bad Request", "Title is required"); return; }
                free(t->title); t->title = strdup(nt);
            } else if(json_is_null(jt)) {
                // ignore null, not allowed per spec but treat as no-op
            } else {
                // ignore non-string
            }
        }
        json_t *jd = json_object_get(root, "description");
        if(jd){
            if(json_is_string(jd)){
                const char *nd = json_string_value(jd);
                free(t->description); t->description = strdup(nd?nd:"");
            }
        }
        json_t *jc = json_object_get(root, "completed");
        if(jc){
            if(json_is_boolean(jc)) t->completed = json_is_true(jc)?1:0;
        }
    }
    if(root) json_decref(root);
    char *now = current_time_iso8601();
    strncpy(t->updated_at, now, sizeof(t->updated_at)); t->updated_at[20]='\0';
    free(now);
    json_t *o = json_todo_obj(t);
    char *s = json_dumps(o, JSON_COMPACT);
    json_decref(o);
    send_response(fd, 200, "OK", s, NULL, 1);
    free(s);
}

static void handle_todos_delete(int fd, HttpRequest *req, int id){
    User *u = NULL; if(!require_auth(fd, req, &u, NULL)) return;
    size_t idx = (size_t)-1;
    for(size_t i=0;i<todos_count;i++){ if(todos[i].id==id){ idx=i; break; } }
    if(idx==(size_t)-1 || todos[idx].user_id != u->id){ send_json_error(fd, 404, "Not Found", "Todo not found"); return; }
    // free strings
    free(todos[idx].title); free(todos[idx].description);
    // remove by swapping last
    if(idx != todos_count-1){ todos[idx] = todos[todos_count-1]; }
    todos_count--;
    send_response(fd, 204, "No Content", NULL, NULL, 0);
}

static void route_request(int fd, HttpRequest *req){
    if(strcmp(req->method, "POST")==0 && strcmp(req->path, "/register")==0){ handle_register(fd, req); return; }
    if(strcmp(req->method, "POST")==0 && strcmp(req->path, "/login")==0){ handle_login(fd, req); return; }
    if(strcmp(req->method, "POST")==0 && strcmp(req->path, "/logout")==0){ handle_logout(fd, req); return; }
    if(strcmp(req->method, "GET")==0 && strcmp(req->path, "/me")==0){ handle_me(fd, req); return; }
    if(strcmp(req->method, "PUT")==0 && strcmp(req->path, "/password")==0){ handle_password(fd, req); return; }

    if(strcmp(req->method, "GET")==0 && strcmp(req->path, "/todos")==0){ handle_todos_list(fd, req); return; }
    if(strcmp(req->method, "POST")==0 && strcmp(req->path, "/todos")==0){ handle_todos_create(fd, req); return; }

    int tid = parse_id_from_path(req->path);
    if(tid > 0){
        if(strcmp(req->method, "GET")==0){ handle_todos_get(fd, req, tid); return; }
        if(strcmp(req->method, "PUT")==0){ handle_todos_update(fd, req, tid); return; }
        if(strcmp(req->method, "DELETE")==0){ handle_todos_delete(fd, req, tid); return; }
    }

    send_json_error(fd, 404, "Not Found", "Not found");
}

static int create_server_socket(int port){
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if(s < 0) fatal("socket failed: %s", strerror(errno));
    int yes = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_ANY); addr.sin_port = htons((uint16_t)port);
    if(bind(s, (struct sockaddr*)&addr, sizeof(addr))<0) fatal("bind failed: %s", strerror(errno));
    if(listen(s, BACKLOG)<0) fatal("listen failed: %s", strerror(errno));
    return s;
}

int main(int argc, char **argv){
    int port = 8080;
    for(int i=1;i<argc;i++){
        if(strcmp(argv[i], "--port")==0 && i+1<argc){ port = atoi(argv[i+1]); i++; }
    }
    int srv = create_server_socket(port);
    fprintf(stderr, "Server listening on 0.0.0.0:%d\n", port);
    while(1){
        struct sockaddr_in cli; socklen_t clilen = sizeof(cli);
        int c = accept(srv, (struct sockaddr*)&cli, &clilen);
        if(c < 0){ if(errno==EINTR) continue; fatal("accept failed: %s", strerror(errno)); }
        HttpRequest req; if(parse_request(c, &req)==0){ route_request(c, &req); free_request(&req); } else {
            // bad request
            send_json_error(c, 400, "Bad Request", "Bad request");
        }
        close(c);
    }
    return 0;
}

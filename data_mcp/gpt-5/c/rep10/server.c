#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <regex.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <jansson.h>

#define BACKLOG 64
#define READ_BUF_INIT 8192
#define MAX_HEADER_LINES 200
#define MAX_HEADER_LINE 8192

static volatile sig_atomic_t running = 1;

static void on_sigint(int sig){ (void)sig; running = 0; }

// Data structures

typedef struct {
    int id;
    char username[64]; // allow up to 63 + null
    char password[256];
} User;

typedef struct {
    char token[65]; // 32 bytes hex -> 64 chars + null
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
    int alive; // for deletion
} Todo;

static User *users = NULL; size_t users_len = 0; size_t users_cap = 0; int next_user_id = 1;
static Session *sessions = NULL; size_t sessions_len = 0; size_t sessions_cap = 0;
static Todo *todos = NULL; size_t todos_len = 0; size_t todos_cap = 0; int next_todo_id = 1;

static void die(const char *msg){ perror(msg); exit(1); }

static void *xmalloc(size_t n){ void *p = malloc(n); if(!p){ perror("malloc"); exit(1);} return p; }
static void *xrealloc(void *ptr, size_t n){ void *p = realloc(ptr, n); if(!p){ perror("realloc"); exit(1);} return p; }
static char *xstrdup(const char *s){ if(!s) return NULL; size_t n = strlen(s)+1; char *d = (char*)xmalloc(n); memcpy(d,s,n); return d; }

static void ensure_users_cap(){ if(users_len >= users_cap){ users_cap = users_cap? users_cap*2:16; users = (User*)xrealloc(users, users_cap*sizeof(User)); }}
static void ensure_sessions_cap(){ if(sessions_len >= sessions_cap){ sessions_cap = sessions_cap? sessions_cap*2:16; sessions = (Session*)xrealloc(sessions, sessions_cap*sizeof(Session)); }}
static void ensure_todos_cap(){ if(todos_len >= todos_cap){ todos_cap = todos_cap? todos_cap*2:16; todos = (Todo*)xrealloc(todos, todos_cap*sizeof(Todo)); }}

static void http_time_now_iso(char out[21]){
    time_t t = time(NULL);
    struct tm g; gmtime_r(&t, &g);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &g);
}

static void gen_token(char out[65]){
    // 32 random bytes -> 64 hex chars
    unsigned char buf[32];
    int fd = open("/dev/urandom", O_RDONLY);
    if(fd<0){ die("open urandom"); }
    ssize_t r = read(fd, buf, sizeof(buf));
    close(fd);
    if(r != (ssize_t)sizeof(buf)) die("read urandom");
    static const char *hex = "0123456789abcdef";
    for(int i=0;i<32;i++){ out[2*i] = hex[(buf[i]>>4)&0xF]; out[2*i+1] = hex[buf[i]&0xF]; }
    out[64]='\0';
}

// HTTP parsing

typedef struct {
    char *name;
    char *value;
} Header;

typedef struct {
    char method[8];
    char path[1024];
    char httpver[16];
    Header headers[MAX_HEADER_LINES];
    int header_count;
    char *body;
    size_t body_len;
} HttpRequest;

static void free_request(HttpRequest *req){
    for(int i=0;i<req->header_count;i++){ free(req->headers[i].name); free(req->headers[i].value);} 
    free(req->body);
}

static const char *get_header(HttpRequest *req, const char *name){
    for(int i=0;i<req->header_count;i++){
        if(strcasecmp(req->headers[i].name, name)==0) return req->headers[i].value;
    }
    return NULL;
}

static int parse_request(int client_fd, HttpRequest *out){
    memset(out,0,sizeof(*out));
    size_t cap = READ_BUF_INIT;
    size_t len = 0;
    char *buf = (char*)xmalloc(cap);
    ssize_t n;
    int header_done = 0;
    size_t body_start = 0;

    while(!header_done){
        if(len==cap){ cap*=2; buf=(char*)xrealloc(buf,cap);} 
        n = recv(client_fd, buf+len, cap-len, 0);
        if(n<=0){ free(buf); return -1; }
        len += (size_t)n;
        // search for CRLFCRLF
        for(size_t i=3;i<len;i++){
            if(buf[i-3]=='\r' && buf[i-2]=='\n' && buf[i-1]=='\r' && buf[i]=='\n'){
                header_done = 1; body_start = i+1; break;
            }
        }
    }

    // Parse start line
    size_t pos = 0;
    // find first line end
    size_t line_end = 0;
    for(size_t i=0;i<body_start;i++){
        if(buf[i]=='\r' && i+1<body_start && buf[i+1]=='\n'){ line_end = i; break; }
    }
    if(line_end==0){ free(buf); return -1; }
    char *line = (char*)xmalloc(line_end+1);
    memcpy(line, buf, line_end); line[line_end]='\0';
    // method path httpver
    if(sscanf(line, "%7s %1023s %15s", out->method, out->path, out->httpver) != 3){ free(line); free(buf); return -1; }
    free(line);

    // parse headers
    pos = line_end + 2; // skip CRLF
    out->header_count = 0;
    while(pos < body_start - 2){ // there is at least one CRLF before end
        size_t start = pos;
        size_t end = start;
        while(end+1 < body_start && !(buf[end]=='\r' && buf[end+1]=='\n')) end++;
        size_t hlen = end - start;
        if(hlen==0) break;
        if(out->header_count >= MAX_HEADER_LINES){ free(buf); return -1; }
        // split at ':'
        size_t colon = start;
        while(colon < end && buf[colon] != ':') colon++;
        if(colon>=end){ free(buf); return -1; }
        size_t name_len = colon-start;
        size_t value_len = end-(colon+1);
        char *hname = (char*)xmalloc(name_len+1);
        memcpy(hname, buf+start, name_len); hname[name_len]='\0';
        // value may have leading spaces
        size_t vstart = colon+1;
        while(vstart<end && (buf[vstart]==' ' || buf[vstart]=='\t')) vstart++;
        value_len = end - vstart;
        char *hval = (char*)xmalloc(value_len+1);
        memcpy(hval, buf+vstart, value_len); hval[value_len]='\0';
        out->headers[out->header_count].name = hname;
        out->headers[out->header_count].value = hval;
        out->header_count++;
        pos = end + 2; // next line start
    }

    // determine content-length
    size_t content_length = 0;
    const char *cl = get_header(out, "Content-Length");
    if(cl){ content_length = (size_t)strtoul(cl, NULL, 10); }

    size_t body_have = len - body_start;
    if(body_have < content_length){
        // need more
        size_t need = content_length - body_have;
        size_t newcap = len + need;
        if(newcap>cap){ cap = newcap; buf=(char*)xrealloc(buf,cap);} 
        size_t got = 0;
        while(got < need){
            n = recv(client_fd, buf+len, cap-len, 0);
            if(n<=0){ free(buf); return -1; }
            len += (size_t)n; got += (size_t)n;
        }
    }

    out->body_len = content_length;
    out->body = (char*)xmalloc(content_length+1);
    memcpy(out->body, buf + body_start, content_length);
    out->body[content_length] = '\0';

    free(buf);
    return 0;
}

static void send_response_headers(int fd, int status, const char *status_text, const char *extra_headers, size_t content_length, int include_json_ct){
    char head[1024];
    int n = snprintf(head, sizeof(head), "HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Length: %zu\r\n%s%s\r\n",
                     status, status_text, content_length, include_json_ct?"Content-Type: application/json\r\n":"", extra_headers?extra_headers:"");
    send(fd, head, (size_t)n, 0);
}

static void send_json(int fd, int status, const char *status_text, json_t *obj, const char *extra_headers){
    char *body = json_dumps(obj, JSON_COMPACT);
    size_t blen = strlen(body);
    send_response_headers(fd, status, status_text, extra_headers, blen, 1);
    if(blen>0) send(fd, body, blen, 0);
    free(body);
}

static void send_no_content(int fd){
    const char *head = "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    send(fd, head, strlen(head), 0);
}

static void send_error(int fd, int status, const char *message){
    json_t *err = json_pack("{s:s}", "error", message);
    send_json(fd, status, (status==400?"Bad Request":status==401?"Unauthorized":status==404?"Not Found":status==409?"Conflict":"Error"), err, NULL);
    json_decref(err);
}

// Cookie parsing
static int extract_session_id(HttpRequest *req, char *out_token, size_t out_sz){
    const char *ck = get_header(req, "Cookie");
    if(!ck) return 0;
    // parse pairs separated by ';'
    const char *p = ck;
    while(*p){
        while(*p==' ' || *p=='\t' || *p==';') p++;
        const char *name_start = p;
        while(*p && *p!='=' && *p!=';' ) p++;
        if(*p!='=') { while(*p && *p!=';') p++; continue; }
        const char *name_end = p;
        p++; // skip '='
        const char *val_start = p;
        while(*p && *p!=';') p++;
        const char *val_end = p;
        size_t nlen = (size_t)(name_end - name_start);
        size_t vlen = (size_t)(val_end - val_start);
        if(nlen==10 && strncasecmp(name_start, "session_id", 10)==0){
            size_t cpy = vlen < out_sz-1 ? vlen : out_sz-1;
            memcpy(out_token, val_start, cpy); out_token[cpy]='\0';
            return 1;
        }
        if(*p==';') p++;
    }
    return 0;
}

static Session* find_session(const char *token){
    for(size_t i=0;i<sessions_len;i++){ if(sessions[i].valid && strcmp(sessions[i].token, token)==0) return &sessions[i]; }
    return NULL;
}

static User* find_user_by_id(int id){
    for(size_t i=0;i<users_len;i++){ if(users[i].id==id) return &users[i]; }
    return NULL;
}

static User* find_user_by_username(const char *username){
    for(size_t i=0;i<users_len;i++){ if(strcmp(users[i].username, username)==0) return &users[i]; }
    return NULL;
}

static Todo* find_todo_by_id(int id){
    for(size_t i=0;i<todos_len;i++){ if(todos[i].alive && todos[i].id==id) return &todos[i]; }
    return NULL;
}

// Validation
static int validate_username(const char *username){
    if(!username) return 0;
    size_t len = strlen(username);
    if(len<3 || len>50) return 0;
    regex_t re; if(regcomp(&re, "^[A-Za-z0-9_]+$", REG_EXTENDED|REG_NOSUB)!=0) return 0;
    int ok = regexec(&re, username, 0, NULL, 0)==0;
    regfree(&re);
    return ok;
}

// Handlers

static void handle_register(int fd, HttpRequest *req){
    json_error_t jerr; json_t *root = json_loadb(req->body, req->body_len, 0, &jerr);
    if(!root || !json_is_object(root)){ if(root) json_decref(root); send_error(fd, 400, "Invalid JSON"); return; }
    json_t *juser = json_object_get(root, "username");
    json_t *jpass = json_object_get(root, "password");
    if(!juser || !json_is_string(juser) || !validate_username(json_string_value(juser))){ json_decref(root); send_error(fd, 400, "Invalid username"); return; }
    if(!jpass || !json_is_string(jpass) || strlen(json_string_value(jpass)) < 8){ json_decref(root); send_error(fd, 400, "Password too short"); return; }
    const char *uname = json_string_value(juser);
    if(find_user_by_username(uname)){ json_decref(root); send_error(fd, 409, "Username already exists"); return; }
    ensure_users_cap();
    User u; memset(&u,0,sizeof(u));
    u.id = next_user_id++;
    snprintf(u.username, sizeof(u.username), "%s", uname);
    snprintf(u.password, sizeof(u.password), "%s", json_string_value(jpass));
    users[users_len++] = u;
    json_t *resp = json_pack("{s:i,s:s}", "id", u.id, "username", u.username);
    send_json(fd, 201, "Created", resp, NULL);
    json_decref(resp);
    json_decref(root);
}

static void handle_login(int fd, HttpRequest *req){
    json_error_t jerr; json_t *root = json_loadb(req->body, req->body_len, 0, &jerr);
    if(!root || !json_is_object(root)){ if(root) json_decref(root); send_error(fd, 400, "Invalid JSON"); return; }
    json_t *juser = json_object_get(root, "username");
    json_t *jpass = json_object_get(root, "password");
    if(!juser || !json_is_string(juser) || !jpass || !json_is_string(jpass)){ json_decref(root); send_error(fd, 401, "Invalid credentials"); return; }
    const char *uname = json_string_value(juser);
    const char *pwd = json_string_value(jpass);
    User *u = find_user_by_username(uname);
    if(!u || strcmp(u->password, pwd)!=0){ json_decref(root); send_error(fd, 401, "Invalid credentials"); return; }
    // create session
    ensure_sessions_cap();
    Session s; memset(&s,0,sizeof(s));
    gen_token(s.token); s.user_id = u->id; s.valid = 1;
    sessions[sessions_len++] = s;
    char cookie_hdr[256];
    snprintf(cookie_hdr, sizeof(cookie_hdr), "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", s.token);
    json_t *resp = json_pack("{s:i,s:s}", "id", u->id, "username", u->username);
    send_json(fd, 200, "OK", resp, cookie_hdr);
    json_decref(resp);
    json_decref(root);
}

static int require_auth(int fd, HttpRequest *req, User **out_user, Session **out_sess){
    char token[256];
    if(!extract_session_id(req, token, sizeof(token))){ send_error(fd, 401, "Authentication required"); return 0; }
    Session *s = find_session(token);
    if(!s){ send_error(fd, 401, "Authentication required"); return 0; }
    User *u = find_user_by_id(s->user_id);
    if(!u){ send_error(fd, 401, "Authentication required"); return 0; }
    if(out_user) *out_user = u;
    if(out_sess) *out_sess = s;
    return 1;
}

static void handle_logout(int fd, HttpRequest *req){
    User *u=NULL; Session *s=NULL; if(!require_auth(fd, req, &u, &s)) return; (void)u;
    // invalidate session
    if(s){ s->valid = 0; s->token[0]='\0'; }
    json_t *resp = json_object();
    send_json(fd, 200, "OK", resp, NULL);
    json_decref(resp);
}

static void handle_me(int fd, HttpRequest *req){
    User *u=NULL; if(!require_auth(fd, req, &u, NULL)) return;
    json_t *resp = json_pack("{s:i,s:s}", "id", u->id, "username", u->username);
    send_json(fd, 200, "OK", resp, NULL);
    json_decref(resp);
}

static void handle_password(int fd, HttpRequest *req){
    User *u=NULL; if(!require_auth(fd, req, &u, NULL)) return;
    json_error_t jerr; json_t *root = json_loadb(req->body, req->body_len, 0, &jerr);
    if(!root || !json_is_object(root)){ if(root) json_decref(root); send_error(fd, 400, "Invalid JSON"); return; }
    json_t *jold = json_object_get(root, "old_password");
    json_t *jnew = json_object_get(root, "new_password");
    if(!jold || !json_is_string(jold) || !jnew || !json_is_string(jnew)){ json_decref(root); send_error(fd, 400, "Invalid JSON"); return; }
    const char *old = json_string_value(jold); const char *nw = json_string_value(jnew);
    if(strcmp(u->password, old)!=0){ json_decref(root); send_error(fd, 401, "Invalid credentials"); return; }
    if(strlen(nw) < 8){ json_decref(root); send_error(fd, 400, "Password too short"); return; }
    snprintf(u->password, sizeof(u->password), "%s", nw);
    json_t *resp = json_object();
    send_json(fd, 200, "OK", resp, NULL);
    json_decref(resp);
    json_decref(root);
}

static json_t* todo_to_json(const Todo *t){
    return json_pack("{s:i,s:s,s:s,s:b,s:s,s:s}",
        "id", t->id,
        "title", t->title?t->title: "",
        "description", t->description? t->description: "",
        "completed", t->completed?1:0,
        "created_at", t->created_at,
        "updated_at", t->updated_at
    );
}

static void handle_todos_list(int fd, HttpRequest *req){
    User *u=NULL; if(!require_auth(fd, req, &u, NULL)) return;
    size_t count=0; for(size_t i=0;i<todos_len;i++){ if(todos[i].alive && todos[i].user_id==u->id) count++; }
    Todo **arr = NULL; if(count>0) arr = (Todo**)xmalloc(sizeof(Todo*)*count); size_t idx=0; 
    for(size_t i=0;i<todos_len;i++){ if(todos[i].alive && todos[i].user_id==u->id) arr[idx++]=&todos[i]; }
    for(size_t i=1;i<count;i++){
        Todo *key = arr[i]; size_t j=i; while(j>0 && arr[j-1]->id > key->id){ arr[j]=arr[j-1]; j--; } arr[j]=key; 
    }
    json_t *list = json_array();
    for(size_t i=0;i<count;i++){ json_t *jt = todo_to_json(arr[i]); json_array_append_new(list, jt);} 
    if(arr) free(arr);
    send_json(fd, 200, "OK", list, NULL);
    json_decref(list);
}

static void handle_todos_create(int fd, HttpRequest *req){
    User *u=NULL; if(!require_auth(fd, req, &u, NULL)) return;
    json_error_t jerr; json_t *root = json_loadb(req->body, req->body_len, 0, &jerr);
    if(!root || !json_is_object(root)){ if(root) json_decref(root); send_error(fd, 400, "Invalid JSON"); return; }
    json_t *jtitle = json_object_get(root, "title");
    if(!jtitle || !json_is_string(jtitle) || strlen(json_string_value(jtitle))==0){ json_decref(root); send_error(fd, 400, "Title is required"); return; }
    json_t *jdesc = json_object_get(root, "description");
    const char *desc = "";
    if(jdesc){ if(!json_is_string(jdesc)){ json_decref(root); send_error(fd, 400, "Invalid JSON"); return; } desc = json_string_value(jdesc); }
    ensure_todos_cap();
    Todo t; memset(&t,0,sizeof(t));
    t.id = next_todo_id++;
    t.user_id = u->id;
    t.title = xstrdup(json_string_value(jtitle));
    t.description = xstrdup(desc);
    t.completed = 0;
    http_time_now_iso(t.created_at);
    snprintf(t.updated_at, sizeof(t.updated_at), "%s", t.created_at);
    t.alive = 1;
    todos[todos_len++] = t;
    json_t *resp = todo_to_json(&todos[todos_len-1]);
    send_json(fd, 201, "Created", resp, NULL);
    json_decref(resp);
    json_decref(root);
}

static int parse_id_from_path(const char *path){
    int id = -1; char extra;
    if(sscanf(path, "/todos/%d%c", &id, &extra) == 1){
        if(id > 0) return id;
    }
    return -1;
}

static void handle_todos_get(int fd, HttpRequest *req, int id){
    User *u=NULL; if(!require_auth(fd, req, &u, NULL)) return;
    Todo *t = find_todo_by_id(id);
    if(!t || t->user_id != u->id){ send_error(fd, 404, "Todo not found"); return; }
    json_t *resp = todo_to_json(t);
    send_json(fd, 200, "OK", resp, NULL);
    json_decref(resp);
}

static void handle_todos_update(int fd, HttpRequest *req, int id){
    User *u=NULL; if(!require_auth(fd, req, &u, NULL)) return;
    Todo *t = find_todo_by_id(id);
    if(!t || t->user_id != u->id){ send_error(fd, 404, "Todo not found"); return; }
    json_error_t jerr; json_t *root = json_loadb(req->body, req->body_len, 0, &jerr);
    if(!root || !json_is_object(root)){ if(root) json_decref(root); send_error(fd, 400, "Invalid JSON"); return; }
    json_t *jtitle = json_object_get(root, "title");
    if(jtitle){ if(!json_is_string(jtitle)){ json_decref(root); send_error(fd, 400, "Invalid JSON"); return; } const char *v = json_string_value(jtitle); if(strlen(v)==0){ json_decref(root); send_error(fd, 400, "Title is required"); return; } free(t->title); t->title = xstrdup(v);} 
    json_t *jdesc = json_object_get(root, "description");
    if(jdesc){ if(!json_is_string(jdesc)){ json_decref(root); send_error(fd, 400, "Invalid JSON"); return; } free(t->description); t->description = xstrdup(json_string_value(jdesc)); }
    json_t *jcomp = json_object_get(root, "completed");
    if(jcomp){ if(!json_is_boolean(jcomp)){ json_decref(root); send_error(fd, 400, "Invalid JSON"); return; } t->completed = json_is_true(jcomp)?1:0; }
    http_time_now_iso(t->updated_at);
    json_t *resp = todo_to_json(t);
    send_json(fd, 200, "OK", resp, NULL);
    json_decref(resp);
    json_decref(root);
}

static void handle_todos_delete(int fd, HttpRequest *req, int id){
    User *u=NULL; if(!require_auth(fd, req, &u, NULL)) return;
    Todo *t = find_todo_by_id(id);
    if(!t || t->user_id != u->id){ send_error(fd, 404, "Todo not found"); return; }
    t->alive = 0;
    if(t->title){ free(t->title); t->title=NULL; }
    if(t->description){ free(t->description); t->description=NULL; }
    send_no_content(fd);
}

static void route_request(int fd, HttpRequest *req){
    char path_only[1024]; snprintf(path_only, sizeof(path_only), "%s", req->path);
    char *q = strchr(path_only, '?'); if(q) *q='\0';

    if(strcmp(req->method, "POST")==0 && strcmp(path_only, "/register")==0){ handle_register(fd, req); return; }
    if(strcmp(req->method, "POST")==0 && strcmp(path_only, "/login")==0){ handle_login(fd, req); return; }
    if(strcmp(req->method, "POST")==0 && strcmp(path_only, "/logout")==0){ handle_logout(fd, req); return; }
    if(strcmp(req->method, "GET")==0 && strcmp(path_only, "/me")==0){ handle_me(fd, req); return; }
    if(strcmp(req->method, "PUT")==0 && strcmp(path_only, "/password")==0){ handle_password(fd, req); return; }

    if(strcmp(req->method, "GET")==0 && strcmp(path_only, "/todos")==0){ handle_todos_list(fd, req); return; }
    if(strcmp(req->method, "POST")==0 && strcmp(path_only, "/todos")==0){ handle_todos_create(fd, req); return; }

    if(strncmp(path_only, "/todos/", 8)==0){
        int id = parse_id_from_path(path_only);
        if(id<=0){
            fprintf(stderr, "Bad todo path: '%s'\n", path_only);
            send_error(fd, 404, "Not Found"); return; }
        if(strcmp(req->method, "GET")==0){ handle_todos_get(fd, req, id); return; }
        if(strcmp(req->method, "PUT")==0){ handle_todos_update(fd, req, id); return; }
        if(strcmp(req->method, "DELETE")==0){ handle_todos_delete(fd, req, id); return; }
    }

    send_error(fd, 404, "Not Found");
}

int main(int argc, char **argv){
    int port = 8000;
    for(int i=1;i<argc;i++){
        if(strcmp(argv[i], "--port")==0 && i+1<argc){ port = atoi(argv[++i]); }
    }
    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);

    int s = socket(AF_INET, SOCK_STREAM, 0); if(s<0) die("socket");
    int opt=1; if(setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))<0) die("setsockopt");
    struct sockaddr_in addr; memset(&addr,0,sizeof(addr)); addr.sin_family = AF_INET; addr.sin_addr.s_addr = inet_addr("0.0.0.0"); addr.sin_port = htons((uint16_t)port);
    if(bind(s, (struct sockaddr*)&addr, sizeof(addr))<0) die("bind");
    if(listen(s, BACKLOG)<0) die("listen");
    fprintf(stderr, "Server listening on 0.0.0.0:%d\n", port);

    while(running){
        struct sockaddr_in cli; socklen_t clilen=sizeof(cli);
        int c = accept(s, (struct sockaddr*)&cli, &clilen);
        if(c<0){ if(errno==EINTR) continue; die("accept"); }
        HttpRequest req; memset(&req,0,sizeof(req));
        if(parse_request(c, &req)==0){
            route_request(c, &req);
            free_request(&req);
        } else {
            send_error(c, 400, "Bad Request");
        }
        close(c);
    }

    close(s);
    return 0;
}

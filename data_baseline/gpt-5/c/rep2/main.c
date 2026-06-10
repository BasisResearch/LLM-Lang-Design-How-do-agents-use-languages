#include <microhttpd.h>
#include <jansson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <ctype.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>

#define MAX_BODY_SIZE 1048576

typedef struct User {
    int id;
    char *username;
    char *password; // plain for simplicity
} User;

typedef struct Session {
    char *token; // opaque hex string
    int user_id;
} Session;

typedef struct Todo {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0 or 1
    char created_at[21]; // YYYY-MM-DDTHH:MM:SSZ -> 20 + null
    char updated_at[21];
} Todo;

typedef struct {
    char *method;
    char *url;
    char *body;
    size_t body_size;
    size_t body_capacity;
} RequestContext;

// Global in-memory storage
static User *users = NULL; size_t users_count = 0; size_t users_cap = 0; int next_user_id = 1;
static Session *sessions = NULL; size_t sessions_count = 0; size_t sessions_cap = 0;
static Todo *todos = NULL; size_t todos_count = 0; size_t todos_cap = 0; int next_todo_id = 1;

static pthread_mutex_t db_mutex = PTHREAD_MUTEX_INITIALIZER;

static void *xmalloc(size_t n) { void *p = malloc(n); if(!p){fprintf(stderr,"OOM\n"); exit(1);} return p; }
static char *xstrdup(const char *s) { if(!s) return NULL; size_t n = strlen(s); char *d = xmalloc(n+1); memcpy(d,s,n+1); return d; }

static void iso8601_now(char out[21]) {
    time_t t = time(NULL);
    struct tm g;
    gmtime_r(&t, &g);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &g);
}

static int validate_username(const char *u) {
    if(!u) return 0;
    size_t len = strlen(u);
    if(len < 3 || len > 50) return 0;
    for(size_t i=0;i<len;i++) {
        char c = u[i];
        if(!(isalnum((unsigned char)c) || c=='_')) return 0;
    }
    return 1;
}

static int validate_password(const char *p) {
    if(!p) return 0; 
    return strlen(p) >= 8;
}

static User* find_user_by_username(const char *username) {
    for(size_t i=0;i<users_count;i++) {
        if(strcmp(users[i].username, username)==0) return &users[i];
    }
    return NULL;
}

static User* find_user_by_id(int id) {
    for(size_t i=0;i<users_count;i++) if(users[i].id==id) return &users[i];
    return NULL;
}

static Session* find_session(const char *token) {
    if(!token) return NULL;
    for(size_t i=0;i<sessions_count;i++) if(strcmp(sessions[i].token, token)==0) return &sessions[i];
    return NULL;
}

static void remove_session_token(const char *token) {
    if(!token) return;
    for(size_t i=0;i<sessions_count;i++) {
        if(strcmp(sessions[i].token, token)==0) {
            free(sessions[i].token);
            // move last into i
            if(i != sessions_count-1) sessions[i] = sessions[sessions_count-1];
            sessions_count--;
            return;
        }
    }
}

static Todo* find_todo_by_id(int id) {
    for(size_t i=0;i<todos_count;i++) if(todos[i].id==id) return &todos[i];
    return NULL;
}

static void ensure_users_cap() {
    if(users_count >= users_cap) {
        users_cap = users_cap? users_cap*2 : 16;
        users = realloc(users, users_cap * sizeof(User));
        if(!users){fprintf(stderr,"OOM users\n"); exit(1);}    
    }
}

static void ensure_sessions_cap() {
    if(sessions_count >= sessions_cap) {
        sessions_cap = sessions_cap? sessions_cap*2 : 16;
        sessions = realloc(sessions, sessions_cap * sizeof(Session));
        if(!sessions){fprintf(stderr,"OOM sessions\n"); exit(1);}    
    }
}

static void ensure_todos_cap() {
    if(todos_count >= todos_cap) {
        todos_cap = todos_cap? todos_cap*2 : 32;
        todos = realloc(todos, todos_cap * sizeof(Todo));
        if(!todos){fprintf(stderr,"OOM todos\n"); exit(1);}    
    }
}

static void json_response_headers(struct MHD_Response *response) {
    MHD_add_response_header(response, "Content-Type", "application/json");
}

static enum MHD_Result send_json_response(struct MHD_Connection *conn, unsigned int status, const char *json_str) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(json_str?strlen(json_str):0, (void*)(json_str?json_str:""), MHD_RESPMEM_MUST_COPY);
    if(!resp) return MHD_NO;
    json_response_headers(resp);
    enum MHD_Result ret = MHD_queue_response(conn, status, resp);
    MHD_destroy_response(resp);
    return ret;
}

static enum MHD_Result send_json_error(struct MHD_Connection *conn, unsigned int status, const char *msg) {
    json_t *o = json_object();
    json_object_set_new(o, "error", json_string(msg));
    char *s = json_dumps(o, JSON_COMPACT);
    json_decref(o);
    enum MHD_Result ret = send_json_response(conn, status, s);
    free(s);
    return ret;
}

static enum MHD_Result send_no_content(struct MHD_Connection *conn) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
    if(!resp) return MHD_NO;
    enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_NO_CONTENT, resp);
    MHD_destroy_response(resp);
    return ret;
}

static void gen_token(char out[65]) {
    // 32 bytes -> 64 hex chars
    unsigned char buf[32];
    FILE *f = fopen("/dev/urandom", "rb");
    if(f) {
        if (fread(buf,1,32,f) != 32) {
            // fallback
            for(int i=0;i<32;i++) buf[i] = (unsigned char)rand();
        }
        fclose(f);
    } else {
        for(int i=0;i<32;i++) buf[i] = (unsigned char)rand();
    }
    static const char *hex = "0123456789abcdef";
    for(int i=0;i<32;i++) { out[2*i] = hex[(buf[i]>>4)&0xF]; out[2*i+1] = hex[buf[i]&0xF]; }
    out[64]='\0';
}

static int get_authenticated_user(struct MHD_Connection *conn, User **out_user, Session **out_sess) {
    const char *cookie = MHD_lookup_connection_value(conn, MHD_COOKIE_KIND, "session_id");
    if(!cookie) return 0;
    pthread_mutex_lock(&db_mutex);
    Session *s = find_session(cookie);
    if(!s) {
        pthread_mutex_unlock(&db_mutex);
        return 0;
    }
    User *u = find_user_by_id(s->user_id);
    if(!u) {
        pthread_mutex_unlock(&db_mutex);
        return 0;
    }
    if(out_user) *out_user = u;
    if(out_sess) *out_sess = s;
    pthread_mutex_unlock(&db_mutex);
    return 1;
}

static int require_auth(struct MHD_Connection *conn, User **u) {
    User *user = NULL;
    if(!get_authenticated_user(conn, &user, NULL)) {
        return send_json_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    }
    if(u) *u = user;
    return -1; // signal OK but response not sent
}

static enum MHD_Result handle_register(struct MHD_Connection *conn, const char *body) {
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if(!root || !json_is_object(root)) { if(root) json_decref(root); return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    json_t *juser = json_object_get(root, "username");
    json_t *jpass = json_object_get(root, "password");
    if(!json_is_string(juser) || !validate_username(json_string_value(juser))) {
        json_decref(root);
        return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }
    if(!json_is_string(jpass) || !validate_password(json_string_value(jpass))) {
        json_decref(root);
        return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    const char *username = json_string_value(juser);
    const char *password = json_string_value(jpass);

    pthread_mutex_lock(&db_mutex);
    if(find_user_by_username(username)) {
        pthread_mutex_unlock(&db_mutex);
        json_decref(root);
        return send_json_error(conn, MHD_HTTP_CONFLICT, "Username already exists");
    }
    ensure_users_cap();
    User u; u.id = next_user_id++; u.username = xstrdup(username); u.password = xstrdup(password);
    users[users_count++] = u;
    pthread_mutex_unlock(&db_mutex);

    json_t *resp = json_object();
    json_object_set_new(resp, "id", json_integer(u.id));
    json_object_set_new(resp, "username", json_string(u.username));
    char *s = json_dumps(resp, JSON_COMPACT);
    json_decref(resp);
    json_decref(root);
    struct MHD_Response *http_resp = MHD_create_response_from_buffer(strlen(s), s, MHD_RESPMEM_MUST_FREE);
    json_response_headers(http_resp);
    enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_CREATED, http_resp);
    MHD_destroy_response(http_resp);
    return ret;
}

static enum MHD_Result handle_login(struct MHD_Connection *conn, const char *body) {
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if(!root || !json_is_object(root)) { if(root) json_decref(root); return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    json_t *juser = json_object_get(root, "username");
    json_t *jpass = json_object_get(root, "password");
    if(!json_is_string(juser) || !json_is_string(jpass)) { json_decref(root); return send_json_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); }

    const char *username = json_string_value(juser);
    const char *password = json_string_value(jpass);

    pthread_mutex_lock(&db_mutex);
    User *u = find_user_by_username(username);
    if(!u || strcmp(u->password, password)!=0) {
        pthread_mutex_unlock(&db_mutex);
        json_decref(root);
        return send_json_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    ensure_sessions_cap();
    char tok[65]; gen_token(tok);
    Session s; s.token = xstrdup(tok); s.user_id = u->id;
    sessions[sessions_count++] = s;
    pthread_mutex_unlock(&db_mutex);

    json_t *resp = json_object();
    json_object_set_new(resp, "id", json_integer(u->id));
    json_object_set_new(resp, "username", json_string(u->username));
    char *jsons = json_dumps(resp, JSON_COMPACT);
    json_decref(resp);

    struct MHD_Response *http_resp = MHD_create_response_from_buffer(strlen(jsons), jsons, MHD_RESPMEM_MUST_FREE);
    json_response_headers(http_resp);
    char cookiehdr[128];
    snprintf(cookiehdr, sizeof(cookiehdr), "session_id=%s; Path=/; HttpOnly", tok);
    MHD_add_response_header(http_resp, "Set-Cookie", cookiehdr);
    enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_OK, http_resp);
    MHD_destroy_response(http_resp);
    json_decref(root);
    return ret;
}

static enum MHD_Result handle_logout(struct MHD_Connection *conn) {
    const char *token = MHD_lookup_connection_value(conn, MHD_COOKIE_KIND, "session_id");
    if(!token) return send_json_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    pthread_mutex_lock(&db_mutex);
    Session *s = find_session(token);
    if(!s) { pthread_mutex_unlock(&db_mutex); return send_json_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); }
    remove_session_token(token);
    pthread_mutex_unlock(&db_mutex);
    return send_json_response(conn, MHD_HTTP_OK, "{}");
}

static enum MHD_Result handle_me(struct MHD_Connection *conn) {
    User *u=NULL; int r = require_auth(conn, &u); if(r!=-1) return r;
    json_t *resp = json_object(); json_object_set_new(resp, "id", json_integer(u->id)); json_object_set_new(resp, "username", json_string(u->username));
    char *s = json_dumps(resp, JSON_COMPACT); json_decref(resp);
    enum MHD_Result ret = send_json_response(conn, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_password(struct MHD_Connection *conn, const char *body) {
    User *u=NULL; int r = require_auth(conn, &u); if(r!=-1) return r;
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if(!root || !json_is_object(root)) { if(root) json_decref(root); return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    const char *oldp = NULL, *newp = NULL;
    json_t *jo = json_object_get(root, "old_password"); if(json_is_string(jo)) oldp = json_string_value(jo);
    json_t *jn = json_object_get(root, "new_password"); if(json_is_string(jn)) newp = json_string_value(jn);
    if(!oldp || strcmp(oldp, u->password)!=0) { json_decref(root); return send_json_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); }
    if(!validate_password(newp)) { json_decref(root); return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short"); }
    pthread_mutex_lock(&db_mutex);
    free(u->password); u->password = xstrdup(newp);
    pthread_mutex_unlock(&db_mutex);
    json_decref(root);
    return send_json_response(conn, MHD_HTTP_OK, "{}");
}

static json_t* todo_to_json(const Todo *t) {
    json_t *o = json_object();
    json_object_set_new(o, "id", json_integer(t->id));
    json_object_set_new(o, "title", json_string(t->title));
    json_object_set_new(o, "description", json_string(t->description?t->description:"") );
    json_object_set_new(o, "completed", json_boolean(t->completed));
    json_object_set_new(o, "created_at", json_string(t->created_at));
    json_object_set_new(o, "updated_at", json_string(t->updated_at));
    return o;
}

static enum MHD_Result handle_todos_get(struct MHD_Connection *conn) {
    User *u=NULL; int r = require_auth(conn, &u); if(r!=-1) return r;
    pthread_mutex_lock(&db_mutex);
    json_t *arr = json_array();
    // order by id ascending
    for(int id=1; id<next_todo_id; id++) {
        Todo *t = find_todo_by_id(id);
        if(t && t->user_id == u->id) {
            json_t *o = todo_to_json(t);
            json_array_append_new(arr, o);
        }
    }
    char *s = json_dumps(arr, JSON_COMPACT);
    json_decref(arr);
    pthread_mutex_unlock(&db_mutex);
    enum MHD_Result ret = send_json_response(conn, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_todos_post(struct MHD_Connection *conn, const char *body) {
    User *u=NULL; int r = require_auth(conn, &u); if(r!=-1) return r;
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if(!root || !json_is_object(root)) { if(root) json_decref(root); return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    json_t *jtitle = json_object_get(root, "title");
    json_t *jdesc = json_object_get(root, "description");
    if(!json_is_string(jtitle) || strlen(json_string_value(jtitle))==0) { json_decref(root); return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); }
    const char *title = json_string_value(jtitle);
    const char *desc = (json_is_string(jdesc) ? json_string_value(jdesc) : "");

    pthread_mutex_lock(&db_mutex);
    ensure_todos_cap();
    Todo t; t.id = next_todo_id++; t.user_id = u->id; t.title = xstrdup(title); t.description = xstrdup(desc); t.completed = 0; iso8601_now(t.created_at); memcpy(t.updated_at, t.created_at, 21);
    todos[todos_count++] = t;
    json_t *resp = todo_to_json(&t);
    char *s = json_dumps(resp, JSON_COMPACT);
    json_decref(resp);
    pthread_mutex_unlock(&db_mutex);

    struct MHD_Response *http_resp = MHD_create_response_from_buffer(strlen(s), s, MHD_RESPMEM_MUST_FREE);
    json_response_headers(http_resp);
    enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_CREATED, http_resp);
    MHD_destroy_response(http_resp);
    json_decref(root);
    return ret;
}

static int parse_id_from_path(const char *path) {
    // expects /todos/<id>
    const char *prefix = "/todos/"; size_t prelen = 7; // strlen("/todos/")
    if(strncmp(path, prefix, prelen)!=0) return -1;
    const char *p = path + prelen;
    if(!*p) return -1;
    char *end=NULL; long v = strtol(p, &end, 10);
    if(end==p || *end!='\0' || v<=0 || v>2147483647L) return -1;
    return (int)v;
}

static enum MHD_Result handle_todo_get(struct MHD_Connection *conn, const char *path) {
    User *u=NULL; int r = require_auth(conn, &u); if(r!=-1) return r;
    int id = parse_id_from_path(path); if(id<0) return send_json_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    pthread_mutex_lock(&db_mutex);
    Todo *t = find_todo_by_id(id);
    if(!t || t->user_id != u->id) { pthread_mutex_unlock(&db_mutex); return send_json_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); }
    json_t *o = todo_to_json(t);
    char *s = json_dumps(o, JSON_COMPACT);
    json_decref(o);
    pthread_mutex_unlock(&db_mutex);
    enum MHD_Result ret = send_json_response(conn, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_todo_put(struct MHD_Connection *conn, const char *path, const char *body) {
    User *u=NULL; int r = require_auth(conn, &u); if(r!=-1) return r;
    int id = parse_id_from_path(path); if(id<0) return send_json_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if(!root || !json_is_object(root)) { if(root) json_decref(root); return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }

    pthread_mutex_lock(&db_mutex);
    Todo *t = find_todo_by_id(id);
    if(!t || t->user_id != u->id) { pthread_mutex_unlock(&db_mutex); json_decref(root); return send_json_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); }

    json_t *jtitle = json_object_get(root, "title");
    if(jtitle) {
        if(!json_is_string(jtitle) || strlen(json_string_value(jtitle))==0) { pthread_mutex_unlock(&db_mutex); json_decref(root); return send_json_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); }
        free(t->title); t->title = xstrdup(json_string_value(jtitle));
    }
    json_t *jdesc = json_object_get(root, "description");
    if(jdesc) {
        if(json_is_string(jdesc)) { free(t->description); t->description = xstrdup(json_string_value(jdesc)); }
        else if(json_is_null(jdesc)) { free(t->description); t->description = xstrdup(""); }
        else { /* ignore invalid type */ }
    }
    json_t *jcomp = json_object_get(root, "completed");
    if(jcomp) {
        if(json_is_boolean(jcomp)) t->completed = json_boolean_value(jcomp);
    }
    iso8601_now(t->updated_at);

    json_t *resp = todo_to_json(t);
    char *s = json_dumps(resp, JSON_COMPACT);
    json_decref(resp);
    pthread_mutex_unlock(&db_mutex);

    enum MHD_Result ret = send_json_response(conn, MHD_HTTP_OK, s);
    free(s);
    json_decref(root);
    return ret;
}

static enum MHD_Result handle_todo_delete(struct MHD_Connection *conn, const char *path) {
    User *u=NULL; int r = require_auth(conn, &u); if(r!=-1) return r;
    int id = parse_id_from_path(path); if(id<0) return send_json_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");

    pthread_mutex_lock(&db_mutex);
    for(size_t i=0;i<todos_count;i++) {
        if(todos[i].id == id) {
            if(todos[i].user_id != u->id) { pthread_mutex_unlock(&db_mutex); return send_json_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); }
            // free fields
            free(todos[i].title); free(todos[i].description);
            if(i != todos_count-1) todos[i] = todos[todos_count-1];
            todos_count--;
            pthread_mutex_unlock(&db_mutex);
            return send_no_content(conn);
        }
    }
    pthread_mutex_unlock(&db_mutex);
    return send_json_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
}

static enum MHD_Result route_request(struct MHD_Connection *conn, const char *method, const char *url, const char *body) {
    fprintf(stderr, "[%s] %s\n", method, url);
    if(strcmp(method, "POST")==0 && strcmp(url, "/register")==0) {
        return handle_register(conn, body);
    }
    if(strcmp(method, "POST")==0 && strcmp(url, "/login")==0) {
        return handle_login(conn, body);
    }
    if(strcmp(method, "POST")==0 && strcmp(url, "/logout")==0) {
        return handle_logout(conn);
    }
    if(strcmp(method, "GET")==0 && strcmp(url, "/me")==0) {
        return handle_me(conn);
    }
    if(strcmp(method, "PUT")==0 && strcmp(url, "/password")==0) {
        return handle_password(conn, body);
    }
    if(strcmp(method, "GET")==0 && strcmp(url, "/todos")==0) {
        return handle_todos_get(conn);
    }
    if(strcmp(method, "POST")==0 && strcmp(url, "/todos")==0) {
        return handle_todos_post(conn, body);
    }
    if(strncmp(url, "/todos/", 7)==0) {
        if(strcmp(method, "GET")==0) return handle_todo_get(conn, url);
        if(strcmp(method, "PUT")==0) return handle_todo_put(conn, url, body);
        if(strcmp(method, "DELETE")==0) return handle_todo_delete(conn, url);
    }
    return send_json_error(conn, MHD_HTTP_NOT_FOUND, "Not found");
}

static enum MHD_Result ahc_handler(void *cls, struct MHD_Connection *connection, const char *url,
                       const char *method, const char *version, const char *upload_data,
                       size_t *upload_data_size, void **con_cls)
{
    (void)cls; (void)version;
    RequestContext *ctx = *con_cls;
    if(!ctx) {
        ctx = (RequestContext*)calloc(1, sizeof(RequestContext));
        ctx->method = xstrdup(method);
        ctx->url = xstrdup(url);
        ctx->body_capacity = 4096; ctx->body = (char*)malloc(ctx->body_capacity); ctx->body[0]='\0'; ctx->body_size=0;
        *con_cls = ctx;
        return MHD_YES; // continue
    }

    if(*upload_data_size != 0) {
        if(ctx->body_size + *upload_data_size + 1 > MAX_BODY_SIZE) {
            // too big
            *upload_data_size = 0;
            return send_json_error(connection, MHD_HTTP_REQUEST_ENTITY_TOO_LARGE, "Request body too large");
        }
        if(ctx->body_size + *upload_data_size + 1 > ctx->body_capacity) {
            while(ctx->body_size + *upload_data_size + 1 > ctx->body_capacity) ctx->body_capacity *= 2;
            ctx->body = (char*)realloc(ctx->body, ctx->body_capacity);
            if(!ctx->body){fprintf(stderr,"OOM body\n"); exit(1);}            
        }
        memcpy(ctx->body + ctx->body_size, upload_data, *upload_data_size);
        ctx->body_size += *upload_data_size;
        ctx->body[ctx->body_size] = '\0';
        *upload_data_size = 0;
        return MHD_YES;
    } else {
        enum MHD_Result ret = route_request(connection, ctx->method, ctx->url, ctx->body);
        free(ctx->method); free(ctx->url); free(ctx->body); free(ctx);
        *con_cls = NULL;
        return ret;
    }
}

static void print_usage(const char *prog) {
    fprintf(stderr, "Usage: %s --port PORT\n", prog);
}

int main(int argc, char *argv[]) {
    int port = 0;
    for(int i=1;i<argc;i++) {
        if(strcmp(argv[i], "--port")==0 && i+1<argc) {
            port = atoi(argv[++i]);
        } else if(strcmp(argv[i], "-p")==0 && i+1<argc) {
            port = atoi(argv[++i]);
        } else {
            print_usage(argv[0]);
            return 1;
        }
    }
    if(port<=0 || port>65535) { print_usage(argv[0]); return 1; }

    struct MHD_Daemon *d = MHD_start_daemon(MHD_USE_SELECT_INTERNALLY, (uint16_t)port, NULL, NULL, &ahc_handler, NULL, MHD_OPTION_END);
    if(!d) {
        fprintf(stderr, "Failed to start server on port %d\n", port);
        return 1;
    }
    printf("Server listening on 0.0.0.0:%d\n", port);
    fflush(stdout);
    // run forever
    while(1) pause();
    MHD_stop_daemon(d);
    return 0;
}

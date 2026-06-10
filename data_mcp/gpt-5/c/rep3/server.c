#include <microhttpd.h>
#include <jansson.h>
#include <uuid/uuid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <ctype.h>
#include <stdarg.h>
#include <errno.h>
#include <arpa/inet.h>
#include <netinet/in.h>

#define MAX_BODY_SIZE (10 * 1024 * 1024)

typedef struct {
    int id;
    char *username;
    char *password; // plaintext for simplicity
} User;

typedef struct {
    char *token; // session_id
    int user_id;
} Session;

typedef struct {
    int id;
    int user_id; // owner
    char *title;
    char *description;
    int completed; // bool
    char created_at[21]; // YYYY-MM-DDTHH:MM:SSZ -> 20 + null
    char updated_at[21];
} Todo;

// In-memory storage
static User *users = NULL; static size_t users_len = 0; static size_t users_cap = 0; static int next_user_id = 1;
static Session *sessions = NULL; static size_t sessions_len = 0; static size_t sessions_cap = 0;
static Todo *todos = NULL; static size_t todos_len = 0; static size_t todos_cap = 0; static int next_todo_id = 1;

// Utility dynamic array helpers
static void *xrealloc(void *p, size_t n) { void *q = realloc(p, n); if (!q && n) { perror("realloc"); exit(1);} return q; }
static char *xstrdup(const char *s) { if(!s) return NULL; size_t n=strlen(s)+1; char *p=malloc(n); if(!p){perror("malloc"); exit(1);} memcpy(p,s,n); return p; }

static void users_push(User u){ if(users_len==users_cap){ users_cap = users_cap? users_cap*2 : 8; users = xrealloc(users, users_cap*sizeof(User)); } users[users_len++] = u; }
static void sessions_push(Session s){ if(sessions_len==sessions_cap){ sessions_cap = sessions_cap? sessions_cap*2 : 8; sessions = xrealloc(sessions, sessions_cap*sizeof(Session)); } sessions[sessions_len++] = s; }
static void todos_push(Todo t){ if(todos_len==todos_cap){ todos_cap = todos_cap? todos_cap*2 : 16; todos = xrealloc(todos, todos_cap*sizeof(Todo)); } todos[todos_len++] = t; }

static void now_iso8601_utc(char out[21]){
    time_t t=time(NULL); struct tm g; gmtime_r(&t, &g); strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &g);
}

static int is_valid_username(const char *u){ if(!u) return 0; size_t n=strlen(u); if(n<3||n>50) return 0; for(size_t i=0;i<n;i++){ if(!(isalnum((unsigned char)u[i]) || u[i]=='_')) return 0; } return 1; }

static int username_exists(const char *u){ for(size_t i=0;i<users_len;i++){ if(strcmp(users[i].username,u)==0) return 1; } return 0; }

static User* find_user_by_username(const char *u){ for(size_t i=0;i<users_len;i++){ if(strcmp(users[i].username,u)==0) return &users[i]; } return NULL; }

static User* find_user_by_id(int id){ for(size_t i=0;i<users_len;i++){ if(users[i].id==id) return &users[i]; } return NULL; }

static Session* find_session_token(const char *tok){ if(!tok) return NULL; for(size_t i=0;i<sessions_len;i++){ if(strcmp(sessions[i].token, tok)==0) return &sessions[i]; } return NULL; }

static Todo* find_todo_by_id(int id){ for(size_t i=0;i<todos_len;i++){ if(todos[i].id==id) return &todos[i]; } return NULL; }

static void remove_session(Session *s){ if(!s) return; size_t idx = (size_t)(s - sessions); if(idx < sessions_len){ free(sessions[idx].token); sessions[idx] = sessions[sessions_len-1]; sessions_len--; }
}

static void remove_todo(Todo *t){ if(!t) return; size_t idx = (size_t)(t - todos); if(idx < todos_len){ free(todos[idx].title); free(todos[idx].description); todos[idx] = todos[todos_len-1]; todos_len--; }
}

// Request context for body accumulation
struct ReqCtx { char *body; size_t size; };

static enum MHD_Result add_header(struct MHD_Response *resp, const char *k, const char *v){ return MHD_add_response_header(resp, k, v); }

static enum MHD_Result respond_json(struct MHD_Connection *conn, unsigned int status, json_t *obj){ char *data = NULL; size_t len = 0; if(obj){ data = json_dumps(obj, JSON_COMPACT); if(!data) return MHD_NO; len = strlen(data); }
    struct MHD_Response *resp = MHD_create_response_from_buffer(len, data? (void*)data : NULL, MHD_RESPMEM_MUST_FREE);
    if(!resp){ if(data) free(data); return MHD_NO; }
    add_header(resp, "Content-Type", "application/json");
    // Prevent caching
    add_header(resp, "Cache-Control", "no-store");
    enum MHD_Result ret = MHD_queue_response(conn, status, resp);
    MHD_destroy_response(resp);
    return ret;
}

static enum MHD_Result respond_error(struct MHD_Connection *conn, unsigned int status, const char *fmt, ...){ char msg[256]; va_list ap; va_start(ap, fmt); vsnprintf(msg, sizeof(msg), fmt, ap); va_end(ap);
    json_t *o = json_object(); json_object_set_new(o, "error", json_string(msg)); enum MHD_Result r = respond_json(conn, status, o); json_decref(o); return r; }

static const char* get_cookie_session_id(struct MHD_Connection *conn){ const char *cookie = MHD_lookup_connection_value(conn, MHD_HEADER_KIND, "Cookie"); if(!cookie) return NULL; // parse cookies
    const char *p = cookie; while(*p){ while(*p==' '||*p==';') p++; if(!*p) break; const char *k = p; while(*p && *p!='=' && *p!=';' ) p++; size_t klen = p-k; if(*p!='='){ while(*p && *p!=';') p++; continue; } p++; const char *v = p; while(*p && *p!=';') p++; size_t vlen = p-v; if(klen==10 && strncasecmp(k, "session_id", 10)==0){ static __thread char token[128]; size_t n = vlen<sizeof(token)-1? vlen : sizeof(token)-1; memcpy(token, v, n); token[n]='\0'; return token; } }
    return NULL; }

static int require_auth(struct MHD_Connection *conn, User **out_user, Session **out_sess){ const char *tok = get_cookie_session_id(conn); if(!tok){ return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); }
    Session *s = find_session_token(tok); if(!s){ return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); }
    User *u = find_user_by_id(s->user_id); if(!u){ // invalid session if user removed
        return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    }
    if(out_user) *out_user = u;
    if(out_sess) *out_sess = s;
    return 0; }

static void set_cookie_session_id(struct MHD_Response *resp, const char *token){ char buf[256]; snprintf(buf, sizeof(buf), "session_id=%s; Path=/; HttpOnly", token); MHD_add_response_header(resp, "Set-Cookie", buf); }

static char* read_body_copy(struct ReqCtx *ctx){ if(!ctx || !ctx->body) return xstrdup(""); char *s = malloc(ctx->size + 1); if(!s){ perror("malloc"); exit(1);} memcpy(s, ctx->body, ctx->size); s[ctx->size] = '\0'; return s; }

static enum MHD_Result handle_register(struct MHD_Connection *conn, struct ReqCtx *ctx){ char *body = read_body_copy(ctx); fprintf(stderr, "handle_register body size=%zu body=%s\n", strlen(body), body);
    json_error_t jerr; json_t *root = json_loads(body, 0, &jerr); free(body); if(!root || !json_is_object(root)){ if(root) json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    json_t *juser = json_object_get(root, "username"); json_t *jpass = json_object_get(root, "password"); if(!json_is_string(juser) || !json_is_string(jpass)){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    const char *username = json_string_value(juser); const char *password = json_string_value(jpass);
    if(!is_valid_username(username)) { json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid username"); }
    if(!password || strlen(password) < 8){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short"); }
    if(username_exists(username)){ json_decref(root); return respond_error(conn, MHD_HTTP_CONFLICT, "Username already exists"); }
    User u; u.id = next_user_id++; u.username = xstrdup(username); u.password = xstrdup(password); users_push(u);
    json_t *resp = json_object(); json_object_set_new(resp, "id", json_integer(u.id)); json_object_set_new(resp, "username", json_string(u.username)); enum MHD_Result r = respond_json(conn, MHD_HTTP_CREATED, resp); json_decref(resp); json_decref(root); return r; }

static enum MHD_Result handle_login(struct MHD_Connection *conn, struct ReqCtx *ctx){ char *body = read_body_copy(ctx); json_error_t jerr; json_t *root = json_loads(body, 0, &jerr); free(body); if(!root || !json_is_object(root)){ if(root) json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    json_t *juser = json_object_get(root, "username"); json_t *jpass = json_object_get(root, "password"); if(!json_is_string(juser) || !json_is_string(jpass)){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    const char *username = json_string_value(juser); const char *password = json_string_value(jpass);
    User *u = find_user_by_username(username);
    if(!u || strcmp(u->password, password)!=0){ json_decref(root); return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); }
    // create session
    uuid_t uu; uuid_generate(uu); char token[37]; uuid_unparse_lower(uu, token);
    Session s; s.token = xstrdup(token); s.user_id = u->id; sessions_push(s);
    json_t *resp = json_object(); json_object_set_new(resp, "id", json_integer(u->id)); json_object_set_new(resp, "username", json_string(u->username));
    char *data = json_dumps(resp, JSON_COMPACT);
    struct MHD_Response *mresp = MHD_create_response_from_buffer(strlen(data), data, MHD_RESPMEM_MUST_FREE);
    MHD_add_response_header(mresp, "Content-Type", "application/json");
    MHD_add_response_header(mresp, "Cache-Control", "no-store");
    set_cookie_session_id(mresp, token);
    enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_OK, mresp);
    MHD_destroy_response(mresp);
    json_decref(resp); json_decref(root);
    return ret;
}

static enum MHD_Result handle_logout(struct MHD_Connection *conn, struct ReqCtx *ctx){ (void)ctx; User *u=NULL; Session *s=NULL; int auth = require_auth(conn, &u, &s); if(auth!=0) return auth; (void)u; // invalidate
    remove_session(s);
    json_t *o = json_object(); enum MHD_Result r = respond_json(conn, MHD_HTTP_OK, o); json_decref(o); return r; }

static enum MHD_Result handle_me(struct MHD_Connection *conn){ User *u=NULL; int auth = require_auth(conn, &u, NULL); if(auth!=0) return auth; json_t *o = json_object(); json_object_set_new(o, "id", json_integer(u->id)); json_object_set_new(o, "username", json_string(u->username)); enum MHD_Result r = respond_json(conn, MHD_HTTP_OK, o); json_decref(o); return r; }

static enum MHD_Result handle_password(struct MHD_Connection *conn, struct ReqCtx *ctx){ User *u=NULL; int auth = require_auth(conn, &u, NULL); if(auth!=0) return auth; char *body = read_body_copy(ctx); json_error_t jerr; json_t *root = json_loads(body, 0, &jerr); free(body); if(!root || !json_is_object(root)){ if(root) json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    json_t *jold = json_object_get(root, "old_password"); json_t *jnew = json_object_get(root, "new_password"); if(!json_is_string(jold) || !json_is_string(jnew)){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    const char *op = json_string_value(jold); const char *np = json_string_value(jnew);
    if(strcmp(u->password, op)!=0){ json_decref(root); return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); }
    if(strlen(np) < 8){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short"); }
    free(u->password); u->password = xstrdup(np);
    json_t *o = json_object(); enum MHD_Result r = respond_json(conn, MHD_HTTP_OK, o); json_decref(o); json_decref(root); return r; }

static json_t* todo_to_json(const Todo *t){ json_t *o = json_object(); json_object_set_new(o, "id", json_integer(t->id)); json_object_set_new(o, "title", json_string(t->title)); json_object_set_new(o, "description", json_string(t->description ? t->description : "")); json_object_set_new(o, "completed", json_boolean(t->completed)); json_object_set_new(o, "created_at", json_string(t->created_at)); json_object_set_new(o, "updated_at", json_string(t->updated_at)); return o; }

static enum MHD_Result handle_todos_list(struct MHD_Connection *conn){ User *u=NULL; int auth = require_auth(conn, &u, NULL); if(auth!=0) return auth; json_t *arr = json_array(); // ordered by id asc
    // collect and sort
    size_t count = 0; for(size_t i=0;i<todos_len;i++){ if(todos[i].user_id==u->id) count++; }
    Todo **list = malloc(sizeof(Todo*)*count); if(!list && count){ perror("malloc"); exit(1);} size_t j=0; for(size_t i=0;i<todos_len;i++){ if(todos[i].user_id==u->id) list[j++] = &todos[i]; }
    for(size_t a=0;a<count;a++){ for(size_t b=a+1;b<count;b++){ if(list[a]->id > list[b]->id){ Todo* tmp=list[a]; list[a]=list[b]; list[b]=tmp; } } }
    for(size_t i=0;i<count;i++){ json_t *o = todo_to_json(list[i]); json_array_append_new(arr, o); }
    free(list);
    enum MHD_Result r = respond_json(conn, MHD_HTTP_OK, arr); json_decref(arr); return r; }

static enum MHD_Result handle_todos_create(struct MHD_Connection *conn, struct ReqCtx *ctx){ User *u=NULL; int auth = require_auth(conn, &u, NULL); if(auth!=0) return auth; char *body = read_body_copy(ctx); json_error_t jerr; json_t *root = json_loads(body, 0, &jerr); free(body); if(!root || !json_is_object(root)){ if(root) json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    json_t *jtitle = json_object_get(root, "title"); json_t *jdesc = json_object_get(root, "description"); if(!json_is_string(jtitle) || strlen(json_string_value(jtitle))==0){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); }
    const char *title = json_string_value(jtitle); const char *desc = NULL; if(jdesc && json_is_string(jdesc)) desc = json_string_value(jdesc); if(!desc) desc = "";
    Todo t; t.id = next_todo_id++; t.user_id = u->id; t.title = xstrdup(title); t.description = xstrdup(desc); t.completed = 0; now_iso8601_utc(t.created_at); now_iso8601_utc(t.updated_at); todos_push(t);
    json_t *o = todo_to_json(&todos[todos_len-1]); enum MHD_Result r = respond_json(conn, MHD_HTTP_CREATED, o); json_decref(o); json_decref(root); return r; }

static enum MHD_Result handle_todo_get(struct MHD_Connection *conn, int id){ User *u=NULL; int auth = require_auth(conn, &u, NULL); if(auth!=0) return auth; Todo *t = find_todo_by_id(id); if(!t || t->user_id != u->id){ return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); }
    json_t *o = todo_to_json(t); enum MHD_Result r = respond_json(conn, MHD_HTTP_OK, o); json_decref(o); return r; }

static enum MHD_Result handle_todo_put(struct MHD_Connection *conn, int id, struct ReqCtx *ctx){ User *u=NULL; int auth = require_auth(conn, &u, NULL); if(auth!=0) return auth; Todo *t = find_todo_by_id(id); if(!t || t->user_id != u->id){ return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); }
    char *body = read_body_copy(ctx); json_error_t jerr; json_t *root = json_loads(body, 0, &jerr); free(body); if(!root || !json_is_object(root)){ if(root) json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    json_t *jtitle = json_object_get(root, "title"); if(jtitle){ if(!json_is_string(jtitle)){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); } const char *title = json_string_value(jtitle); if(strlen(title)==0){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); } free(t->title); t->title = xstrdup(title); }
    json_t *jdesc = json_object_get(root, "description"); if(jdesc){ if(!json_is_string(jdesc)){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); } const char *desc = json_string_value(jdesc); free(t->description); t->description = xstrdup(desc?desc:""); }
    json_t *jcomp = json_object_get(root, "completed"); if(jcomp){ if(!json_is_boolean(jcomp)){ json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); } t->completed = json_is_true(jcomp) ? 1 : 0; }
    now_iso8601_utc(t->updated_at);
    json_t *o = todo_to_json(t); enum MHD_Result r = respond_json(conn, MHD_HTTP_OK, o); json_decref(o); json_decref(root); return r; }

static enum MHD_Result handle_todo_delete(struct MHD_Connection *conn, int id){ User *u=NULL; int auth = require_auth(conn, &u, NULL); if(auth!=0) return auth; Todo *t = find_todo_by_id(id); if(!t || t->user_id != u->id){ return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); }
    remove_todo(t);
    // 204 No Content, no body
    struct MHD_Response *resp = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
    enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_NO_CONTENT, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int parse_todo_id_from_url(const char *url){ const char *idstr = url+7; if(*idstr=='\0') return -1; char *end=NULL; long id = strtol(idstr, &end, 10); if(id<=0) return -1; if(end && *end!='\0'){ if(!(*end=='/' && end[1]=='\0')) return -1; } return (int)id; }

static enum MHD_Result route_request(struct MHD_Connection *conn, const char *method, const char *url, struct ReqCtx *ctx){
    if(strcmp(url, "/register")==0 && strcmp(method, "POST")==0) return handle_register(conn, ctx);
    if(strcmp(url, "/login")==0 && strcmp(method, "POST")==0) return handle_login(conn, ctx);
    if(strcmp(url, "/logout")==0 && strcmp(method, "POST")==0) return handle_logout(conn, ctx);
    if(strcmp(url, "/me")==0 && strcmp(method, "GET")==0) return handle_me(conn);
    if(strcmp(url, "/password")==0 && strcmp(method, "PUT")==0) return handle_password(conn, ctx);
    if(strcmp(url, "/todos")==0 && strcmp(method, "GET")==0) return handle_todos_list(conn);
    if(strcmp(url, "/todos")==0 && strcmp(method, "POST")==0) return handle_todos_create(conn, ctx);
    if(strncmp(url, "/todos/", 7)==0){ int id = parse_todo_id_from_url(url); if(id<0) return respond_error(conn, MHD_HTTP_NOT_FOUND, "Not found"); if(strcmp(method, "GET")==0) return handle_todo_get(conn, id); if(strcmp(method, "PUT")==0) return handle_todo_put(conn, id, ctx); if(strcmp(method, "DELETE")==0) return handle_todo_delete(conn, id); }
    return respond_error(conn, MHD_HTTP_NOT_FOUND, "Not found");
}

static enum MHD_Result ahc(void *cls, struct MHD_Connection *conn, const char *url, const char *method, const char *ver, const char *upload_data, size_t *upload_data_size, void **con_cls){ (void)cls; (void)ver; struct ReqCtx *ctx = *con_cls; if(!ctx){ ctx = calloc(1, sizeof(*ctx)); if(!ctx){ return MHD_NO; } *con_cls = ctx; return MHD_YES; }
    if(*upload_data_size){
        size_t newsize = ctx->size + *upload_data_size; if(newsize > MAX_BODY_SIZE){ return respond_error(conn, MHD_HTTP_REQUEST_ENTITY_TOO_LARGE, "Payload too large"); }
        char *nbuf = realloc(ctx->body, newsize + 1); if(!nbuf){ return MHD_NO; } memcpy(nbuf + ctx->size, upload_data, *upload_data_size); ctx->body = nbuf; ctx->size = newsize; ctx->body[ctx->size] = '\0'; *upload_data_size = 0; return MHD_YES; }
    if( (0==strcmp(method, "POST") || 0==strcmp(method, "PUT")) ){
        const char *cl = MHD_lookup_connection_value(conn, MHD_HEADER_KIND, MHD_HTTP_HEADER_CONTENT_LENGTH);
        if(cl){ long long clen = atoll(cl); if(clen > 0 && (size_t)clen > ctx->size){ return MHD_YES; } }
    }
    enum MHD_Result ret = route_request(conn, method, url, ctx);
    return ret;
}

static void req_completed_cb (void *cls, struct MHD_Connection *connection, void **con_cls, enum MHD_RequestTerminationCode toe){ (void)cls; (void)connection; (void)toe; struct ReqCtx *ctx = *con_cls; if(ctx){ free(ctx->body); free(ctx);} *con_cls = NULL; }

int main(int argc, char **argv){ int port = 8080; for(int i=1;i<argc;i++){ if(strcmp(argv[i], "--port")==0 && i+1<argc){ port = atoi(argv[++i]); } }
    if(port<=0 || port>65535){ fprintf(stderr, "Invalid port\n"); return 1; }
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr)); addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_ANY); addr.sin_port = htons((uint16_t)port);
    struct MHD_Daemon *d = MHD_start_daemon(MHD_USE_INTERNAL_POLLING_THREAD | MHD_USE_DEBUG, (uint16_t)port, NULL, NULL, &ahc, NULL,
                                            MHD_OPTION_SOCK_ADDR, (struct sockaddr *)&addr,
                                            MHD_OPTION_NOTIFY_COMPLETED, req_completed_cb, NULL,
                                            MHD_OPTION_THREAD_POOL_SIZE, (unsigned int)1,
                                            MHD_OPTION_END);
    if(!d){ fprintf(stderr, "Failed to start server on 0.0.0.0:%d\n", port); return 1; }
    fprintf(stderr, "Server listening on 0.0.0.0:%d\n", port);
    // run forever
    for(;;){ struct timespec ts = { .tv_sec = 3600, .tv_nsec = 0 }; nanosleep(&ts, NULL); }
    MHD_stop_daemon(d);
    return 0;
}

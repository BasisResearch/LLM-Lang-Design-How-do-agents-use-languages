#define _GNU_SOURCE
#include <microhttpd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <ctype.h>
#include <uuid/uuid.h>
#include <cjson/cJSON.h>
#include <signal.h>

#define MAX_USERS 1000
#define MAX_TODOS 10000
#define MAX_SESSIONS 2000

#define CONTENT_TYPE_JSON "application/json"

typedef struct {
    int id;
    char username[64];
    char password[128];
} User;

typedef struct {
    int id;
    int user_id;
    char title[256];
    char description[1024];
    int completed; // 0/1
    char created_at[21]; // YYYY-MM-DDTHH:MM:SSZ\0 => 20+1
    char updated_at[21];
} Todo;

typedef struct {
    char token[64];
    int user_id;
    int valid; // 1=valid,0=invalid
} Session;

static User users[MAX_USERS];
static int users_count = 0;
static int next_user_id = 1;

static Todo todos[MAX_TODOS];
static int todos_count = 0;
static int next_todo_id = 1;

static Session sessions[MAX_SESSIONS];
static int sessions_count = 0;

static volatile sig_atomic_t keep_running = 1;

static void handle_sigint(int sig){ (void)sig; keep_running = 0; }

static void iso8601_utc_now(char out[21]) {
    time_t t = time(NULL);
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

static int validate_username(const char *u){
    if(!u) return 0;
    size_t n = strlen(u);
    if(n < 3 || n > 50) return 0;
    for(size_t i=0;i<n;i++){
        if(!(isalnum((unsigned char)u[i]) || u[i]=='_')) return 0;
    }
    return 1;
}

static int find_user_by_username(const char *u){
    for(int i=0;i<users_count;i++){
        if(strcmp(users[i].username,u)==0) return i;
    }
    return -1;
}

static int find_user_index_by_id(int id){
    for(int i=0;i<users_count;i++) if(users[i].id==id) return i; return -1;
}

static void make_token(char out[64]){
    uuid_t uu; uuid_generate_random(uu);
    char buf[37]; uuid_unparse_lower(uu, buf);
    snprintf(out, 64, "%s", buf);
}

static int create_session(int user_id, char token_out[64]){
    if(sessions_count >= MAX_SESSIONS) return 0;
    make_token(token_out);
    Session s; memset(&s,0,sizeof(s));
    snprintf(s.token, sizeof(s.token), "%s", token_out);
    s.user_id = user_id; s.valid = 1;
    sessions[sessions_count++] = s;
    return 1;
}

static int find_session(const char *token){
    if(!token) return -1;
    for(int i=0;i<sessions_count;i++){
        if(sessions[i].valid && strcmp(sessions[i].token, token)==0) return i;
    }
    return -1;
}

static void invalidate_session(const char *token){
    int i = find_session(token);
    if(i>=0) sessions[i].valid = 0;
}

static int parse_cookies(const char *cookie_hdr, char *session_id_out, size_t out_sz){
    if(!cookie_hdr) return 0;
    const char *p = cookie_hdr;
    while(*p){
        while(*p==' '||*p=='\t' || *p==';') p++;
        const char *k = p;
        while(*p && *p!='=' && *p!=';') p++;
        if(*p!='=') { while(*p && *p!=';') p++; continue; }
        size_t klen = (size_t)(p-k);
        p++; // skip '='
        const char *v = p;
        while(*p && *p!=';') p++;
        size_t vlen = (size_t)(p-v);
        if(klen==10 && strncmp(k, "session_id", 10)==0){
            size_t n = vlen < out_sz-1 ? vlen : out_sz-1;
            memcpy(session_id_out, v, n);
            session_id_out[n] = '\0';
            return 1;
        }
        if(*p==';') p++;
    }
    return 0;
}

static void send_json(struct MHD_Connection *conn, int status, const char *json, struct MHD_Response **out_resp){
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(json), (void*)json, MHD_RESPMEM_MUST_COPY);
    MHD_add_response_header(resp, "Content-Type", CONTENT_TYPE_JSON);
    if(out_resp) *out_resp = resp;
    MHD_queue_response(conn, status, resp);
    MHD_destroy_response(resp);
}

static void send_empty_no_content(struct MHD_Connection *conn){
    struct MHD_Response *resp = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
    // no content-type for 204 per spec (DELETE no body). Do not set content type.
    MHD_queue_response(conn, MHD_HTTP_NO_CONTENT, resp);
    MHD_destroy_response(resp);
}

static void send_error(struct MHD_Connection *conn, int status, const char *msg){
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "error", msg);
    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if(!s){
        const char *fallback = "{\"error\":\"Internal error\"}";
        send_json(conn, status, fallback, NULL);
        return;
    }
    send_json(conn, status, s, NULL);
    free(s);
}

static int parse_int_id(const char *s, int *out){
    if(!s || !*s) return 0;
    char *end=NULL; long v = strtol(s, &end, 10);
    if(*end!='\0' || v<=0 || v>INT32_MAX) return 0;
    *out = (int)v; return 1;
}

static cJSON* read_json_body(struct MHD_Connection *conn, const char *upload_data, size_t *upload_data_size, void **con_cls_state){
    (void)conn;
    // Use connection cls to accumulate body
    typedef struct { char *buf; size_t len; size_t cap; int done; } Acc;
    if(*con_cls_state == NULL){
        Acc *a = calloc(1, sizeof(Acc));
        a->cap = 1024; a->buf = malloc(a->cap); a->len=0; a->done=0;
        *con_cls_state = a;
        return NULL;
    }
    Acc *a = (Acc*)(*con_cls_state);
    if(*upload_data_size != 0){
        size_t need = a->len + *upload_data_size + 1;
        if(need > a->cap){
            size_t newcap = a->cap * 2; if(newcap < need) newcap = need;
            char *nb = realloc(a->buf, newcap);
            if(!nb){ a->done = 1; *upload_data_size = 0; return NULL; }
            a->buf = nb; a->cap = newcap;
        }
        memcpy(a->buf + a->len, upload_data, *upload_data_size);
        a->len += *upload_data_size; a->buf[a->len] = '\0';
        *upload_data_size = 0;
        return NULL;
    }
    if(!a->done){
        a->done = 1;
        if(a->len==0){
            return cJSON_CreateObject(); // empty body treated as empty object
        }
        cJSON *j = cJSON_ParseWithLength(a->buf, a->len);
        return j;
    }
    return NULL;
}

static void free_body_state(void **con_cls_state){
    if(!*con_cls_state) return;
    typedef struct { char *buf; size_t len; size_t cap; int done; } Acc;
    Acc *a = (Acc*)(*con_cls_state);
    free(a->buf); free(a);
    *con_cls_state = NULL;
}

static int is_method(const char *m, const char *target){ return strcmp(m, target)==0; }

static int auth_user(struct MHD_Connection *conn, int *out_user_id, char *session_token, size_t tok_sz){
    const char *cookie = MHD_lookup_connection_value(conn, MHD_HEADER_KIND, "Cookie");
    char tok[128]={0};
    if(!parse_cookies(cookie, tok, sizeof(tok))) return 0;
    int si = find_session(tok);
    if(si<0) return 0;
    if(out_user_id) *out_user_id = sessions[si].user_id;
    if(session_token) snprintf(session_token, tok_sz, "%s", tok);
    return 1;
}

static int json_bool_get(cJSON *obj, const char *key, int *has){
    cJSON *it = cJSON_GetObjectItemCaseSensitive(obj, key);
    if(!it){ if(has) *has=0; return 0; }
    if(!cJSON_IsBool(it)) return -1;
    if(has) *has = 1; return cJSON_IsTrue(it) ? 1 : 0;
}

static int json_string_get(cJSON *obj, const char *key, char *out, size_t outsz, int *has){
    cJSON *it = cJSON_GetObjectItemCaseSensitive(obj, key);
    if(!it){ if(has) *has = 0; return 1; }
    if(!cJSON_IsString(it)) return 0;
    const char *s = cJSON_GetStringValue(it);
    if(!s) s = "";
    size_t n = strlen(s); if(n >= outsz) n = outsz-1;
    memcpy(out, s, n); out[n]='\0';
    if(has) *has = 1; return 1;
}

static int todo_belongs_to_user(int todo_id, int user_id, int *idx_out){
    for(int i=0;i<todos_count;i++){
        if(todos[i].id==todo_id){
            if(todos[i].user_id!=user_id) return 0; // exists, but not user's
            if(idx_out) *idx_out = i; return 1;
        }
    }
    return -1; // not found
}

static void respond_user(struct MHD_Connection *conn, User *u){
    cJSON *o = cJSON_CreateObject();
    cJSON_AddNumberToObject(o, "id", u->id);
    cJSON_AddStringToObject(o, "username", u->username);
    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if(!s){ send_error(conn, 500, "Internal error"); return; }
    send_json(conn, MHD_HTTP_OK, s, NULL); free(s);
}

static void respond_todo(struct MHD_Connection *conn, Todo *t, int status){
    cJSON *o = cJSON_CreateObject();
    cJSON_AddNumberToObject(o, "id", t->id);
    cJSON_AddStringToObject(o, "title", t->title);
    cJSON_AddStringToObject(o, "description", t->description);
    cJSON_AddBoolToObject(o, "completed", t->completed ? 1 : 0);
    cJSON_AddStringToObject(o, "created_at", t->created_at);
    cJSON_AddStringToObject(o, "updated_at", t->updated_at);
    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if(!s){ send_error(conn, 500, "Internal error"); return; }
    send_json(conn, status, s, NULL); free(s);
}

static void respond_todos_list(struct MHD_Connection *conn, int user_id){
    cJSON *arr = cJSON_CreateArray();
    for(int i=0;i<todos_count;i++){
        if(todos[i].user_id==user_id){
            cJSON *o = cJSON_CreateObject();
            cJSON_AddNumberToObject(o, "id", todos[i].id);
            cJSON_AddStringToObject(o, "title", todos[i].title);
            cJSON_AddStringToObject(o, "description", todos[i].description);
            cJSON_AddBoolToObject(o, "completed", todos[i].completed?1:0);
            cJSON_AddStringToObject(o, "created_at", todos[i].created_at);
            cJSON_AddStringToObject(o, "updated_at", todos[i].updated_at);
            cJSON_AddItemToArray(arr, o);
        }
    }
    // Sort by id ascending (simple O(n^2) sort for small n)
    int n = cJSON_GetArraySize(arr);
    for(int i=0;i<n;i++){
        for(int j=i+1;j<n;j++){
            cJSON *oi = cJSON_GetArrayItem(arr, i);
            cJSON *oj = cJSON_GetArrayItem(arr, j);
            int idi = cJSON_GetObjectItem(oi, "id")->valueint;
            int idj = cJSON_GetObjectItem(oj, "id")->valueint;
            if(idj < idi){
                cJSON_DetachItemFromArray(arr, j);
                cJSON_InsertItemInArray(arr, i, oj);
            }
        }
    }
    char *s = cJSON_PrintUnformatted(arr);
    cJSON_Delete(arr);
    if(!s){ send_error(conn, 500, "Internal error"); return; }
    send_json(conn, MHD_HTTP_OK, s, NULL); free(s);
}

struct ReqCtx {
    cJSON *json;
};

static enum MHD_Result answer_to_connection(void *cls, struct MHD_Connection *conn,
                                const char *url, const char *method,
                                const char *ver, const char *upload_data,
                                size_t *upload_data_size, void **con_cls){
    (void)cls; (void)ver;

    // Initialize per-connection state for body parsing
    cJSON *json = read_json_body(conn, upload_data, upload_data_size, con_cls);
    if(json == NULL) return MHD_YES; // continue receiving

    // After body parsed or for GET/DELETE with empty body
    int authed_user = 0; char session_tok[128]={0};

    // Routing
    if(is_method(method, "POST") && strcmp(url, "/register")==0){
        if(!cJSON_IsObject(json)) { send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); cJSON_Delete(json); return MHD_YES; }
        char username[64]={0}; char password[256]={0};
        int ok_u = json_string_get(json, "username", username, sizeof(username), NULL);
        int ok_p = json_string_get(json, "password", password, sizeof(password), NULL);
        if(!ok_u || !*username || !validate_username(username)){
            send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid username"); cJSON_Delete(json); return MHD_YES;
        }
        if(!ok_p || strlen(password) < 8){
            send_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short"); cJSON_Delete(json); return MHD_YES;
        }
        if(find_user_by_username(username)>=0){
            send_error(conn, MHD_HTTP_CONFLICT, "Username already exists"); cJSON_Delete(json); return MHD_YES;
        }
        if(users_count >= MAX_USERS){ send_error(conn, 500, "User limit reached"); cJSON_Delete(json); return MHD_YES; }
        User u; memset(&u,0,sizeof(u));
        u.id = next_user_id++;
        snprintf(u.username, sizeof(u.username), "%s", username);
        snprintf(u.password, sizeof(u.password), "%s", password);
        users[users_count++] = u;
        cJSON *o = cJSON_CreateObject(); cJSON_AddNumberToObject(o, "id", u.id); cJSON_AddStringToObject(o, "username", u.username);
        char *s = cJSON_PrintUnformatted(o); cJSON_Delete(o);
        if(!s){ send_error(conn, 500, "Internal error"); cJSON_Delete(json); return MHD_YES; }
        struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(s), s, MHD_RESPMEM_MUST_FREE);
        MHD_add_response_header(resp, "Content-Type", CONTENT_TYPE_JSON);
        MHD_queue_response(conn, MHD_HTTP_CREATED, resp);
        MHD_destroy_response(resp);
        cJSON_Delete(json);
        return MHD_YES;
    }

    if(is_method(method, "POST") && strcmp(url, "/login")==0){
        if(!cJSON_IsObject(json)) { send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); cJSON_Delete(json); return MHD_YES; }
        char username[64]={0}; char password[256]={0};
        if(!json_string_get(json, "username", username, sizeof(username), NULL) ||
           !json_string_get(json, "password", password, sizeof(password), NULL)){
            send_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); cJSON_Delete(json); return MHD_YES;
        }
        int idx = find_user_by_username(username);
        if(idx<0 || strcmp(users[idx].password, password)!=0){
            send_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); cJSON_Delete(json); return MHD_YES;
        }
        char tok[64]; if(!create_session(users[idx].id, tok)){ send_error(conn, 500, "Internal error"); cJSON_Delete(json); return MHD_YES; }
        cJSON *o = cJSON_CreateObject(); cJSON_AddNumberToObject(o, "id", users[idx].id); cJSON_AddStringToObject(o, "username", users[idx].username);
        char *s = cJSON_PrintUnformatted(o); cJSON_Delete(o);
        struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(s), s, MHD_RESPMEM_MUST_FREE);
        MHD_add_response_header(resp, "Content-Type", CONTENT_TYPE_JSON);
        char set_cookie[256]; snprintf(set_cookie, sizeof(set_cookie), "session_id=%s; Path=/; HttpOnly", tok);
        MHD_add_response_header(resp, "Set-Cookie", set_cookie);
        MHD_queue_response(conn, MHD_HTTP_OK, resp);
        MHD_destroy_response(resp);
        cJSON_Delete(json);
        return MHD_YES;
    }

    // Auth-required endpoints
    if(!auth_user(conn, &authed_user, session_tok, sizeof(session_tok))){
        send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); cJSON_Delete(json); return MHD_YES;
    }

    if(is_method(method, "POST") && strcmp(url, "/logout")==0){
        invalidate_session(session_tok);
        cJSON *o = cJSON_CreateObject(); char *s = cJSON_PrintUnformatted(o); cJSON_Delete(o);
        struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(s), s, MHD_RESPMEM_MUST_FREE);
        MHD_add_response_header(resp, "Content-Type", CONTENT_TYPE_JSON);
        MHD_queue_response(conn, MHD_HTTP_OK, resp); MHD_destroy_response(resp);
        cJSON_Delete(json); return MHD_YES;
    }

    if(is_method(method, "GET") && strcmp(url, "/me")==0){
        int ui = find_user_index_by_id(authed_user);
        if(ui<0){ send_error(conn, 500, "Internal error"); cJSON_Delete(json); return MHD_YES; }
        respond_user(conn, &users[ui]); cJSON_Delete(json); return MHD_YES;
    }

    if(is_method(method, "PUT") && strcmp(url, "/password")==0){
        if(!cJSON_IsObject(json)) { send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); cJSON_Delete(json); return MHD_YES; }
        char oldp[256]={0}, newp[256]={0};
        if(!json_string_get(json, "old_password", oldp, sizeof(oldp), NULL) ||
           !json_string_get(json, "new_password", newp, sizeof(newp), NULL)){
            send_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); cJSON_Delete(json); return MHD_YES;
        }
        int ui = find_user_index_by_id(authed_user);
        if(ui<0){ send_error(conn, 500, "Internal error"); cJSON_Delete(json); return MHD_YES; }
        if(strcmp(users[ui].password, oldp)!=0){ send_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); cJSON_Delete(json); return MHD_YES; }
        if(strlen(newp) < 8){ send_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short"); cJSON_Delete(json); return MHD_YES; }
        snprintf(users[ui].password, sizeof(users[ui].password), "%s", newp);
        cJSON *o = cJSON_CreateObject(); char *s = cJSON_PrintUnformatted(o); cJSON_Delete(o);
        send_json(conn, MHD_HTTP_OK, s, NULL); free(s);
        cJSON_Delete(json); return MHD_YES;
    }

    if(strcmp(url, "/todos")==0 && is_method(method, "GET")){
        respond_todos_list(conn, authed_user); cJSON_Delete(json); return MHD_YES;
    }

    if(strcmp(url, "/todos")==0 && is_method(method, "POST")){
        if(!cJSON_IsObject(json)) { send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); cJSON_Delete(json); return MHD_YES; }
        char title[256]=""; char desc[1024]=""; int has_title=0;
        cJSON *jt = cJSON_GetObjectItemCaseSensitive(json, "title");
        if(jt && cJSON_IsString(jt)) { snprintf(title, sizeof(title), "%s", cJSON_GetStringValue(jt)); has_title=1; }
        cJSON *jd = cJSON_GetObjectItemCaseSensitive(json, "description");
        if(jd && cJSON_IsString(jd)) { snprintf(desc, sizeof(desc), "%s", cJSON_GetStringValue(jd)); }
        if(!has_title || strlen(title)==0){ send_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); cJSON_Delete(json); return MHD_YES; }
        if(todos_count >= MAX_TODOS){ send_error(conn, 500, "Todo limit reached"); cJSON_Delete(json); return MHD_YES; }
        Todo t; memset(&t,0,sizeof(t));
        t.id = next_todo_id++; t.user_id = authed_user; snprintf(t.title,sizeof(t.title),"%s",title);
        snprintf(t.description,sizeof(t.description),"%s",desc);
        t.completed = 0; iso8601_utc_now(t.created_at); snprintf(t.updated_at,sizeof(t.updated_at),"%s",t.created_at);
        todos[todos_count++] = t;
        respond_todo(conn, &t, MHD_HTTP_CREATED); cJSON_Delete(json); return MHD_YES;
    }

    // Routes with /todos/:id
    if(strncmp(url, "/todos/", 7)==0){
        const char *idstr = url + 7; int tid=0; if(!parse_int_id(idstr, &tid)){
            send_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); cJSON_Delete(json); return MHD_YES; }
        int idx = -1; int belong = todo_belongs_to_user(tid, authed_user, &idx);
        if(belong==-1 || belong==0){ send_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); cJSON_Delete(json); return MHD_YES; }
        if(is_method(method, "GET")){
            respond_todo(conn, &todos[idx], MHD_HTTP_OK); cJSON_Delete(json); return MHD_YES;
        } else if(is_method(method, "PUT")){
            if(!cJSON_IsObject(json)) { send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); cJSON_Delete(json); return MHD_YES; }
            int has_title=0; char title[256];
            cJSON *jt = cJSON_GetObjectItemCaseSensitive(json, "title");
            if(jt){ if(!cJSON_IsString(jt)){ send_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); cJSON_Delete(json); return MHD_YES; } has_title=1; snprintf(title,sizeof(title),"%s", cJSON_GetStringValue(jt)); if(strlen(title)==0){ send_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); cJSON_Delete(json); return MHD_YES; } }
            cJSON *jd = cJSON_GetObjectItemCaseSensitive(json, "description");
            if(jd && !cJSON_IsString(jd)){ send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); cJSON_Delete(json); return MHD_YES; }
            cJSON *jc = cJSON_GetObjectItemCaseSensitive(json, "completed");
            if(jc && !cJSON_IsBool(jc)){ send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); cJSON_Delete(json); return MHD_YES; }
            if(has_title){ snprintf(todos[idx].title, sizeof(todos[idx].title), "%s", title); }
            if(jd){ snprintf(todos[idx].description, sizeof(todos[idx].description), "%s", cJSON_GetStringValue(jd)); }
            if(jc){ todos[idx].completed = cJSON_IsTrue(jc) ? 1 : 0; }
            iso8601_utc_now(todos[idx].updated_at);
            respond_todo(conn, &todos[idx], MHD_HTTP_OK); cJSON_Delete(json); return MHD_YES;
        } else if(is_method(method, "DELETE")){
            // delete
            for(int i=idx;i<todos_count-1;i++) todos[i]=todos[i+1];
            todos_count--;
            send_empty_no_content(conn); cJSON_Delete(json); return MHD_YES;
        }
    }

    // Unknown route
    send_error(conn, MHD_HTTP_NOT_FOUND, "Not found");
    cJSON_Delete(json);
    return MHD_YES;
}

static void request_completed_callback (void *cls, struct MHD_Connection *connection,
                              void **con_cls, enum MHD_RequestTerminationCode toe){
    (void)cls; (void)connection; (void)toe; 
    free_body_state(con_cls);
}

int main(int argc, char *argv[]){
    int port = 8080;
    for(int i=1;i<argc;i++){
        if(strcmp(argv[i], "--port")==0 && i+1<argc){ port = atoi(argv[i+1]); i++; }
    }

    signal(SIGINT, handle_sigint);

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_SELECT_INTERNALLY, port, NULL, NULL, &answer_to_connection, NULL, 
                                MHD_OPTION_NOTIFY_COMPLETED, request_completed_callback, NULL,
                                MHD_OPTION_LISTENING_ADDRESS_REUSE, 1,
                                MHD_OPTION_END);
    if(NULL == daemon){ fprintf(stderr, "Failed to start server\n"); return 1; }
    fprintf(stdout, "Server listening on 0.0.0.0:%d\n", port);
    fflush(stdout);
    while(keep_running){ sleep(1); }
    MHD_stop_daemon(daemon);
    return 0;
}

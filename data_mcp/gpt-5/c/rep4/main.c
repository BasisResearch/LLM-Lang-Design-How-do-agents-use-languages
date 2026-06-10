#include <microhttpd.h>
#include <jansson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <stdarg.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <netinet/in.h>

#ifndef MHD_HTTP_HEADER_SET_COOKIE
#define MHD_HTTP_HEADER_SET_COOKIE "Set-Cookie"
#endif

#define MAX_USERNAME_LEN 50
#define MAX_PASSWORD_LEN 256
#define TOKEN_LEN 64

typedef struct {
    int id;
    char username[MAX_USERNAME_LEN + 1];
    char password[MAX_PASSWORD_LEN + 1];
} User;

typedef struct {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed;
    char created_at[21];
    char updated_at[21];
} Todo;

typedef struct {
    char token[TOKEN_LEN + 1];
    int user_id;
    int valid;
} Session;

static User *users = NULL; static size_t users_count = 0; static size_t users_cap = 0; static int next_user_id = 1;
static Todo *todos = NULL; static size_t todos_count = 0; static size_t todos_cap = 0; static int next_todo_id = 1;
static Session *sessions = NULL; static size_t sessions_count = 0; static size_t sessions_cap = 0;

static int server_port = 8080;

static void ensure_users_cap() {
    if (users_count >= users_cap) {
        users_cap = users_cap ? users_cap * 2 : 16;
        users = (User*)realloc(users, users_cap * sizeof(User));
        if (!users) {
            perror("realloc users");
            exit(1);
        }
    }
}
static void ensure_todos_cap() {
    if (todos_count >= todos_cap) {
        todos_cap = todos_cap ? todos_cap * 2 : 16;
        todos = (Todo*)realloc(todos, todos_cap * sizeof(Todo));
        if (!todos) {
            perror("realloc todos");
            exit(1);
        }
    }
}
static void ensure_sessions_cap() {
    if (sessions_count >= sessions_cap) {
        sessions_cap = sessions_cap ? sessions_cap * 2 : 16;
        sessions = (Session*)realloc(sessions, sessions_cap * sizeof(Session));
        if (!sessions) {
            perror("realloc sessions");
            exit(1);
        }
    }
}

static void free_todo_fields(Todo *t) {
    if (t) {
        free(t->title); t->title = NULL;
        free(t->description); t->description = NULL;
    }
}

static void format_time_iso8601(time_t t, char out[21]) {
    struct tm gm; gmtime_r(&t, &gm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &gm);
}

static void now_iso8601(char out[21]) {
    time_t t = time(NULL);
    format_time_iso8601(t, out);
}

static int is_valid_username(const char *u) {
    if (!u)
        return 0;
    size_t n = strlen(u);
    if (n < 3 || n > 50)
        return 0;
    for (size_t i = 0; i < n; i++) {
        char c = u[i];
        if (!(isalnum((unsigned char)c) || c == '_'))
            return 0;
    }
    return 1;
}

static int find_user_by_username(const char *u) {
    for (size_t i = 0; i < users_count; i++) {
        if (strcmp(users[i].username, u) == 0)
            return (int)i;
    }
    return -1;
}

static int add_user(const char *username, const char *password, User *out) {
    ensure_users_cap();
    User u;
    memset(&u, 0, sizeof(u));
    u.id = next_user_id++;
    strncpy(u.username, username, MAX_USERNAME_LEN);
    u.username[MAX_USERNAME_LEN] = '\0';
    strncpy(u.password, password, MAX_PASSWORD_LEN);
    u.password[MAX_PASSWORD_LEN] = '\0';
    users[users_count++] = u;
    if (out)
        *out = u;
    return u.id;
}

static User* get_user_by_id(int id) {
    for (size_t i = 0; i < users_count; i++) {
        if (users[i].id == id)
            return &users[i];
    }
    return NULL;
}

static void random_bytes(unsigned char *buf, size_t n) {
    FILE *f = fopen("/dev/urandom", "rb");
    if (!f) {
        perror("/dev/urandom");
        exit(1);
    }
    size_t got = 0;
    while (got < n) {
        size_t r = fread(buf + got, 1, n - got, f);
        if (r == 0) {
            if (ferror(f)) {
                perror("fread urandom");
                fclose(f);
                exit(1);
            }
        }
        got += r;
    }
    fclose(f);
}

static void gen_token(char out[TOKEN_LEN+1]) {
    unsigned char bytes[TOKEN_LEN/2];
    random_bytes(bytes, sizeof(bytes));
    static const char *hex = "0123456789abcdef";
    for (size_t i = 0; i < sizeof(bytes); i++) {
        out[2*i] = hex[(bytes[i]>>4)&0xF];
        out[2*i+1] = hex[bytes[i]&0xF];
    }
    out[TOKEN_LEN] = '\0';
}

static Session* create_session(int user_id) {
    ensure_sessions_cap();
    Session s;
    memset(&s, 0, sizeof(s));
    s.user_id = user_id;
    s.valid = 1;
    gen_token(s.token);
    sessions[sessions_count++] = s;
    return &sessions[sessions_count - 1];
}

static Session* find_session_by_token(const char *token) {
    if (!token)
        return NULL;
    for (size_t i = 0; i < sessions_count; i++) {
        if (sessions[i].valid && strcmp(sessions[i].token, token) == 0)
            return &sessions[i];
    }
    return NULL;
}

static void invalidate_session(Session *s) {
    if (s)
        s->valid = 0;
}

static Todo* find_todo_by_id(int id) {
    for (size_t i = 0; i < todos_count; i++) {
        if (todos[i].id == id)
            return &todos[i];
    }
    return NULL;
}

static Todo* add_todo(int user_id, const char *title, const char *description) {
    ensure_todos_cap();
    Todo t;
    memset(&t, 0, sizeof(t));
    t.id = next_todo_id++;
    t.user_id = user_id;
    t.completed = 0;
    t.title = strdup(title ? title : "");
    t.description = strdup(description ? description : "");
    now_iso8601(t.created_at);
    strncpy(t.updated_at, t.created_at, sizeof(t.updated_at));
    todos[todos_count++] = t;
    return &todos[todos_count - 1];
}

static void delete_todo_by_index(size_t idx) {
    if (idx >= todos_count)
        return;
    free_todo_fields(&todos[idx]);
    if (idx != todos_count - 1)
        todos[idx] = todos[todos_count - 1];
    todos_count--;
}

static char* todo_to_json_string(const Todo *t) {
    json_t *obj = json_object();
    json_object_set_new(obj, "id", json_integer(t->id));
    json_object_set_new(obj, "title", json_string(t->title ? t->title : ""));
    json_object_set_new(obj, "description", json_string(t->description ? t->description : ""));
    json_object_set_new(obj, "completed", json_boolean(t->completed));
    json_object_set_new(obj, "created_at", json_string(t->created_at));
    json_object_set_new(obj, "updated_at", json_string(t->updated_at));
    char *s = json_dumps(obj, JSON_COMPACT);
    json_decref(obj);
    return s; // must free
}

static char* todos_array_for_user_json_string(int user_id) {
    json_t *arr = json_array();
    for (size_t i = 0; i < todos_count; i++) {
        if (todos[i].user_id == user_id) {
            json_t *obj = json_object();
            json_object_set_new(obj, "id", json_integer(todos[i].id));
            json_object_set_new(obj, "title", json_string(todos[i].title ? todos[i].title : ""));
            json_object_set_new(obj, "description", json_string(todos[i].description ? todos[i].description : ""));
            json_object_set_new(obj, "completed", json_boolean(todos[i].completed));
            json_object_set_new(obj, "created_at", json_string(todos[i].created_at));
            json_object_set_new(obj, "updated_at", json_string(todos[i].updated_at));
            json_array_append_new(arr, obj);
        }
    }
    char *s = json_dumps(arr, JSON_COMPACT);
    json_decref(arr);
    return s; // must free
}

static struct MHD_Response* json_response(const char *json_str) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(json_str), (void*)json_str, MHD_RESPMEM_MUST_COPY);
    if (!resp) return NULL;
    MHD_add_response_header(resp, MHD_HTTP_HEADER_CONTENT_TYPE, "application/json");
    return resp;
}

static enum MHD_Result send_json(struct MHD_Connection *conn, unsigned int status, const char *json_str) {
    struct MHD_Response *resp = json_response(json_str);
    if (!resp) return MHD_NO;
    enum MHD_Result ret = MHD_queue_response(conn, status, resp);
    MHD_destroy_response(resp);
    return ret;
}

static enum MHD_Result send_error(struct MHD_Connection *conn, unsigned int status, const char *msg) {
    json_t *err = json_object();
    json_object_set_new(err, "error", json_string(msg));
    char *s = json_dumps(err, JSON_COMPACT);
    json_decref(err);
    enum MHD_Result ret = send_json(conn, status, s);
    free(s);
    return ret;
}

static enum MHD_Result send_empty_ok(struct MHD_Connection *conn) {
    json_t *obj = json_object();
    char *s = json_dumps(obj, JSON_COMPACT);
    json_decref(obj);
    enum MHD_Result ret = send_json(conn, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static enum MHD_Result send_no_content(struct MHD_Connection *conn) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
    if (!resp) return MHD_NO;
    enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_NO_CONTENT, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int parse_int_id(const char *s, int *out_id) {
    if (!s || !*s)
        return 0;
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (*end != '\0')
        return 0;
    if (v <= 0 || v > 2147483647L)
        return 0;
    *out_id = (int)v;
    return 1;
}

static int get_auth_user(struct MHD_Connection *conn, User **out_user, Session **out_sess) {
    const char *token = MHD_lookup_connection_value(conn, MHD_COOKIE_KIND, "session_id");
    if (!token) return 0;
    Session *s = find_session_by_token(token);
    if (!s) return 0;
    User *u = get_user_by_id(s->user_id);
    if (!u) return 0;
    if (out_user)
        *out_user = u;
    if (out_sess)
        *out_sess = s;
    return 1;
}

struct RequestContext {
    char *body; size_t size; size_t cap;
};

static void rc_free(struct RequestContext *rc){ if (!rc) return; free(rc->body); free(rc); }

static int append_body(struct RequestContext *rc, const char *data, size_t size) {
    if (size==0) return 1;
    if (rc->size + size + 1 > rc->cap) {
        size_t newcap = rc->cap ? rc->cap*2 : 1024;
        while (newcap < rc->size + size + 1) newcap*=2;
        char *nb = (char*)realloc(rc->body, newcap);
        if (!nb) return 0;
        rc->body = nb; rc->cap = newcap;
    }
    memcpy(rc->body + rc->size, data, size);
    rc->size += size;
    rc->body[rc->size] = '\0';
    return 1;
}

static enum MHD_Result handle_request(void *cls, struct MHD_Connection *conn, const char *url, const char *method, const char *version, const char *upload_data, size_t *upload_data_size, void **con_cls) {
    (void)cls; (void)version;
    struct RequestContext *rc = *con_cls ? (struct RequestContext*)*con_cls : NULL;
    int is_post = (0==strcmp(method, MHD_HTTP_METHOD_POST));
    int is_put = (0==strcmp(method, MHD_HTTP_METHOD_PUT));

    if (!rc && (is_post || is_put)) {
        rc = (struct RequestContext*)calloc(1, sizeof(struct RequestContext));
        if (!rc) return MHD_NO;
        *con_cls = rc;
        return MHD_YES;
    }
    if ((is_post || is_put)) {
        if (*upload_data_size != 0) {
            if (!append_body(rc, upload_data, *upload_data_size))
                return MHD_NO;
            *upload_data_size = 0;
            return MHD_YES;
        }
    }

    // Routing
    if (strcmp(url, "/register")==0 && is_post) {
        if (!rc || !rc->body)
            return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
        json_error_t jerr; json_t *root = json_loads(rc->body, 0, &jerr);
        if (!root || !json_is_object(root)) { if (root) json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
        const char *username = NULL; const char *password = NULL;
        json_t *ju = json_object_get(root, "username"); if (json_is_string(ju)) username = json_string_value(ju);
        json_t *jp = json_object_get(root, "password"); if (json_is_string(jp)) password = json_string_value(jp);
        if (!is_valid_username(username)) { json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid username"); }
        if (!password || strlen(password) < 8) { json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short"); }
        if (find_user_by_username(username) >= 0) { json_decref(root); return send_error(conn, MHD_HTTP_CONFLICT, "Username already exists"); }
        User u; add_user(username, password, &u);
        json_t *resp = json_object(); json_object_set_new(resp, "id", json_integer(u.id)); json_object_set_new(resp, "username", json_string(u.username)); char *s = json_dumps(resp, JSON_COMPACT); json_decref(resp); json_decref(root);
        enum MHD_Result ret = send_json(conn, MHD_HTTP_CREATED, s); free(s); return ret;
    }

    if (strcmp(url, "/login")==0 && is_post) {
        if (!rc || !rc->body)
            return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
        json_error_t jerr; json_t *root = json_loads(rc->body, 0, &jerr);
        if (!root || !json_is_object(root)) { if (root) json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
        const char *username=NULL; const char *password=NULL; json_t *ju=json_object_get(root, "username"); if (json_is_string(ju)) username=json_string_value(ju); json_t *jp=json_object_get(root, "password"); if (json_is_string(jp)) password=json_string_value(jp);
        int idx = (username? find_user_by_username(username) : -1);
        if (idx < 0 || !password || strcmp(users[idx].password, password)!=0) { json_decref(root); return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); }
        User *u = &users[idx]; Session *s = create_session(u->id);
        json_t *resp = json_object(); json_object_set_new(resp, "id", json_integer(u->id)); json_object_set_new(resp, "username", json_string(u->username)); char *body = json_dumps(resp, JSON_COMPACT); json_decref(resp); json_decref(root);
        struct MHD_Response *mresp = json_response(body); if (!mresp) { free(body); return MHD_NO; }
        char cookie[128]; snprintf(cookie, sizeof(cookie), "session_id=%s; Path=/; HttpOnly", s->token);
        MHD_add_response_header(mresp, MHD_HTTP_HEADER_SET_COOKIE, cookie);
        enum MHD_Result ret = MHD_queue_response(conn, MHD_HTTP_OK, mresp);
        MHD_destroy_response(mresp); free(body);
        return ret;
    }

    if (strcmp(url, "/logout")==0 && is_post) {
        User *u=NULL; Session *s=NULL; if (!get_auth_user(conn, &u, &s)) return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); (void)u; invalidate_session(s); return send_empty_ok(conn);
    }

    if (strcmp(url, "/me")==0 && 0==strcmp(method, MHD_HTTP_METHOD_GET)) {
        User *u=NULL; if (!get_auth_user(conn, &u, NULL)) return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); json_t *resp=json_object(); json_object_set_new(resp, "id", json_integer(u->id)); json_object_set_new(resp, "username", json_string(u->username)); char *s=json_dumps(resp, JSON_COMPACT); json_decref(resp); enum MHD_Result ret=send_json(conn, MHD_HTTP_OK, s); free(s); return ret;
    }

    if (strcmp(url, "/password")==0 && is_put) {
        User *u=NULL; if (!get_auth_user(conn, &u, NULL)) return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); if (!rc || !rc->body) return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); json_error_t jerr; json_t *root=json_loads(rc->body,0,&jerr); if (!root||!json_is_object(root)) { if (root) json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
        const char *oldp=NULL; const char *newp=NULL; json_t *jo=json_object_get(root, "old_password"); if (json_is_string(jo)) oldp=json_string_value(jo); json_t *jn=json_object_get(root, "new_password"); if (json_is_string(jn)) newp=json_string_value(jn);
        if (!oldp || strcmp(u->password, oldp)!=0) { json_decref(root); return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); }
        if (!newp || strlen(newp) < 8) { json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short"); }
        strncpy(u->password, newp, MAX_PASSWORD_LEN); u->password[MAX_PASSWORD_LEN]='\0'; json_decref(root); return send_empty_ok(conn);
    }

    if (strcmp(url, "/todos")==0 && 0==strcmp(method, MHD_HTTP_METHOD_GET)) {
        User *u=NULL; if (!get_auth_user(conn, &u, NULL)) return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); char *s = todos_array_for_user_json_string(u->id); enum MHD_Result ret = send_json(conn, MHD_HTTP_OK, s); free(s); return ret;
    }

    if (strcmp(url, "/todos")==0 && is_post) {
        User *u=NULL; if (!get_auth_user(conn, &u, NULL)) return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); if (!rc || !rc->body) return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); json_error_t jerr; json_t *root=json_loads(rc->body,0,&jerr); if (!root||!json_is_object(root)) { if (root) json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
        const char *title=NULL; const char *description=""; json_t *jt=json_object_get(root, "title"); if (json_is_string(jt)) title=json_string_value(jt); json_t *jd=json_object_get(root, "description"); if (json_is_string(jd)) description=json_string_value(jd);
        if (!title || strlen(title)==0) { json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); }
        Todo *t = add_todo(u->id, title, description);
        char *s = todo_to_json_string(t); json_decref(root); enum MHD_Result ret = send_json(conn, MHD_HTTP_CREATED, s); free(s); return ret;
    }

    // /todos/:id
    if (strncmp(url, "/todos/", 7)==0) {
        const char *idstr = url + 7; // up to end
        int id=0; if (!parse_int_id(idstr, &id)) {
            return send_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
        }
        if (0==strcmp(method, MHD_HTTP_METHOD_GET)) {
            User *u=NULL; if (!get_auth_user(conn, &u, NULL)) return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); Todo *t=find_todo_by_id(id); if (!t || t->user_id != u->id) return send_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); char *s=todo_to_json_string(t); enum MHD_Result ret=send_json(conn, MHD_HTTP_OK, s); free(s); return ret;
        } else if (is_put) {
            User *u=NULL; if (!get_auth_user(conn, &u, NULL)) return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); Todo *t=find_todo_by_id(id); if (!t || t->user_id != u->id) return send_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); if (!rc || !rc->body) return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); json_error_t jerr; json_t *root=json_loads(rc->body,0,&jerr); if (!root||!json_is_object(root)) { if (root) json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
            json_t *jt=json_object_get(root, "title"); if (jt) { if (!json_is_string(jt)) { json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); } const char *nt=json_string_value(jt); if (!nt || strlen(nt)==0) { json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); } free(t->title); t->title=strdup(nt); }
            json_t *jd=json_object_get(root, "description"); if (jd) { if (!json_is_string(jd)) { json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); } const char *nd=json_string_value(jd); free(t->description); t->description=strdup(nd?nd:""); }
            json_t *jc=json_object_get(root, "completed"); if (jc) { if (!json_is_boolean(jc)) { json_decref(root); return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); } t->completed = json_is_true(jc) ? 1 : 0; }
            now_iso8601(t->updated_at);
            char *s=todo_to_json_string(t); json_decref(root); enum MHD_Result ret=send_json(conn, MHD_HTTP_OK, s); free(s); return ret;
        } else if (0==strcmp(method, MHD_HTTP_METHOD_DELETE)) {
            User *u=NULL; if (!get_auth_user(conn, &u, NULL)) return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required"); size_t idx=(size_t)-1; Todo *t=NULL; for (size_t i=0;i<todos_count;i++){ if (todos[i].id==id){ idx=i; t=&todos[i]; break; } } if (!t || t->user_id!=u->id) return send_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found"); delete_todo_by_index(idx); return send_no_content(conn);
        }
    }

    return send_error(conn, MHD_HTTP_NOT_FOUND, "Not found");
}

static void request_completed(void *cls, struct MHD_Connection *conn, void **con_cls, enum MHD_RequestTerminationCode toe) {
    (void)cls; (void)conn; (void)toe; struct RequestContext *rc = *con_cls ? (struct RequestContext*)*con_cls : NULL; if (rc) rc_free(rc); *con_cls=NULL; }

int main(int argc, char *argv[]) {
    for (int i=1;i<argc;i++) {
        if (strcmp(argv[i], "--port")==0 && i+1<argc) { server_port = atoi(argv[++i]); }
    }

    // Bind to 0.0.0.0:PORT explicitly
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)server_port);

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_SELECT_INTERNALLY,
                                                 server_port,
                                                 NULL, NULL,
                                                 &handle_request, NULL,
                                                 MHD_OPTION_NOTIFY_COMPLETED, request_completed, NULL,
                                                 MHD_OPTION_SOCK_ADDR, &addr,
                                                 MHD_OPTION_END);
    if (!daemon) { fprintf(stderr, "Failed to start server on port %d\n", server_port); return 1; }
    printf("Server listening on 0.0.0.0:%d\n", server_port);
    fflush(stdout);
    // run forever
    while (1) pause();
    MHD_stop_daemon(daemon);
    return 0;
}

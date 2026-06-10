#include <microhttpd.h>
#include <jansson.h>
#include <uuid/uuid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ctype.h>

#define MAX_BODY_SIZE (1024*1024)

typedef struct {
    int id;
    char username[64];
    char *password; // plain for in-memory demo
} User;

typedef struct {
    char token[64];
    int user_id;
} Session;

typedef struct {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0 or 1
    char created_at[21];
    char updated_at[21];
} Todo;

static User *users = NULL; static size_t users_count = 0; static size_t users_cap = 0; static int next_user_id = 1;
static Session *sessions = NULL; static size_t sessions_count = 0; static size_t sessions_cap = 0;
static Todo *todos = NULL; static size_t todos_count = 0; static size_t todos_cap = 0; static int next_todo_id = 1;

static int server_port = 8080;

static void iso_timestamp_now(char out[21]) {
    time_t now = time(NULL);
    struct tm tm;
    gmtime_r(&now, &tm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

static void ensure_users_cap() { if (users_count >= users_cap) { users_cap = users_cap ? users_cap*2 : 16; users = realloc(users, users_cap*sizeof(User)); } }
static void ensure_sessions_cap() { if (sessions_count >= sessions_cap) { sessions_cap = sessions_cap ? sessions_cap*2 : 16; sessions = realloc(sessions, sessions_cap*sizeof(Session)); } }
static void ensure_todos_cap() { if (todos_count >= todos_cap) { todos_cap = todos_cap ? todos_cap*2 : 16; todos = realloc(todos, todos_cap*sizeof(Todo)); } }

static User* find_user_by_username(const char *username) {
    for (size_t i=0;i<users_count;i++) if (strcmp(users[i].username, username)==0) return &users[i];
    return NULL;
}

static User* find_user_by_id(int id) {
    for (size_t i=0;i<users_count;i++) if (users[i].id == id) return &users[i];
    return NULL;
}

static Session* find_session_by_token(const char *token) {
    for (size_t i=0;i<sessions_count;i++) if (strcmp(sessions[i].token, token)==0) return &sessions[i];
    return NULL;
}

static void delete_session_by_token(const char *token) {
    for (size_t i=0;i<sessions_count;i++) {
        if (strcmp(sessions[i].token, token)==0) {
            if (i+1 < sessions_count) memmove(&sessions[i], &sessions[i+1], (sessions_count-i-1)*sizeof(Session));
            sessions_count--;
            return;
        }
    }
}

static Todo* find_todo_by_id(int id) {
    for (size_t i=0;i<todos_count;i++) if (todos[i].id == id) return &todos[i];
    return NULL;
}

static int username_valid(const char *u) {
    size_t len = strlen(u);
    if (len < 3 || len > 50) return 0;
    for (size_t i=0;i<len;i++) {
        char c = u[i];
        if (!(isalnum((unsigned char)c) || c=='_')) return 0;
    }
    return 1;
}

static void uuid_token(char out[64]) {
    uuid_t u;
    uuid_generate(u);
    uuid_unparse_lower(u, out);
}

static const char* get_cookie_session_id(struct MHD_Connection *connection) {
    const char *cookie_hdr = MHD_lookup_connection_value(connection, MHD_HEADER_KIND, "Cookie");
    if (!cookie_hdr) return NULL;
    const char *p = cookie_hdr;
    static __thread char token[128];
    token[0] = '\0';
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == ';') p++;
        if (!*p) break;
        const char *key_start = p;
        while (*p && *p!='=' && *p!=';' ) p++;
        size_t key_len = p - key_start;
        if (*p != '=') { while (*p && *p!=';') p++; continue; }
        p++; // skip '='
        const char *val_start = p;
        while (*p && *p!=';') p++;
        size_t val_len = p - val_start;
        if (key_len == strlen("session_id") && strncmp(key_start, "session_id", key_len)==0) {
            size_t n = val_len < sizeof(token)-1 ? val_len : sizeof(token)-1;
            memcpy(token, val_start, n);
            token[n] = '\0';
            return token;
        }
    }
    return NULL;
}

struct ReqCtx {
    char *body;
    size_t body_len;
    size_t body_cap;
};

static int send_json(struct MHD_Connection *conn, int status, const char *json_str, const char *set_cookie) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(json_str), (void*)json_str, MHD_RESPMEM_MUST_COPY);
    if (!resp) return MHD_NO;
    MHD_add_response_header(resp, "Content-Type", "application/json");
    if (set_cookie) MHD_add_response_header(resp, "Set-Cookie", set_cookie);
    int ret = MHD_queue_response(conn, status, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int send_json_obj(struct MHD_Connection *conn, int status, json_t *obj, const char *set_cookie) {
    char *dump = json_dumps(obj, JSON_COMPACT);
    json_decref(obj);
    int ret = send_json(conn, status, dump, set_cookie);
    free(dump);
    return ret;
}

static int send_error(struct MHD_Connection *conn, int status, const char *msg) {
    json_t *obj = json_pack("{s:s}", "error", msg);
    return send_json_obj(conn, status, obj, NULL);
}

static int send_empty_ok(struct MHD_Connection *conn) {
    json_t *obj = json_object();
    return send_json_obj(conn, 200, obj, NULL);
}

static int send_204(struct MHD_Connection *conn) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(conn, 204, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int ensure_body_capacity(struct ReqCtx *ctx, size_t add) {
    if (ctx->body_len + add + 1 > MAX_BODY_SIZE) return 0;
    if (ctx->body_len + add + 1 > ctx->body_cap) {
        size_t newcap = ctx->body_cap ? ctx->body_cap*2 : 4096;
        while (newcap < ctx->body_len + add + 1) newcap *= 2;
        char *nb = realloc(ctx->body, newcap);
        if (!nb) return 0;
        ctx->body = nb; ctx->body_cap = newcap;
    }
    return 1;
}

static int authenticate(struct MHD_Connection *conn, User **out_user, Session **out_sess) {
    const char *token = get_cookie_session_id(conn);
    if (!token) return 0;
    Session *s = find_session_by_token(token);
    if (!s) return 0;
    User *u = find_user_by_id(s->user_id);
    if (!u) return 0;
    if (out_user) *out_user = u;
    if (out_sess) *out_sess = s;
    return 1;
}

static json_t* todo_to_json(const Todo *t) {
    return json_pack("{s:i, s:s, s:s, s:b, s:s, s:s}",
        "id", t->id,
        "title", t->title ? t->title : "",
        "description", t->description ? t->description : "",
        "completed", t->completed ? 1 : 0,
        "created_at", t->created_at,
        "updated_at", t->updated_at
    );
}

static int handle_register(struct MHD_Connection *conn, const char *body) {
    json_error_t jerr; json_t *in = json_loads(body ? body : "", 0, &jerr);
    if (!in) return send_error(conn, 400, "Invalid JSON");
    json_t *ju = json_object_get(in, "username");
    json_t *jp = json_object_get(in, "password");
    if (!ju || !json_is_string(ju) || !username_valid(json_string_value(ju))) { json_decref(in); return send_error(conn, 400, "Invalid username"); }
    if (!jp || !json_is_string(jp) || strlen(json_string_value(jp)) < 8) { json_decref(in); return send_error(conn, 400, "Password too short"); }
    const char *username = json_string_value(ju);
    if (find_user_by_username(username)) { json_decref(in); return send_error(conn, 409, "Username already exists"); }
    ensure_users_cap();
    User u = (User){0};
    u.id = next_user_id++;
    snprintf(u.username, sizeof(u.username), "%s", username);
    u.password = strdup(json_string_value(jp));
    users[users_count++] = u;
    json_decref(in);
    json_t *out = json_pack("{s:i, s:s}", "id", u.id, "username", u.username);
    return send_json_obj(conn, 201, out, NULL);
}

static int handle_login(struct MHD_Connection *conn, const char *body) {
    json_error_t jerr; json_t *in = json_loads(body ? body : "", 0, &jerr);
    if (!in) return send_error(conn, 400, "Invalid JSON");
    json_t *ju = json_object_get(in, "username");
    json_t *jp = json_object_get(in, "password");
    if (!ju || !json_is_string(ju) || !jp || !json_is_string(jp)) { json_decref(in); return send_error(conn, 401, "Invalid credentials"); }
    const char *username = json_string_value(ju);
    const char *password = json_string_value(jp);
    User *u = find_user_by_username(username);
    if (!u || strcmp(u->password, password)!=0) { json_decref(in); return send_error(conn, 401, "Invalid credentials"); }
    ensure_sessions_cap();
    Session s = (Session){0};
    uuid_token(s.token);
    s.user_id = u->id;
    sessions[sessions_count++] = s;
    char set_cookie[256];
    snprintf(set_cookie, sizeof(set_cookie), "session_id=%s; Path=/; HttpOnly", s.token);
    json_decref(in);
    json_t *out = json_pack("{s:i, s:s}", "id", u->id, "username", u->username);
    char *dump = json_dumps(out, JSON_COMPACT);
    json_decref(out);
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(dump), (void*)dump, MHD_RESPMEM_MUST_FREE);
    if (!resp) { free(dump); return MHD_NO; }
    MHD_add_response_header(resp, "Content-Type", "application/json");
    MHD_add_response_header(resp, "Set-Cookie", set_cookie);
    int ret = MHD_queue_response(conn, 200, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int handle_logout(struct MHD_Connection *conn) {
    User *u=NULL; Session *s=NULL;
    if (!authenticate(conn, &u, &s)) return send_error(conn, 401, "Authentication required");
    delete_session_by_token(s->token);
    return send_empty_ok(conn);
}

static int handle_me(struct MHD_Connection *conn) {
    User *u=NULL; if (!authenticate(conn, &u, NULL)) return send_error(conn, 401, "Authentication required");
    json_t *out = json_pack("{s:i, s:s}", "id", u->id, "username", u->username);
    return send_json_obj(conn, 200, out, NULL);
}

static int handle_password(struct MHD_Connection *conn, const char *body) {
    User *u=NULL; if (!authenticate(conn, &u, NULL)) return send_error(conn, 401, "Authentication required");
    json_error_t jerr; json_t *in = json_loads(body ? body : "", 0, &jerr);
    if (!in) return send_error(conn, 400, "Invalid JSON");
    json_t *jo = json_object_get(in, "old_password");
    json_t *jn = json_object_get(in, "new_password");
    if (!jo || !json_is_string(jo) || strcmp(json_string_value(jo), u->password)!=0) { json_decref(in); return send_error(conn, 401, "Invalid credentials"); }
    if (!jn || !json_is_string(jn) || strlen(json_string_value(jn))<8) { json_decref(in); return send_error(conn, 400, "Password too short"); }
    free(u->password); u->password = strdup(json_string_value(jn));
    json_decref(in);
    return send_empty_ok(conn);
}

static int handle_todos_get_all(struct MHD_Connection *conn) {
    User *u=NULL; if (!authenticate(conn, &u, NULL)) return send_error(conn, 401, "Authentication required");
    json_t *arr = json_array();
    for (size_t i=0;i<todos_count;i++) if (todos[i].user_id == u->id) {
        json_t *jt = todo_to_json(&todos[i]);
        json_array_append_new(arr, jt);
    }
    return send_json_obj(conn, 200, arr, NULL);
}

static int handle_todos_create(struct MHD_Connection *conn, const char *body) {
    User *u=NULL; if (!authenticate(conn, &u, NULL)) return send_error(conn, 401, "Authentication required");
    json_error_t jerr; json_t *in = json_loads(body ? body : "", 0, &jerr);
    if (!in) return send_error(conn, 400, "Invalid JSON");
    json_t *jt = json_object_get(in, "title");
    json_t *jd = json_object_get(in, "description");
    if (!jt || !json_is_string(jt) || strlen(json_string_value(jt))==0) { json_decref(in); return send_error(conn, 400, "Title is required"); }
    const char *title = json_string_value(jt);
    const char *desc = (jd && json_is_string(jd)) ? json_string_value(jd) : "";
    ensure_todos_cap();
    Todo t = (Todo){0};
    t.id = next_todo_id++;
    t.user_id = u->id;
    t.title = strdup(title);
    t.description = strdup(desc);
    t.completed = 0;
    iso_timestamp_now(t.created_at);
    strncpy(t.updated_at, t.created_at, sizeof(t.updated_at));
    t.updated_at[20] = '\0';
    todos[todos_count++] = t;
    json_decref(in);
    json_t *out = todo_to_json(&t);
    return send_json_obj(conn, 201, out, NULL);
}

static int handle_todo_get(struct MHD_Connection *conn, int id) {
    User *u=NULL; if (!authenticate(conn, &u, NULL)) return send_error(conn, 401, "Authentication required");
    Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != u->id) return send_error(conn, 404, "Todo not found");
    json_t *out = todo_to_json(t);
    return send_json_obj(conn, 200, out, NULL);
}

static int handle_todo_update(struct MHD_Connection *conn, int id, const char *body) {
    User *u=NULL; if (!authenticate(conn, &u, NULL)) return send_error(conn, 401, "Authentication required");
    Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != u->id) return send_error(conn, 404, "Todo not found");
    json_error_t jerr; json_t *in = json_loads(body ? body : "", 0, &jerr);
    if (!in) return send_error(conn, 400, "Invalid JSON");
    json_t *jt = json_object_get(in, "title");
    json_t *jd = json_object_get(in, "description");
    json_t *jc = json_object_get(in, "completed");
    if (jt) {
        if (!json_is_string(jt) || strlen(json_string_value(jt))==0) { json_decref(in); return send_error(conn, 400, "Title is required"); }
        free(t->title); t->title = strdup(json_string_value(jt));
    }
    if (jd) {
        if (!json_is_string(jd)) { json_decref(in); return send_error(conn, 400, "Invalid JSON"); }
        free(t->description); t->description = strdup(json_string_value(jd));
    }
    if (jc) {
        if (!json_is_boolean(jc)) { json_decref(in); return send_error(conn, 400, "Invalid JSON"); }
        t->completed = json_boolean_value(jc) ? 1 : 0;
    }
    iso_timestamp_now(t->updated_at);
    json_decref(in);
    json_t *out = todo_to_json(t);
    return send_json_obj(conn, 200, out, NULL);
}

static int handle_todo_delete(struct MHD_Connection *conn, int id) {
    User *u=NULL; if (!authenticate(conn, &u, NULL)) return send_error(conn, 401, "Authentication required");
    for (size_t i=0;i<todos_count;i++) {
        if (todos[i].id == id) {
            if (todos[i].user_id != u->id) return send_error(conn, 404, "Todo not found");
            free(todos[i].title); free(todos[i].description);
            if (i+1 < todos_count) memmove(&todos[i], &todos[i+1], (todos_count-i-1)*sizeof(Todo));
            todos_count--;
            return send_204(conn);
        }
    }
    return send_error(conn, 404, "Todo not found");
}

static int parse_todo_id(const char *path) {
    const char *prefix = "/todos/";
    size_t plen = strlen(prefix); // 7
    if (strncmp(path, prefix, plen)!=0) return -1;
    const char *p = path + plen;
    if (!*p) return -1;
    long v = 0;
    while (*p && isdigit((unsigned char)*p)) {
        v = v*10 + (*p - '0');
        p++;
    }
    if (v <= 0) return -1;
    return (int)v;
}

static enum MHD_Result ahc(void *cls, struct MHD_Connection *connection,
                  const char *url, const char *method,
                  const char *version, const char *upload_data,
                  size_t *upload_data_size, void **con_cls) {
    (void)cls; (void)version;
    struct ReqCtx *ctx = *con_cls;
    if (!ctx) {
        ctx = calloc(1, sizeof(*ctx));
        *con_cls = ctx;
        return MHD_YES;
    }

    if ((strcmp(method, "POST")==0 || strcmp(method, "PUT")==0)) {
        if (*upload_data_size) {
            if (!ensure_body_capacity(ctx, *upload_data_size)) {
                *upload_data_size = 0;
                return send_error(connection, 413, "Payload too large");
            }
            if (!ctx->body_cap) {
                if (!ensure_body_capacity(ctx, 0)) {
                    *upload_data_size = 0;
                    return send_error(connection, 500, "Internal error");
                }
            }
            memcpy(ctx->body + ctx->body_len, upload_data, *upload_data_size);
            ctx->body_len += *upload_data_size;
            ctx->body[ctx->body_len] = '\0';
            *upload_data_size = 0;
            return MHD_YES;
        }
    }

    int ret = MHD_NO;
    const char *body = (ctx->body ? ctx->body : "");

    if (strcmp(method, "POST")==0 && strcmp(url, "/register")==0) {
        ret = handle_register(connection, body);
    } else if (strcmp(method, "POST")==0 && strcmp(url, "/login")==0) {
        ret = handle_login(connection, body);
    } else if (strcmp(method, "POST")==0 && strcmp(url, "/logout")==0) {
        ret = handle_logout(connection);
    } else if (strcmp(method, "GET")==0 && strcmp(url, "/me")==0) {
        ret = handle_me(connection);
    } else if (strcmp(method, "PUT")==0 && strcmp(url, "/password")==0) {
        ret = handle_password(connection, body);
    } else if (strncmp(url, "/todos", 6)==0) {
        if (strcmp(url, "/todos")==0) {
            if (strcmp(method, "GET")==0) ret = handle_todos_get_all(connection);
            else if (strcmp(method, "POST")==0) ret = handle_todos_create(connection, body);
            else ret = send_error(connection, 404, "Not found");
        } else {
            int id = parse_todo_id(url);
            if (id <= 0) {
                ret = send_error(connection, 404, "Not found");
            } else {
                if (strcmp(method, "GET")==0) ret = handle_todo_get(connection, id);
                else if (strcmp(method, "PUT")==0) ret = handle_todo_update(connection, id, body);
                else if (strcmp(method, "DELETE")==0) ret = handle_todo_delete(connection, id);
                else ret = send_error(connection, 404, "Not found");
            }
        }
    } else {
        ret = send_error(connection, 404, "Not found");
    }

    if (ctx) { free(ctx->body); free(ctx); *con_cls = NULL; }
    return ret;
}

int main(int argc, char *argv[]) {
    for (int i=1;i<argc;i++) {
        if (strcmp(argv[i], "--port")==0 && i+1<argc) {
            server_port = atoi(argv[++i]);
        }
    }

    struct MHD_Daemon *daemon = MHD_start_daemon(
        MHD_USE_INTERNAL_POLLING_THREAD,
        server_port,
        NULL, NULL,
        &ahc, NULL,
        MHD_OPTION_LISTENING_ADDRESS_REUSE, 1,
        MHD_OPTION_END);

    if (!daemon) {
        fprintf(stderr, "Failed to start server on port %d\n", server_port);
        return 1;
    }
    printf("Server listening on 0.0.0.0:%d\n", server_port);
    fflush(stdout);
    while (1) {
        struct timespec ts = { .tv_sec = 1, .tv_nsec = 0 };
        nanosleep(&ts, NULL);
    }
    MHD_stop_daemon(daemon);
    return 0;
}

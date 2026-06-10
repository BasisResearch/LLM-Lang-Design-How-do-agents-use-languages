#define _GNU_SOURCE
#include <microhttpd.h>
#include <jansson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>
#include <time.h>
#include <errno.h>
#include <stdint.h>
#include <stdatomic.h>
#include <signal.h>
#include <arpa/inet.h>

#define MAX_USERS 1024
#define MAX_TODOS 8192
#define MAX_SESSIONS 2048

#define CONTENT_TYPE_JSON "application/json"

// Data structures

typedef struct {
    int id;
    char username[64];
    char password[128];
    int active; // 1 if in use
} User;

typedef struct {
    int id;
    int user_id;
    char title[256];
    char description[1024];
    int completed; // 0/1
    char created_at[21]; // YYYY-MM-DDTHH:MM:SSZ\0
    char updated_at[21];
    int active;
} Todo;

typedef struct {
    char token[65]; // 32 bytes hex or 64 hex; we use 64 hex
    int user_id;
    int active;
} Session;

static User users[MAX_USERS];
static Todo todos[MAX_TODOS];
static Session sessions[MAX_SESSIONS];
static atomic_int next_user_id = 1;
static atomic_int next_todo_id = 1;

// Utility: time formatting
static void iso8601_utc_now(char out[21]) {
    time_t t = time(NULL);
    struct tm gm;
    gmtime_r(&t, &gm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &gm);
}

// Utility: hex encoding
static void to_hex(const unsigned char *in, size_t len, char *out) {
    static const char *hex = "0123456789abcdef";
    for (size_t i = 0; i < len; ++i) {
        out[2*i] = hex[(in[i] >> 4) & 0xF];
        out[2*i+1] = hex[in[i] & 0xF];
    }
    out[2*len] = '\0';
}

static int secure_random(unsigned char *buf, size_t len) {
    FILE *f = fopen("/dev/urandom", "rb");
    if (!f) return -1;
    size_t r = fread(buf, 1, len, f);
    fclose(f);
    return (r == len) ? 0 : -1;
}

static void gen_token(char token_out[65]) {
    unsigned char rnd[32];
    if (secure_random(rnd, sizeof(rnd)) != 0) {
        // fallback to rand (should not happen)
        for (size_t i = 0; i < sizeof(rnd); ++i) rnd[i] = (unsigned char)rand();
    }
    to_hex(rnd, sizeof(rnd), token_out);
}

// Validation helpers
static int valid_username(const char *u) {
    if (!u) return 0;
    size_t n = strlen(u);
    if (n < 3 || n > 50) return 0;
    for (size_t i = 0; i < n; ++i) {
        char c = u[i];
        if (!(isalnum((unsigned char)c) || c == '_')) return 0;
    }
    return 1;
}

// Simple password policy: length check only
static int valid_password(const char *p) {
    if (!p) return 0;
    return strlen(p) >= 8;
}

// Data management helpers
static User* find_user_by_username(const char *username) {
    for (int i = 0; i < MAX_USERS; ++i) {
        if (users[i].active && strcmp(users[i].username, username) == 0) return &users[i];
    }
    return NULL;
}

static User* find_user_by_id(int id) {
    for (int i = 0; i < MAX_USERS; ++i) {
        if (users[i].active && users[i].id == id) return &users[i];
    }
    return NULL;
}

static Session* find_session(const char *token) {
    if (!token) return NULL;
    for (int i = 0; i < MAX_SESSIONS; ++i) {
        if (sessions[i].active && strcmp(sessions[i].token, token) == 0) return &sessions[i];
    }
    return NULL;
}

static Session* create_session(int user_id) {
    // Reuse inactive slots
    for (int i = 0; i < MAX_SESSIONS; ++i) {
        if (!sessions[i].active) {
            sessions[i].active = 1;
            sessions[i].user_id = user_id;
            gen_token(sessions[i].token);
            return &sessions[i];
        }
    }
    // If full, overwrite a random slot (simple policy)
    int idx = rand() % MAX_SESSIONS;
    sessions[idx].active = 1;
    sessions[idx].user_id = user_id;
    gen_token(sessions[idx].token);
    return &sessions[idx];
}

static void invalidate_session_token(const char *token) {
    Session *s = find_session(token);
    if (s) s->active = 0;
}

static int extract_session_user(struct MHD_Connection *conn, int *out_user_id) {
    const char *cookie = MHD_lookup_connection_value(conn, MHD_HEADER_KIND, MHD_HTTP_HEADER_COOKIE);
    if (!cookie) return 0;
    // parse simple cookies
    const char *p = cookie;
    while (p && *p) {
        while (*p == ' ') p++;
        if (strncmp(p, "session_id=", 11) == 0) {
            p += 11;
            const char *end = strchr(p, ';');
            size_t len = end ? (size_t)(end - p) : strlen(p);
            char token[129];
            if (len >= sizeof(token)) len = sizeof(token)-1;
            memcpy(token, p, len);
            token[len] = '\0';
            Session *s = find_session(token);
            if (s && s->active) {
                *out_user_id = s->user_id;
                return 1;
            } else {
                return 0;
            }
        }
        const char *sc = strchr(p, ';');
        if (!sc) break;
        p = sc + 1;
    }
    return 0;
}

static Todo* find_todo_by_id(int id) {
    for (int i = 0; i < MAX_TODOS; ++i) {
        if (todos[i].active && todos[i].id == id) return &todos[i];
    }
    return NULL;
}

// HTTP helpers
struct RequestContext {
    char *body;
    size_t size;
};

static enum MHD_Result send_json(struct MHD_Connection *conn, unsigned int status_code, const char *json_str, const char *set_cookie) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(json_str), (void*)json_str, MHD_RESPMEM_MUST_COPY);
    if (!resp) return MHD_NO;
    MHD_add_response_header(resp, MHD_HTTP_HEADER_CONTENT_TYPE, CONTENT_TYPE_JSON);
    if (set_cookie) {
        MHD_add_response_header(resp, MHD_HTTP_HEADER_SET_COOKIE, set_cookie);
    }
    enum MHD_Result ret = MHD_queue_response(conn, status_code, resp);
    MHD_destroy_response(resp);
    return ret;
}

static enum MHD_Result send_json_obj(struct MHD_Connection *conn, unsigned int status_code, json_t *obj, const char *set_cookie) {
    char *dump = json_dumps(obj, JSON_COMPACT);
    enum MHD_Result r = send_json(conn, status_code, dump, set_cookie);
    free(dump);
    return r;
}

static enum MHD_Result send_error(struct MHD_Connection *conn, unsigned int status_code, const char *msg) {
    json_t *o = json_object();
    json_object_set_new(o, "error", json_string(msg));
    enum MHD_Result r = send_json_obj(conn, status_code, o, NULL);
    json_decref(o);
    return r;
}

static enum MHD_Result send_no_content(struct MHD_Connection *conn, unsigned int status_code) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
    if (!resp) return MHD_NO;
    enum MHD_Result ret = MHD_queue_response(conn, status_code, resp);
    MHD_destroy_response(resp);
    return ret;
}

static enum MHD_Result require_auth(struct MHD_Connection *conn, int *out_user_id) {
    if (!extract_session_user(conn, out_user_id)) {
        return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    }
    return (enum MHD_Result)0; // sentinel meaning continue
}

// Endpoint handlers
static enum MHD_Result handle_register(struct MHD_Connection *conn, struct RequestContext *ctx) {
    json_error_t jerr;
    json_t *root = json_loadb(ctx->body ? ctx->body : "", ctx->size, 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    json_t *ju = json_object_get(root, "username");
    json_t *jp = json_object_get(root, "password");
    const char *username = json_is_string(ju) ? json_string_value(ju) : NULL;
    const char *password = json_is_string(jp) ? json_string_value(jp) : NULL;

    if (!valid_username(username)) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }
    if (!valid_password(password)) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    if (find_user_by_username(username)) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_CONFLICT, "Username already exists");
    }
    // create user
    for (int i = 0; i < MAX_USERS; ++i) {
        if (!users[i].active) {
            users[i].active = 1;
            users[i].id = atomic_fetch_add(&next_user_id, 1);
            snprintf(users[i].username, sizeof(users[i].username), "%s", username);
            snprintf(users[i].password, sizeof(users[i].password), "%s", password);
            json_t *o = json_object();
            json_object_set_new(o, "id", json_integer(users[i].id));
            json_object_set_new(o, "username", json_string(users[i].username));
            enum MHD_Result r = send_json_obj(conn, MHD_HTTP_CREATED, o, NULL);
            json_decref(o);
            json_decref(root);
            return r;
        }
    }
    json_decref(root);
    return send_error(conn, MHD_HTTP_INTERNAL_SERVER_ERROR, "User storage full");
}

static enum MHD_Result handle_login(struct MHD_Connection *conn, struct RequestContext *ctx) {
    json_error_t jerr;
    json_t *root = json_loadb(ctx->body ? ctx->body : "", ctx->size, 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    const char *username = NULL, *password = NULL;
    json_t *ju = json_object_get(root, "username");
    json_t *jp = json_object_get(root, "password");
    if (json_is_string(ju)) username = json_string_value(ju);
    if (json_is_string(jp)) password = json_string_value(jp);
    User *u = find_user_by_username(username);
    if (!u || strcmp(u->password, password ? password : "") != 0) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    Session *s = create_session(u->id);
    char set_cookie[256];
    snprintf(set_cookie, sizeof(set_cookie), "session_id=%s; Path=/; HttpOnly", s->token);

    json_t *o = json_object();
    json_object_set_new(o, "id", json_integer(u->id));
    json_object_set_new(o, "username", json_string(u->username));
    enum MHD_Result r = send_json_obj(conn, MHD_HTTP_OK, o, set_cookie);
    json_decref(o);
    json_decref(root);
    return r;
}

static enum MHD_Result handle_logout(struct MHD_Connection *conn) {
    // Extract cookie and invalidate
    const char *cookie = MHD_lookup_connection_value(conn, MHD_HEADER_KIND, MHD_HTTP_HEADER_COOKIE);
    if (cookie) {
        const char *p = strstr(cookie, "session_id=");
        if (p) {
            p += 11;
            const char *end = strchr(p, ';');
            size_t len = end ? (size_t)(end - p) : strlen(p);
            char token[129];
            if (len >= sizeof(token)) len = sizeof(token)-1;
            memcpy(token, p, len);
            token[len] = '\0';
            invalidate_session_token(token);
        }
    }
    json_t *o = json_object();
    enum MHD_Result r = send_json_obj(conn, MHD_HTTP_OK, o, NULL);
    json_decref(o);
    return r;
}

static enum MHD_Result handle_me(struct MHD_Connection *conn, int user_id) {
    User *u = find_user_by_id(user_id);
    if (!u) {
        return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    }
    json_t *o = json_object();
    json_object_set_new(o, "id", json_integer(u->id));
    json_object_set_new(o, "username", json_string(u->username));
    enum MHD_Result r = send_json_obj(conn, MHD_HTTP_OK, o, NULL);
    json_decref(o);
    return r;
}

static enum MHD_Result handle_password(struct MHD_Connection *conn, int user_id, struct RequestContext *ctx) {
    User *u = find_user_by_id(user_id);
    if (!u) return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");

    json_error_t jerr;
    json_t *root = json_loadb(ctx->body ? ctx->body : "", ctx->size, 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    const char *oldp = NULL, *newp = NULL;
    json_t *jo = json_object_get(root, "old_password");
    json_t *jn = json_object_get(root, "new_password");
    if (json_is_string(jo)) oldp = json_string_value(jo);
    if (json_is_string(jn)) newp = json_string_value(jn);

    if (!oldp || strcmp(oldp, u->password) != 0) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    if (!valid_password(newp)) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    snprintf(u->password, sizeof(u->password), "%s", newp);
    json_t *o = json_object();
    enum MHD_Result r = send_json_obj(conn, MHD_HTTP_OK, o, NULL);
    json_decref(o);
    json_decref(root);
    return r;
}

static void todo_to_json(const Todo *t, json_t *obj) {
    json_object_set_new(obj, "id", json_integer(t->id));
    json_object_set_new(obj, "title", json_string(t->title));
    json_object_set_new(obj, "description", json_string(t->description));
    json_object_set_new(obj, "completed", json_boolean(t->completed));
    json_object_set_new(obj, "created_at", json_string(t->created_at));
    json_object_set_new(obj, "updated_at", json_string(t->updated_at));
}

static int cmp_int_asc(const void *a, const void *b) {
    int ia = *(const int*)a;
    int ib = *(const int*)b;
    return (ia > ib) - (ia < ib);
}

static enum MHD_Result handle_todos_list(struct MHD_Connection *conn, int user_id) {
    // Collect IDs and sort by id ascending
    int ids[MAX_TODOS];
    int count = 0;
    for (int i = 0; i < MAX_TODOS; ++i) {
        if (todos[i].active && todos[i].user_id == user_id) {
            ids[count++] = todos[i].id;
        }
    }
    qsort(ids, count, sizeof(int), cmp_int_asc);

    json_t *arr = json_array();
    for (int j = 0; j < count; ++j) {
        Todo *t = find_todo_by_id(ids[j]);
        if (t && t->active && t->user_id == user_id) {
            json_t *o = json_object();
            todo_to_json(t, o);
            json_array_append_new(arr, o);
        }
    }
    enum MHD_Result r;
    char *dump = json_dumps(arr, JSON_COMPACT);
    r = send_json(conn, MHD_HTTP_OK, dump, NULL);
    free(dump);
    json_decref(arr);
    return r;
}

static enum MHD_Result handle_todos_create(struct MHD_Connection *conn, int user_id, struct RequestContext *ctx) {
    json_error_t jerr;
    json_t *root = json_loadb(ctx->body ? ctx->body : "", ctx->size, 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    const char *title = NULL; const char *desc = "";
    json_t *jt = json_object_get(root, "title");
    json_t *jd = json_object_get(root, "description");
    if (json_is_string(jt)) title = json_string_value(jt);
    if (json_is_string(jd)) desc = json_string_value(jd);

    if (!title || strlen(title) == 0) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required");
    }

    for (int i = 0; i < MAX_TODOS; ++i) {
        if (!todos[i].active) {
            todos[i].active = 1;
            todos[i].id = atomic_fetch_add(&next_todo_id, 1);
            todos[i].user_id = user_id;
            snprintf(todos[i].title, sizeof(todos[i].title), "%s", title);
            snprintf(todos[i].description, sizeof(todos[i].description), "%s", desc ? desc : "");
            todos[i].completed = 0;
            iso8601_utc_now(todos[i].created_at);
            memcpy(todos[i].updated_at, todos[i].created_at, sizeof(todos[i].updated_at));

            json_t *o = json_object();
            todo_to_json(&todos[i], o);
            enum MHD_Result r = send_json_obj(conn, MHD_HTTP_CREATED, o, NULL);
            json_decref(o);
            json_decref(root);
            return r;
        }
    }
    json_decref(root);
    return send_error(conn, MHD_HTTP_INTERNAL_SERVER_ERROR, "Todo storage full");
}

static enum MHD_Result handle_todo_get(struct MHD_Connection *conn, int user_id, int id) {
    Todo *t = find_todo_by_id(id);
    if (!t || !t->active || t->user_id != user_id) {
        return send_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    json_t *o = json_object();
    todo_to_json(t, o);
    enum MHD_Result r = send_json_obj(conn, MHD_HTTP_OK, o, NULL);
    json_decref(o);
    return r;
}

static enum MHD_Result handle_todo_update(struct MHD_Connection *conn, int user_id, int id, struct RequestContext *ctx) {
    Todo *t = find_todo_by_id(id);
    if (!t || !t->active || t->user_id != user_id) {
        return send_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    json_error_t jerr;
    json_t *root = json_loadb(ctx->body ? ctx->body : "", ctx->size, 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }

    json_t *jt = json_object_get(root, "title");
    json_t *jd = json_object_get(root, "description");
    json_t *jc = json_object_get(root, "completed");

    if (jt && json_is_string(jt)) {
        const char *title = json_string_value(jt);
        if (!title || strlen(title) == 0) {
            json_decref(root);
            return send_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required");
        }
        snprintf(t->title, sizeof(t->title), "%s", title);
    } else if (jt) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }

    if (jd && json_is_string(jd)) {
        const char *desc = json_string_value(jd);
        snprintf(t->description, sizeof(t->description), "%s", desc ? desc : "");
    } else if (jd) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }

    if (jc && json_is_boolean(jc)) {
        t->completed = json_is_true(jc) ? 1 : 0;
    } else if (jc) {
        json_decref(root);
        return send_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }

    iso8601_utc_now(t->updated_at);

    json_t *o = json_object();
    todo_to_json(t, o);
    enum MHD_Result r = send_json_obj(conn, MHD_HTTP_OK, o, NULL);
    json_decref(o);
    json_decref(root);
    return r;
}

static enum MHD_Result handle_todo_delete(struct MHD_Connection *conn, int user_id, int id) {
    Todo *t = find_todo_by_id(id);
    if (!t || !t->active || t->user_id != user_id) {
        return send_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    t->active = 0;
    return send_no_content(conn, MHD_HTTP_NO_CONTENT);
}

// Router
static enum MHD_Result request_handler(void *cls, struct MHD_Connection *connection,
                           const char *url, const char *method,
                           const char *version, const char *upload_data,
                           size_t *upload_data_size, void **con_cls)
{
    (void)cls; (void)version;
    struct RequestContext *ctx = *con_cls;
    if (!ctx) {
        ctx = calloc(1, sizeof(*ctx));
        *con_cls = ctx;
        return MHD_YES;
    }

    // accumulate upload data for POST/PUT
    if (*upload_data_size) {
        size_t old = ctx->size;
        ctx->size += *upload_data_size;
        ctx->body = realloc(ctx->body, ctx->size + 1);
        memcpy(ctx->body + old, upload_data, *upload_data_size);
        ctx->body[ctx->size] = '\0';
        *upload_data_size = 0;
        return MHD_YES;
    }

    enum MHD_Result ret = MHD_NO;

    // Route dispatch
    if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(url, "/register") == 0) {
        ret = handle_register(connection, ctx);
    } else if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(url, "/login") == 0) {
        ret = handle_login(connection, ctx);
    } else if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(url, "/logout") == 0) {
        int uid; enum MHD_Result e = require_auth(connection, &uid); if (e) ret = e; else ret = handle_logout(connection);
    } else if (strcmp(method, MHD_HTTP_METHOD_GET) == 0 && strcmp(url, "/me") == 0) {
        int uid; enum MHD_Result e = require_auth(connection, &uid); if (e) ret = e; else ret = handle_me(connection, uid);
    } else if (strcmp(method, MHD_HTTP_METHOD_PUT) == 0 && strcmp(url, "/password") == 0) {
        int uid; enum MHD_Result e = require_auth(connection, &uid); if (e) ret = e; else ret = handle_password(connection, uid, ctx);
    } else if (strncmp(url, "/todos", 6) == 0) {
        // Auth required for all /todos*
        int uid; enum MHD_Result e = require_auth(connection, &uid); if (e) ret = e; else {
            if (strcmp(url, "/todos") == 0) {
                if (strcmp(method, MHD_HTTP_METHOD_GET) == 0) ret = handle_todos_list(connection, uid);
                else if (strcmp(method, MHD_HTTP_METHOD_POST) == 0) ret = handle_todos_create(connection, uid, ctx);
                else ret = send_error(connection, MHD_HTTP_METHOD_NOT_ALLOWED, "Method not allowed");
            } else if (strncmp(url, "/todos/", 7) == 0) {
                const char *idstr = url + 7;
                char *endp = NULL;
                long idl = strtol(idstr, &endp, 10);
                if (idstr[0] == '\0' || *endp != '\0' || idl <= 0 || idl > INT32_MAX) {
                    ret = send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
                } else {
                    int id = (int)idl;
                    if (strcmp(method, MHD_HTTP_METHOD_GET) == 0) ret = handle_todo_get(connection, uid, id);
                    else if (strcmp(method, MHD_HTTP_METHOD_PUT) == 0) ret = handle_todo_update(connection, uid, id, ctx);
                    else if (strcmp(method, MHD_HTTP_METHOD_DELETE) == 0) ret = handle_todo_delete(connection, uid, id);
                    else ret = send_error(connection, MHD_HTTP_METHOD_NOT_ALLOWED, "Method not allowed");
                }
            } else {
                ret = send_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
            }
        }
    } else if (strcmp(method, MHD_HTTP_METHOD_GET) == 0 && strcmp(url, "/") == 0) {
        json_t *o = json_object();
        json_object_set_new(o, "status", json_string("ok"));
        ret = send_json_obj(connection, MHD_HTTP_OK, o, NULL);
        json_decref(o);
    } else {
        ret = send_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
    }

    if (ctx) {
        free(ctx->body);
        free(ctx);
        *con_cls = NULL;
    }
    return ret;
}

static void request_completed(void *cls, struct MHD_Connection *connection, void **con_cls,
                              enum MHD_RequestTerminationCode toe) {
    (void)cls; (void)connection; (void)toe;
    if (con_cls && *con_cls) {
        struct RequestContext *ctx = *con_cls;
        free(ctx->body);
        free(ctx);
        *con_cls = NULL;
    }
}

static volatile sig_atomic_t stop_flag = 0;
static void handle_sigint(int sig) { (void)sig; stop_flag = 1; }

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--port") == 0 && i+1 < argc) {
            port = atoi(argv[++i]);
        }
    }

    signal(SIGINT, handle_sigint);
    signal(SIGTERM, handle_sigint);

    static struct sockaddr_in bind_addr; // static to ensure lifetime
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_addr.s_addr = htonl(INADDR_ANY); // 0.0.0.0
    bind_addr.sin_port = htons((uint16_t)port);

    struct MHD_Daemon *d = MHD_start_daemon(MHD_USE_INTERNAL_POLLING_THREAD, port,
                                            NULL, NULL,
                                            &request_handler, NULL,
                                            MHD_OPTION_SOCK_ADDR, (struct sockaddr*)&bind_addr,
                                            MHD_OPTION_CONNECTION_TIMEOUT, (unsigned int)120,
                                            MHD_OPTION_NOTIFY_COMPLETED, request_completed, NULL,
                                            MHD_OPTION_END);
    if (!d) {
        fprintf(stderr, "Failed to start server on 0.0.0.0:%d\n", port);
        return 1;
    }
    printf("Server listening on 0.0.0.0:%d\n", port);

    while (!stop_flag) {
        sleep(1);
    }

    MHD_stop_daemon(d);
    return 0;
}

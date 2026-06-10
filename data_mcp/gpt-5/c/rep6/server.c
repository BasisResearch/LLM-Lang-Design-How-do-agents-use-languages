#define _GNU_SOURCE
#include <microhttpd.h>
#include <jansson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>

#define MAX_BODY_SIZE (1024*1024)

typedef struct {
    int id;
    char *username;
    char *password; // stored as plain text for simplicity
} User;

typedef struct {
    char *token; // session token (hex)
    int user_id;
} Session;

typedef struct {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0 or 1
    char created_at[21]; // YYYY-MM-DDTHH:MM:SSZ\0
    char updated_at[21];
} Todo;

static User *users = NULL; static size_t users_len = 0; static size_t users_cap = 0; static int next_user_id = 1;
static Session *sessions = NULL; static size_t sessions_len = 0; static size_t sessions_cap = 0;
static Todo *todos = NULL; static size_t todos_len = 0; static size_t todos_cap = 0; static int next_todo_id = 1;

static void json_response_headers(struct MHD_Response *resp, int status) {
    (void)status; // not used, but kept for potential future
    MHD_add_response_header(resp, MHD_HTTP_HEADER_CONTENT_TYPE, "application/json");
}

static enum MHD_Result send_json(struct MHD_Connection *connection, unsigned int status_code, json_t *obj) {
    char *dump = json_dumps(obj, JSON_COMPACT);
    if (!dump) dump = strdup("{}\n");
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(dump), (void*)dump, MHD_RESPMEM_MUST_FREE);
    if (!resp) { free(dump); return MHD_NO; }
    json_response_headers(resp, (int)status_code);
    enum MHD_Result ret = MHD_queue_response(connection, status_code, resp);
    MHD_destroy_response(resp);
    return ret;
}

static enum MHD_Result send_json_error(struct MHD_Connection *connection, unsigned int status_code, const char *message) {
    json_t *obj = json_object();
    json_object_set_new(obj, "error", json_string(message));
    enum MHD_Result ret = send_json(connection, status_code, obj);
    json_decref(obj);
    return ret;
}

static enum MHD_Result send_empty_no_content(struct MHD_Connection *connection) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
    if (!resp) return MHD_NO;
    enum MHD_Result ret = MHD_queue_response(connection, MHD_HTTP_NO_CONTENT, resp);
    MHD_destroy_response(resp);
    return ret;
}

static void ensure_capacity(void **arr, size_t *cap, size_t elem_size, size_t min_cap) {
    if (*cap >= min_cap) return;
    size_t new_cap = (*cap == 0) ? 8 : *cap;
    while (new_cap < min_cap) new_cap *= 2;
    void *new_arr = realloc(*arr, new_cap * elem_size);
    if (!new_arr) { perror("realloc"); exit(1);} 
    *arr = new_arr; *cap = new_cap;
}

static int username_valid(const char *u) {
    size_t len = strlen(u);
    if (len < 3 || len > 50) return 0;
    for (size_t i=0;i<len;i++){
        char c = u[i];
        if (!(isalnum((unsigned char)c) || c=='_')) return 0;
    }
    return 1;
}

static void fill_iso8601_utc(char out[21]) {
    time_t t = time(NULL);
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

static char *gen_token_hex(size_t nbytes) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return NULL;
    unsigned char *buf = malloc(nbytes);
    if (!buf) { close(fd); return NULL; }
    ssize_t r = read(fd, buf, nbytes);
    close(fd);
    if (r != (ssize_t)nbytes) { free(buf); return NULL; }
    static const char hex[] = "0123456789abcdef";
    char *out = malloc(nbytes*2 + 1);
    if (!out) { free(buf); return NULL; }
    for (size_t i=0;i<nbytes;i++){
        out[i*2] = hex[(buf[i]>>4) & 0xF];
        out[i*2+1] = hex[buf[i] & 0xF];
    }
    out[nbytes*2] = '\0';
    free(buf);
    return out;
}

static User* find_user_by_username(const char *username) {
    for (size_t i=0;i<users_len;i++) {
        if (users[i].username && strcmp(users[i].username, username)==0) return &users[i];
    }
    return NULL;
}

static User* find_user_by_id(int id) {
    for (size_t i=0;i<users_len;i++) {
        if (users[i].id == id) return &users[i];
    }
    return NULL;
}

static Session* find_session_by_token(const char *token) {
    for (size_t i=0;i<sessions_len;i++) {
        if (sessions[i].token && strcmp(sessions[i].token, token)==0) return &sessions[i];
    }
    return NULL;
}

static int remove_session_by_token(const char *token) {
    for (size_t i=0;i<sessions_len;i++) {
        if (sessions[i].token && strcmp(sessions[i].token, token)==0) {
            free(sessions[i].token);
            // move last into i
            if (i != sessions_len-1) sessions[i] = sessions[sessions_len-1];
            sessions_len--;
            return 1;
        }
    }
    return 0;
}

static Todo* find_todo_by_id(int id) {
    for (size_t i=0;i<todos_len;i++) {
        if (todos[i].id == id) return &todos[i];
    }
    return NULL;
}

static json_t* user_to_json(const User *u) {
    json_t *o = json_object();
    json_object_set_new(o, "id", json_integer(u->id));
    json_object_set_new(o, "username", json_string(u->username));
    return o;
}

static json_t* todo_to_json(const Todo *t) {
    json_t *o = json_object();
    json_object_set_new(o, "id", json_integer(t->id));
    json_object_set_new(o, "title", json_string(t->title));
    json_object_set_new(o, "description", json_string(t->description ? t->description : ""));
    json_object_set_new(o, "completed", json_boolean(t->completed));
    json_object_set_new(o, "created_at", json_string(t->created_at));
    json_object_set_new(o, "updated_at", json_string(t->updated_at));
    return o;
}

static const char* get_cookie_value(const char *cookie_header, const char *name) {
    if (!cookie_header || !name) return NULL;
    size_t name_len = strlen(name);
    const char *p = cookie_header;
    while (*p) {
        while (*p==' ' || *p==';') p++;
        if (!*p) break;
        const char *eq = strchr(p, '=');
        if (!eq) break;
        size_t key_len = (size_t)(eq - p);
        const char *val_start = eq + 1;
        const char *val_end = strchr(val_start, ';');
        if (!val_end) val_end = p + strlen(p);
        if (key_len == name_len && strncmp(p, name, key_len)==0) {
            size_t vlen = (size_t)(val_end - val_start);
            char *value = (char*)malloc(vlen+1);
            if (!value) return NULL;
            memcpy(value, val_start, vlen); value[vlen]='\0';
            // caller must free
            return value;
        }
        p = val_end;
    }
    return NULL;
}

static int get_authenticated_user(struct MHD_Connection *connection, User **out_user, char **out_token) {
    const char *cookie = MHD_lookup_connection_value(connection, MHD_HEADER_KIND, MHD_HTTP_HEADER_COOKIE);
    char *token = NULL;
    if (cookie) {
        const char *tmp = get_cookie_value(cookie, "session_id");
        token = (char*)tmp; // malloced
    }
    if (!token) {
        if (out_token) *out_token = NULL;
        *out_user = NULL;
        return 0;
    }
    Session *s = find_session_by_token(token);
    if (!s) {
        if (out_token) *out_token = token; else free(token);
        *out_user = NULL;
        return 0;
    }
    User *u = find_user_by_id(s->user_id);
    if (!u) {
        if (out_token) *out_token = token; else free(token);
        *out_user = NULL;
        return 0;
    }
    *out_user = u;
    if (out_token) *out_token = token; else free(token);
    return 1;
}

struct RequestContext {
    char *body;
    size_t size;
    size_t cap;
};

static int add_body_data(struct RequestContext *ctx, const char *data, size_t size) {
    if (ctx->size + size > MAX_BODY_SIZE) return 0;
    if (ctx->size + size + 1 > ctx->cap) {
        size_t newcap = ctx->cap ? ctx->cap * 2 : 4096;
        while (newcap < ctx->size + size + 1) newcap *= 2;
        char *nb = realloc(ctx->body, newcap);
        if (!nb) return 0;
        ctx->body = nb;
        ctx->cap = newcap;
    }
    memcpy(ctx->body + ctx->size, data, size);
    ctx->size += size; ctx->body[ctx->size] = '\0';
    return 1;
}

static int parse_id_from_path(const char *url, const char *prefix) {
    size_t prelen = strlen(prefix);
    if (strncmp(url, prefix, prelen) != 0) return -1;
    const char *p = url + prelen;
    if (*p == '\0') return -1;
    char *endptr=NULL;
    long v = strtol(p, &endptr, 10);
    if (endptr == p || v <= 0) return -1;
    if (*endptr != '\0') return -1;
    return (int)v;
}

static enum MHD_Result route_register(struct MHD_Connection *connection, json_t *body) {
    if (!json_is_object(body)) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    json_t *ju = json_object_get(body, "username");
    json_t *jp = json_object_get(body, "password");
    if (!ju || !json_is_string(ju) || !username_valid(json_string_value(ju))) {
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }
    if (!jp || !json_is_string(jp) || strlen(json_string_value(jp)) < 8) {
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    const char *username = json_string_value(ju);
    if (find_user_by_username(username)) {
        return send_json_error(connection, MHD_HTTP_CONFLICT, "Username already exists");
    }
    ensure_capacity((void**)&users, &users_cap, sizeof(User), users_len+1);
    User u; u.id = next_user_id++; u.username = strdup(username); u.password = strdup(json_string_value(jp));
    if (!u.username || !u.password) { perror("strdup"); exit(1);} 
    users[users_len++] = u;
    json_t *out = user_to_json(&users[users_len-1]);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_CREATED, out);
    json_decref(out);
    return ret;
}

static enum MHD_Result route_login(struct MHD_Connection *connection, json_t *body) {
    if (!json_is_object(body)) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    json_t *ju = json_object_get(body, "username");
    json_t *jp = json_object_get(body, "password");
    if (!ju || !json_is_string(ju) || !jp || !json_is_string(jp)) {
        return send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    const char *username = json_string_value(ju);
    const char *password = json_string_value(jp);
    User *u = find_user_by_username(username);
    if (!u || strcmp(u->password, password) != 0) {
        return send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    // create session
    char *token = gen_token_hex(16);
    if (!token) return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Internal error");
    ensure_capacity((void**)&sessions, &sessions_cap, sizeof(Session), sessions_len+1);
    Session s; s.token = token; s.user_id = u->id;
    sessions[sessions_len++] = s;
    json_t *out = user_to_json(u);
    char cookie_header[256];
    snprintf(cookie_header, sizeof(cookie_header), "session_id=%s; Path=/; HttpOnly", token);
    char *dump = json_dumps(out, JSON_COMPACT);
    if (!dump) dump = strdup("{}\n");
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(dump), (void*)dump, MHD_RESPMEM_MUST_FREE);
    if (!resp) { json_decref(out); free(dump); return MHD_NO; }
    json_response_headers(resp, MHD_HTTP_OK);
    MHD_add_response_header(resp, MHD_HTTP_HEADER_SET_COOKIE, cookie_header);
    enum MHD_Result ret = MHD_queue_response(connection, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    json_decref(out);
    return ret;
}

static int require_auth(struct MHD_Connection *connection, User **out_user, char **out_token) {
    User *u=NULL; char *tok=NULL;
    int ok = get_authenticated_user(connection, &u, &tok);
    if (!ok || !u) {
        if (tok) free(tok);
        (void)out_user; (void)out_token;
        send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
        return 0; // indicate failure already responded
    }
    if (out_user) *out_user = u;
    if (out_token) *out_token = tok; else if (tok) free(tok);
    return 1; // success
}

static enum MHD_Result route_logout(struct MHD_Connection *connection) {
    User *u=NULL; char *token=NULL;
    if (!require_auth(connection, &u, &token)) return MHD_YES; // response sent
    (void)u;
    if (token) {
        remove_session_by_token(token);
        free(token);
    }
    json_t *out = json_object();
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, out);
    json_decref(out);
    return ret;
}

static enum MHD_Result route_me(struct MHD_Connection *connection) {
    User *u=NULL; if (!require_auth(connection, &u, NULL)) return MHD_YES;
    json_t *out = user_to_json(u);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, out);
    json_decref(out);
    return ret;
}

static enum MHD_Result route_password(struct MHD_Connection *connection, json_t *body) {
    User *u=NULL; if (!require_auth(connection, &u, NULL)) return MHD_YES;
    if (!json_is_object(body)) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    json_t *jo = json_object_get(body, "old_password");
    json_t *jn = json_object_get(body, "new_password");
    if (!jo || !json_is_string(jo) || !jn || !json_is_string(jn)) {
        return send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    const char *oldp = json_string_value(jo);
    const char *newp = json_string_value(jn);
    if (strcmp(u->password, oldp) != 0) {
        return send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    if (strlen(newp) < 8) {
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    char *np = strdup(newp);
    if (!np) return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Internal error");
    free(u->password);
    u->password = np;
    json_t *out = json_object();
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, out);
    json_decref(out);
    return ret;
}

static int cmp_todo_ptrs_by_id(const void *a, const void *b) {
    const Todo *ta = *(const Todo* const*)a;
    const Todo *tb = *(const Todo* const*)b;
    if (ta->id < tb->id) return -1;
    if (ta->id > tb->id) return 1;
    return 0;
}

static enum MHD_Result route_todos_list(struct MHD_Connection *connection) {
    User *u=NULL; if (!require_auth(connection, &u, NULL)) return MHD_YES;
    // Collect pointers to user's todos
    size_t count = 0;
    for (size_t i=0;i<todos_len;i++) if (todos[i].user_id == u->id) count++;
    Todo **ptrs = NULL;
    if (count > 0) {
        ptrs = (Todo**)malloc(sizeof(Todo*) * count);
        if (!ptrs) return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Internal error");
        size_t idx=0;
        for (size_t i=0;i<todos_len;i++) if (todos[i].user_id == u->id) ptrs[idx++] = &todos[i];
        qsort(ptrs, count, sizeof(Todo*), cmp_todo_ptrs_by_id);
    }
    json_t *arr = json_array();
    for (size_t i=0;i<count;i++) {
        json_array_append_new(arr, todo_to_json(ptrs[i]));
    }
    free(ptrs);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, arr);
    json_decref(arr);
    return ret;
}

static enum MHD_Result route_todos_create(struct MHD_Connection *connection, json_t *body) {
    User *u=NULL; if (!require_auth(connection, &u, NULL)) return MHD_YES;
    if (!json_is_object(body)) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    json_t *jt = json_object_get(body, "title");
    json_t *jd = json_object_get(body, "description");
    if (!jt || !json_is_string(jt) || strlen(json_string_value(jt)) == 0) {
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
    }
    const char *title = json_string_value(jt);
    const char *desc = (jd && json_is_string(jd)) ? json_string_value(jd) : "";
    ensure_capacity((void**)&todos, &todos_cap, sizeof(Todo), todos_len+1);
    Todo t; memset(&t,0,sizeof(t));
    t.id = next_todo_id++; t.user_id = u->id;
    t.title = strdup(title);
    t.description = strdup(desc);
    t.completed = 0;
    fill_iso8601_utc(t.created_at);
    memcpy(t.updated_at, t.created_at, sizeof(t.updated_at));
    if (!t.title || !t.description) { perror("strdup"); exit(1);} 
    todos[todos_len++] = t;
    json_t *out = todo_to_json(&todos[todos_len-1]);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_CREATED, out);
    json_decref(out);
    return ret;
}

static enum MHD_Result route_todos_get(struct MHD_Connection *connection, int id) {
    User *u=NULL; if (!require_auth(connection, &u, NULL)) return MHD_YES;
    Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != u->id) {
        return send_json_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    json_t *out = todo_to_json(t);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, out);
    json_decref(out);
    return ret;
}

static enum MHD_Result route_todos_update(struct MHD_Connection *connection, int id, json_t *body) {
    User *u=NULL; if (!require_auth(connection, &u, NULL)) return MHD_YES;
    Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != u->id) {
        return send_json_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    if (!json_is_object(body)) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    json_t *jt = json_object_get(body, "title");
    json_t *jd = json_object_get(body, "description");
    json_t *jc = json_object_get(body, "completed");
    if (jt) {
        if (!json_is_string(jt) || strlen(json_string_value(jt)) == 0) {
            return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
        }
        char *nt = strdup(json_string_value(jt));
        if (!nt) return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Internal error");
        free(t->title); t->title = nt;
    }
    if (jd) {
        if (!json_is_string(jd)) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
        char *nd = strdup(json_string_value(jd));
        if (!nd) return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Internal error");
        free(t->description); t->description = nd;
    }
    if (jc) {
        if (!json_is_boolean(jc)) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
        t->completed = json_is_true(jc) ? 1 : 0;
    }
    fill_iso8601_utc(t->updated_at);
    json_t *out = todo_to_json(t);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, out);
    json_decref(out);
    return ret;
}

static enum MHD_Result route_todos_delete(struct MHD_Connection *connection, int id) {
    User *u=NULL; if (!require_auth(connection, &u, NULL)) return MHD_YES;
    for (size_t i=0;i<todos_len;i++) {
        if (todos[i].id == id) {
            if (todos[i].user_id != u->id) {
                return send_json_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
            }
            // free strings
            free(todos[i].title); free(todos[i].description);
            if (i != todos_len-1) todos[i] = todos[todos_len-1];
            todos_len--;
            return send_empty_no_content(connection);
        }
    }
    return send_json_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
}

static enum MHD_Result handle_request(void *cls, struct MHD_Connection *connection, const char *url,
                          const char *method, const char *version, const char *upload_data,
                          size_t *upload_data_size, void **con_cls) {
    (void)cls; (void)version;
    struct RequestContext *ctx = *con_cls;
    if (!ctx) {
        ctx = calloc(1, sizeof(*ctx));
        if (!ctx) return MHD_NO;
        *con_cls = ctx;
        return MHD_YES; // first call, will be called again
    }
    if (*upload_data_size) {
        if (!add_body_data(ctx, upload_data, *upload_data_size)) {
            return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Request body too large");
        }
        *upload_data_size = 0;
        return MHD_YES;
    }

    json_t *body_json = NULL; json_error_t jerr;
    if (ctx->size > 0) {
        body_json = json_loads(ctx->body, 0, &jerr);
        if (!body_json) {
            // invalid JSON
            enum MHD_Result r = send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
            if (ctx) { free(ctx->body); free(ctx); *con_cls=NULL; }
            return r;
        }
    }

    enum MHD_Result ret = MHD_NO;
    if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(url, "/register") == 0) {
        ret = route_register(connection, body_json ? body_json : json_object());
    } else if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(url, "/login") == 0) {
        ret = route_login(connection, body_json ? body_json : json_object());
    } else if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(url, "/logout") == 0) {
        ret = route_logout(connection);
    } else if (strcmp(method, MHD_HTTP_METHOD_GET) == 0 && strcmp(url, "/me") == 0) {
        ret = route_me(connection);
    } else if (strcmp(method, MHD_HTTP_METHOD_PUT) == 0 && strcmp(url, "/password") == 0) {
        ret = route_password(connection, body_json ? body_json : json_object());
    } else if (strcmp(method, MHD_HTTP_METHOD_GET) == 0 && strcmp(url, "/todos") == 0) {
        ret = route_todos_list(connection);
    } else if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(url, "/todos") == 0) {
        ret = route_todos_create(connection, body_json ? body_json : json_object());
    } else if (strncmp(url, "/todos/", 7) == 0) {
        int id = parse_id_from_path(url, "/todos/");
        if (id <= 0) {
            ret = send_json_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
        } else if (strcmp(method, MHD_HTTP_METHOD_GET) == 0) {
            ret = route_todos_get(connection, id);
        } else if (strcmp(method, MHD_HTTP_METHOD_PUT) == 0) {
            ret = route_todos_update(connection, id, body_json ? body_json : json_object());
        } else if (strcmp(method, MHD_HTTP_METHOD_DELETE) == 0) {
            ret = route_todos_delete(connection, id);
        } else {
            ret = send_json_error(connection, MHD_HTTP_METHOD_NOT_ALLOWED, "Method not allowed");
        }
    } else {
        ret = send_json_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
    }

    if (body_json) json_decref(body_json);
    if (ctx) { free(ctx->body); free(ctx); *con_cls=NULL; }
    return ret;
}

static void request_completed_cb (void *cls, struct MHD_Connection *connection, void **con_cls, enum MHD_RequestTerminationCode toe) {
    (void)cls; (void)connection; (void)toe;
    if (con_cls && *con_cls) {
        struct RequestContext *ctx = *con_cls;
        free(ctx->body); free(ctx);
        *con_cls = NULL;
    }
}

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i=1;i<argc;i++) {
        if (strcmp(argv[i], "--port") == 0 && i+1 < argc) {
            port = atoi(argv[i+1]);
            i++;
        } else {
            fprintf(stderr, "Usage: %s --port PORT\n", argv[0]);
            return 1;
        }
    }
    struct MHD_Daemon *daemon;
    daemon = MHD_start_daemon(MHD_USE_INTERNAL_POLLING_THREAD,
                              (uint16_t)port,
                              NULL, NULL,
                              &handle_request, NULL,
                              MHD_OPTION_CONNECTION_TIMEOUT, (unsigned int)120,
                              MHD_OPTION_NOTIFY_COMPLETED, request_completed_cb, NULL,
                              MHD_OPTION_THREAD_POOL_SIZE, (unsigned int)1,
                              MHD_OPTION_END);
    if (!daemon) {
        fprintf(stderr, "Failed to start server on port %d\n", port);
        return 1;
    }
    printf("Server listening on 0.0.0.0:%d\n", port);
    fflush(stdout);
    while (1) sleep(60);
    MHD_stop_daemon(daemon);
    return 0;
}

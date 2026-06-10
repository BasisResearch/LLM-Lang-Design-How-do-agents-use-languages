#include <microhttpd.h>
#include <jansson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>

#define MAX_BODY_SIZE (1024 * 1024) // 1MB

// Data structures
typedef struct {
    int id;
    char *username;
    char *password; // stored in plain for simplicity
} User;

typedef struct {
    char token[65]; // hex string up to 64 chars (32 bytes * 2) + null
    int user_id;
} Session;

typedef struct {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0/1
    char created_at[21]; // YYYY-MM-DDTHH:MM:SSZ -> 20 + null
    char updated_at[21];
} Todo;

// Global in-memory storage
static User *users = NULL; size_t users_count = 0; size_t users_cap = 0; int next_user_id = 1;
static Session *sessions = NULL; size_t sessions_count = 0; size_t sessions_cap = 0;
static Todo *todos = NULL; size_t todos_count = 0; size_t todos_cap = 0; int next_todo_id = 1;

static pthread_mutex_t store_mutex = PTHREAD_MUTEX_INITIALIZER;

static volatile sig_atomic_t keep_running = 1;
static void handle_sigint(int sig) { (void)sig; keep_running = 0; }

static void iso8601_utc_now(char out[21]) {
    time_t t = time(NULL);
    struct tm gm;
    gmtime_r(&t, &gm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &gm);
}

static int rand_bytes(unsigned char *buf, size_t len) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    size_t off = 0;
    while (off < len) {
        ssize_t r = read(fd, buf + off, len - off);
        if (r < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (r == 0) break;
        off += (size_t)r;
    }
    close(fd);
    return (off == len) ? 0 : -1;
}

static void gen_token(char *out_hex, size_t hex_len) {
    // generate 16 random bytes => 32 hex chars
    unsigned char buf[16];
    if (rand_bytes(buf, sizeof(buf)) != 0) {
        srand((unsigned)time(NULL) ^ (unsigned)getpid());
        for (size_t i = 0; i < sizeof(buf); i++) buf[i] = (unsigned char)(rand() & 0xFF);
    }
    static const char *hex = "0123456789abcdef";
    size_t out_len = (sizeof(buf) * 2);
    if (hex_len < out_len + 1) out_len = hex_len - 1;
    for (size_t i = 0; i < out_len / 2; i++) {
        out_hex[i*2] = hex[(buf[i] >> 4) & 0xF];
        out_hex[i*2+1] = hex[buf[i] & 0xF];
    }
    out_hex[out_len] = '\0';
}

static int username_valid(const char *u) {
    if (!u) return 0;
    size_t n = strlen(u);
    if (n < 3 || n > 50) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = u[i];
        if (!(isalnum((unsigned char)c) || c == '_')) return 0;
    }
    return 1;
}

static int ensure_capacity(void **arr, size_t *cap, size_t elem_size, size_t needed) {
    if (*cap >= needed) return 0;
    size_t newcap = (*cap == 0) ? 8 : *cap;
    while (newcap < needed) newcap *= 2;
    void *p = realloc(*arr, newcap * elem_size);
    if (!p) return -1;
    *arr = p;
    *cap = newcap;
    return 0;
}

static User* find_user_by_username(const char *username) {
    for (size_t i = 0; i < users_count; i++) {
        if (strcmp(users[i].username, username) == 0) return &users[i];
    }
    return NULL;
}

static User* find_user_by_id(int id) {
    for (size_t i = 0; i < users_count; i++) if (users[i].id == id) return &users[i];
    return NULL;
}

static Session* find_session(const char *token) {
    if (!token) return NULL;
    for (size_t i = 0; i < sessions_count; i++) {
        if (strcmp(sessions[i].token, token) == 0) return &sessions[i];
    }
    return NULL;
}

static void remove_session_token(const char *token) {
    for (size_t i = 0; i < sessions_count; i++) {
        if (strcmp(sessions[i].token, token) == 0) {
            sessions[i] = sessions[sessions_count - 1];
            sessions_count--;
            return;
        }
    }
}

static Todo* find_todo_by_id(int id) {
    for (size_t i = 0; i < todos_count; i++) if (todos[i].id == id) return &todos[i];
    return NULL;
}

static void delete_todo_by_index(size_t idx) {
    if (idx >= todos_count) return;
    free(todos[idx].title);
    free(todos[idx].description);
    todos[idx] = todos[todos_count - 1];
    todos_count--;
}

// HTTP helpers
struct ConnectionInfo {
    char *body;
    size_t size;
    size_t cap;
};

static int add_header(struct MHD_Response *resp, const char *k, const char *v) {
    return MHD_add_response_header(resp, k, v) == MHD_YES ? 0 : -1;
}

static int respond_json(struct MHD_Connection *conn, unsigned int status, json_t *j) {
    char *dump = json_dumps(j, JSON_COMPACT);
    if (!dump) return MHD_NO;
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(dump), (void*)dump, MHD_RESPMEM_MUST_FREE);
    if (!resp) { free(dump); return MHD_NO; }
    add_header(resp, "Content-Type", "application/json");
    int ret = MHD_queue_response(conn, status, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int respond_json_str(struct MHD_Connection *conn, unsigned int status, const char *s) {
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(s), (void*)s, MHD_RESPMEM_MUST_COPY);
    if (!resp) return MHD_NO;
    add_header(resp, "Content-Type", "application/json");
    int ret = MHD_queue_response(conn, status, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int respond_error(struct MHD_Connection *conn, unsigned int status, const char *msg) {
    json_t *j = json_object();
    json_object_set_new(j, "error", json_string(msg));
    int r = respond_json(conn, status, j);
    json_decref(j);
    return r;
}

static const char* get_cookie_session(struct MHD_Connection *conn) {
    const char *cookie = MHD_lookup_connection_value(conn, MHD_HEADER_KIND, "Cookie");
    if (!cookie) return NULL;
    const char *p = cookie;
    size_t len = strlen("session_id=");
    while (*p) {
        while (*p == ' ' || *p == ';') p++;
        if (strncmp(p, "session_id=", len) == 0) {
            p += len;
            static __thread char token[129];
            size_t i = 0;
            while (*p && *p != ';' && i < sizeof(token)-1) {
                token[i++] = *p++;
            }
            token[i] = '\0';
            return token;
        }
        while (*p && *p != ';') p++;
        if (*p == ';') p++;
    }
    return NULL;
}

static int parse_int_id(const char *s, int *out) {
    if (!s || !*s) return -1;
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (*end != '\0' || v <= 0 || v > 2147483647L) return -1;
    *out = (int)v;
    return 0;
}

static json_t* user_to_json(const User *u) {
    json_t *j = json_object();
    json_object_set_new(j, "id", json_integer(u->id));
    json_object_set_new(j, "username", json_string(u->username));
    return j;
}

static json_t* todo_to_json(const Todo *t) {
    json_t *j = json_object();
    json_object_set_new(j, "id", json_integer(t->id));
    json_object_set_new(j, "title", json_string(t->title));
    json_object_set_new(j, "description", json_string(t->description ? t->description : ""));
    json_object_set_new(j, "completed", json_boolean(t->completed));
    json_object_set_new(j, "created_at", json_string(t->created_at));
    json_object_set_new(j, "updated_at", json_string(t->updated_at));
    return j;
}

static int require_auth(struct MHD_Connection *conn, User **out_user, const char **out_token) {
    int ret = 0;
    pthread_mutex_lock(&store_mutex);
    const char *token = get_cookie_session(conn);
    Session *s = token ? find_session(token) : NULL;
    if (!s) {
        ret = -1;
    } else {
        User *u = find_user_by_id(s->user_id);
        if (!u) {
            ret = -1;
        } else {
            if (out_user) *out_user = u;
            if (out_token) *out_token = token; // token buffer is thread-local static within get_cookie_session
            ret = 0;
        }
    }
    pthread_mutex_unlock(&store_mutex);
    if (ret != 0) {
        respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    }
    return ret;
}

static int handle_register(struct MHD_Connection *conn, const char *body, size_t body_len) {
    json_error_t err; json_t *root = json_loadb(body, body_len, 0, &err);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    const char *username = NULL, *password = NULL;
    json_t *ju = json_object_get(root, "username");
    json_t *jp = json_object_get(root, "password");
    if (ju && json_is_string(ju)) username = json_string_value(ju);
    if (jp && json_is_string(jp)) password = json_string_value(jp);

    if (!username_valid(username)) {
        json_decref(root);
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }
    if (!password || strlen(password) < 8) {
        json_decref(root);
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    pthread_mutex_lock(&store_mutex);
    if (find_user_by_username(username)) {
        pthread_mutex_unlock(&store_mutex);
        json_decref(root);
        return respond_error(conn, MHD_HTTP_CONFLICT, "Username already exists");
    }
    if (ensure_capacity((void**)&users, &users_cap, sizeof(User), users_count + 1) != 0) {
        pthread_mutex_unlock(&store_mutex);
        json_decref(root);
        return respond_error(conn, MHD_HTTP_INTERNAL_SERVER_ERROR, "Server error");
    }
    User u;
    u.id = next_user_id++;
    u.username = strdup(username);
    u.password = strdup(password);
    users[users_count++] = u;
    User *pu = &users[users_count - 1];
    json_t *j = user_to_json(pu);
    pthread_mutex_unlock(&store_mutex);

    int r = respond_json(conn, MHD_HTTP_CREATED, j);
    json_decref(j);
    json_decref(root);
    return r;
}

static int handle_login(struct MHD_Connection *conn, const char *body, size_t body_len) {
    json_error_t err; json_t *root = json_loadb(body, body_len, 0, &err);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    const char *username = NULL, *password = NULL;
    json_t *ju = json_object_get(root, "username");
    json_t *jp = json_object_get(root, "password");
    if (ju && json_is_string(ju)) username = json_string_value(ju);
    if (jp && json_is_string(jp)) password = json_string_value(jp);

    pthread_mutex_lock(&store_mutex);
    User *u = (username ? find_user_by_username(username) : NULL);
    if (!u || !password || strcmp(u->password, password) != 0) {
        pthread_mutex_unlock(&store_mutex);
        json_decref(root);
        return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    if (ensure_capacity((void**)&sessions, &sessions_cap, sizeof(Session), sessions_count + 1) != 0) {
        pthread_mutex_unlock(&store_mutex);
        json_decref(root);
        return respond_error(conn, MHD_HTTP_INTERNAL_SERVER_ERROR, "Server error");
    }
    Session s;
    memset(&s, 0, sizeof(s));
    gen_token(s.token, sizeof(s.token));
    s.user_id = u->id;
    sessions[sessions_count++] = s;
    json_t *j = user_to_json(u);
    pthread_mutex_unlock(&store_mutex);

    char cookie_hdr[256];
    snprintf(cookie_hdr, sizeof(cookie_hdr), "session_id=%s; Path=/; HttpOnly", s.token);
    char *dump = json_dumps(j, JSON_COMPACT);
    if (!dump) { json_decref(j); return respond_error(conn, MHD_HTTP_INTERNAL_SERVER_ERROR, "Server error"); }
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(dump), (void*)dump, MHD_RESPMEM_MUST_FREE);
    if (!resp) { free(dump); json_decref(j); return MHD_NO; }
    add_header(resp, "Content-Type", "application/json");
    add_header(resp, "Set-Cookie", cookie_hdr);
    int r = MHD_queue_response(conn, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    json_decref(j);
    json_decref(root);
    return r;
}

static int handle_logout(struct MHD_Connection *conn) {
    const char *token = NULL; User *u = NULL;
    if (require_auth(conn, &u, &token) != 0) return MHD_YES; // already responded with 401
    pthread_mutex_lock(&store_mutex);
    if (token) remove_session_token(token);
    pthread_mutex_unlock(&store_mutex);
    return respond_json_str(conn, MHD_HTTP_OK, "{}");
}

static int handle_me(struct MHD_Connection *conn) {
    User *u = NULL;
    if (require_auth(conn, &u, NULL) != 0) return MHD_YES;
    json_t *j = user_to_json(u);
    int r = respond_json(conn, MHD_HTTP_OK, j);
    json_decref(j);
    return r;
}

static int handle_password(struct MHD_Connection *conn, const char *body, size_t body_len) {
    User *u = NULL;
    if (require_auth(conn, &u, NULL) != 0) return MHD_YES;
    json_error_t err; json_t *root = json_loadb(body, body_len, 0, &err);
    if (!root || !json_is_object(root)) { if (root) json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    const char *oldp = NULL, *newp = NULL;
    json_t *jo = json_object_get(root, "old_password");
    json_t *jn = json_object_get(root, "new_password");
    if (jo && json_is_string(jo)) oldp = json_string_value(jo);
    if (jn && json_is_string(jn)) newp = json_string_value(jn);

    pthread_mutex_lock(&store_mutex);
    if (!oldp || strcmp(u->password, oldp) != 0) {
        pthread_mutex_unlock(&store_mutex);
        json_decref(root);
        return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    if (!newp || strlen(newp) < 8) {
        pthread_mutex_unlock(&store_mutex);
        json_decref(root);
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    free(u->password);
    u->password = strdup(newp);
    pthread_mutex_unlock(&store_mutex);
    json_decref(root);
    return respond_json_str(conn, MHD_HTTP_OK, "{}");
}

static int handle_todos_list(struct MHD_Connection *conn) {
    User *u = NULL; if (require_auth(conn, &u, NULL) != 0) return MHD_YES;
    pthread_mutex_lock(&store_mutex);
    json_t *arr = json_array();
    size_t *idxs = malloc(sizeof(size_t) * (todos_count ? todos_count : 1));
    size_t n = 0;
    for (size_t i = 0; i < todos_count; i++) if (todos[i].user_id == u->id) idxs[n++] = i;
    for (size_t i = 1; i < n; i++) {
        size_t key = idxs[i];
        int keyid = todos[key].id;
        size_t j = i;
        while (j > 0 && todos[idxs[j-1]].id > keyid) { idxs[j] = idxs[j-1]; j--; }
        idxs[j] = key;
    }
    for (size_t i = 0; i < n; i++) {
        json_t *jt = todo_to_json(&todos[idxs[i]]);
        json_array_append_new(arr, jt);
    }
    free(idxs);
    pthread_mutex_unlock(&store_mutex);
    int r = respond_json(conn, MHD_HTTP_OK, arr);
    json_decref(arr);
    return r;
}

static int handle_todos_create(struct MHD_Connection *conn, const char *body, size_t body_len) {
    User *u = NULL; if (require_auth(conn, &u, NULL) != 0) return MHD_YES;
    json_error_t err; json_t *root = json_loadb(body, body_len, 0, &err);
    if (!root || !json_is_object(root)) { if (root) json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    const char *title = NULL; const char *description = "";
    json_t *jt = json_object_get(root, "title");
    json_t *jd = json_object_get(root, "description");
    if (jt && json_is_string(jt)) title = json_string_value(jt);
    if (jd && json_is_string(jd)) description = json_string_value(jd);

    if (!title || strlen(title) == 0) { json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required"); }

    pthread_mutex_lock(&store_mutex);
    if (ensure_capacity((void**)&todos, &todos_cap, sizeof(Todo), todos_count + 1) != 0) {
        pthread_mutex_unlock(&store_mutex);
        json_decref(root);
        return respond_error(conn, MHD_HTTP_INTERNAL_SERVER_ERROR, "Server error");
    }
    Todo t;
    memset(&t, 0, sizeof(t));
    t.id = next_todo_id++;
    t.user_id = u->id;
    t.title = strdup(title);
    t.description = strdup(description ? description : "");
    t.completed = 0;
    iso8601_utc_now(t.created_at);
    memcpy(t.updated_at, t.created_at, sizeof(t.created_at));
    todos[todos_count++] = t;
    Todo *pt = &todos[todos_count - 1];
    json_t *j = todo_to_json(pt);
    pthread_mutex_unlock(&store_mutex);

    int r = respond_json(conn, MHD_HTTP_CREATED, j);
    json_decref(j);
    json_decref(root);
    return r;
}

static int handle_todos_get(struct MHD_Connection *conn, int id) {
    User *u = NULL; if (require_auth(conn, &u, NULL) != 0) return MHD_YES;
    pthread_mutex_lock(&store_mutex);
    Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != u->id) {
        pthread_mutex_unlock(&store_mutex);
        return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    json_t *j = todo_to_json(t);
    pthread_mutex_unlock(&store_mutex);
    int r = respond_json(conn, MHD_HTTP_OK, j);
    json_decref(j);
    return r;
}

static int handle_todos_update(struct MHD_Connection *conn, int id, const char *body, size_t body_len) {
    User *u = NULL; if (require_auth(conn, &u, NULL) != 0) return MHD_YES;
    json_error_t err; json_t *root = json_loadb(body, body_len, 0, &err);
    if (!root || !json_is_object(root)) { if (root) json_decref(root); return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }

    pthread_mutex_lock(&store_mutex);
    Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != u->id) {
        pthread_mutex_unlock(&store_mutex);
        json_decref(root);
        return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    json_t *jt = json_object_get(root, "title");
    if (jt) {
        if (!json_is_string(jt) || strlen(json_string_value(jt)) == 0) {
            pthread_mutex_unlock(&store_mutex);
            json_decref(root);
            return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required");
        }
        free(t->title);
        t->title = strdup(json_string_value(jt));
    }
    json_t *jd = json_object_get(root, "description");
    if (jd) {
        if (json_is_string(jd)) {
            free(t->description);
            t->description = strdup(json_string_value(jd));
        }
    }
    json_t *jc = json_object_get(root, "completed");
    if (jc) {
        if (json_is_boolean(jc)) {
            t->completed = json_is_true(jc) ? 1 : 0;
        } else if (json_is_integer(jc)) {
            t->completed = json_integer_value(jc) ? 1 : 0;
        }
    }
    iso8601_utc_now(t->updated_at);
    json_t *j = todo_to_json(t);
    pthread_mutex_unlock(&store_mutex);
    json_decref(root);
    int r = respond_json(conn, MHD_HTTP_OK, j);
    json_decref(j);
    return r;
}

static int handle_todos_delete(struct MHD_Connection *conn, int id) {
    User *u = NULL; if (require_auth(conn, &u, NULL) != 0) return MHD_YES;
    pthread_mutex_lock(&store_mutex);
    size_t idx = (size_t)-1;
    for (size_t i = 0; i < todos_count; i++) {
        if (todos[i].id == id) { idx = i; break; }
    }
    if (idx == (size_t)-1 || todos[idx].user_id != u->id) {
        pthread_mutex_unlock(&store_mutex);
        return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    delete_todo_by_index(idx);
    pthread_mutex_unlock(&store_mutex);
    struct MHD_Response *resp = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_MUST_COPY);
    if (!resp) return MHD_NO;
    int r = MHD_queue_response(conn, MHD_HTTP_NO_CONTENT, resp);
    MHD_destroy_response(resp);
    return r;
}

static int answer_to_connection(void *cls, struct MHD_Connection *connection, const char *url,
                                const char *method, const char *version,
                                const char *upload_data, size_t *upload_data_size, void **con_cls) {
    (void)cls; (void)version;
    struct ConnectionInfo *ci = *con_cls;

    if (ci == NULL) {
        ci = calloc(1, sizeof(struct ConnectionInfo));
        if (!ci) return MHD_NO;
        ci->body = NULL; ci->size = 0; ci->cap = 0;
        *con_cls = ci;
        return MHD_YES;
    }

    int expects_body = (strcmp(method, MHD_HTTP_METHOD_POST) == 0) || (strcmp(method, MHD_HTTP_METHOD_PUT) == 0);
    if (expects_body) {
        if (*upload_data_size != 0) {
            size_t newsize = ci->size + *upload_data_size;
            if (newsize > MAX_BODY_SIZE) {
                *upload_data_size = 0;
                return respond_error(connection, MHD_HTTP_BAD_REQUEST, "Request body too large");
            }
            if (newsize + 1 > ci->cap) {
                size_t ncap = ci->cap == 0 ? 4096 : ci->cap;
                while (ncap < newsize + 1) ncap *= 2;
                char *nb = realloc(ci->body, ncap);
                if (!nb) {
                    *upload_data_size = 0;
                    return respond_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Server error");
                }
                ci->body = nb; ci->cap = ncap;
            }
            memcpy(ci->body + ci->size, upload_data, *upload_data_size);
            ci->size = newsize; ci->body[ci->size] = '\0';
            *upload_data_size = 0;
            return MHD_YES;
        }
    }

    const char *path = url;

    if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(path, "/register") == 0) {
        return handle_register(connection, ci->body ? ci->body : "", ci->size);
    }
    if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(path, "/login") == 0) {
        return handle_login(connection, ci->body ? ci->body : "", ci->size);
    }
    if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 && strcmp(path, "/logout") == 0) {
        return handle_logout(connection);
    }
    if (strcmp(method, MHD_HTTP_METHOD_GET) == 0 && strcmp(path, "/me") == 0) {
        return handle_me(connection);
    }
    if (strcmp(method, MHD_HTTP_METHOD_PUT) == 0 && strcmp(path, "/password") == 0) {
        return handle_password(connection, ci->body ? ci->body : "", ci->size);
    }

    if (strncmp(path, "/todos", 6) == 0) {
        if (strcmp(path, "/todos") == 0) {
            if (strcmp(method, MHD_HTTP_METHOD_GET) == 0) return handle_todos_list(connection);
            if (strcmp(method, MHD_HTTP_METHOD_POST) == 0) return handle_todos_create(connection, ci->body ? ci->body : "", ci->size);
        } else if (strncmp(path, "/todos/", 7) == 0) {
            const char *idstr = path + 7;
            int id = 0; if (parse_int_id(idstr, &id) != 0) {
                return respond_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
            }
            if (strcmp(method, MHD_HTTP_METHOD_GET) == 0) return handle_todos_get(connection, id);
            if (strcmp(method, MHD_HTTP_METHOD_PUT) == 0) return handle_todos_update(connection, id, ci->body ? ci->body : "", ci->size);
            if (strcmp(method, MHD_HTTP_METHOD_DELETE) == 0) return handle_todos_delete(connection, id);
        }
    }

    return respond_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
}

static void request_completed(void *cls, struct MHD_Connection *connection, void **con_cls,
                              enum MHD_RequestTerminationCode toe) {
    (void)cls; (void)connection; (void)toe;
    struct ConnectionInfo *ci = *con_cls;
    if (ci) {
        free(ci->body);
        free(ci);
    }
    *con_cls = NULL;
}

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i+1]);
            i++;
        }
    }

    struct sigaction sa; memset(&sa, 0, sizeof(sa)); sa.sa_handler = handle_sigint; sigaction(SIGINT, &sa, NULL); sigaction(SIGTERM, &sa, NULL);

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_INTERNAL_POLLING_THREAD,
                                                 port,
                                                 NULL, NULL,
                                                 &answer_to_connection, NULL,
                                                 MHD_OPTION_NOTIFY_COMPLETED, request_completed, NULL,
                                                 MHD_OPTION_END);
    if (daemon == NULL) {
        fprintf(stderr, "Failed to start server on port %d\n", port);
        return 1;
    }
    printf("Server listening on 0.0.0.0:%d\n", port);
    fflush(stdout);

    while (keep_running) {
        sleep(1);
    }

    MHD_stop_daemon(daemon);
    return 0;
}

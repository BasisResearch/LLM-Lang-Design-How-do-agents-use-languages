#include <microhttpd.h>
#include <jansson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define MAX_USERNAME 50
#define MAX_PASSWORD 256
#define TOKEN_LEN 64

static char *my_strdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (!p) return NULL;
    memcpy(p, s, n);
    return p;
}

struct User {
    int id;
    char username[MAX_USERNAME + 1];
    char password[MAX_PASSWORD + 1];
};

struct Todo {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0/1
    char created_at[21];
    char updated_at[21];
};

struct Session {
    char token[TOKEN_LEN + 1];
    int user_id;
};

static struct User *users = NULL; size_t users_len = 0; size_t users_cap = 0; int next_user_id = 1;
static struct Todo *todos = NULL; size_t todos_len = 0; size_t todos_cap = 0; int next_todo_id = 1;
static struct Session *sessions = NULL; size_t sessions_len = 0; size_t sessions_cap = 0;

static pthread_mutex_t db_mutex = PTHREAD_MUTEX_INITIALIZER;

static void ensure_users_cap() {
    if (users_len >= users_cap) {
        size_t ncap = users_cap ? users_cap * 2 : 16;
        struct User *nu = realloc(users, ncap * sizeof(*users));
        if (!nu) { perror("realloc users"); exit(1);} users = nu; users_cap = ncap;
    }
}
static void ensure_todos_cap() {
    if (todos_len >= todos_cap) {
        size_t ncap = todos_cap ? todos_cap * 2 : 32;
        struct Todo *nt = realloc(todos, ncap * sizeof(*todos));
        if (!nt) { perror("realloc todos"); exit(1);} todos = nt; todos_cap = ncap;
    }
}
static void ensure_sessions_cap() {
    if (sessions_len >= sessions_cap) {
        size_t ncap = sessions_cap ? sessions_cap * 2 : 16;
        struct Session *ns = realloc(sessions, ncap * sizeof(*sessions));
        if (!ns) { perror("realloc sessions"); exit(1);} sessions = ns; sessions_cap = ncap;
    }
}

static int username_valid(const char *u) {
    size_t n = strlen(u);
    if (n < 3 || n > 50) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = u[i];
        if (!(isalnum((unsigned char)c) || c == '_')) return 0;
    }
    return 1;
}

static int secure_random_bytes(unsigned char *buf, size_t len) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    size_t off = 0; while (off < len) {
        ssize_t r = read(fd, buf + off, len - off);
        if (r < 0) { if (errno == EINTR) continue; close(fd); return -1; }
        if (r == 0) { close(fd); return -1; }
        off += (size_t)r;
    }
    close(fd);
    return 0;
}

static void gen_token(char out[TOKEN_LEN + 1]) {
    unsigned char bytes[TOKEN_LEN/2];
    if (secure_random_bytes(bytes, sizeof(bytes)) != 0) {
        // fallback
        srand((unsigned)time(NULL) ^ (unsigned)getpid());
        for (size_t i=0;i<sizeof(bytes);i++) bytes[i] = rand() & 0xFF;
    }
    static const char *hex = "0123456789abcdef";
    for (size_t i=0;i<sizeof(bytes);i++) {
        out[2*i] = hex[(bytes[i]>>4)&0xF];
        out[2*i+1] = hex[bytes[i]&0xF];
    }
    out[TOKEN_LEN] = '\0';
}

static void iso8601_now(char out[21]) {
    time_t t = time(NULL);
    struct tm g;
#if defined(_GNU_SOURCE) || defined(__USE_MISC)
    gmtime_r(&t, &g);
#else
    struct tm *pg = gmtime(&t); if (pg) g = *pg; else memset(&g,0,sizeof g);
#endif
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &g);
}

static struct User* find_user_by_username(const char *u) {
    for (size_t i=0;i<users_len;i++) if (strcmp(users[i].username, u)==0) return &users[i];
    return NULL;
}
static struct User* find_user_by_id(int id) {
    for (size_t i=0;i<users_len;i++) if (users[i].id == id) return &users[i];
    return NULL;
}

static struct Todo* find_todo_by_id(int id) {
    for (size_t i=0;i<todos_len;i++) if (todos[i].id == id) return &todos[i];
    return NULL;
}

static struct Session* find_session(const char *token) {
    for (size_t i=0;i<sessions_len;i++) if (strcmp(sessions[i].token, token)==0) return &sessions[i];
    return NULL;
}

static int remove_session_token(const char *token) {
    for (size_t i=0;i<sessions_len;i++) {
        if (strcmp(sessions[i].token, token)==0) {
            sessions[i] = sessions[sessions_len-1];
            sessions_len--;
            return 1;
        }
    }
    return 0;
}

static void json_add_user(json_t *o, const struct User *u) {
    json_object_set_new(o, "id", json_integer(u->id));
    json_object_set_new(o, "username", json_string(u->username));
}

static json_t* todo_to_json(const struct Todo *t) {
    json_t *o = json_object();
    json_object_set_new(o, "id", json_integer(t->id));
    json_object_set_new(o, "title", json_string(t->title ? t->title : ""));
    json_object_set_new(o, "description", json_string(t->description ? t->description : ""));
    json_object_set_new(o, "completed", json_boolean(t->completed ? 1:0));
    json_object_set_new(o, "created_at", json_string(t->created_at));
    json_object_set_new(o, "updated_at", json_string(t->updated_at));
    return o;
}

static struct MHD_Response* json_response_with_code(json_t *j, unsigned int code) {
    (void)code;
    char *dump = json_dumps(j, JSON_COMPACT);
    size_t len = strlen(dump);
    struct MHD_Response *resp = MHD_create_response_from_buffer(len, (void*)dump, MHD_RESPMEM_MUST_FREE);
    if (!resp) { free(dump); return NULL; }
    MHD_add_response_header(resp, MHD_HTTP_HEADER_CONTENT_TYPE, "application/json");
    return resp;
}

static struct MHD_Response* json_error_response(int code, const char *msg) {
    json_t *o = json_object();
    json_object_set_new(o, "error", json_string(msg));
    struct MHD_Response *r = json_response_with_code(o, code);
    json_decref(o);
    return r;
}

struct ConnInfo {
    char *body;
    size_t body_len;
    size_t body_cap;
    int processed;
};

static void conninfo_free(void *con_cls) {
    if (!con_cls) return;
    struct ConnInfo *ci = (struct ConnInfo*)con_cls;
    free(ci->body);
    free(ci);
}

static int append_body(struct ConnInfo *ci, const char *data, size_t sz) {
    if (sz == 0) return 1;
    if (ci->body_len + sz + 1 > ci->body_cap) {
        size_t ncap = ci->body_cap ? ci->body_cap : 1024;
        while (ci->body_len + sz + 1 > ncap) ncap *= 2;
        char *nb = realloc(ci->body, ncap);
        if (!nb) return 0;
        ci->body = nb; ci->body_cap = ncap;
    }
    memcpy(ci->body + ci->body_len, data, sz);
    ci->body_len += sz;
    ci->body[ci->body_len] = '\0';
    return 1;
}

static int parse_id_from_path(const char *url, const char *prefix) {
    size_t prelen = strlen(prefix);
    if (strncmp(url, prefix, prelen) != 0) return -1;
    const char *rest = url + prelen;
    if (*rest == '\0') return -1;
    char *endptr = NULL;
    long v = strtol(rest, &endptr, 10);
    if (endptr == rest) return -1;
    if (*endptr != '\0') {
        if (*endptr == '/' && *(endptr+1) == '\0') {
        } else {
            return -1;
        }
    }
    if (v <= 0 || v > 2147483647L) return -1;
    return (int)v;
}

static int require_auth(struct MHD_Connection *conn, struct User **out_user, const char **out_token, struct MHD_Response **out_resp, unsigned int *out_code) {
    const char *token = MHD_lookup_connection_value(conn, MHD_COOKIE_KIND, "session_id");
    if (!token) {
        *out_resp = json_error_response(MHD_HTTP_UNAUTHORIZED, "Authentication required");
        *out_code = MHD_HTTP_UNAUTHORIZED;
        return 0;
    }
    pthread_mutex_lock(&db_mutex);
    struct Session *s = find_session(token);
    struct User *u = NULL;
    if (s) u = find_user_by_id(s->user_id);
    pthread_mutex_unlock(&db_mutex);
    if (!s || !u) {
        *out_resp = json_error_response(MHD_HTTP_UNAUTHORIZED, "Authentication required");
        *out_code = MHD_HTTP_UNAUTHORIZED;
        return 0;
    }
    if (out_user) *out_user = u;
    if (out_token) *out_token = token;
    return 1;
}

static int method_is(const char *method, const char *m) { return 0 == strcmp(method, m); }

static enum MHD_Result send_response(struct MHD_Connection *conn, unsigned int code, struct MHD_Response *resp) {
    if (!resp) return MHD_NO;
    enum MHD_Result ret = MHD_queue_response(conn, code, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int cmp_todo_ptr_id(const void *a, const void *b) {
    const struct Todo *const *ta = (const struct Todo *const *)a;
    const struct Todo *const *tb = (const struct Todo *const *)b;
    if ((*ta)->id < (*tb)->id) return -1; else if ((*ta)->id > (*tb)->id) return 1; else return 0;
}

static enum MHD_Result handle_request(void *cls, struct MHD_Connection *connection,
                          const char *url, const char *method,
                          const char *version, const char *upload_data,
                          size_t *upload_data_size, void **con_cls) {
    (void)cls; (void)version;
    struct ConnInfo *ci = *con_cls;
    if (!ci) {
        ci = calloc(1, sizeof(*ci));
        if (!ci) return MHD_NO;
        *con_cls = ci;
        return MHD_YES;
    }

    if (*upload_data_size) {
        if (!append_body(ci, upload_data, *upload_data_size)) return MHD_NO;
        *upload_data_size = 0;
        return MHD_YES;
    }

    if (ci->processed) return MHD_YES; // already responded
    ci->processed = 1;

    struct MHD_Response *resp = NULL;
    unsigned int code = MHD_HTTP_OK;

    // POST /register
    if (method_is(method, MHD_HTTP_METHOD_POST) && strcmp(url, "/register") == 0) {
        json_error_t jerr;
        json_t *root = NULL;
        if (ci->body_len == 0) {
            resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON");
            code = MHD_HTTP_BAD_REQUEST;
            goto sendit;
        }
        root = json_loads(ci->body, 0, &jerr);
        if (!root || !json_is_object(root)) {
            if (root) json_decref(root);
            resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON");
            code = MHD_HTTP_BAD_REQUEST; goto sendit;
        }
        json_t *ju = json_object_get(root, "username");
        json_t *jp = json_object_get(root, "password");
        if (!ju || !json_is_string(ju) || !jp || !json_is_string(jp)) {
            json_decref(root);
            resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON");
            code = MHD_HTTP_BAD_REQUEST; goto sendit;
        }
        const char *username = json_string_value(ju);
        const char *password = json_string_value(jp);
        if (!username_valid(username)) {
            json_decref(root);
            resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid username");
            code = MHD_HTTP_BAD_REQUEST; goto sendit;
        }
        if (strlen(password) < 8) {
            json_decref(root);
            resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Password too short");
            code = MHD_HTTP_BAD_REQUEST; goto sendit;
        }
        pthread_mutex_lock(&db_mutex);
        if (find_user_by_username(username)) {
            pthread_mutex_unlock(&db_mutex);
            json_decref(root);
            resp = json_error_response(MHD_HTTP_CONFLICT, "Username already exists");
            code = MHD_HTTP_CONFLICT; goto sendit;
        }
        ensure_users_cap();
        struct User *u = &users[users_len++];
        u->id = next_user_id++;
        strncpy(u->username, username, MAX_USERNAME); u->username[MAX_USERNAME] = '\0';
        strncpy(u->password, password, MAX_PASSWORD); u->password[MAX_PASSWORD] = '\0';
        json_t *o = json_object();
        json_add_user(o, u);
        pthread_mutex_unlock(&db_mutex);
        resp = json_response_with_code(o, MHD_HTTP_CREATED);
        json_decref(o);
        code = MHD_HTTP_CREATED;
        json_decref(root);
        goto sendit;
    }

    // POST /login
    if (method_is(method, MHD_HTTP_METHOD_POST) && strcmp(url, "/login") == 0) {
        json_error_t jerr; json_t *root = json_loads(ci->body ? ci->body : "", 0, &jerr);
        if (!root || !json_is_object(root)) { if (root) json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
        const char *username = NULL; const char *password = NULL;
        json_t *ju = json_object_get(root, "username"); if (ju && json_is_string(ju)) username = json_string_value(ju);
        json_t *jp = json_object_get(root, "password"); if (jp && json_is_string(jp)) password = json_string_value(jp);
        if (!username || !password) { json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
        pthread_mutex_lock(&db_mutex);
        struct User *u = find_user_by_username(username);
        if (!u || strcmp(u->password, password) != 0) {
            pthread_mutex_unlock(&db_mutex);
            json_decref(root);
            resp = json_error_response(MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
            code = MHD_HTTP_UNAUTHORIZED; goto sendit;
        }
        ensure_sessions_cap();
        struct Session *s = &sessions[sessions_len++];
        gen_token(s->token);
        s->user_id = u->id;
        json_t *o = json_object(); json_add_user(o, u);
        pthread_mutex_unlock(&db_mutex);
        resp = json_response_with_code(o, MHD_HTTP_OK);
        json_decref(o);
        {
            char cookie[256]; snprintf(cookie, sizeof(cookie), "session_id=%s; Path=/; HttpOnly", s->token);
            MHD_add_response_header(resp, MHD_HTTP_HEADER_SET_COOKIE, cookie);
        }
        code = MHD_HTTP_OK;
        json_decref(root);
        goto sendit;
    }

    // POST /logout
    if (method_is(method, MHD_HTTP_METHOD_POST) && strcmp(url, "/logout") == 0) {
        struct User *u = NULL; const char *token = NULL; if (!require_auth(connection, &u, &token, &resp, &code)) goto sendit;
        (void)u;
        pthread_mutex_lock(&db_mutex);
        remove_session_token(token);
        pthread_mutex_unlock(&db_mutex);
        json_t *o = json_object();
        resp = json_response_with_code(o, MHD_HTTP_OK);
        json_decref(o);
        code = MHD_HTTP_OK;
        goto sendit;
    }

    // GET /me
    if (method_is(method, MHD_HTTP_METHOD_GET) && strcmp(url, "/me") == 0) {
        struct User *u = NULL; if (!require_auth(connection, &u, NULL, &resp, &code)) goto sendit;
        json_t *o = json_object(); json_add_user(o, u);
        resp = json_response_with_code(o, MHD_HTTP_OK); json_decref(o);
        code = MHD_HTTP_OK; goto sendit;
    }

    // PUT /password
    if (method_is(method, MHD_HTTP_METHOD_PUT) && strcmp(url, "/password") == 0) {
        struct User *u = NULL; if (!require_auth(connection, &u, NULL, &resp, &code)) goto sendit;
        json_error_t jerr; json_t *root = json_loads(ci->body ? ci->body : "", 0, &jerr);
        if (!root || !json_is_object(root)) { if (root) json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
        json_t *jo = json_object_get(root, "old_password"); json_t *jn = json_object_get(root, "new_password");
        if (!jo || !json_is_string(jo) || !jn || !json_is_string(jn)) { json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
        const char *oldp = json_string_value(jo); const char *newp = json_string_value(jn);
        if (strlen(newp) < 8) { json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Password too short"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
        pthread_mutex_lock(&db_mutex);
        if (strcmp(u->password, oldp) != 0) {
            pthread_mutex_unlock(&db_mutex);
            json_decref(root);
            resp = json_error_response(MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); code = MHD_HTTP_UNAUTHORIZED; goto sendit;
        }
        strncpy(u->password, newp, MAX_PASSWORD); u->password[MAX_PASSWORD] = '\0';
        pthread_mutex_unlock(&db_mutex);
        json_t *o = json_object(); resp = json_response_with_code(o, MHD_HTTP_OK); json_decref(o); code = MHD_HTTP_OK; json_decref(root); goto sendit;
    }

    // GET /todos
    if (method_is(method, MHD_HTTP_METHOD_GET) && strcmp(url, "/todos") == 0) {
        struct User *u = NULL; if (!require_auth(connection, &u, NULL, &resp, &code)) goto sendit;
        json_t *arr = json_array();
        pthread_mutex_lock(&db_mutex);
        size_t cnt = 0; for (size_t i=0;i<todos_len;i++) if (todos[i].user_id == u->id) cnt++;
        struct Todo **list = NULL;
        if (cnt > 0) {
            list = malloc(cnt * sizeof(*list)); if (!list) { pthread_mutex_unlock(&db_mutex); json_decref(arr); return MHD_NO; }
            size_t k=0; for (size_t i=0;i<todos_len;i++) if (todos[i].user_id == u->id) list[k++] = &todos[i];
            qsort(list, cnt, sizeof(*list), cmp_todo_ptr_id);
            for (size_t i=0;i<cnt;i++) {
                json_t *tj = todo_to_json(list[i]); json_array_append_new(arr, tj);
            }
            free(list);
        }
        pthread_mutex_unlock(&db_mutex);
        resp = json_response_with_code(arr, MHD_HTTP_OK);
        json_decref(arr);
        code = MHD_HTTP_OK; goto sendit;
    }

    // POST /todos
    if (method_is(method, MHD_HTTP_METHOD_POST) && strcmp(url, "/todos") == 0) {
        struct User *u = NULL; if (!require_auth(connection, &u, NULL, &resp, &code)) goto sendit;
        json_error_t jerr; json_t *root = json_loads(ci->body ? ci->body : "", 0, &jerr);
        if (!root || !json_is_object(root)) { if (root) json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
        json_t *jt = json_object_get(root, "title"); json_t *jd = json_object_get(root, "description");
        if (!jt || !json_is_string(jt) || strlen(json_string_value(jt)) == 0) { json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Title is required"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
        const char *title = json_string_value(jt);
        const char *desc = (jd && json_is_string(jd)) ? json_string_value(jd) : "";
        pthread_mutex_lock(&db_mutex);
        ensure_todos_cap();
        struct Todo *t = &todos[todos_len++];
        t->id = next_todo_id++;
        t->user_id = u->id;
        t->title = my_strdup(title ? title : ""); if (!t->title) { perror("strdup"); exit(1);} 
        t->description = my_strdup(desc ? desc : ""); if (!t->description) { perror("strdup"); exit(1);} 
        t->completed = 0;
        iso8601_now(t->created_at); strcpy(t->updated_at, t->created_at);
        json_t *tj = todo_to_json(t);
        pthread_mutex_unlock(&db_mutex);
        resp = json_response_with_code(tj, MHD_HTTP_CREATED);
        json_decref(tj);
        code = MHD_HTTP_CREATED;
        json_decref(root); goto sendit;
    }

    // /todos/:id handlers
    {
        const char *prefix = "/todos/";
        size_t prelen = strlen(prefix);
        if (strncmp(url, prefix, prelen) == 0) {
            int id = parse_id_from_path(url, prefix);
            if (id <= 0) {
                resp = json_error_response(MHD_HTTP_NOT_FOUND, "Not found"); code = MHD_HTTP_NOT_FOUND; goto sendit;
            }
            // GET
            if (method_is(method, MHD_HTTP_METHOD_GET)) {
                struct User *u = NULL; if (!require_auth(connection, &u, NULL, &resp, &code)) goto sendit;
                pthread_mutex_lock(&db_mutex);
                struct Todo *t = find_todo_by_id(id);
                if (!t || t->user_id != u->id) {
                    pthread_mutex_unlock(&db_mutex);
                    resp = json_error_response(MHD_HTTP_NOT_FOUND, "Todo not found"); code = MHD_HTTP_NOT_FOUND; goto sendit;
                }
                json_t *tj = todo_to_json(t);
                pthread_mutex_unlock(&db_mutex);
                resp = json_response_with_code(tj, MHD_HTTP_OK); json_decref(tj); code = MHD_HTTP_OK; goto sendit;
            }
            // PUT
            if (method_is(method, MHD_HTTP_METHOD_PUT)) {
                struct User *u = NULL; if (!require_auth(connection, &u, NULL, &resp, &code)) goto sendit;
                json_error_t jerr; json_t *root = json_loads(ci->body ? ci->body : "", 0, &jerr);
                if (!root || !json_is_object(root)) { if (root) json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
                json_t *jt = json_object_get(root, "title");
                json_t *jd = json_object_get(root, "description");
                json_t *jc = json_object_get(root, "completed");
                if (jt && (!json_is_string(jt) || strlen(json_string_value(jt)) == 0)) { json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Title is required"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
                if (jc && !json_is_boolean(jc)) { json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
                pthread_mutex_lock(&db_mutex);
                struct Todo *t = find_todo_by_id(id);
                if (!t || t->user_id != u->id) {
                    pthread_mutex_unlock(&db_mutex);
                    json_decref(root);
                    resp = json_error_response(MHD_HTTP_NOT_FOUND, "Todo not found"); code = MHD_HTTP_NOT_FOUND; goto sendit;
                }
                if (jt) {
                    free(t->title); t->title = my_strdup(json_string_value(jt)); if (!t->title) { perror("strdup"); exit(1);} 
                }
                if (jd) {
                    if (!json_is_string(jd)) { pthread_mutex_unlock(&db_mutex); json_decref(root); resp = json_error_response(MHD_HTTP_BAD_REQUEST, "Invalid JSON"); code = MHD_HTTP_BAD_REQUEST; goto sendit; }
                    free(t->description); t->description = my_strdup(json_string_value(jd)); if (!t->description) { perror("strdup"); exit(1);} 
                }
                if (jc) {
                    t->completed = json_is_true(jc) ? 1 : 0;
                }
                iso8601_now(t->updated_at);
                json_t *tj = todo_to_json(t);
                pthread_mutex_unlock(&db_mutex);
                resp = json_response_with_code(tj, MHD_HTTP_OK); json_decref(tj); code = MHD_HTTP_OK; json_decref(root); goto sendit;
            }
            // DELETE
            if (method_is(method, MHD_HTTP_METHOD_DELETE)) {
                struct User *u = NULL; if (!require_auth(connection, &u, NULL, &resp, &code)) goto sendit;
                pthread_mutex_lock(&db_mutex);
                size_t idx = (size_t)-1; struct Todo *t = NULL;
                for (size_t i=0;i<todos_len;i++) if (todos[i].id == id) { idx = i; t = &todos[i]; break; }
                if (!t || t->user_id != u->id) {
                    pthread_mutex_unlock(&db_mutex);
                    resp = json_error_response(MHD_HTTP_NOT_FOUND, "Todo not found"); code = MHD_HTTP_NOT_FOUND; goto sendit;
                }
                free(t->title); free(t->description);
                if (idx != todos_len-1) todos[idx] = todos[todos_len-1];
                todos_len--;
                pthread_mutex_unlock(&db_mutex);
                struct MHD_Response *r = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
                resp = r;
                code = MHD_HTTP_NO_CONTENT;
                goto sendit;
            }
        }
    }

    // Not found
    resp = json_error_response(MHD_HTTP_NOT_FOUND, "Not found"); code = MHD_HTTP_NOT_FOUND; goto sendit;

sendit:
    {
        enum MHD_Result ret = send_response(connection, code, resp);
        return ret;
    }
}

static void request_completed_callback(void *cls, struct MHD_Connection *connection, void **con_cls, enum MHD_RequestTerminationCode toe) {
    (void)cls; (void)connection; (void)toe;
    if (*con_cls) { conninfo_free(*con_cls); *con_cls = NULL; }
}

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i=1;i<argc;i++) {
        if (strcmp(argv[i], "--port") == 0 && i+1 < argc) {
            port = atoi(argv[++i]);
        }
    }
    if (port <= 0 || port > 65535) { fprintf(stderr, "Invalid port\n"); return 1; }

    static struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_port = htons((uint16_t)port); addr.sin_addr.s_addr = htonl(INADDR_ANY); // 0.0.0.0

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_INTERNAL_POLLING_THREAD,
                                                 0 /* ignored when SOCK_ADDR provided */, NULL, NULL,
                                                 &handle_request, NULL,
                                                 MHD_OPTION_NOTIFY_COMPLETED, request_completed_callback, NULL,
                                                 MHD_OPTION_SOCK_ADDR, (struct sockaddr*)&addr,
                                                 MHD_OPTION_END);
    if (!daemon) { fprintf(stderr, "Failed to start server\n"); return 1; }
    printf("Server listening on 0.0.0.0:%d\n", port);
    fflush(stdout);
    pause();
    MHD_stop_daemon(daemon);
    return 0;
}

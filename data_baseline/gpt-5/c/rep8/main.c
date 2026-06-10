#include <microhttpd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ctype.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <cjson/cJSON.h>

#define MAX_USERNAME_LEN 50
#define MIN_USERNAME_LEN 3
#define MIN_PASSWORD_LEN 8

#define RESP_MEM MHD_RESPMEM_MUST_COPY

/* Data structures */
typedef struct {
    int id;
    char *username;
    char *password; /* stored as plain for simplicity (in-memory only) */
} User;

typedef struct {
    char token[65]; /* 32 bytes hex *2 =64 + NUL */
    int user_id;
} Session;

typedef struct {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; /* 0/1 */
    char created_at[21]; /* YYYY-MM-DDTHH:MM:SSZ -> 20 + NUL */
    char updated_at[21];
} Todo;

/* Global state */
static User *users = NULL; size_t users_len = 0; size_t users_cap = 0; int next_user_id = 1;
static Session *sessions = NULL; size_t sessions_len = 0; size_t sessions_cap = 0;
static Todo *todos = NULL; size_t todos_len = 0; size_t todos_cap = 0; int next_todo_id = 1;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* Utility: ISO8601 UTC timestamp with second precision */
static void now_iso8601(char out[21]) {
    time_t t = time(NULL);
    struct tm gm;
    gmtime_r(&t, &gm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &gm);
}

static int is_valid_username(const char *u) {
    size_t n = strlen(u);
    if (n < MIN_USERNAME_LEN || n > MAX_USERNAME_LEN) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = u[i];
        if (!(isalnum((unsigned char)c) || c == '_')) return 0;
    }
    return 1;
}

static void *xrealloc(void *p, size_t sz) {
    void *q = realloc(p, sz);
    if (!q) {
        perror("realloc");
        exit(1);
    }
    return q;
}

static char *xstrdup(const char *s) {
    size_t n = strlen(s);
    char *p = malloc(n + 1);
    if (!p) { perror("malloc"); exit(1);} 
    memcpy(p, s, n + 1);
    return p;
}

static void ensure_users_cap() { if (users_len >= users_cap) { users_cap = users_cap? users_cap*2: 16; users = xrealloc(users, users_cap*sizeof(User)); } }
static void ensure_sessions_cap() { if (sessions_len >= sessions_cap) { sessions_cap = sessions_cap? sessions_cap*2: 32; sessions = xrealloc(sessions, sessions_cap*sizeof(Session)); } }
static void ensure_todos_cap() { if (todos_len >= todos_cap) { todos_cap = todos_cap? todos_cap*2: 64; todos = xrealloc(todos, todos_cap*sizeof(Todo)); } }

/* Token generation using /dev/urandom */
static void bytes_to_hex(const unsigned char *in, size_t inlen, char *out_hex) {
    static const char *hex = "0123456789abcdef";
    for (size_t i = 0; i < inlen; i++) {
        out_hex[2*i] = hex[(in[i] >> 4) & 0xF];
        out_hex[2*i+1] = hex[in[i] & 0xF];
    }
    out_hex[2*inlen] = '\0';
}

static void generate_token(char token_out[65]) {
    unsigned char buf[32];
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        ssize_t r = read(fd, buf, sizeof(buf));
        close(fd);
        if (r == (ssize_t)sizeof(buf)) {
            bytes_to_hex(buf, sizeof(buf), token_out);
            return;
        }
    }
    /* fallback to rand() */
    for (size_t i = 0; i < sizeof(buf); i++) buf[i] = (unsigned char)(rand() & 0xFF);
    bytes_to_hex(buf, sizeof(buf), token_out);
}

/* Lookup helpers (call with g_lock held) */
static User *find_user_by_username(const char *username) {
    for (size_t i = 0; i < users_len; i++) if (strcmp(users[i].username, username) == 0) return &users[i];
    return NULL;
}
static User *find_user_by_id(int id) {
    for (size_t i = 0; i < users_len; i++) if (users[i].id == id) return &users[i];
    return NULL;
}
static Session *find_session_by_token(const char *token) {
    for (size_t i = 0; i < sessions_len; i++) if (strcmp(sessions[i].token, token) == 0) return &sessions[i];
    return NULL;
}
static Todo *find_todo_by_id(int id) {
    for (size_t i = 0; i < todos_len; i++) if (todos[i].id == id) return &todos[i];
    return NULL;
}

/* HTTP utilities */
static enum MHD_Result send_json(struct MHD_Connection *connection, unsigned int status, const char *json) {
    struct MHD_Response *response = MHD_create_response_from_buffer(strlen(json), (void*)json, RESP_MEM);
    if (!response) return MHD_NO;
    MHD_add_response_header(response, MHD_HTTP_HEADER_CONTENT_TYPE, "application/json");
    enum MHD_Result ret = MHD_queue_response(connection, status, response);
    MHD_destroy_response(response);
    return ret;
}
static enum MHD_Result send_error(struct MHD_Connection *connection, unsigned int status, const char *msg) {
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "error", msg);
    char *s = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    enum MHD_Result ret = send_json(connection, status, s);
    free(s);
    return ret;
}
static enum MHD_Result send_no_content(struct MHD_Connection *connection, unsigned int status) {
    struct MHD_Response *response = MHD_create_response_from_buffer(0, (void*)"", RESP_MEM);
    if (!response) return MHD_NO;
    /* No Content-Type header for DELETE per spec */
    enum MHD_Result ret = MHD_queue_response(connection, status, response);
    MHD_destroy_response(response);
    return ret;
}

/* Authentication: returns user* if authenticated, else NULL. Optionally returns token string pointer from cookie. */
static User *authenticate(struct MHD_Connection *connection, const char **out_token) {
    const char *cookie = MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");
    if (!cookie) return NULL;
    pthread_mutex_lock(&g_lock);
    Session *s = find_session_by_token(cookie);
    User *u = NULL;
    if (s) u = find_user_by_id(s->user_id);
    pthread_mutex_unlock(&g_lock);
    if (u && out_token) *out_token = cookie;
    return u;
}

/* Request context for accumulating body */
typedef struct {
    char *body;
    size_t size;
} ReqCtx;

static void request_completed_callback(void *cls, struct MHD_Connection *connection, void **con_cls, enum MHD_RequestTerminationCode toe) {
    (void)cls; (void)connection; (void)toe;
    ReqCtx *ctx = (ReqCtx*)(*con_cls);
    if (ctx) {
        free(ctx->body);
        free(ctx);
        *con_cls = NULL;
    }
}

/* Helpers to parse id from URL: returns 1 if matches and sets *out_id */
static int parse_todo_id(const char *url, int *out_id) {
    const char *prefix = "/todos/";
    size_t plen = strlen(prefix);
    if (strncmp(url, prefix, plen) != 0) return 0;
    const char *p = url + plen;
    if (*p == '\0') return 0;
    char *end;
    long v = strtol(p, &end, 10);
    if (v <= 0 || *end != '\0') return 0;
    *out_id = (int)v;
    return 1;
}

/* JSON builders */
static cJSON *user_to_json(const User *u) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddNumberToObject(o, "id", u->id);
    cJSON_AddStringToObject(o, "username", u->username);
    return o;
}
static cJSON *todo_to_json(const Todo *t) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddNumberToObject(o, "id", t->id);
    cJSON_AddStringToObject(o, "title", t->title ? t->title : "");
    cJSON_AddStringToObject(o, "description", t->description ? t->description : "");
    cJSON_AddBoolToObject(o, "completed", t->completed ? 1 : 0);
    cJSON_AddStringToObject(o, "created_at", t->created_at);
    cJSON_AddStringToObject(o, "updated_at", t->updated_at);
    return o;
}

/* Endpoint handlers */
static enum MHD_Result handle_register(struct MHD_Connection *connection, const char *body) {
    cJSON *root = cJSON_Parse(body ? body : "");
    if (!root) return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    cJSON *juser = cJSON_GetObjectItemCaseSensitive(root, "username");
    cJSON *jpass = cJSON_GetObjectItemCaseSensitive(root, "password");
    if (!cJSON_IsString(juser) || !cJSON_IsString(jpass)) { cJSON_Delete(root); return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    const char *username = juser->valuestring;
    const char *password = jpass->valuestring;

    if (!is_valid_username(username)) { cJSON_Delete(root); return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid username"); }
    if ((int)strlen(password) < MIN_PASSWORD_LEN) { cJSON_Delete(root); return send_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short"); }

    pthread_mutex_lock(&g_lock);
    if (find_user_by_username(username)) { pthread_mutex_unlock(&g_lock); cJSON_Delete(root); return send_error(connection, MHD_HTTP_CONFLICT, "Username already exists"); }
    ensure_users_cap();
    User *u = &users[users_len++];
    u->id = next_user_id++;
    u->username = xstrdup(username);
    u->password = xstrdup(password);
    /* build response while holding lock to ensure consistent read */
    cJSON *out = user_to_json(u);
    pthread_mutex_unlock(&g_lock);

    char *s = cJSON_PrintUnformatted(out);
    cJSON_Delete(out);
    cJSON_Delete(root);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_CREATED, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_login(struct MHD_Connection *connection, const char *body) {
    cJSON *root = cJSON_Parse(body ? body : "");
    if (!root) return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    cJSON *juser = cJSON_GetObjectItemCaseSensitive(root, "username");
    cJSON *jpass = cJSON_GetObjectItemCaseSensitive(root, "password");
    if (!cJSON_IsString(juser) || !cJSON_IsString(jpass)) { cJSON_Delete(root); return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    const char *username = juser->valuestring;
    const char *password = jpass->valuestring;

    pthread_mutex_lock(&g_lock);
    User *u = find_user_by_username(username);
    if (!u || strcmp(u->password, password) != 0) { pthread_mutex_unlock(&g_lock); cJSON_Delete(root); return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials"); }
    /* create session */
    ensure_sessions_cap();
    Session *s = &sessions[sessions_len++];
    generate_token(s->token);
    s->user_id = u->id;
    cJSON *out = user_to_json(u);
    pthread_mutex_unlock(&g_lock);

    char cookie_hdr[128];
    snprintf(cookie_hdr, sizeof(cookie_hdr), "session_id=%s; Path=/; HttpOnly", s->token);

    char *resp = cJSON_PrintUnformatted(out);
    cJSON_Delete(out);

    struct MHD_Response *response = MHD_create_response_from_buffer(strlen(resp), (void*)resp, RESP_MEM);
    if (!response) { free(resp); cJSON_Delete(root); return MHD_NO; }
    MHD_add_response_header(response, MHD_HTTP_HEADER_CONTENT_TYPE, "application/json");
    MHD_add_response_header(response, MHD_HTTP_HEADER_SET_COOKIE, cookie_hdr);
    enum MHD_Result ret = MHD_queue_response(connection, MHD_HTTP_OK, response);
    MHD_destroy_response(response);
    free(resp);
    cJSON_Delete(root);
    return ret;
}

static enum MHD_Result handle_logout(struct MHD_Connection *connection) {
    const char *cookie = MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");
    if (!cookie) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    int ok = 0;
    pthread_mutex_lock(&g_lock);
    for (size_t i = 0; i < sessions_len; i++) {
        if (strcmp(sessions[i].token, cookie) == 0) {
            /* remove session by swapping last */
            sessions[i] = sessions[sessions_len - 1];
            sessions_len--;
            ok = 1;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    if (!ok) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    cJSON *out = cJSON_CreateObject();
    char *s = cJSON_PrintUnformatted(out);
    cJSON_Delete(out);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_me(struct MHD_Connection *connection, User *u) {
    if (!u) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    pthread_mutex_lock(&g_lock);
    User *u2 = find_user_by_id(u->id);
    if (!u2) { pthread_mutex_unlock(&g_lock); return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required"); }
    cJSON *out = user_to_json(u2);
    pthread_mutex_unlock(&g_lock);
    char *s = cJSON_PrintUnformatted(out);
    cJSON_Delete(out);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_password(struct MHD_Connection *connection, User *u, const char *body) {
    if (!u) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    cJSON *root = cJSON_Parse(body ? body : "");
    if (!root) return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    cJSON *jold = cJSON_GetObjectItemCaseSensitive(root, "old_password");
    cJSON *jnew = cJSON_GetObjectItemCaseSensitive(root, "new_password");
    if (!cJSON_IsString(jold) || !cJSON_IsString(jnew)) { cJSON_Delete(root); return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }

    int unauthorized = 0;
    int badreq = 0;
    pthread_mutex_lock(&g_lock);
    User *u2 = find_user_by_id(u->id);
    if (!u2 || strcmp(u2->password, jold->valuestring) != 0) unauthorized = 1;
    else if ((int)strlen(jnew->valuestring) < MIN_PASSWORD_LEN) badreq = 1;
    else {
        free(u2->password);
        u2->password = xstrdup(jnew->valuestring);
    }
    pthread_mutex_unlock(&g_lock);

    cJSON_Delete(root);
    if (unauthorized) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    if (badreq) return send_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    cJSON *out = cJSON_CreateObject();
    char *s = cJSON_PrintUnformatted(out);
    cJSON_Delete(out);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static int cmp_todo_ptr_id_asc(const void *a, const void *b) {
    const Todo * const *ta = (const Todo* const*)a;
    const Todo * const *tb = (const Todo* const*)b;
    if ((*ta)->id < (*tb)->id) return -1;
    if ((*ta)->id > (*tb)->id) return 1;
    return 0;
}

static enum MHD_Result handle_todos_list(struct MHD_Connection *connection, User *u) {
    if (!u) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    cJSON *arr = cJSON_CreateArray();

    pthread_mutex_lock(&g_lock);
    /* collect user's todos pointers */
    size_t count = 0;
    for (size_t i = 0; i < todos_len; i++) if (todos[i].user_id == u->id) count++;
    Todo **vec = NULL;
    if (count) vec = (Todo**)malloc(count * sizeof(Todo*));
    size_t idx = 0;
    for (size_t i = 0; i < todos_len; i++) if (todos[i].user_id == u->id) vec[idx++] = &todos[i];
    if (count > 1) qsort(vec, count, sizeof(Todo*), cmp_todo_ptr_id_asc);
    for (size_t i = 0; i < count; i++) {
        cJSON *o = todo_to_json(vec[i]);
        cJSON_AddItemToArray(arr, o);
    }
    free(vec);
    pthread_mutex_unlock(&g_lock);

    char *s = cJSON_PrintUnformatted(arr);
    cJSON_Delete(arr);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_todos_create(struct MHD_Connection *connection, User *u, const char *body) {
    if (!u) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    cJSON *root = cJSON_Parse(body ? body : "");
    if (!root) return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    cJSON *jtitle = cJSON_GetObjectItemCaseSensitive(root, "title");
    cJSON *jdesc = cJSON_GetObjectItemCaseSensitive(root, "description");
    if (!cJSON_IsString(jtitle) || strlen(jtitle->valuestring) == 0) { cJSON_Delete(root); return send_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required"); }
    const char *desc = (cJSON_IsString(jdesc) ? jdesc->valuestring : "");

    cJSON *out = NULL;
    pthread_mutex_lock(&g_lock);
    ensure_todos_cap();
    Todo *nt = &todos[todos_len++];
    nt->id = next_todo_id++;
    nt->user_id = u->id;
    nt->title = xstrdup(jtitle->valuestring);
    nt->description = xstrdup(desc);
    nt->completed = 0;
    now_iso8601(nt->created_at);
    memcpy(nt->updated_at, nt->created_at, sizeof(nt->created_at));
    out = todo_to_json(nt); /* cJSON duplicates strings internally */
    pthread_mutex_unlock(&g_lock);

    cJSON_Delete(root);
    char *s = cJSON_PrintUnformatted(out);
    cJSON_Delete(out);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_CREATED, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_todos_get(struct MHD_Connection *connection, User *u, int todo_id) {
    if (!u) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    int notfound = 0;
    cJSON *out = NULL;
    pthread_mutex_lock(&g_lock);
    Todo *t = find_todo_by_id(todo_id);
    if (!t || t->user_id != u->id) notfound = 1;
    else out = todo_to_json(t);
    pthread_mutex_unlock(&g_lock);
    if (notfound) return send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    char *s = cJSON_PrintUnformatted(out);
    cJSON_Delete(out);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_todos_update(struct MHD_Connection *connection, User *u, int todo_id, const char *body) {
    if (!u) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    cJSON *root = cJSON_Parse(body ? body : "");
    if (!root) return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    cJSON *jtitle = cJSON_GetObjectItemCaseSensitive(root, "title");
    cJSON *jdesc = cJSON_GetObjectItemCaseSensitive(root, "description");
    cJSON *jcomp = cJSON_GetObjectItemCaseSensitive(root, "completed");

    if (jtitle && (!cJSON_IsString(jtitle) || strlen(jtitle->valuestring) == 0)) { cJSON_Delete(root); return send_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required"); }
    if (jdesc && !cJSON_IsString(jdesc)) { cJSON_Delete(root); return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }
    if (jcomp && !cJSON_IsBool(jcomp)) { cJSON_Delete(root); return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON"); }

    int notfound = 0;
    cJSON *out = NULL;
    pthread_mutex_lock(&g_lock);
    Todo *t = find_todo_by_id(todo_id);
    if (!t || t->user_id != u->id) {
        notfound = 1;
    } else {
        if (jtitle) { free(t->title); t->title = xstrdup(jtitle->valuestring); }
        if (jdesc) { free(t->description); t->description = xstrdup(jdesc->valuestring); }
        if (jcomp) { t->completed = cJSON_IsTrue(jcomp) ? 1 : 0; }
        now_iso8601(t->updated_at);
        out = todo_to_json(t);
    }
    pthread_mutex_unlock(&g_lock);

    cJSON_Delete(root);
    if (notfound) return send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");

    char *s = cJSON_PrintUnformatted(out);
    cJSON_Delete(out);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, s);
    free(s);
    return ret;
}

static enum MHD_Result handle_todos_delete(struct MHD_Connection *connection, User *u, int todo_id) {
    if (!u) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    int notfound = 1;
    pthread_mutex_lock(&g_lock);
    for (size_t i = 0; i < todos_len; i++) {
        if (todos[i].id == todo_id && todos[i].user_id == u->id) {
            /* free strings */
            free(todos[i].title);
            free(todos[i].description);
            /* remove by swap last */
            todos[i] = todos[todos_len - 1];
            todos_len--;
            notfound = 0;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    if (notfound) return send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    return send_no_content(connection, MHD_HTTP_NO_CONTENT);
}

/* Central handler */
static enum MHD_Result ahc(void *cls, struct MHD_Connection *connection, const char *url, const char *method, const char *version, const char *upload_data, size_t *upload_data_size, void **con_cls) {
    (void)cls; (void)version;
    ReqCtx *ctx = *con_cls;
    if (!ctx) {
        ctx = calloc(1, sizeof(ReqCtx));
        if (!ctx) return MHD_NO;
        *con_cls = ctx;
        return MHD_YES; /* wait for next call with possible upload data */
    }

    if (*upload_data_size) {
        size_t old = ctx->size;
        char *nb = realloc(ctx->body, old + *upload_data_size + 1);
        if (!nb) return MHD_NO;
        ctx->body = nb;
        memcpy(ctx->body + old, upload_data, *upload_data_size);
        ctx->size = old + *upload_data_size;
        ctx->body[ctx->size] = '\0';
        *upload_data_size = 0;
        return MHD_YES;
    }

    /* Authentication where needed */
    User *auth_user = NULL;
    const char *cookie_token = NULL; (void)cookie_token;
    if ((strcmp(url, "/logout") == 0) || (strcmp(url, "/me") == 0) || (strcmp(url, "/password") == 0) || (strncmp(url, "/todos", 6) == 0)) {
        auth_user = authenticate(connection, &cookie_token);
    }

    /* Routing */
    if (strcmp(method, "POST") == 0 && strcmp(url, "/register") == 0) {
        return handle_register(connection, ctx->body);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/login") == 0) {
        return handle_login(connection, ctx->body);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/logout") == 0) {
        if (!auth_user) return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
        return handle_logout(connection);
    } else if (strcmp(method, "GET") == 0 && strcmp(url, "/me") == 0) {
        return handle_me(connection, auth_user);
    } else if (strcmp(method, "PUT") == 0 && strcmp(url, "/password") == 0) {
        return handle_password(connection, auth_user, ctx->body);
    } else if (strcmp(method, "GET") == 0 && strcmp(url, "/todos") == 0) {
        return handle_todos_list(connection, auth_user);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/todos") == 0) {
        return handle_todos_create(connection, auth_user, ctx->body);
    } else if (strncmp(url, "/todos/", 7) == 0) {
        int id = 0;
        if (!parse_todo_id(url, &id)) {
            return send_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
        }
        if (strcmp(method, "GET") == 0) {
            return handle_todos_get(connection, auth_user, id);
        } else if (strcmp(method, "PUT") == 0) {
            return handle_todos_update(connection, auth_user, id, ctx->body);
        } else if (strcmp(method, "DELETE") == 0) {
            return handle_todos_delete(connection, auth_user, id);
        } else {
            return send_error(connection, MHD_HTTP_METHOD_NOT_ALLOWED, "Method not allowed");
        }
    }

    return send_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
}

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        }
    }

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_INTERNAL_POLLING_THREAD,
                                                 (uint16_t)port,
                                                 NULL, NULL,
                                                 &ahc, NULL,
                                                 MHD_OPTION_NOTIFY_COMPLETED, request_completed_callback, NULL,
                                                 MHD_OPTION_END);
    if (!daemon) {
        fprintf(stderr, "Failed to start server on 0.0.0.0:%d\n", port);
        return 1;
    }
    printf("Server listening on 0.0.0.0:%d\n", port);
    fflush(stdout);

    /* Run until killed */
    while (1) pause();

    MHD_stop_daemon(daemon);
    return 0;
}

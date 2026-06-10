#define _GNU_SOURCE
#include <microhttpd.h>
#include <jansson.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
#include <limits.h>

#define MAX_USERNAME_LEN 50
#define MAX_PASSWORD_LEN 256
#define ISO_TIME_LEN 21
#define TOKEN_LEN 64

struct User {
    int id;
    char username[MAX_USERNAME_LEN + 1];
    char password[MAX_PASSWORD_LEN + 1];
    struct User *next;
};

struct Todo {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0 or 1
    char created_at[ISO_TIME_LEN];
    char updated_at[ISO_TIME_LEN];
    struct Todo *next;
};

struct Session {
    char token[TOKEN_LEN + 1];
    int user_id;
    struct Session *next;
};

static struct User *users_head = NULL;
static struct Todo *todos_head = NULL;
static struct Session *sessions_head = NULL;
static int next_user_id = 1;
static int next_todo_id = 1;
static pthread_mutex_t db_mutex = PTHREAD_MUTEX_INITIALIZER;

struct RequestCtx {
    char *body;
    size_t body_size;
    int processed;
};

static void iso8601_now(char out[ISO_TIME_LEN]) {
    time_t t = time(NULL);
    struct tm tm;
#if defined(_GNU_SOURCE) || defined(_POSIX_C_SOURCE)
    gmtime_r(&t, &tm);
#else
    struct tm *ptm = gmtime(&t);
    if (ptm) tm = *ptm; else memset(&tm, 0, sizeof(tm));
#endif
    strftime(out, ISO_TIME_LEN, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

static int gen_token(char out[TOKEN_LEN + 1]) {
    FILE *f = fopen("/dev/urandom", "rb");
    if (!f) return -1;
    unsigned char bytes[32];
    size_t r = fread(bytes, 1, sizeof(bytes), f);
    fclose(f);
    if (r != sizeof(bytes)) return -1;
    static const char *hex = "0123456789abcdef";
    for (size_t i = 0; i < sizeof(bytes); ++i) {
        out[i*2] = hex[(bytes[i] >> 4) & 0xF];
        out[i*2+1] = hex[bytes[i] & 0xF];
    }
    out[64] = '\0';
    return 0;
}

static int username_valid(const char *u) {
    size_t len = u ? strlen(u) : 0;
    if (len < 3 || len > 50) return 0;
    for (size_t i = 0; i < len; ++i) {
        if (!(isalnum((unsigned char)u[i]) || u[i] == '_')) return 0;
    }
    return 1;
}

static int password_valid(const char *p) {
    size_t len = p ? strlen(p) : 0;
    return len >= 8;
}

static struct User* find_user_by_username(const char *username) {
    struct User *u = users_head;
    while (u) {
        if (strcmp(u->username, username) == 0) return u;
        u = u->next;
    }
    return NULL;
}

static struct User* find_user_by_id(int id) {
    struct User *u = users_head;
    while (u) {
        if (u->id == id) return u;
        u = u->next;
    }
    return NULL;
}

static struct Session* find_session_by_token(const char *token) {
    struct Session *s = sessions_head;
    while (s) {
        if (strcmp(s->token, token) == 0) return s;
        s = s->next;
    }
    return NULL;
}

static struct Todo* find_todo_by_id(int id) {
    struct Todo *t = todos_head;
    while (t) {
        if (t->id == id) return t;
        t = t->next;
    }
    return NULL;
}

static void delete_session_token(const char *token) {
    struct Session **pp = &sessions_head;
    while (*pp) {
        if (strcmp((*pp)->token, token) == 0) {
            struct Session *tmp = *pp;
            *pp = (*pp)->next;
            free(tmp);
            return;
        }
        pp = &((*pp)->next);
    }
}

static void delete_todo(struct Todo *todel) {
    struct Todo **pp = &todos_head;
    while (*pp) {
        if (*pp == todel) {
            struct Todo *tmp = *pp;
            *pp = (*pp)->next;
            free(tmp->title);
            free(tmp->description);
            free(tmp);
            return;
        }
        pp = &((*pp)->next);
    }
}

static enum MHD_Result send_json(struct MHD_Connection *connection, unsigned int status_code, json_t *obj) {
    char *data = NULL;
    size_t len = 0;
    if (obj) {
        data = json_dumps(obj, JSON_COMPACT);
        if (!data) return MHD_NO;
        len = strlen(data);
    }
    struct MHD_Response *response;
    if (obj) {
        response = MHD_create_response_from_buffer(len, (void*)data, MHD_RESPMEM_MUST_FREE);
    } else {
        response = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
    }
    if (!response) {
        if (data) free(data);
        return MHD_NO;
    }
    if (status_code != MHD_HTTP_NO_CONTENT) {
        MHD_add_response_header(response, "Content-Type", "application/json");
    }
    enum MHD_Result ret = MHD_queue_response(connection, status_code, response);
    MHD_destroy_response(response);
    return ret;
}

static enum MHD_Result send_error(struct MHD_Connection *connection, unsigned int status_code, const char *message) {
    json_t *obj = json_object();
    json_object_set_new(obj, "error", json_string(message));
    enum MHD_Result ret = send_json(connection, status_code, obj);
    json_decref(obj);
    return ret;
}

static const char* get_cookie_header(struct MHD_Connection *connection) {
    return MHD_lookup_connection_value(connection, MHD_HEADER_KIND, "Cookie");
}

static int parse_cookie_value(const char *cookie_header, const char *key, char *out, size_t outlen) {
    if (!cookie_header) return 0;
    size_t keylen = strlen(key);
    const char *p = cookie_header;
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == ';') p++;
        if (!*p) break;
        const char *kstart = p;
        while (*p && *p != '=' && *p != ';') p++;
        const char *kend = p;
        if (*p != '=') {
            while (*p && *p != ';') p++;
            continue;
        }
        p++; // skip '='
        const char *vstart = p;
        while (*p && *p != ';') p++;
        const char *vend = p;
        size_t klen = (size_t)(kend - kstart);
        if (klen == keylen && strncmp(kstart, key, klen) == 0) {
            size_t vlen = (size_t)(vend - vstart);
            if (vlen >= outlen) vlen = outlen - 1;
            memcpy(out, vstart, vlen);
            out[vlen] = '\0';
            return 1;
        }
        if (*p == ';') p++;
    }
    return 0;
}

// Returns 1 if authenticated; 0 if not (and error already sent)
static int require_auth(struct MHD_Connection *connection, int *out_user_id, char *out_token, size_t out_token_len) {
    const char *cookie = get_cookie_header(connection);
    char token[TOKEN_LEN + 1];
    if (!parse_cookie_value(cookie, "session_id", token, sizeof(token))) {
        send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
        return 0;
    }
    pthread_mutex_lock(&db_mutex);
    struct Session *s = find_session_by_token(token);
    if (!s) {
        pthread_mutex_unlock(&db_mutex);
        send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
        return 0;
    }
    int uid = s->user_id;
    pthread_mutex_unlock(&db_mutex);
    if (out_user_id) *out_user_id = uid;
    if (out_token) strncpy(out_token, token, out_token_len);
    return 1;
}

static json_t* user_to_json(struct User *u) {
    json_t *obj = json_object();
    json_object_set_new(obj, "id", json_integer(u->id));
    json_object_set_new(obj, "username", json_string(u->username));
    return obj;
}

static json_t* todo_to_json(struct Todo *t) {
    json_t *obj = json_object();
    json_object_set_new(obj, "id", json_integer(t->id));
    json_object_set_new(obj, "title", json_string(t->title));
    json_object_set_new(obj, "description", json_string(t->description ? t->description : ""));
    json_object_set_new(obj, "completed", json_boolean(t->completed));
    json_object_set_new(obj, "created_at", json_string(t->created_at));
    json_object_set_new(obj, "updated_at", json_string(t->updated_at));
    return obj;
}

static enum MHD_Result handle_register(struct MHD_Connection *connection, const char *body) {
    json_error_t jerr;
    json_t *root = json_loads(body ? body : "", 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    const char *username = NULL, *password = NULL;
    json_t *juser = json_object_get(root, "username");
    json_t *jpass = json_object_get(root, "password");
    if (juser && json_is_string(juser)) username = json_string_value(juser);
    if (jpass && json_is_string(jpass)) password = json_string_value(jpass);
    if (!username || !username_valid(username)) {
        json_decref(root);
        return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }
    if (!password || !password_valid(password)) {
        json_decref(root);
        return send_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    pthread_mutex_lock(&db_mutex);
    if (find_user_by_username(username)) {
        pthread_mutex_unlock(&db_mutex);
        json_decref(root);
        return send_error(connection, MHD_HTTP_CONFLICT, "Username already exists");
    }
    struct User *u = (struct User*)calloc(1, sizeof(struct User));
    u->id = next_user_id++;
    strncpy(u->username, username, MAX_USERNAME_LEN);
    u->username[MAX_USERNAME_LEN] = '\0';
    strncpy(u->password, password, MAX_PASSWORD_LEN);
    u->password[MAX_PASSWORD_LEN] = '\0';
    u->next = users_head;
    users_head = u;
    pthread_mutex_unlock(&db_mutex);

    json_t *resp = user_to_json(u);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_CREATED, resp);
    json_decref(resp);
    json_decref(root);
    return ret;
}

static enum MHD_Result handle_login(struct MHD_Connection *connection, const char *body) {
    json_error_t jerr;
    json_t *root = json_loads(body ? body : "", 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    const char *username = NULL, *password = NULL;
    json_t *juser = json_object_get(root, "username");
    json_t *jpass = json_object_get(root, "password");
    if (juser && json_is_string(juser)) username = json_string_value(juser);
    if (jpass && json_is_string(jpass)) password = json_string_value(jpass);

    pthread_mutex_lock(&db_mutex);
    struct User *u = username ? find_user_by_username(username) : NULL;
    if (!u || !password || strcmp(u->password, password) != 0) {
        pthread_mutex_unlock(&db_mutex);
        json_decref(root);
        return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    // Create session token
    char token[TOKEN_LEN + 1];
    if (gen_token(token) != 0) {
        pthread_mutex_unlock(&db_mutex);
        json_decref(root);
        return send_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Failed to generate token");
    }
    struct Session *s = (struct Session*)calloc(1, sizeof(struct Session));
    strncpy(s->token, token, TOKEN_LEN);
    s->token[TOKEN_LEN] = '\0';
    s->user_id = u->id;
    s->next = sessions_head;
    sessions_head = s;
    pthread_mutex_unlock(&db_mutex);

    json_t *resp = user_to_json(u);
    char set_cookie[128 + TOKEN_LEN];
    snprintf(set_cookie, sizeof(set_cookie), "session_id=%s; Path=/; HttpOnly", token);
    char *data = json_dumps(resp, JSON_COMPACT);
    json_decref(resp);
    if (!data) {
        json_decref(root);
        return send_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Internal error");
    }
    size_t len = strlen(data);
    struct MHD_Response *response = MHD_create_response_from_buffer(len, (void*)data, MHD_RESPMEM_MUST_FREE);
    if (!response) {
        free(data);
        json_decref(root);
        return MHD_NO;
    }
    MHD_add_response_header(response, "Content-Type", "application/json");
    MHD_add_response_header(response, "Set-Cookie", set_cookie);
    enum MHD_Result ret = MHD_queue_response(connection, MHD_HTTP_OK, response);
    MHD_destroy_response(response);
    json_decref(root);
    return ret;
}

static enum MHD_Result handle_logout(struct MHD_Connection *connection) {
    int uid = 0; char token[TOKEN_LEN + 1] = {0};
    if (!require_auth(connection, &uid, token, sizeof(token))) return MHD_YES; // already responded
    pthread_mutex_lock(&db_mutex);
    delete_session_token(token);
    pthread_mutex_unlock(&db_mutex);
    json_t *obj = json_object();
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, obj);
    json_decref(obj);
    return ret;
}

static enum MHD_Result handle_me(struct MHD_Connection *connection) {
    int uid = 0;
    if (!require_auth(connection, &uid, NULL, 0)) return MHD_YES;
    pthread_mutex_lock(&db_mutex);
    struct User *u = find_user_by_id(uid);
    pthread_mutex_unlock(&db_mutex);
    if (!u) return send_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "User not found");
    json_t *obj = user_to_json(u);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, obj);
    json_decref(obj);
    return ret;
}

static enum MHD_Result handle_password(struct MHD_Connection *connection, const char *body) {
    int uid = 0;
    if (!require_auth(connection, &uid, NULL, 0)) return MHD_YES;
    json_error_t jerr;
    json_t *root = json_loads(body ? body : "", 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    const char *oldp = NULL, *newp = NULL;
    json_t *jold = json_object_get(root, "old_password");
    json_t *jnew = json_object_get(root, "new_password");
    if (jold && json_is_string(jold)) oldp = json_string_value(jold);
    if (jnew && json_is_string(jnew)) newp = json_string_value(jnew);

    pthread_mutex_lock(&db_mutex);
    struct User *u = find_user_by_id(uid);
    if (!u || !oldp || strcmp(u->password, oldp) != 0) {
        pthread_mutex_unlock(&db_mutex);
        json_decref(root);
        return send_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    if (!newp || !password_valid(newp)) {
        pthread_mutex_unlock(&db_mutex);
        json_decref(root);
        return send_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    strncpy(u->password, newp, MAX_PASSWORD_LEN);
    u->password[MAX_PASSWORD_LEN] = '\0';
    pthread_mutex_unlock(&db_mutex);

    json_t *obj = json_object();
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, obj);
    json_decref(obj);
    json_decref(root);
    return ret;
}

static enum MHD_Result handle_todos_list(struct MHD_Connection *connection) {
    int uid = 0;
    if (!require_auth(connection, &uid, NULL, 0)) return MHD_YES;
    pthread_mutex_lock(&db_mutex);
    json_t *arr = json_array();
    struct Todo *t = todos_head;
    while (t) {
        if (t->user_id == uid) {
            json_t *jt = todo_to_json(t);
            json_array_append_new(arr, jt);
        }
        t = t->next;
    }
    pthread_mutex_unlock(&db_mutex);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, arr);
    json_decref(arr);
    return ret;
}

static enum MHD_Result handle_todos_create(struct MHD_Connection *connection, const char *body) {
    int uid = 0;
    if (!require_auth(connection, &uid, NULL, 0)) return MHD_YES;
    json_error_t jerr;
    json_t *root = json_loads(body ? body : "", 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    const char *title = NULL; const char *desc = "";
    json_t *jtitle = json_object_get(root, "title");
    if (jtitle && json_is_string(jtitle)) title = json_string_value(jtitle);
    json_t *jdesc = json_object_get(root, "description");
    if (jdesc && json_is_string(jdesc)) desc = json_string_value(jdesc);
    if (!title || strlen(title) == 0) {
        json_decref(root);
        return send_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
    }

    struct Todo *t = (struct Todo*)calloc(1, sizeof(struct Todo));
    t->user_id = uid;
    t->id = 0; // set after lock
    t->title = strdup(title);
    t->description = strdup(desc ? desc : "");
    t->completed = 0;
    iso8601_now(t->created_at);
    strncpy(t->updated_at, t->created_at, ISO_TIME_LEN);

    pthread_mutex_lock(&db_mutex);
    t->id = next_todo_id++;
    // append at end to preserve order
    if (!todos_head) {
        todos_head = t;
    } else {
        struct Todo *cur = todos_head;
        while (cur->next) cur = cur->next;
        cur->next = t;
    }
    pthread_mutex_unlock(&db_mutex);

    json_t *resp = todo_to_json(t);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_CREATED, resp);
    json_decref(resp);
    json_decref(root);
    return ret;
}

static enum MHD_Result handle_todo_get(struct MHD_Connection *connection, int id) {
    int uid = 0;
    if (!require_auth(connection, &uid, NULL, 0)) return MHD_YES;
    pthread_mutex_lock(&db_mutex);
    struct Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != uid) {
        pthread_mutex_unlock(&db_mutex);
        return send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    json_t *resp = todo_to_json(t);
    pthread_mutex_unlock(&db_mutex);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, resp);
    json_decref(resp);
    return ret;
}

static enum MHD_Result handle_todo_update(struct MHD_Connection *connection, int id, const char *body) {
    int uid = 0;
    if (!require_auth(connection, &uid, NULL, 0)) return MHD_YES;
    json_error_t jerr;
    json_t *root = json_loads(body ? body : "", 0, &jerr);
    if (!root || !json_is_object(root)) {
        if (root) json_decref(root);
        return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    pthread_mutex_lock(&db_mutex);
    struct Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != uid) {
        pthread_mutex_unlock(&db_mutex);
        json_decref(root);
        return send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    json_t *jtitle = json_object_get(root, "title");
    if (jtitle) {
        if (!json_is_string(jtitle)) {
            pthread_mutex_unlock(&db_mutex);
            json_decref(root);
            return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid field: title");
        }
        const char *nt = json_string_value(jtitle);
        if (!nt || strlen(nt) == 0) {
            pthread_mutex_unlock(&db_mutex);
            json_decref(root);
            return send_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
        }
        free(t->title);
        t->title = strdup(nt);
    }
    json_t *jdesc = json_object_get(root, "description");
    if (jdesc) {
        if (!json_is_string(jdesc)) {
            pthread_mutex_unlock(&db_mutex);
            json_decref(root);
            return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid field: description");
        }
        const char *nd = json_string_value(jdesc);
        free(t->description);
        t->description = strdup(nd ? nd : "");
    }
    json_t *jcomp = json_object_get(root, "completed");
    if (jcomp) {
        if (!json_is_boolean(jcomp)) {
            pthread_mutex_unlock(&db_mutex);
            json_decref(root);
            return send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid field: completed");
        }
        t->completed = json_is_true(jcomp) ? 1 : 0;
    }
    iso8601_now(t->updated_at);
    json_t *resp = todo_to_json(t);
    pthread_mutex_unlock(&db_mutex);
    enum MHD_Result ret = send_json(connection, MHD_HTTP_OK, resp);
    json_decref(resp);
    json_decref(root);
    return ret;
}

static enum MHD_Result handle_todo_delete(struct MHD_Connection *connection, int id) {
    int uid = 0;
    if (!require_auth(connection, &uid, NULL, 0)) return MHD_YES;
    pthread_mutex_lock(&db_mutex);
    struct Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != uid) {
        pthread_mutex_unlock(&db_mutex);
        return send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    delete_todo(t);
    pthread_mutex_unlock(&db_mutex);
    // 204 No Content, no body
    return send_json(connection, MHD_HTTP_NO_CONTENT, NULL);
}

static int is_prefix(const char *path, const char *prefix) {
    size_t lp = strlen(prefix);
    return strncmp(path, prefix, lp) == 0;
}

static enum MHD_Result route_request(struct MHD_Connection *connection, const char *method, const char *url, const char *body) {
    // Routes
    if (strcmp(method, "POST") == 0 && strcmp(url, "/register") == 0) {
        return handle_register(connection, body);
    }
    if (strcmp(method, "POST") == 0 && strcmp(url, "/login") == 0) {
        return handle_login(connection, body);
    }
    if (strcmp(method, "POST") == 0 && strcmp(url, "/logout") == 0) {
        return handle_logout(connection);
    }
    if (strcmp(method, "GET") == 0 && strcmp(url, "/me") == 0) {
        return handle_me(connection);
    }
    if (strcmp(method, "PUT") == 0 && strcmp(url, "/password") == 0) {
        return handle_password(connection, body);
    }
    if (strcmp(method, "GET") == 0 && strcmp(url, "/todos") == 0) {
        return handle_todos_list(connection);
    }
    if (strcmp(method, "POST") == 0 && strcmp(url, "/todos") == 0) {
        return handle_todos_create(connection, body);
    }
    if (is_prefix(url, "/todos/")) {
        const char *idstr = url + strlen("/todos/");
        if (*idstr == '\0') {
            return send_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
        }
        char *endptr = NULL;
        long idl = strtol(idstr, &endptr, 10);
        if (*endptr != '\0' || idl <= 0 || idl > INT_MAX) {
            return send_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
        }
        int id = (int)idl;
        if (strcmp(method, "GET") == 0) {
            return handle_todo_get(connection, id);
        } else if (strcmp(method, "PUT") == 0) {
            return handle_todo_update(connection, id, body);
        } else if (strcmp(method, "DELETE") == 0) {
            return handle_todo_delete(connection, id);
        }
    }
    return send_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
}

static enum MHD_Result request_handler(void *cls, struct MHD_Connection *connection,
                           const char *url, const char *method,
                           const char *version, const char *upload_data,
                           size_t *upload_data_size, void **con_cls) {
    (void)cls; (void)version;
    struct RequestCtx *ctx = (struct RequestCtx*)*con_cls;
    if (!ctx) {
        ctx = (struct RequestCtx*)calloc(1, sizeof(struct RequestCtx));
        ctx->body = NULL;
        ctx->body_size = 0;
        ctx->processed = 0;
        *con_cls = (void*)ctx;
        return MHD_YES;
    }

    if (*upload_data_size != 0) {
        size_t old = ctx->body_size;
        ctx->body = (char*)realloc(ctx->body, old + *upload_data_size + 1);
        memcpy(ctx->body + old, upload_data, *upload_data_size);
        ctx->body_size += *upload_data_size;
        ctx->body[ctx->body_size] = '\0';
        *upload_data_size = 0;
        return MHD_YES;
    }

    if (!ctx->processed) {
        ctx->processed = 1;
        const char *body = ctx->body ? ctx->body : NULL;
        return route_request(connection, method, url, body);
    }
    return MHD_YES;
}

static void request_completed_cb(void *cls, struct MHD_Connection *connection, void **con_cls, enum MHD_RequestTerminationCode toe) {
    (void)cls; (void)connection; (void)toe;
    if (!con_cls) return;
    struct RequestCtx *ctx = (struct RequestCtx*)*con_cls;
    if (ctx) {
        if (ctx->body) free(ctx->body);
        free(ctx);
    }
    *con_cls = NULL;
}

static void print_usage(const char *prog) {
    fprintf(stderr, "Usage: %s --port PORT\n", prog);
}

int main(int argc, char *argv[]) {
    int port = 0;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--port") == 0) {
            if (i + 1 < argc) {
                port = atoi(argv[++i]);
            } else {
                print_usage(argv[0]);
                return 1;
            }
        } else {
            print_usage(argv[0]);
            return 1;
        }
    }
    if (port <= 0 || port > 65535) {
        print_usage(argv[0]);
        return 1;
    }

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_INTERNAL_POLLING_THREAD,
                                                 (uint16_t)port,
                                                 NULL, NULL, &request_handler, NULL,
                                                 MHD_OPTION_NOTIFY_COMPLETED, request_completed_cb, NULL,
                                                 MHD_OPTION_END);
    if (!daemon) {
        fprintf(stderr, "Failed to start server on port %d\n", port);
        return 1;
    }
    printf("Server listening on 0.0.0.0:%d\n", port);
    fflush(stdout);
    // Run indefinitely
    while (1) {
        sleep(1);
    }

    MHD_stop_daemon(daemon);
    return 0;
}

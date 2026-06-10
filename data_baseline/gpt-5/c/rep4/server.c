#include <microhttpd.h>
#include <jansson.h>
#include <uuid/uuid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ctype.h>
#include <regex.h>
#include <limits.h>
#include <unistd.h>
#include <signal.h>
#include <arpa/inet.h>
#include <netinet/in.h>

#define MAX_TIME_STR 21 /* YYYY-MM-DDTHH:MM:SSZ */

struct User {
    int id;
    char *username;
    char *password; /* stored as plain for simplicity */
};

struct Session {
    char *token; /* uuid string */
    int user_id;
};

struct Todo {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; /* 0 or 1 */
    char created_at[MAX_TIME_STR];
    char updated_at[MAX_TIME_STR];
};

struct RequestContext {
    char *body;
    size_t size;
    size_t cap;
};

static struct User *users = NULL; size_t users_len = 0; size_t users_cap = 0; int next_user_id = 1;
static struct Session *sessions = NULL; size_t sessions_len = 0; size_t sessions_cap = 0;
static struct Todo *todos = NULL; size_t todos_len = 0; size_t todos_cap = 0; int next_todo_id = 1;

static volatile sig_atomic_t stop_flag = 0;
static void on_sigint(int sig){ (void)sig; stop_flag = 1; }

static void ensure_users_cap(){ if (users_len >= users_cap){ users_cap = users_cap? users_cap*2: 16; users = realloc(users, users_cap * sizeof(*users)); if(!users){ perror("realloc users"); exit(1);} } }
static void ensure_sessions_cap(){ if (sessions_len >= sessions_cap){ sessions_cap = sessions_cap? sessions_cap*2: 16; sessions = realloc(sessions, sessions_cap * sizeof(*sessions)); if(!sessions){ perror("realloc sessions"); exit(1);} } }
static void ensure_todos_cap(){ if (todos_len >= todos_cap){ todos_cap = todos_cap? todos_cap*2: 32; todos = realloc(todos, todos_cap * sizeof(*todos)); if(!todos){ perror("realloc todos"); exit(1);} } }

static void free_user(struct User *u){ if (!u) return; free(u->username); free(u->password); }
static void free_session(struct Session *s){ if (!s) return; free(s->token); }
static void free_todo(struct Todo *t){ if (!t) return; free(t->title); free(t->description); }

static void iso_time_now(char out[MAX_TIME_STR]){
    time_t t = time(NULL);
    struct tm g;
    gmtime_r(&t, &g);
    strftime(out, MAX_TIME_STR, "%Y-%m-%dT%H:%M:%SZ", &g);
}

static int validate_username(const char *username){
    if (!username) return 0;
    size_t len = strlen(username);
    if (len < 3 || len > 50) return 0;
    // regex ^[A-Za-z0-9_]+$
    regex_t regex; int rc = regcomp(&regex, "^[A-Za-z0-9_]+$", REG_EXTENDED | REG_NOSUB);
    if (rc != 0) return 0;
    rc = regexec(&regex, username, 0, NULL, 0);
    regfree(&regex);
    return rc == 0;
}

static struct User* find_user_by_username(const char *username){
    for (size_t i=0;i<users_len;i++){
        if (strcmp(users[i].username, username)==0) return &users[i];
    }
    return NULL;
}

static struct User* find_user_by_id(int id){
    for (size_t i=0;i<users_len;i++){
        if (users[i].id == id) return &users[i];
    }
    return NULL;
}

static char* generate_token(){
    uuid_t uuid; uuid_generate(uuid);
    char *buf = malloc(37);
    if (!buf) return NULL;
    uuid_unparse_lower(uuid, buf);
    return buf;
}

static int session_user_id_from_cookie(const char *cookie_header){
    if (!cookie_header) return 0;
    // parse cookie header to find session_id=<token>
    const char *p = cookie_header;
    while (*p){
        while (isspace((unsigned char)*p)) p++;
        const char *key = p;
        while (*p && *p != '=' && *p != ';') p++;
        size_t keylen = p - key;
        if (*p == '='){
            p++;
            const char *val = p;
            while (*p && *p != ';') p++;
            size_t vallen = p - val;
            // trim spaces around key
            while (keylen>0 && isspace((unsigned char)key[keylen-1])) keylen--;
            while (vallen>0 && isspace((unsigned char)val[0])) { val++; vallen--; }
            while (vallen>0 && isspace((unsigned char)val[vallen-1])) vallen--;
            if (keylen == strlen("session_id") && strncmp(key, "session_id", keylen)==0){
                // compare with sessions
                for (size_t i=0;i<sessions_len;i++){
                    if (strlen(sessions[i].token)==vallen && strncmp(sessions[i].token, val, vallen)==0){
                        return sessions[i].user_id;
                    }
                }
            }
        }
        if (*p == ';') p++;
        while (*p == ' ') p++;
    }
    return 0;
}

static const char* extract_session_token(const char *cookie_header){
    if (!cookie_header) return NULL;
    const char *p = cookie_header;
    while (*p){
        while (isspace((unsigned char)*p)) p++;
        const char *key = p;
        while (*p && *p != '=' && *p != ';') p++;
        size_t keylen = p - key;
        if (*p == '='){
            p++;
            const char *val = p;
            while (*p && *p != ';') p++;
            size_t vallen = p - val;
            while (keylen>0 && isspace((unsigned char)key[keylen-1])) keylen--;
            while (vallen>0 && isspace((unsigned char)val[0])) { val++; vallen--; }
            while (vallen>0 && isspace((unsigned char)val[vallen-1])) vallen--;
            if (keylen == strlen("session_id") && strncmp(key, "session_id", keylen)==0){
                char *token = malloc(vallen+1);
                if (!token) return NULL;
                memcpy(token, val, vallen);
                token[vallen] = '\0';
                return token; // caller must free
            }
        }
        if (*p == ';') p++;
        while (*p == ' ') p++;
    }
    return NULL;
}

static enum MHD_Result send_json_response(struct MHD_Connection *connection, int status, json_t *json){
    char *resp = json_dumps(json, JSON_COMPACT);
    if (!resp) resp = strdup("{}");
    struct MHD_Response *response = MHD_create_response_from_buffer(strlen(resp), (void*)resp, MHD_RESPMEM_MUST_FREE);
    MHD_add_response_header(response, "Content-Type", "application/json");
    enum MHD_Result ret = MHD_queue_response(connection, status, response);
    MHD_destroy_response(response);
    return ret;
}

static enum MHD_Result send_error(struct MHD_Connection *connection, int status, const char *msg){
    json_t *err = json_pack("{s:s}", "error", msg);
    enum MHD_Result ret = send_json_response(connection, status, err);
    json_decref(err);
    return ret;
}

static int auth_user(struct MHD_Connection *connection, int *out_user_id){
    const char *cookie = MHD_lookup_connection_value(connection, MHD_HEADER_KIND, "Cookie");
    int uid = session_user_id_from_cookie(cookie);
    if (uid <= 0){
        send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
        return MHD_YES; // response queued
    }
    *out_user_id = uid;
    return -1; // indicates authenticated, continue handling
}

static struct Todo* find_todo_by_id(int id){
    for (size_t i=0;i<todos_len;i++){
        if (todos[i].id == id) return &todos[i];
    }
    return NULL;
}

static int compare_todo_ptrs_by_id(const void *a, const void *b){
    const struct Todo * const *ta = (const struct Todo* const *)a;
    const struct Todo * const *tb = (const struct Todo* const *)b;
    if ((*ta)->id < (*tb)->id) return -1;
    if ((*ta)->id > (*tb)->id) return 1;
    return 0;
}

static enum MHD_Result request_handler(
    void *cls,
    struct MHD_Connection *connection,
    const char *url,
    const char *method,
    const char *version,
    const char *upload_data,
    size_t *upload_data_size,
    void **con_cls)
{
    (void)cls; (void)version;
    struct RequestContext *ctx = *con_cls;
    if (!ctx){
        ctx = calloc(1, sizeof(*ctx));
        if (!ctx) return MHD_NO;
        ctx->cap = 0; ctx->size = 0; ctx->body = NULL;
        *con_cls = ctx;
        return MHD_YES; // first call, will be called again with upload data
    }

    if (*upload_data_size != 0){
        size_t need = ctx->size + *upload_data_size + 1;
        if (need > ctx->cap){
            size_t newcap = ctx->cap? ctx->cap*2: 1024;
            if (newcap < need) newcap = need;
            char *nb = realloc(ctx->body, newcap);
            if (!nb) return MHD_NO;
            ctx->body = nb; ctx->cap = newcap;
        }
        memcpy(ctx->body + ctx->size, upload_data, *upload_data_size);
        ctx->size += *upload_data_size;
        ctx->body[ctx->size] = '\0';
        *upload_data_size = 0;
        return MHD_YES;
    }

    enum MHD_Result ret = MHD_NO;

    if (strcmp(method, "POST") == 0 && strcmp(url, "/register") == 0){
        json_error_t jerr; json_t *root = NULL;
        if (ctx->body && ctx->size>0){ root = json_loadb(ctx->body, ctx->size, 0, &jerr); }
        const char *username = NULL; const char *password = NULL;
        if (!root || !json_is_object(root)){
            if (root) json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
            goto cleanup;
        }
        json_t *juser = json_object_get(root, "username");
        json_t *jpass = json_object_get(root, "password");
        if (!juser || !json_is_string(juser)){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid username");
            goto cleanup;
        }
        if (!jpass || !json_is_string(jpass)){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
            goto cleanup;
        }
        username = json_string_value(juser);
        password = json_string_value(jpass);
        if (!validate_username(username)){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid username");
            goto cleanup;
        }
        if (strlen(password) < 8){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
            goto cleanup;
        }
        if (find_user_by_username(username)){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_CONFLICT, "Username already exists");
            goto cleanup;
        }
        ensure_users_cap();
        users[users_len].id = next_user_id++;
        users[users_len].username = strdup(username);
        users[users_len].password = strdup(password);
        if (!users[users_len].username || !users[users_len].password){ perror("strdup"); exit(1);}        
        json_t *resp = json_pack("{s:i,s:s}", "id", users[users_len].id, "username", users[users_len].username);
        users_len++;
        ret = send_json_response(connection, MHD_HTTP_CREATED, resp);
        json_decref(resp);
        json_decref(root);
        goto cleanup;
    }

    if (strcmp(method, "POST") == 0 && strcmp(url, "/login") == 0){
        json_error_t jerr; json_t *root = NULL;
        if (ctx->body && ctx->size>0){ root = json_loadb(ctx->body, ctx->size, 0, &jerr); }
        if (!root || !json_is_object(root)){
            if (root) json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
            goto cleanup;
        }
        json_t *juser = json_object_get(root, "username");
        json_t *jpass = json_object_get(root, "password");
        if (!juser || !json_is_string(juser) || !jpass || !json_is_string(jpass)){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
            goto cleanup;
        }
        const char *username = json_string_value(juser);
        const char *password = json_string_value(jpass);
        struct User *u = find_user_by_username(username);
        if (!u || strcmp(u->password, password) != 0){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
            goto cleanup;
        }
        char *tok = generate_token();
        ensure_sessions_cap();
        sessions[sessions_len].token = tok;
        sessions[sessions_len].user_id = u->id;
        sessions_len++;

        json_t *resp = json_pack("{s:i,s:s}", "id", u->id, "username", u->username);
        char *resp_str = json_dumps(resp, JSON_COMPACT);
        json_decref(resp);
        struct MHD_Response *response = MHD_create_response_from_buffer(strlen(resp_str), resp_str, MHD_RESPMEM_MUST_FREE);
        MHD_add_response_header(response, "Content-Type", "application/json");
        char cookie_hdr[256];
        snprintf(cookie_hdr, sizeof(cookie_hdr), "session_id=%s; Path=/; HttpOnly", tok);
        MHD_add_response_header(response, "Set-Cookie", cookie_hdr);
        ret = MHD_queue_response(connection, MHD_HTTP_OK, response);
        MHD_destroy_response(response);
        json_decref(root);
        goto cleanup;
    }

    if (strcmp(method, "POST") == 0 && strcmp(url, "/logout") == 0){
        int uid = 0; ret = auth_user(connection, &uid); if (ret != (enum MHD_Result)-1) goto cleanup;
        const char *cookie = MHD_lookup_connection_value(connection, MHD_HEADER_KIND, "Cookie");
        char *token = (char*)extract_session_token(cookie);
        if (token){
            for (size_t i=0;i<sessions_len;i++){
                if (strcmp(sessions[i].token, token)==0){
                    free_session(&sessions[i]);
                    sessions[i] = sessions[sessions_len-1];
                    sessions_len--;
                    break;
                }
            }
            free(token);
        }
        json_t *empty = json_object();
        ret = send_json_response(connection, MHD_HTTP_OK, empty);
        json_decref(empty);
        goto cleanup;
    }

    if (strcmp(method, "GET") == 0 && strcmp(url, "/me") == 0){
        int uid = 0; ret = auth_user(connection, &uid); if (ret != (enum MHD_Result)-1) goto cleanup;
        struct User *u = find_user_by_id(uid);
        if (!u){ ret = send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required"); goto cleanup; }
        json_t *resp = json_pack("{s:i,s:s}", "id", u->id, "username", u->username);
        ret = send_json_response(connection, MHD_HTTP_OK, resp);
        json_decref(resp);
        goto cleanup;
    }

    if (strcmp(method, "PUT") == 0 && strcmp(url, "/password") == 0){
        int uid = 0; ret = auth_user(connection, &uid); if (ret != (enum MHD_Result)-1) goto cleanup;
        struct User *u = find_user_by_id(uid);
        if (!u){ ret = send_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required"); goto cleanup; }
        json_error_t jerr; json_t *root = NULL;
        if (ctx->body && ctx->size>0){ root = json_loadb(ctx->body, ctx->size, 0, &jerr); }
        if (!root || !json_is_object(root)){
            if (root) json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
            goto cleanup;
        }
        json_t *jold = json_object_get(root, "old_password");
        json_t *jnew = json_object_get(root, "new_password");
        if (!jold || !json_is_string(jold) || !jnew || !json_is_string(jnew)){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
            goto cleanup;
        }
        const char *oldp = json_string_value(jold);
        const char *newp = json_string_value(jnew);
        if (strcmp(u->password, oldp) != 0){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
            goto cleanup;
        }
        if (strlen(newp) < 8){
            json_decref(root);
            ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
            goto cleanup;
        }
        free(u->password); u->password = strdup(newp); if (!u->password){ perror("strdup"); exit(1);}        
        json_t *empty = json_object();
        ret = send_json_response(connection, MHD_HTTP_OK, empty);
        json_decref(empty);
        json_decref(root);
        goto cleanup;
    }

    if (strncmp(url, "/todos", 6) == 0){
        int uid = 0; ret = auth_user(connection, &uid); if (ret != (enum MHD_Result)-1) goto cleanup;
        if (strcmp(url, "/todos") == 0){
            if (strcmp(method, "GET")==0){
                size_t count = 0;
                for (size_t i=0;i<todos_len;i++) if (todos[i].user_id == uid) count++;
                struct Todo **arr = malloc(sizeof(struct Todo*) * (count?count:1));
                size_t idx = 0;
                for (size_t i=0;i<todos_len;i++) if (todos[i].user_id == uid) arr[idx++] = &todos[i];
                if (count>1) qsort(arr, count, sizeof(struct Todo*), compare_todo_ptrs_by_id);
                json_t *list = json_array();
                for (size_t i=0;i<count;i++){
                    struct Todo *t = arr[i];
                    json_t *jt = json_pack("{s:i,s:s,s:s,s:b,s:s,s:s}",
                        "id", t->id,
                        "title", t->title,
                        "description", t->description ? t->description: "",
                        "completed", t->completed?1:0,
                        "created_at", t->created_at,
                        "updated_at", t->updated_at
                    );
                    json_array_append_new(list, jt);
                }
                free(arr);
                ret = send_json_response(connection, MHD_HTTP_OK, list);
                json_decref(list);
                goto cleanup;
            } else if (strcmp(method, "POST")==0){
                json_error_t jerr; json_t *root = NULL;
                if (ctx->body && ctx->size>0){ root = json_loadb(ctx->body, ctx->size, 0, &jerr); }
                if (!root || !json_is_object(root)){
                    if (root) json_decref(root);
                    ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
                    goto cleanup;
                }
                json_t *jtitle = json_object_get(root, "title");
                json_t *jdesc = json_object_get(root, "description");
                if (!jtitle || !json_is_string(jtitle) || strlen(json_string_value(jtitle))==0){
                    json_decref(root);
                    ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
                    goto cleanup;
                }
                const char *title = json_string_value(jtitle);
                const char *desc = NULL; if (jdesc && json_is_string(jdesc)) desc = json_string_value(jdesc);
                ensure_todos_cap();
                struct Todo *t = &todos[todos_len];
                t->id = next_todo_id++;
                t->user_id = uid;
                t->title = strdup(title);
                t->description = strdup(desc?desc:"");
                t->completed = 0;
                iso_time_now(t->created_at);
                memcpy(t->updated_at, t->created_at, MAX_TIME_STR);
                if (!t->title || !t->description){ perror("strdup"); exit(1);}                
                json_t *jt = json_pack("{s:i,s:s,s:s,s:b,s:s,s:s}",
                    "id", t->id,
                    "title", t->title,
                    "description", t->description,
                    "completed", t->completed?1:0,
                    "created_at", t->created_at,
                    "updated_at", t->updated_at
                );
                todos_len++;
                ret = send_json_response(connection, MHD_HTTP_CREATED, jt);
                json_decref(jt);
                json_decref(root);
                goto cleanup;
            } else {
                ret = send_error(connection, MHD_HTTP_METHOD_NOT_ALLOWED, "Method not allowed");
                goto cleanup;
            }
        } else if (strncmp(url, "/todos/", 7) == 0){
            const char *idstr = url + 7; // after '/todos/'
            if (*idstr == '\0') { ret = send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found"); goto cleanup; }
            const char *p = idstr; int valid = 1; if (!isdigit((unsigned char)*p)) valid = 0; int id = 0;
            while (*p){
                if (!isdigit((unsigned char)*p)) { valid = 0; break; }
                int digit = *p - '0';
                if (id > (INT_MAX - digit)/10) { valid = 0; break; }
                id = id*10 + digit; p++;
            }
            if (!valid){ ret = send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found"); goto cleanup; }
            struct Todo *t = find_todo_by_id(id);
            if (!t || t->user_id != uid){ ret = send_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found"); goto cleanup; }
            if (strcmp(method, "GET")==0){
                json_t *jt = json_pack("{s:i,s:s,s:s,s:b,s:s,s:s}",
                    "id", t->id,
                    "title", t->title,
                    "description", t->description ? t->description: "",
                    "completed", t->completed?1:0,
                    "created_at", t->created_at,
                    "updated_at", t->updated_at
                );
                ret = send_json_response(connection, MHD_HTTP_OK, jt);
                json_decref(jt);
                goto cleanup;
            } else if (strcmp(method, "PUT")==0){
                json_error_t jerr; json_t *root = NULL;
                if (ctx->body && ctx->size>0){ root = json_loadb(ctx->body, ctx->size, 0, &jerr); }
                if (!root || !json_is_object(root)){
                    if (root) json_decref(root);
                    ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
                    goto cleanup;
                }
                json_t *jtitle = json_object_get(root, "title");
                json_t *jdesc = json_object_get(root, "description");
                json_t *jcomp = json_object_get(root, "completed");
                if (jtitle){
                    if (!json_is_string(jtitle) || strlen(json_string_value(jtitle))==0){
                        json_decref(root);
                        ret = send_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
                        goto cleanup;
                    }
                    free(t->title); t->title = strdup(json_string_value(jtitle)); if (!t->title){ perror("strdup"); exit(1);}                }
                if (jdesc){
                    if (json_is_string(jdesc)){
                        free(t->description); t->description = strdup(json_string_value(jdesc)); if (!t->description){ perror("strdup"); exit(1);}                    } else if (json_is_null(jdesc)){
                        free(t->description); t->description = strdup(""); if (!t->description){ perror("strdup"); exit(1);}                    } else {
                        // ignore invalid type
                    }
                }
                if (jcomp){
                    if (json_is_boolean(jcomp)){
                        t->completed = json_boolean_value(jcomp) ? 1 : 0;
                    }
                }
                iso_time_now(t->updated_at);
                json_t *jt = json_pack("{s:i,s:s,s:s,s:b,s:s,s:s}",
                    "id", t->id,
                    "title", t->title,
                    "description", t->description ? t->description: "",
                    "completed", t->completed?1:0,
                    "created_at", t->created_at,
                    "updated_at", t->updated_at
                );
                ret = send_json_response(connection, MHD_HTTP_OK, jt);
                json_decref(jt);
                json_decref(root);
                goto cleanup;
            } else if (strcmp(method, "DELETE")==0){
                free_todo(t);
                size_t idx = (size_t)(t - todos);
                todos[idx] = todos[todos_len-1];
                todos_len--;
                struct MHD_Response *response = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
                ret = MHD_queue_response(connection, MHD_HTTP_NO_CONTENT, response);
                MHD_destroy_response(response);
                goto cleanup;
            } else {
                ret = send_error(connection, MHD_HTTP_METHOD_NOT_ALLOWED, "Method not allowed");
                goto cleanup;
            }
        } else {
            ret = send_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
            goto cleanup;
        }
    }

    ret = send_error(connection, MHD_HTTP_NOT_FOUND, "Not found");

cleanup:
    if (ctx){ free(ctx->body); free(ctx); *con_cls = NULL; }
    return ret;
}

static void usage(const char *prog){
    fprintf(stderr, "Usage: %s --port PORT\n", prog);
}

int main(int argc, char *argv[]){
    int port = 0;
    for (int i=1;i<argc;i++){
        if (strcmp(argv[i], "--port")==0){
            if (i+1 < argc){ port = atoi(argv[i+1]); i++; }
        } else if (strncmp(argv[i], "--port=", 8)==0){
            port = atoi(argv[i]+8);
        } else if (strcmp(argv[i], "-p")==0){
            if (i+1 < argc){ port = atoi(argv[i+1]); i++; }
        } else if (strcmp(argv[i], "-h")==0 || strcmp(argv[i], "--help")==0){
            usage(argv[0]); return 1;
        }
    }
    if (port <= 0){ usage(argv[0]); return 1; }

    struct sigaction sa; memset(&sa, 0, sizeof(sa)); sa.sa_handler = on_sigint; sigaction(SIGINT, &sa, NULL); sigaction(SIGTERM, &sa, NULL);

    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY); // 0.0.0.0
    addr.sin_port = htons(port);

    struct MHD_Daemon *daemon = MHD_start_daemon(
        MHD_USE_INTERNAL_POLLING_THREAD,
        (uint16_t)port,
        NULL, NULL,
        &request_handler, NULL,
        MHD_OPTION_SOCK_ADDR, (struct sockaddr*)&addr,
        MHD_OPTION_END
    );

    if (daemon == NULL){
        fprintf(stderr, "Failed to start server on port %d\n", port);
        return 1;
    }
    fprintf(stderr, "Server listening on 0.0.0.0:%d\n", port);

    while (!stop_flag){
        pause();
    }

    MHD_stop_daemon(daemon);

    for (size_t i=0;i<todos_len;i++) free_todo(&todos[i]);
    free(todos);
    for (size_t i=0;i<sessions_len;i++) free_session(&sessions[i]);
    free(sessions);
    for (size_t i=0;i<users_len;i++) free_user(&users[i]);
    free(users);
    return 0;
}

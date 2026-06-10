#include <microhttpd.h>
#include <jansson.h>
#include <uuid/uuid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <regex.h>
#include <time.h>
#include <ctype.h>
#include <errno.h>
#include <stdint.h>

#define MAX_BODY_SIZE 1048576 /* 1MB */

struct User {
    int id;
    char *username;
    char *password;
};

struct Session {
    char *token; // uuid string
    int user_id;
};

struct Todo {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0/1
    char created_at[21]; // YYYY-MM-DDTHH:MM:SSZ + NUL
    char updated_at[21];
};

struct ConnectionInfo {
    char *method;
    char *url;
    char *body;
    size_t body_size;
    int processed; // flag indicating we responded
};

static struct User *users = NULL; size_t users_count = 0; size_t users_cap = 0; int next_user_id = 1;
static struct Session *sessions = NULL; size_t sessions_count = 0; size_t sessions_cap = 0;
static struct Todo *todos = NULL; size_t todos_count = 0; size_t todos_cap = 0; int next_todo_id = 1;

static regex_t username_regex;
static int username_regex_compiled = 0;

static void format_time_iso8601_utc(time_t t, char out[21]) {
    struct tm tm_utc;
#if defined(_GNU_SOURCE) || defined(__USE_MISC)
    gmtime_r(&t, &tm_utc);
#else
    struct tm *tmp = gmtime(&t);
    if (tmp) tm_utc = *tmp; else memset(&tm_utc, 0, sizeof tm_utc);
#endif
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

static void ensure_users_cap() {
    if (users_count >= users_cap) {
        size_t newcap = users_cap ? users_cap * 2 : 16;
        struct User *nu = realloc(users, newcap * sizeof *nu);
        if (!nu) { perror("realloc users"); exit(1);} 
        users = nu; users_cap = newcap;
    }
}

static void ensure_sessions_cap() {
    if (sessions_count >= sessions_cap) {
        size_t newcap = sessions_cap ? sessions_cap * 2 : 16;
        struct Session *ns = realloc(sessions, newcap * sizeof *ns);
        if (!ns) { perror("realloc sessions"); exit(1);} 
        sessions = ns; sessions_cap = newcap;
    }
}

static void ensure_todos_cap() {
    if (todos_count >= todos_cap) {
        size_t newcap = todos_cap ? todos_cap * 2 : 32;
        struct Todo *nt = realloc(todos, newcap * sizeof *nt);
        if (!nt) { perror("realloc todos"); exit(1);} 
        todos = nt; todos_cap = newcap;
    }
}

static struct User* find_user_by_username(const char *username){
    for (size_t i=0;i<users_count;i++){
        if (strcmp(users[i].username, username)==0) return &users[i];
    }
    return NULL;
}

static struct User* find_user_by_id(int id){
    for (size_t i=0;i<users_count;i++){
        if (users[i].id==id) return &users[i];
    }
    return NULL;
}

static struct Todo* find_todo_by_id(int id){
    for (size_t i=0;i<todos_count;i++){
        if (todos[i].id==id) return &todos[i];
    }
    return NULL;
}

static int remove_session_token(const char *token){
    for (size_t i=0;i<sessions_count;i++){
        if (strcmp(sessions[i].token, token)==0){
            free(sessions[i].token);
            if (i != sessions_count-1) sessions[i] = sessions[sessions_count-1];
            sessions_count--;
            return 1;
        }
    }
    return 0;
}

static int user_id_from_token(const char *token){
    for (size_t i=0;i<sessions_count;i++){
        if (strcmp(sessions[i].token, token)==0){
            return sessions[i].user_id;
        }
    }
    return 0;
}

static char* gen_uuid_token(){
    uuid_t uu; uuid_generate(uu);
    char *buf = malloc(37);
    if (!buf) return NULL;
    uuid_unparse_lower(uu, buf);
    return buf;
}

static int is_valid_username(const char *username){
    if (!username) return 0;
    if (!username_regex_compiled){
        if (regcomp(&username_regex, "^[A-Za-z0-9_]{3,50}$", REG_EXTENDED | REG_NOSUB) != 0){
            fprintf(stderr, "Failed to compile regex\n");
            exit(1);
        }
        username_regex_compiled = 1;
    }
    int rc = regexec(&username_regex, username, 0, NULL, 0);
    return rc==0;
}

static struct MHD_Response* json_response_obj(json_t *obj, int status){
    char *dump = json_dumps(obj, JSON_COMPACT);
    if (!dump) dump = strdup("{}");
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(dump), dump, MHD_RESPMEM_MUST_FREE);
    if (!resp) { free(dump); return NULL; }
    MHD_add_response_header(resp, "Content-Type", "application/json");
    return resp;
}

static int respond_json_message(struct MHD_Connection *connection, int status, const char *msg_key, const char *msg_val){
    json_t *obj = json_object();
    json_object_set_new(obj, msg_key, json_string(msg_val));
    struct MHD_Response *resp = json_response_obj(obj, status);
    json_decref(obj);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(connection, status, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int respond_error(struct MHD_Connection *connection, int status, const char *message){
    return respond_json_message(connection, status, "error", message);
}

static const char* get_cookie_session_id(struct MHD_Connection *connection){
    const char *cookie_header = MHD_lookup_connection_value(connection, MHD_HEADER_KIND, "Cookie");
    if (!cookie_header) return NULL;
    const char *p = cookie_header;
    static __thread char token_buf[128];
    token_buf[0] = '\0';
    while (*p){
        while (*p==' ' || *p==';') p++;
        const char *key_start = p;
        while (*p && *p!='=' && *p!=';' ) p++;
        if (*p!='=') break;
        const char *key_end = p;
        p++;
        const char *val_start = p;
        while (*p && *p!=';') p++;
        const char *val_end = p;
        size_t klen = (size_t)(key_end - key_start);
        size_t vlen = (size_t)(val_end - val_start);
        if (klen==10 && strncmp(key_start, "session_id", 10)==0){
            size_t copy = vlen < sizeof(token_buf)-1 ? vlen : sizeof(token_buf)-1;
            memcpy(token_buf, val_start, copy);
            token_buf[copy] = '\0';
            return token_buf;
        }
        if (*p==';') p++;
    }
    return NULL;
}

static int auth_required(struct MHD_Connection *connection, int *out_user_id){
    const char *token = get_cookie_session_id(connection);
    if (!token){
        *out_user_id = 0;
        return 0;
    }
    int uid = user_id_from_token(token);
    if (uid<=0){
        *out_user_id = 0;
        return 0;
    }
    *out_user_id = uid;
    return 1;
}

static int parse_url_id(const char *url, const char *prefix){
    size_t prelen = strlen(prefix);
    if (strncmp(url, prefix, prelen)!=0) return -1;
    const char *p = url + prelen;
    if (*p=='\0') return -1;
    char *endptr=NULL;
    long id = strtol(p, &endptr, 10);
    if (id<=0 || endptr==p || *endptr!='\0') return -1;
    if (id > INT32_MAX) return -1;
    return (int)id;
}

static int handle_register(struct MHD_Connection *conn, const char *body){
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if (!root){
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    json_t *juser = json_object_get(root, "username");
    json_t *jpass = json_object_get(root, "password");
    if (!juser || !json_is_string(juser) || !is_valid_username(json_string_value(juser))){
        json_decref(root);
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }
    if (!jpass || !json_is_string(jpass) || strlen(json_string_value(jpass)) < 8){
        json_decref(root);
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    const char *username = json_string_value(juser);
    const char *password = json_string_value(jpass);
    if (find_user_by_username(username)){
        json_decref(root);
        return respond_error(conn, MHD_HTTP_CONFLICT, "Username already exists");
    }
    ensure_users_cap();
    users[users_count].id = next_user_id++;
    users[users_count].username = strdup(username);
    users[users_count].password = strdup(password);
    struct User *u = &users[users_count];
    users_count++;

    json_t *resp_obj = json_object();
    json_object_set_new(resp_obj, "id", json_integer(u->id));
    json_object_set_new(resp_obj, "username", json_string(u->username));
    struct MHD_Response *resp = json_response_obj(resp_obj, MHD_HTTP_CREATED);
    json_decref(resp_obj);
    json_decref(root);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(conn, MHD_HTTP_CREATED, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int handle_login(struct MHD_Connection *conn, const char *body){
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if (!root){
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    json_t *juser = json_object_get(root, "username");
    json_t *jpass = json_object_get(root, "password");
    if (!juser || !json_is_string(juser) || !jpass || !json_is_string(jpass)){
        json_decref(root);
        return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    const char *username = json_string_value(juser);
    const char *password = json_string_value(jpass);
    struct User *u = find_user_by_username(username);
    if (!u || strcmp(u->password, password)!=0){
        json_decref(root);
        return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    ensure_sessions_cap();
    char *token = gen_uuid_token();
    if (!token){ json_decref(root); return respond_error(conn, MHD_HTTP_INTERNAL_SERVER_ERROR, "Internal error"); }
    sessions[sessions_count].token = token;
    sessions[sessions_count].user_id = u->id;
    sessions_count++;

    json_t *resp_obj = json_object();
    json_object_set_new(resp_obj, "id", json_integer(u->id));
    json_object_set_new(resp_obj, "username", json_string(u->username));
    struct MHD_Response *resp = json_response_obj(resp_obj, MHD_HTTP_OK);
    json_decref(resp_obj);
    json_decref(root);
    if (!resp) return MHD_NO;
    char setcookie[256];
    snprintf(setcookie, sizeof setcookie, "session_id=%s; Path=/; HttpOnly", token);
    MHD_add_response_header(resp, "Set-Cookie", setcookie);
    int ret = MHD_queue_response(conn, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int handle_logout(struct MHD_Connection *conn){
    const char *token = get_cookie_session_id(conn);
    if (!token) return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    int uid = user_id_from_token(token);
    if (uid<=0) return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    remove_session_token(token);
    json_t *obj = json_object();
    struct MHD_Response *resp = json_response_obj(obj, MHD_HTTP_OK);
    json_decref(obj);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(conn, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int handle_me(struct MHD_Connection *conn, int user_id){
    struct User *u = find_user_by_id(user_id);
    if (!u) return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    json_t *resp_obj = json_object();
    json_object_set_new(resp_obj, "id", json_integer(u->id));
    json_object_set_new(resp_obj, "username", json_string(u->username));
    struct MHD_Response *resp = json_response_obj(resp_obj, MHD_HTTP_OK);
    json_decref(resp_obj);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(conn, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int handle_password(struct MHD_Connection *conn, int user_id, const char *body){
    struct User *u = find_user_by_id(user_id);
    if (!u) return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if (!root){
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    json_t *jold = json_object_get(root, "old_password");
    json_t *jnew = json_object_get(root, "new_password");
    if (!jold || !json_is_string(jold) || strcmp(json_string_value(jold), u->password)!=0){
        json_decref(root);
        return respond_error(conn, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }
    if (!jnew || !json_is_string(jnew) || strlen(json_string_value(jnew))<8){
        json_decref(root);
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Password too short");
    }
    free(u->password);
    u->password = strdup(json_string_value(jnew));

    json_t *obj = json_object();
    struct MHD_Response *resp = json_response_obj(obj, MHD_HTTP_OK);
    json_decref(obj);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(conn, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    json_decref(root);
    return ret;
}

static json_t* todo_to_json(const struct Todo *t){
    json_t *obj = json_object();
    json_object_set_new(obj, "id", json_integer(t->id));
    json_object_set_new(obj, "title", json_string(t->title));
    json_object_set_new(obj, "description", json_string(t->description ? t->description : ""));
    json_object_set_new(obj, "completed", json_boolean(t->completed));
    json_object_set_new(obj, "created_at", json_string(t->created_at));
    json_object_set_new(obj, "updated_at", json_string(t->updated_at));
    return obj;
}

static int handle_get_todos(struct MHD_Connection *conn, int user_id){
    json_t *arr = json_array();
    for (size_t i=0;i<todos_count;i++){
        if (todos[i].user_id == user_id){
            json_t *obj = todo_to_json(&todos[i]);
            json_array_append_new(arr, obj);
        }
    }
    struct MHD_Response *resp = json_response_obj(arr, MHD_HTTP_OK);
    json_decref(arr);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(conn, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int handle_post_todo(struct MHD_Connection *conn, int user_id, const char *body){
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if (!root){
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    json_t *jtitle = json_object_get(root, "title");
    json_t *jdesc = json_object_get(root, "description");
    if (!jtitle || !json_is_string(jtitle) || strlen(json_string_value(jtitle))==0){
        json_decref(root);
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required");
    }
    const char *title = json_string_value(jtitle);
    const char *description = (jdesc && json_is_string(jdesc)) ? json_string_value(jdesc) : "";

    ensure_todos_cap();
    struct Todo *t = &todos[todos_count];
    t->id = next_todo_id++;
    t->user_id = user_id;
    t->title = strdup(title);
    t->description = strdup(description);
    t->completed = 0;
    time_t now = time(NULL);
    format_time_iso8601_utc(now, t->created_at);
    format_time_iso8601_utc(now, t->updated_at);
    todos_count++;

    json_t *obj = todo_to_json(t);
    struct MHD_Response *resp = json_response_obj(obj, MHD_HTTP_CREATED);
    json_decref(obj);
    json_decref(root);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(conn, MHD_HTTP_CREATED, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int handle_get_todo_by_id(struct MHD_Connection *conn, int user_id, int id){
    struct Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != user_id){
        return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    json_t *obj = todo_to_json(t);
    struct MHD_Response *resp = json_response_obj(obj, MHD_HTTP_OK);
    json_decref(obj);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(conn, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int handle_put_todo_by_id(struct MHD_Connection *conn, int user_id, int id, const char *body){
    struct Todo *t = find_todo_by_id(id);
    if (!t || t->user_id != user_id){
        return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
    }
    json_error_t jerr; json_t *root = json_loads(body?body:"", 0, &jerr);
    if (!root){
        return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }
    int modified = 0;

    if (json_object_get(root, "title") != NULL){
        json_t *jt = json_object_get(root, "title");
        if (!json_is_string(jt) || strlen(json_string_value(jt))==0){
            json_decref(root);
            return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Title is required");
        }
        free(t->title);
        t->title = strdup(json_string_value(jt));
        modified = 1;
    }
    if (json_object_get(root, "description") != NULL){
        json_t *jd = json_object_get(root, "description");
        if (!json_is_string(jd)){
            json_decref(root);
            return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
        }
        free(t->description);
        t->description = strdup(json_string_value(jd));
        modified = 1;
    }
    if (json_object_get(root, "completed") != NULL){
        json_t *jc = json_object_get(root, "completed");
        if (!json_is_boolean(jc)){
            json_decref(root);
            return respond_error(conn, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
        }
        t->completed = json_is_true(jc) ? 1 : 0;
        modified = 1;
    }

    if (modified){
        time_t now = time(NULL);
        format_time_iso8601_utc(now, t->updated_at);
    }

    json_t *obj = todo_to_json(t);
    struct MHD_Response *resp = json_response_obj(obj, MHD_HTTP_OK);
    json_decref(obj);
    json_decref(root);
    if (!resp) return MHD_NO;
    int ret = MHD_queue_response(conn, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    return ret;
}

static int handle_delete_todo_by_id(struct MHD_Connection *conn, int user_id, int id){
    for (size_t i=0;i<todos_count;i++){
        if (todos[i].id==id){
            if (todos[i].user_id != user_id){
                return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
            }
            free(todos[i].title);
            free(todos[i].description);
            if (i != todos_count-1) todos[i] = todos[todos_count-1];
            todos_count--;
            struct MHD_Response *resp = MHD_create_response_from_buffer(0, (void*)"", MHD_RESPMEM_PERSISTENT);
            if (!resp) return MHD_NO;
            int ret = MHD_queue_response(conn, MHD_HTTP_NO_CONTENT, resp);
            MHD_destroy_response(resp);
            return ret;
        }
    }
    return respond_error(conn, MHD_HTTP_NOT_FOUND, "Todo not found");
}

static enum MHD_Result request_handler(void *cls, struct MHD_Connection *connection,
                                       const char *url, const char *method,
                                       const char *version, const char *upload_data,
                                       size_t *upload_data_size, void **con_cls){
    (void)cls; (void)version;

    struct ConnectionInfo *ci = *con_cls;
    if (!ci){
        ci = calloc(1, sizeof *ci);
        if (!ci) return MHD_NO;
        ci->method = strdup(method);
        ci->url = strdup(url);
        ci->body = NULL; ci->body_size = 0; ci->processed = 0;
        *con_cls = ci;
        return MHD_YES;
    }

    if (ci->processed){
        return MHD_YES;
    }

    int is_write = (strcmp(method, "POST")==0 || strcmp(method, "PUT")==0);
    if (is_write){
        if (*upload_data_size != 0){
            size_t newsize = ci->body_size + *upload_data_size;
            if (newsize > MAX_BODY_SIZE){
                ci->processed = 1;
                return respond_error(connection, MHD_HTTP_REQUEST_ENTITY_TOO_LARGE, "Request too large");
            }
            char *nbuf = realloc(ci->body, newsize + 1);
            if (!nbuf){
                ci->processed = 1;
                return respond_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Internal error");
            }
            ci->body = nbuf;
            memcpy(ci->body + ci->body_size, upload_data, *upload_data_size);
            ci->body_size = newsize;
            ci->body[ci->body_size] = '\0';
            *upload_data_size = 0;
            return MHD_YES;
        }
    }

    int user_id = 0;
    if (strcmp(method, "POST")==0 && strcmp(url, "/register")==0){
        ci->processed = 1; return handle_register(connection, ci->body);
    }
    if (strcmp(method, "POST")==0 && strcmp(url, "/login")==0){
        ci->processed = 1; return handle_login(connection, ci->body);
    }
    if (strcmp(method, "POST")==0 && strcmp(url, "/logout")==0){
        if (!auth_required(connection, &user_id)) { ci->processed=1; return respond_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required"); }
        ci->processed = 1; return handle_logout(connection);
    }
    if (strcmp(method, "GET")==0 && strcmp(url, "/me")==0){
        if (!auth_required(connection, &user_id)) { ci->processed=1; return respond_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required"); }
        ci->processed = 1; return handle_me(connection, user_id);
    }
    if (strcmp(method, "PUT")==0 && strcmp(url, "/password")==0){
        if (!auth_required(connection, &user_id)) { ci->processed=1; return respond_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required"); }
        ci->processed = 1; return handle_password(connection, user_id, ci->body);
    }

    if (strncmp(url, "/todos", 6)==0){
        if (!auth_required(connection, &user_id)) { ci->processed=1; return respond_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required"); }
        if (strcmp(method, "GET")==0 && strcmp(url, "/todos")==0){
            ci->processed = 1; return handle_get_todos(connection, user_id);
        }
        if (strcmp(method, "POST")==0 && strcmp(url, "/todos")==0){
            ci->processed = 1; return handle_post_todo(connection, user_id, ci->body);
        }
        if (strncmp(url, "/todos/", 7)==0){
            int id = parse_url_id(url, "/todos/");
            if (id <= 0){ ci->processed=1; return respond_error(connection, MHD_HTTP_NOT_FOUND, "Not found"); }
            if (strcmp(method, "GET")==0){ ci->processed=1; return handle_get_todo_by_id(connection, user_id, id); }
            if (strcmp(method, "PUT")==0){ ci->processed=1; return handle_put_todo_by_id(connection, user_id, id, ci->body); }
            if (strcmp(method, "DELETE")==0){ ci->processed=1; return handle_delete_todo_by_id(connection, user_id, id); }
        }
    }

    ci->processed = 1;
    return respond_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
}

static void request_completed_cb(void *cls, struct MHD_Connection *connection, void **con_cls, enum MHD_RequestTerminationCode toe){
    (void)cls; (void)connection; (void)toe;
    if (!con_cls) return;
    struct ConnectionInfo *ci = *con_cls;
    if (ci){
        free(ci->method);
        free(ci->url);
        free(ci->body);
        free(ci);
    }
    *con_cls = NULL;
}

int main(int argc, char *argv[]){
    int port = 0;
    for (int i=1;i<argc;i++){
        if (strcmp(argv[i], "--port")==0 && i+1<argc){
            port = atoi(argv[i+1]);
            i++;
        }
    }
    if (port<=0){
        fprintf(stderr, "Usage: %s --port PORT\n", argv[0]);
        return 1;
    }

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_SELECT_INTERNALLY,
                                                 (uint16_t)port,
                                                 NULL, NULL,
                                                 &request_handler, NULL,
                                                 MHD_OPTION_NOTIFY_COMPLETED, request_completed_cb, NULL,
                                                 MHD_OPTION_END);
    if (!daemon){
        fprintf(stderr, "Failed to start server on port %d\n", port);
        return 1;
    }
    printf("Server listening on 0.0.0.0:%d\n", port);
    while (1){
        sleep(1);
    }
    MHD_stop_daemon(daemon);
    return 0;
}

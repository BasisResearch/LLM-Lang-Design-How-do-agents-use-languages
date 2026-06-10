#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <pthread.h>
#include <uuid/uuid.h>
#include <cjson/cJSON.h>
#include <microhttpd.h>

#define MAX_USERS 1000
#define MAX_TODOS 10000
#define MAX_SESSIONS 1000

typedef struct {
    int id;
    char username[52];
    char password[256];
} User;

typedef struct {
    int id;
    int user_id;
    char title[256];
    char description[1024];
    bool completed;
    char created_at[32];
    char updated_at[32];
} Todo;

typedef struct {
    char token[64];
    int user_id;
} Session;

static pthread_mutex_t state_mutex = PTHREAD_MUTEX_INITIALIZER;

static int next_user_id = 1;
static User users[MAX_USERS];
static int user_count = 0;

static int next_todo_id = 1;
static Todo todos[MAX_TODOS];
static int todo_count = 0;

static int session_count = 0;
static Session sessions[MAX_SESSIONS];

struct ConnectionInfo {
    char *post_data;
    size_t post_data_size;
    size_t post_data_allocated;
};

struct ResponseInfo {
    struct MHD_Response *response;
    int status_code;
};

void get_current_timestamp(char *out, size_t size) {
    time_t t = time(NULL);
    struct tm *tm = gmtime(&t);
    strftime(out, size, "%Y-%m-%dT%H:%M:%SZ", tm);
}

void generate_uuid(char *out, size_t size) {
    uuid_t uuid;
    uuid_generate(uuid);
    uuid_unparse_lower(uuid, out);
}

int extract_cookie(const char *cookie_header, const char *name, char *value, size_t max_len) {
    if (!cookie_header || !name || !value) return -1;
    const char *p = cookie_header;
    size_t name_len = strlen(name);
    
    while ((p = strstr(p, name)) != NULL) {
        if ((p == cookie_header || p[-1] == ' ' || p[-1] == ';' || p[-1] == ',') && p[name_len] == '=') {
            p += name_len + 1;
            size_t i = 0;
            while (*p && *p != ';' && *p != ' ' && *p != ',' && i < max_len - 1) {
                value[i++] = *p++;
            }
            value[i] = '\0';
            return 0;
        }
        p++;
    }
    return -1;
}

int get_user_id_by_session(const char *token) {
    if (!token || strlen(token) == 0) return -1;
    pthread_mutex_lock(&state_mutex);
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, token) == 0) {
            int uid = sessions[i].user_id;
            pthread_mutex_unlock(&state_mutex);
            return uid;
        }
    }
    pthread_mutex_unlock(&state_mutex);
    return -1;
}

struct ResponseInfo* create_json_response(int status_code, const char *json_str) {
    struct ResponseInfo *info = malloc(sizeof(struct ResponseInfo));
    char *json_copy = strdup(json_str);
    info->response = MHD_create_response_from_buffer(strlen(json_copy), (void *)json_copy, MHD_RESPMEM_MUST_FREE);
    MHD_add_response_header(info->response, "Content-Type", "application/json");
    info->status_code = status_code;
    return info;
}

struct ResponseInfo* create_empty_response(int status_code) {
    struct ResponseInfo *info = malloc(sizeof(struct ResponseInfo));
    info->response = MHD_create_response_from_buffer(0, "", MHD_RESPMEM_PERSISTENT);
    info->status_code = status_code;
    return info;
}

int match_path(const char *url, const char *path) {
    size_t path_len = strlen(path);
    if (strncmp(url, path, path_len) == 0) {
        if (url[path_len] == '\0' || url[path_len] == '?') {
            return 1;
        }
    }
    return 0;
}

struct ResponseInfo* handle_register(const char *body) {
    if (!body) return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid username\"}");
    cJSON *root = cJSON_Parse(body);
    if (!root) return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid username\"}");
    
    cJSON *username_json = cJSON_GetObjectItem(root, "username");
    cJSON *password_json = cJSON_GetObjectItem(root, "password");
    
    if (!username_json || !cJSON_IsString(username_json)) {
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid username\"}");
    }
    if (!password_json || !cJSON_IsString(password_json)) {
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Password too short\"}");
    }
    
    const char *username = username_json->valuestring;
    const char *password = password_json->valuestring;
    
    size_t len = strlen(username);
    if (len < 3 || len > 50) {
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid username\"}");
    }
    
    for (size_t i = 0; i < len; i++) {
        char c = username[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) {
            cJSON_Delete(root);
            return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid username\"}");
        }
    }
    
    if (strlen(password) < 8) {
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Password too short\"}");
    }
    
    pthread_mutex_lock(&state_mutex);
    if (user_count >= MAX_USERS) {
        pthread_mutex_unlock(&state_mutex);
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_INTERNAL_SERVER_ERROR, "{\"error\": \"User limit reached\"}");
    }
    
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            pthread_mutex_unlock(&state_mutex);
            cJSON_Delete(root);
            return create_json_response(MHD_HTTP_CONFLICT, "{\"error\": \"Username already exists\"}");
        }
    }
    
    User *u = &users[user_count++];
    u->id = next_user_id++;
    strncpy(u->username, username, sizeof(u->username) - 1);
    u->username[sizeof(u->username) - 1] = '\0';
    strncpy(u->password, password, sizeof(u->password) - 1);
    u->password[sizeof(u->password) - 1] = '\0';
    
    int new_id = u->id;
    char new_username[52];
    strncpy(new_username, u->username, sizeof(new_username));
    pthread_mutex_unlock(&state_mutex);
    cJSON_Delete(root);
    
    char resp[256];
    snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", new_id, new_username);
    return create_json_response(MHD_HTTP_CREATED, resp);
}

struct ResponseInfo* handle_login(const char *body, struct MHD_Connection *connection) {
    if (!body) return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Invalid credentials\"}");
    cJSON *root = cJSON_Parse(body);
    if (!root) return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Invalid credentials\"}");
    
    cJSON *username_json = cJSON_GetObjectItem(root, "username");
    cJSON *password_json = cJSON_GetObjectItem(root, "password");
    
    if (!username_json || !cJSON_IsString(username_json) || !password_json || !cJSON_IsString(password_json)) {
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Invalid credentials\"}");
    }
    
    const char *username = username_json->valuestring;
    const char *password = password_json->valuestring;
    
    int found_user_id = -1;
    char found_username[52] = {0};
    
    pthread_mutex_lock(&state_mutex);
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0 && strcmp(users[i].password, password) == 0) {
            found_user_id = users[i].id;
            strncpy(found_username, users[i].username, sizeof(found_username) - 1);
            break;
        }
    }
    pthread_mutex_unlock(&state_mutex);
    
    cJSON_Delete(root);
    
    if (found_user_id == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Invalid credentials\"}");
    }
    
    char token[64];
    generate_uuid(token, sizeof(token));
    
    pthread_mutex_lock(&state_mutex);
    if (session_count >= MAX_SESSIONS) {
        pthread_mutex_unlock(&state_mutex);
        return create_json_response(MHD_HTTP_INTERNAL_SERVER_ERROR, "{\"error\": \"Session limit reached\"}");
    }
    Session *s = &sessions[session_count++];
    strncpy(s->token, token, sizeof(s->token) - 1);
    s->user_id = found_user_id;
    pthread_mutex_unlock(&state_mutex);
    
    char cookie_val[256];
    snprintf(cookie_val, sizeof(cookie_val), "session_id=%s; Path=/; HttpOnly", token);
    
    char resp[256];
    snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", found_user_id, found_username);
    
    struct ResponseInfo *info = create_json_response(MHD_HTTP_OK, resp);
    MHD_add_response_header(info->response, "Set-Cookie", cookie_val);
    return info;
}

struct ResponseInfo* handle_logout(int user_id, const char *session_token, struct MHD_Connection *connection) {
    if (user_id == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    pthread_mutex_lock(&state_mutex);
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, session_token) == 0 && sessions[i].user_id == user_id) {
            sessions[i] = sessions[session_count - 1];
            session_count--;
            break;
        }
    }
    pthread_mutex_unlock(&state_mutex);
    
    return create_json_response(MHD_HTTP_OK, "{}");
}

struct ResponseInfo* handle_me(int user_id) {
    if (user_id == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    char username[52] = {0};
    pthread_mutex_lock(&state_mutex);
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            strncpy(username, users[i].username, sizeof(username) - 1);
            break;
        }
    }
    pthread_mutex_unlock(&state_mutex);
    
    if (username[0] == '\0') {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    char resp[256];
    snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", user_id, username);
    return create_json_response(MHD_HTTP_OK, resp);
}

struct ResponseInfo* handle_password(int user_id, const char *body) {
    if (user_id == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    if (!body) return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid request body\"}");
    cJSON *root = cJSON_Parse(body);
    if (!root) return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid JSON\"}");
    
    cJSON *old_pwd = cJSON_GetObjectItem(root, "old_password");
    cJSON *new_pwd = cJSON_GetObjectItem(root, "new_password");
    
    if (!old_pwd || !cJSON_IsString(old_pwd) || !new_pwd || !cJSON_IsString(new_pwd)) {
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Invalid credentials\"}");
    }
    
    // Copy strings to avoid use-after-free when we delete root
    char old_password[256] = {0};
    char new_password[256] = {0};
    strncpy(old_password, old_pwd->valuestring, sizeof(old_password) - 1);
    strncpy(new_password, new_pwd->valuestring, sizeof(new_password) - 1);
    
    cJSON_Delete(root); // Now safe to delete
    
    pthread_mutex_lock(&state_mutex);
    int found = 0;
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            if (strcmp(users[i].password, old_password) != 0) {
                found = -1;
            } else {
                found = 1;
            }
            break;
        }
    }
    pthread_mutex_unlock(&state_mutex);
    
    if (found == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Invalid credentials\"}");
    } else if (found == 0) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    if (strlen(new_password) < 8) {
        return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Password too short\"}");
    }
    
    pthread_mutex_lock(&state_mutex);
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            strncpy(users[i].password, new_password, sizeof(users[i].password) - 1);
            users[i].password[sizeof(users[i].password) - 1] = '\0';
            break;
        }
    }
    pthread_mutex_unlock(&state_mutex);
    
    return create_json_response(MHD_HTTP_OK, "{}");
}
struct ResponseInfo* handle_get_todos(int user_id) {
    if (user_id == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    cJSON *arr = cJSON_CreateArray();
    pthread_mutex_lock(&state_mutex);
    
    Todo *matches[10000];
    int match_count = 0;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id == user_id) {
            matches[match_count++] = &todos[i];
        }
    }
    
    for (int i = 0; i < match_count - 1; i++) {
        for (int j = i + 1; j < match_count; j++) {
            if (matches[i]->id > matches[j]->id) {
                Todo *temp = matches[i];
                matches[i] = matches[j];
                matches[j] = temp;
            }
        }
    }
    
    for (int i = 0; i < match_count; i++) {
        cJSON *obj = cJSON_CreateObject();
        cJSON_AddNumberToObject(obj, "id", matches[i]->id);
        cJSON_AddStringToObject(obj, "title", matches[i]->title);
        cJSON_AddStringToObject(obj, "description", matches[i]->description);
        cJSON_AddBoolToObject(obj, "completed", matches[i]->completed);
        cJSON_AddStringToObject(obj, "created_at", matches[i]->created_at);
        cJSON_AddStringToObject(obj, "updated_at", matches[i]->updated_at);
        cJSON_AddItemToArray(arr, obj);
    }
    pthread_mutex_unlock(&state_mutex);
    
    char *json_str = cJSON_PrintUnformatted(arr);
    cJSON_Delete(arr);
    
    struct ResponseInfo *info = create_json_response(MHD_HTTP_OK, json_str);
    free(json_str);
    return info;
}

struct ResponseInfo* handle_create_todo(int user_id, const char *body) {
    if (user_id == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    if (!body) return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Title is required\"}");
    cJSON *root = cJSON_Parse(body);
    if (!root) return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Title is required\"}");
    
    cJSON *title_json = cJSON_GetObjectItem(root, "title");
    if (!title_json || !cJSON_IsString(title_json) || strlen(title_json->valuestring) == 0) {
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Title is required\"}");
    }
    
    const char *title = title_json->valuestring;
    const char *description = "";
    cJSON *desc_json = cJSON_GetObjectItem(root, "description");
    if (desc_json && cJSON_IsString(desc_json)) {
        description = desc_json->valuestring;
    }
    
    char created_at[32], updated_at[32];
    get_current_timestamp(created_at, sizeof(created_at));
    get_current_timestamp(updated_at, sizeof(updated_at));
    
    pthread_mutex_lock(&state_mutex);
    if (todo_count >= MAX_TODOS) {
        pthread_mutex_unlock(&state_mutex);
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_INTERNAL_SERVER_ERROR, "{\"error\": \"Todo limit reached\"}");
    }
    
    Todo *t = &todos[todo_count++];
    t->id = next_todo_id++;
    t->user_id = user_id;
    strncpy(t->title, title, sizeof(t->title) - 1);
    t->title[sizeof(t->title) - 1] = '\0';
    strncpy(t->description, description, sizeof(t->description) - 1);
    t->description[sizeof(t->description) - 1] = '\0';
    t->completed = false;
    strncpy(t->created_at, created_at, sizeof(t->created_at) - 1);
    t->created_at[sizeof(t->created_at) - 1] = '\0';
    strncpy(t->updated_at, updated_at, sizeof(t->updated_at) - 1);
    t->updated_at[sizeof(t->updated_at) - 1] = '\0';
    
    int new_id = t->id;
    char new_title[256], new_desc[1024], new_created[32], new_updated[32];
    strncpy(new_title, t->title, sizeof(new_title));
    strncpy(new_desc, t->description, sizeof(new_desc));
    strncpy(new_created, t->created_at, sizeof(new_created));
    strncpy(new_updated, t->updated_at, sizeof(new_updated));
    pthread_mutex_unlock(&state_mutex);
    
    cJSON_Delete(root);
    
    cJSON *obj = cJSON_CreateObject();
    cJSON_AddNumberToObject(obj, "id", new_id);
    cJSON_AddStringToObject(obj, "title", new_title);
    cJSON_AddStringToObject(obj, "description", new_desc);
    cJSON_AddBoolToObject(obj, "completed", false);
    cJSON_AddStringToObject(obj, "created_at", new_created);
    cJSON_AddStringToObject(obj, "updated_at", new_updated);
    
    char *json_str = cJSON_PrintUnformatted(obj);
    cJSON_Delete(obj);
    
    struct ResponseInfo *info = create_json_response(MHD_HTTP_CREATED, json_str);
    free(json_str);
    return info;
}

struct ResponseInfo* handle_get_todo(int user_id, int todo_id) {
    if (user_id == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    pthread_mutex_lock(&state_mutex);
    Todo *found = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id) {
            found = &todos[i];
            break;
        }
    }
    
    if (!found) {
        pthread_mutex_unlock(&state_mutex);
        return create_json_response(MHD_HTTP_NOT_FOUND, "{\"error\": \"Todo not found\"}");
    }
    
    cJSON *obj = cJSON_CreateObject();
    cJSON_AddNumberToObject(obj, "id", found->id);
    cJSON_AddStringToObject(obj, "title", found->title);
    cJSON_AddStringToObject(obj, "description", found->description);
    cJSON_AddBoolToObject(obj, "completed", found->completed);
    cJSON_AddStringToObject(obj, "created_at", found->created_at);
    cJSON_AddStringToObject(obj, "updated_at", found->updated_at);
    
    char *json_str = cJSON_PrintUnformatted(obj);
    cJSON_Delete(obj);
    pthread_mutex_unlock(&state_mutex);
    
    struct ResponseInfo *info = create_json_response(MHD_HTTP_OK, json_str);
    free(json_str);
    return info;
}

struct ResponseInfo* handle_update_todo(int user_id, int todo_id, const char *body) {
    if (user_id == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    if (!body) return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid JSON\"}");
    cJSON *root = cJSON_Parse(body);
    if (!root) return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid JSON\"}");
    
    pthread_mutex_lock(&state_mutex);
    Todo *found = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id) {
            found = &todos[i];
            break;
        }
    }
    
    if (!found) {
        pthread_mutex_unlock(&state_mutex);
        cJSON_Delete(root);
        return create_json_response(MHD_HTTP_NOT_FOUND, "{\"error\": \"Todo not found\"}");
    }
    
    cJSON *title_json = cJSON_GetObjectItem(root, "title");
    if (title_json) {
        if (!cJSON_IsString(title_json) || strlen(title_json->valuestring) == 0) {
            pthread_mutex_unlock(&state_mutex);
            cJSON_Delete(root);
            return create_json_response(MHD_HTTP_BAD_REQUEST, "{\"error\": \"Title is required\"}");
        }
        strncpy(found->title, title_json->valuestring, sizeof(found->title) - 1);
        found->title[sizeof(found->title) - 1] = '\0';
    }
    
    cJSON *desc_json = cJSON_GetObjectItem(root, "description");
    if (desc_json && cJSON_IsString(desc_json)) {
        strncpy(found->description, desc_json->valuestring, sizeof(found->description) - 1);
        found->description[sizeof(found->description) - 1] = '\0';
    }
    
    cJSON *completed_json = cJSON_GetObjectItem(root, "completed");
    if (completed_json && cJSON_IsBool(completed_json)) {
        found->completed = (completed_json->valueint != 0);
    }
    
    get_current_timestamp(found->updated_at, sizeof(found->updated_at));
    
    cJSON *obj = cJSON_CreateObject();
    cJSON_AddNumberToObject(obj, "id", found->id);
    cJSON_AddStringToObject(obj, "title", found->title);
    cJSON_AddStringToObject(obj, "description", found->description);
    cJSON_AddBoolToObject(obj, "completed", found->completed);
    cJSON_AddStringToObject(obj, "created_at", found->created_at);
    cJSON_AddStringToObject(obj, "updated_at", found->updated_at);
    
    char *json_str = cJSON_PrintUnformatted(obj);
    cJSON_Delete(obj);
    pthread_mutex_unlock(&state_mutex);
    cJSON_Delete(root);
    
    struct ResponseInfo *info = create_json_response(MHD_HTTP_OK, json_str);
    free(json_str);
    return info;
}

struct ResponseInfo* handle_delete_todo(int user_id, int todo_id) {
    if (user_id == -1) {
        return create_json_response(MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}");
    }
    
    pthread_mutex_lock(&state_mutex);
    int found_idx = -1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id) {
            found_idx = i;
            break;
        }
    }
    
    if (found_idx == -1) {
        pthread_mutex_unlock(&state_mutex);
        return create_json_response(MHD_HTTP_NOT_FOUND, "{\"error\": \"Todo not found\"}");
    }
    
    for (int i = found_idx; i < todo_count - 1; i++) {
        todos[i] = todos[i + 1];
    }
    todo_count--;
    pthread_mutex_unlock(&state_mutex);
    
    return create_empty_response(MHD_HTTP_NO_CONTENT);
}

struct ResponseInfo* process_request(struct MHD_Connection *connection, const char *url, const char *method, const char *body) {
    const char *cookie_header = MHD_lookup_connection_value(connection, MHD_HEADER_KIND, "Cookie");
    char session_token[64] = {0};
    int user_id = -1;
    if (cookie_header) {
        extract_cookie(cookie_header, "session_id", session_token, sizeof(session_token));
        user_id = get_user_id_by_session(session_token);
    }

    if (match_path(url, "/register") && strcmp(method, "POST") == 0) {
        return handle_register(body);
    } else if (match_path(url, "/login") && strcmp(method, "POST") == 0) {
        return handle_login(body, connection);
    } else if (match_path(url, "/logout") && strcmp(method, "POST") == 0) {
        return handle_logout(user_id, session_token, connection);
    } else if (match_path(url, "/me") && strcmp(method, "GET") == 0) {
        return handle_me(user_id);
    } else if (match_path(url, "/password") && strcmp(method, "PUT") == 0) {
        return handle_password(user_id, body);
    } else if (match_path(url, "/todos") && strcmp(method, "GET") == 0) {
        return handle_get_todos(user_id);
    } else if (match_path(url, "/todos") && strcmp(method, "POST") == 0) {
        return handle_create_todo(user_id, body);
    } else {
        int todo_id = 0;
        char remainder[32] = {0};
        if (sscanf(url, "/todos/%d%31s", &todo_id, remainder) >= 1) {
            if (remainder[0] == '\0' || remainder[0] == '?') {
                if (strcmp(method, "GET") == 0) {
                    return handle_get_todo(user_id, todo_id);
                } else if (strcmp(method, "PUT") == 0) {
                    return handle_update_todo(user_id, todo_id, body);
                } else if (strcmp(method, "DELETE") == 0) {
                    return handle_delete_todo(user_id, todo_id);
                }
            }
        }
    }
    
    return create_json_response(MHD_HTTP_NOT_FOUND, "{\"error\": \"Not found\"}");
}

enum MHD_Result ahc_echo(void *cls, struct MHD_Connection *connection,
             const char *url, const char *method,
             const char *version, const char *upload_data,
             size_t *upload_data_size, void **con_cls) {
    struct ConnectionInfo *con_info = *con_cls;
    if (con_info == NULL) {
        con_info = calloc(1, sizeof(struct ConnectionInfo));
        *con_cls = con_info;
        return MHD_YES;
    }

    if (strcmp(method, "POST") == 0 || strcmp(method, "PUT") == 0) {
        if (*upload_data_size > 0) {
            if (con_info->post_data_size + *upload_data_size + 1 > con_info->post_data_allocated) {
                size_t new_alloc = con_info->post_data_allocated == 0 ? 4096 : con_info->post_data_allocated * 2;
                while (new_alloc < con_info->post_data_size + *upload_data_size + 1) {
                    new_alloc *= 2;
                }
                con_info->post_data = realloc(con_info->post_data, new_alloc);
                con_info->post_data_allocated = new_alloc;
            }
            memcpy(con_info->post_data + con_info->post_data_size, upload_data, *upload_data_size);
            con_info->post_data_size += *upload_data_size;
            con_info->post_data[con_info->post_data_size] = '\0';
            *upload_data_size = 0;
            return MHD_YES;
        } else if (con_info->post_data == NULL) {
            con_info->post_data = strdup("");
        }
    }

    struct ResponseInfo *resp_info = process_request(connection, url, method, con_info->post_data);
    enum MHD_Result ret = MHD_queue_response(connection, resp_info->status_code, resp_info->response);
    MHD_destroy_response(resp_info->response);
    free(resp_info);
    
    free(con_info->post_data);
    free(con_info);
    *con_cls = NULL;
    
    return ret;
}

void request_completed(void *cls, struct MHD_Connection *connection, void **con_cls, enum MHD_RequestTerminationCode toe) {
    struct ConnectionInfo *con_info = *con_cls;
    if (con_info != NULL) {
        free(con_info->post_data);
        free(con_info);
    }
    *con_cls = NULL;
}

int main(int argc, char **argv) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        }
    }
    
    struct MHD_Daemon *daemon = MHD_start_daemon(
        MHD_USE_INTERNAL_POLLING_THREAD | MHD_USE_ERROR_LOG, 
        port, 
        NULL, NULL, 
        &ahc_echo, NULL,
        MHD_OPTION_CONNECTION_MEMORY_LIMIT, (size_t)1024 * 1024,
        MHD_OPTION_NOTIFY_COMPLETED, &request_completed, NULL,
        MHD_OPTION_END
    );
    
    if (daemon == NULL) {
        fprintf(stderr, "Failed to start daemon on port %d\n", port);
        return 1;
    }
    
    printf("Server running on port %d\n", port);
    
    while (1) {
        sleep(1);
    }
    
    MHD_stop_daemon(daemon);
    return 0;
}

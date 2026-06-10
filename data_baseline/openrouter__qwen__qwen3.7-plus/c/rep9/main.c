#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <signal.h>
#include <uuid/uuid.h>
#include <stdbool.h>
#include <microhttpd.h>
#include <cjson/cJSON.h>

#define MAX_USERS 10000
#define MAX_SESSIONS 10000
#define MAX_TODOS 10000

typedef struct {
    int id;
    char username[64];
    char password[256];
} User;

typedef struct {
    char token[64];
    int user_id;
} Session;

typedef struct {
    int id;
    int user_id;
    char title[256];
    char description[1024];
    bool completed;
    char created_at[32];
    char updated_at[32];
} Todo;

User users[MAX_USERS];
int user_count = 0;
int next_user_id = 1;

Session sessions[MAX_SESSIONS];
int session_count = 0;

Todo todos[MAX_TODOS];
int todo_count = 0;
int next_todo_id = 1;

pthread_mutex_t lock;

void get_current_iso8601(char *buf, size_t size) {
    time_t t = time(NULL);
    struct tm *tm = gmtime(&t);
    strftime(buf, size, "%Y-%m-%dT%H:%M:%SZ", tm);
}

bool validate_username(const char *username) {
    if (!username) return false;
    size_t len = strlen(username);
    if (len < 3 || len > 50) return false;
    for (size_t i = 0; i < len; i++) {
        char c = username[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) {
            return false;
        }
    }
    return true;
}

enum MHD_Result send_response(struct MHD_Connection *connection, int status_code, const char *json_str, const char *set_cookie) {
    struct MHD_Response *response;
    enum MHD_Result ret;
    if (json_str) {
        response = MHD_create_response_from_buffer(strlen(json_str), (void *)json_str, MHD_RESPMEM_MUST_COPY);
        MHD_add_response_header(response, "Content-Type", "application/json");
    } else {
        response = MHD_create_response_from_buffer(0, "", MHD_RESPMEM_MUST_COPY);
    }
    if (set_cookie) {
        MHD_add_response_header(response, "Set-Cookie", set_cookie);
    }
    ret = MHD_queue_response(connection, status_code, response);
    MHD_destroy_response(response);
    return ret;
}

const char *get_cookie(struct MHD_Connection *connection, const char *name) {
    const char *cookie_header = MHD_lookup_connection_value(connection, MHD_HEADER_KIND, MHD_HTTP_HEADER_COOKIE);
    if (!cookie_header) return NULL;
    
    char *cookie_copy = strdup(cookie_header);
    char *saveptr;
    char *token = strtok_r(cookie_copy, ";", &saveptr);
    char *found_val = NULL;
    
    while (token) {
        while (*token == ' ') token++;
        size_t name_len = strlen(name);
        if (strncmp(token, name, name_len) == 0 && token[name_len] == '=') {
            found_val = strdup(token + name_len + 1);
            size_t len = strlen(found_val);
            while (len > 0 && found_val[len-1] == ' ') {
                found_val[len-1] = '\0';
                len--;
            }
            break;
        }
        token = strtok_r(NULL, ";", &saveptr);
    }
    free(cookie_copy);
    return (const char *)found_val;
}

struct RequestData {
    char *upload_data;
    size_t upload_data_size;
    int post_processed;
};

enum MHD_Result handle_register(struct MHD_Connection *connection, const char *upload_data);
enum MHD_Result handle_login(struct MHD_Connection *connection, const char *upload_data);
enum MHD_Result handle_logout(struct MHD_Connection *connection, int user_id, const char *session_token);
enum MHD_Result handle_me(struct MHD_Connection *connection, int user_id);
enum MHD_Result handle_password(struct MHD_Connection *connection, int user_id, const char *upload_data);
enum MHD_Result handle_get_todos(struct MHD_Connection *connection, int user_id);
enum MHD_Result handle_post_todo(struct MHD_Connection *connection, int user_id, const char *upload_data);
enum MHD_Result handle_get_todo(struct MHD_Connection *connection, int user_id, int todo_id);
enum MHD_Result handle_put_todo(struct MHD_Connection *connection, int user_id, int todo_id, const char *upload_data);
enum MHD_Result handle_delete_todo(struct MHD_Connection *connection, int user_id, int todo_id);

enum MHD_Result process_request(struct MHD_Connection *connection, const char *url, const char *method, const char *upload_data) {
    int requires_auth = 0;
    if (strcmp(url, "/register") == 0 && strcmp(method, MHD_HTTP_METHOD_POST) == 0) requires_auth = 0;
    else if (strcmp(url, "/login") == 0 && strcmp(method, MHD_HTTP_METHOD_POST) == 0) requires_auth = 0;
    else requires_auth = 1;

    int current_user_id = -1;
    const char *session_token = NULL;

    if (requires_auth) {
        session_token = get_cookie(connection, "session_id");
        if (!session_token) {
            return send_response(connection, MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}", NULL);
        }
        
        pthread_mutex_lock(&lock);
        int found = 0;
        for (int i = 0; i < session_count; i++) {
            if (strcmp(sessions[i].token, session_token) == 0) {
                current_user_id = sessions[i].user_id;
                found = 1;
                break;
            }
        }
        pthread_mutex_unlock(&lock);

        if (!found) {
            free((void*)session_token);
            return send_response(connection, MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Authentication required\"}", NULL);
        }
    }

    enum MHD_Result ret;
    if (strcmp(url, "/register") == 0 && strcmp(method, MHD_HTTP_METHOD_POST) == 0) {
        ret = handle_register(connection, upload_data);
    } else if (strcmp(url, "/login") == 0 && strcmp(method, MHD_HTTP_METHOD_POST) == 0) {
        ret = handle_login(connection, upload_data);
    } else if (strcmp(url, "/logout") == 0 && strcmp(method, MHD_HTTP_METHOD_POST) == 0) {
        ret = handle_logout(connection, current_user_id, session_token);
    } else if (strcmp(url, "/me") == 0 && strcmp(method, MHD_HTTP_METHOD_GET) == 0) {
        ret = handle_me(connection, current_user_id);
    } else if (strcmp(url, "/password") == 0 && strcmp(method, MHD_HTTP_METHOD_PUT) == 0) {
        ret = handle_password(connection, current_user_id, upload_data);
    } else if (strcmp(url, "/todos") == 0 && strcmp(method, MHD_HTTP_METHOD_GET) == 0) {
        ret = handle_get_todos(connection, current_user_id);
    } else if (strcmp(url, "/todos") == 0 && strcmp(method, MHD_HTTP_METHOD_POST) == 0) {
        ret = handle_post_todo(connection, current_user_id, upload_data);
    } else {
        if (strncmp(url, "/todos/", 7) == 0) {
            int todo_id = atoi(url + 7);
            if (todo_id > 0) {
                if (strcmp(method, MHD_HTTP_METHOD_GET) == 0) {
                    ret = handle_get_todo(connection, current_user_id, todo_id);
                } else if (strcmp(method, MHD_HTTP_METHOD_PUT) == 0) {
                    ret = handle_put_todo(connection, current_user_id, todo_id, upload_data);
                } else if (strcmp(method, MHD_HTTP_METHOD_DELETE) == 0) {
                    ret = handle_delete_todo(connection, current_user_id, todo_id);
                } else {
                    ret = send_response(connection, MHD_HTTP_METHOD_NOT_ALLOWED, "{\"error\": \"Method not allowed\"}", NULL);
                }
            } else {
                ret = send_response(connection, MHD_HTTP_NOT_FOUND, "{\"error\": \"Not found\"}", NULL);
            }
        } else {
            ret = send_response(connection, MHD_HTTP_NOT_FOUND, "{\"error\": \"Not found\"}", NULL);
        }
    }

    if (session_token) {
        free((void*)session_token);
    }
    return ret;
}

enum MHD_Result answer_to_connection(void *cls, struct MHD_Connection *connection,
                                     const char *url, const char *method,
                                     const char *version, const char *upload_data,
                                     size_t *upload_data_size, void **con_cls) {
    if (*con_cls == NULL) {
        struct RequestData *data = calloc(1, sizeof(struct RequestData));
        *con_cls = data;
        return MHD_YES;
    }

    struct RequestData *data = (struct RequestData *)*con_cls;
    enum MHD_Result ret;

    if (strcmp(method, MHD_HTTP_METHOD_POST) == 0 || strcmp(method, MHD_HTTP_METHOD_PUT) == 0) {
        if (*upload_data_size > 0) {
            data->upload_data = realloc(data->upload_data, data->upload_data_size + *upload_data_size + 1);
            memcpy(data->upload_data + data->upload_data_size, upload_data, *upload_data_size);
            data->upload_data_size += *upload_data_size;
            data->upload_data[data->upload_data_size] = '\0';
            *upload_data_size = 0;
            return MHD_YES;
        } else if (data->post_processed == 0) {
            data->post_processed = 1;
        } else {
            return MHD_YES;
        }
    } else if (strcmp(method, MHD_HTTP_METHOD_DELETE) == 0) {
        if (!data->post_processed) {
            data->post_processed = 1;
        } else {
            return MHD_YES;
        }
    } else {
        data->post_processed = 1;
    }

    if (data->post_processed == 0) {
        return MHD_YES;
    }

    ret = process_request(connection, url, method, data->upload_data);

    free(data->upload_data);
    free(data);
    *con_cls = NULL;
    return ret;
}

enum MHD_Result handle_register(struct MHD_Connection *connection, const char *upload_data) {
    if (!upload_data) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid request body\"}", NULL);
    }
    cJSON *json = cJSON_Parse(upload_data);
    if (!json) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid JSON\"}", NULL);
    }
    
    cJSON *username_json = cJSON_GetObjectItemCaseSensitive(json, "username");
    cJSON *password_json = cJSON_GetObjectItemCaseSensitive(json, "password");
    
    if (!cJSON_IsString(username_json) || !cJSON_IsString(password_json)) {
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid username\"}", NULL);
    }
    
    const char *username = username_json->valuestring;
    const char *password = password_json->valuestring;
    
    if (!validate_username(username)) {
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid username\"}", NULL);
    }
    
    if (strlen(password) < 8) {
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Password too short\"}", NULL);
    }
    
    pthread_mutex_lock(&lock);
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            pthread_mutex_unlock(&lock);
            cJSON_Delete(json);
            return send_response(connection, MHD_HTTP_CONFLICT, "{\"error\": \"Username already exists\"}", NULL);
        }
    }
    
    if (user_count >= MAX_USERS) {
        pthread_mutex_unlock(&lock);
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "{\"error\": \"Server full\"}", NULL);
    }
    
    User *new_user = &users[user_count++];
    new_user->id = next_user_id++;
    strncpy(new_user->username, username, sizeof(new_user->username) - 1);
    new_user->username[sizeof(new_user->username) - 1] = '\0';
    strncpy(new_user->password, password, sizeof(new_user->password) - 1);
    new_user->password[sizeof(new_user->password) - 1] = '\0';
    
    char resp[256];
    snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", new_user->id, new_user->username);
    pthread_mutex_unlock(&lock);
    cJSON_Delete(json);
    
    return send_response(connection, MHD_HTTP_CREATED, resp, NULL);
}

enum MHD_Result handle_login(struct MHD_Connection *connection, const char *upload_data) {
    if (!upload_data) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid request body\"}", NULL);
    }
    cJSON *json = cJSON_Parse(upload_data);
    if (!json) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid JSON\"}", NULL);
    }
    
    cJSON *username_json = cJSON_GetObjectItemCaseSensitive(json, "username");
    cJSON *password_json = cJSON_GetObjectItemCaseSensitive(json, "password");
    
    if (!cJSON_IsString(username_json) || !cJSON_IsString(password_json)) {
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Invalid credentials\"}", NULL);
    }
    
    const char *username = username_json->valuestring;
    const char *password = password_json->valuestring;
    
    int user_id = -1;
    char found_username[64] = {0};
    
    pthread_mutex_lock(&lock);
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0 && strcmp(users[i].password, password) == 0) {
            user_id = users[i].id;
            strncpy(found_username, users[i].username, sizeof(found_username) - 1);
            break;
        }
    }
    
    if (user_id == -1) {
        pthread_mutex_unlock(&lock);
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Invalid credentials\"}", NULL);
    }
    
    if (session_count >= MAX_SESSIONS) {
        pthread_mutex_unlock(&lock);
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "{\"error\": \"Server full\"}", NULL);
    }
    
    uuid_t uuid;
    uuid_generate(uuid);
    char token_str[64];
    uuid_unparse(uuid, token_str);
    
    sessions[session_count].user_id = user_id;
    strncpy(sessions[session_count].token, token_str, sizeof(sessions[session_count].token) - 1);
    session_count++;
    
    pthread_mutex_unlock(&lock);
    cJSON_Delete(json);
    
    char resp[256];
    snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", user_id, found_username);
    
    char set_cookie[256];
    snprintf(set_cookie, sizeof(set_cookie), "session_id=%s; Path=/; HttpOnly", token_str);
    
    return send_response(connection, MHD_HTTP_OK, resp, set_cookie);
}

enum MHD_Result handle_logout(struct MHD_Connection *connection, int user_id, const char *session_token) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, session_token) == 0) {
            sessions[i] = sessions[session_count - 1];
            session_count--;
            break;
        }
    }
    pthread_mutex_unlock(&lock);
    
    return send_response(connection, MHD_HTTP_OK, "{}", NULL);
}

enum MHD_Result handle_me(struct MHD_Connection *connection, int user_id) {
    pthread_mutex_lock(&lock);
    char username[64] = {0};
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            strncpy(username, users[i].username, sizeof(username) - 1);
            break;
        }
    }
    pthread_mutex_unlock(&lock);
    
    char resp[256];
    snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", user_id, username);
    return send_response(connection, MHD_HTTP_OK, resp, NULL);
}

enum MHD_Result handle_password(struct MHD_Connection *connection, int user_id, const char *upload_data) {
    if (!upload_data) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid request body\"}", NULL);
    }
    cJSON *json = cJSON_Parse(upload_data);
    if (!json) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid JSON\"}", NULL);
    }
    
    cJSON *old_pass_json = cJSON_GetObjectItemCaseSensitive(json, "old_password");
    cJSON *new_pass_json = cJSON_GetObjectItemCaseSensitive(json, "new_password");
    
    if (!cJSON_IsString(old_pass_json) || !cJSON_IsString(new_pass_json)) {
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid credentials\"}", NULL);
    }
    
    const char *old_password = old_pass_json->valuestring;
    const char *new_password = new_pass_json->valuestring;
    
    if (strlen(new_password) < 8) {
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Password too short\"}", NULL);
    }
    
    pthread_mutex_lock(&lock);
    int auth_ok = 0;
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            if (strcmp(users[i].password, old_password) == 0) {
                auth_ok = 1;
                strncpy(users[i].password, new_password, sizeof(users[i].password) - 1);
                users[i].password[sizeof(users[i].password) - 1] = '\0';
            }
            break;
        }
    }
    pthread_mutex_unlock(&lock);
    
    cJSON_Delete(json);
    if (!auth_ok) {
        return send_response(connection, MHD_HTTP_UNAUTHORIZED, "{\"error\": \"Invalid credentials\"}", NULL);
    }
    
    return send_response(connection, MHD_HTTP_OK, "{}", NULL);
}

enum MHD_Result handle_get_todos(struct MHD_Connection *connection, int user_id) {
    cJSON *array = cJSON_CreateArray();
    
    pthread_mutex_lock(&lock);
    Todo *user_todos[MAX_TODOS];
    int user_todo_count = 0;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id == user_id) {
            user_todos[user_todo_count++] = &todos[i];
        }
    }
    
    for (int i = 1; i < user_todo_count; i++) {
        Todo *key = user_todos[i];
        int j = i - 1;
        while (j >= 0 && user_todos[j]->id > key->id) {
            user_todos[j + 1] = user_todos[j];
            j = j - 1;
        }
        user_todos[j + 1] = key;
    }
    
    for (int i = 0; i < user_todo_count; i++) {
        cJSON *todo = cJSON_CreateObject();
        cJSON_AddNumberToObject(todo, "id", user_todos[i]->id);
        cJSON_AddStringToObject(todo, "title", user_todos[i]->title);
        cJSON_AddStringToObject(todo, "description", user_todos[i]->description);
        cJSON_AddBoolToObject(todo, "completed", user_todos[i]->completed);
        cJSON_AddStringToObject(todo, "created_at", user_todos[i]->created_at);
        cJSON_AddStringToObject(todo, "updated_at", user_todos[i]->updated_at);
        cJSON_AddItemToArray(array, todo);
    }
    pthread_mutex_unlock(&lock);
    
    char *resp = cJSON_PrintUnformatted(array);
    cJSON_Delete(array);
    
    enum MHD_Result ret = send_response(connection, MHD_HTTP_OK, resp, NULL);
    free(resp);
    return ret;
}

enum MHD_Result handle_post_todo(struct MHD_Connection *connection, int user_id, const char *upload_data) {
    if (!upload_data) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid request body\"}", NULL);
    }
    cJSON *json = cJSON_Parse(upload_data);
    if (!json) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid JSON\"}", NULL);
    }
    
    cJSON *title_json = cJSON_GetObjectItemCaseSensitive(json, "title");
    if (!cJSON_IsString(title_json) || strlen(title_json->valuestring) == 0) {
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Title is required\"}", NULL);
    }
    
    cJSON *desc_json = cJSON_GetObjectItemCaseSensitive(json, "description");
    const char *description = "";
    if (cJSON_IsString(desc_json)) {
        description = desc_json->valuestring;
    }
    
    pthread_mutex_lock(&lock);
    if (todo_count >= MAX_TODOS) {
        pthread_mutex_unlock(&lock);
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "{\"error\": \"Server full\"}", NULL);
    }
    
    Todo *new_todo = &todos[todo_count++];
    new_todo->id = next_todo_id++;
    new_todo->user_id = user_id;
    strncpy(new_todo->title, title_json->valuestring, sizeof(new_todo->title) - 1);
    new_todo->title[sizeof(new_todo->title) - 1] = '\0';
    strncpy(new_todo->description, description, sizeof(new_todo->description) - 1);
    new_todo->description[sizeof(new_todo->description) - 1] = '\0';
    new_todo->completed = false;
    get_current_iso8601(new_todo->created_at, sizeof(new_todo->created_at));
    get_current_iso8601(new_todo->updated_at, sizeof(new_todo->updated_at));
    
    cJSON *resp_json = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp_json, "id", new_todo->id);
    cJSON_AddStringToObject(resp_json, "title", new_todo->title);
    cJSON_AddStringToObject(resp_json, "description", new_todo->description);
    cJSON_AddBoolToObject(resp_json, "completed", new_todo->completed);
    cJSON_AddStringToObject(resp_json, "created_at", new_todo->created_at);
    cJSON_AddStringToObject(resp_json, "updated_at", new_todo->updated_at);
    
    char *resp = cJSON_PrintUnformatted(resp_json);
    cJSON_Delete(resp_json);
    pthread_mutex_unlock(&lock);
    cJSON_Delete(json);
    
    enum MHD_Result ret = send_response(connection, MHD_HTTP_CREATED, resp, NULL);
    free(resp);
    return ret;
}

enum MHD_Result handle_get_todo(struct MHD_Connection *connection, int user_id, int todo_id) {
    pthread_mutex_lock(&lock);
    Todo *found = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id) {
            if (todos[i].user_id == user_id) {
                found = &todos[i];
            }
            break;
        }
    }
    
    if (!found) {
        pthread_mutex_unlock(&lock);
        return send_response(connection, MHD_HTTP_NOT_FOUND, "{\"error\": \"Todo not found\"}", NULL);
    }
    
    cJSON *resp_json = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp_json, "id", found->id);
    cJSON_AddStringToObject(resp_json, "title", found->title);
    cJSON_AddStringToObject(resp_json, "description", found->description);
    cJSON_AddBoolToObject(resp_json, "completed", found->completed);
    cJSON_AddStringToObject(resp_json, "created_at", found->created_at);
    cJSON_AddStringToObject(resp_json, "updated_at", found->updated_at);
    
    char *resp = cJSON_PrintUnformatted(resp_json);
    cJSON_Delete(resp_json);
    pthread_mutex_unlock(&lock);
    
    enum MHD_Result ret = send_response(connection, MHD_HTTP_OK, resp, NULL);
    free(resp);
    return ret;
}

enum MHD_Result handle_put_todo(struct MHD_Connection *connection, int user_id, int todo_id, const char *upload_data) {
    if (!upload_data) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid request body\"}", NULL);
    }
    cJSON *json = cJSON_Parse(upload_data);
    if (!json) {
        return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Invalid JSON\"}", NULL);
    }
    
    pthread_mutex_lock(&lock);
    Todo *found = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id) {
            if (todos[i].user_id == user_id) {
                found = &todos[i];
            }
            break;
        }
    }
    
    if (!found) {
        pthread_mutex_unlock(&lock);
        cJSON_Delete(json);
        return send_response(connection, MHD_HTTP_NOT_FOUND, "{\"error\": \"Todo not found\"}", NULL);
    }
    
    cJSON *title_json = cJSON_GetObjectItemCaseSensitive(json, "title");
    if (cJSON_IsString(title_json)) {
        if (strlen(title_json->valuestring) == 0) {
            pthread_mutex_unlock(&lock);
            cJSON_Delete(json);
            return send_response(connection, MHD_HTTP_BAD_REQUEST, "{\"error\": \"Title is required\"}", NULL);
        }
        strncpy(found->title, title_json->valuestring, sizeof(found->title) - 1);
        found->title[sizeof(found->title) - 1] = '\0';
    }
    
    cJSON *desc_json = cJSON_GetObjectItemCaseSensitive(json, "description");
    if (cJSON_IsString(desc_json)) {
        strncpy(found->description, desc_json->valuestring, sizeof(found->description) - 1);
        found->description[sizeof(found->description) - 1] = '\0';
    }
    
    cJSON *comp_json = cJSON_GetObjectItemCaseSensitive(json, "completed");
    if (cJSON_IsBool(comp_json)) {
        found->completed = cJSON_IsTrue(comp_json);
    }
    
    get_current_iso8601(found->updated_at, sizeof(found->updated_at));
    
    cJSON *resp_json = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp_json, "id", found->id);
    cJSON_AddStringToObject(resp_json, "title", found->title);
    cJSON_AddStringToObject(resp_json, "description", found->description);
    cJSON_AddBoolToObject(resp_json, "completed", found->completed);
    cJSON_AddStringToObject(resp_json, "created_at", found->created_at);
    cJSON_AddStringToObject(resp_json, "updated_at", found->updated_at);
    
    char *resp = cJSON_PrintUnformatted(resp_json);
    cJSON_Delete(resp_json);
    pthread_mutex_unlock(&lock);
    cJSON_Delete(json);
    
    enum MHD_Result ret = send_response(connection, MHD_HTTP_OK, resp, NULL);
    free(resp);
    return ret;
}

enum MHD_Result handle_delete_todo(struct MHD_Connection *connection, int user_id, int todo_id) {
    pthread_mutex_lock(&lock);
    int found_idx = -1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id) {
            if (todos[i].user_id == user_id) {
                found_idx = i;
            }
            break;
        }
    }
    
    if (found_idx == -1) {
        pthread_mutex_unlock(&lock);
        return send_response(connection, MHD_HTTP_NOT_FOUND, "{\"error\": \"Todo not found\"}", NULL);
    }
    
    todos[found_idx] = todos[todo_count - 1];
    todo_count--;
    pthread_mutex_unlock(&lock);
    
    return send_response(connection, MHD_HTTP_NO_CONTENT, NULL, NULL);
}

int main(int argc, char **argv) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
        }
    }

    pthread_mutex_init(&lock, NULL);

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_SELECT_INTERNALLY | MHD_USE_ERROR_LOG,
                                                 port, NULL, NULL,
                                                 &answer_to_connection, NULL,
                                                 MHD_OPTION_NOTIFY_COMPLETED, NULL, NULL,
                                                 MHD_OPTION_END);
    if (daemon == NULL) {
        fprintf(stderr, "Failed to start daemon\n");
        return 1;
    }

    printf("Server running on port %d\n", port);
    
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGTERM);
    pthread_sigmask(SIG_BLOCK, &mask, NULL);
    
    int sig;
    sigwait(&mask, &sig);

    MHD_stop_daemon(daemon);
    pthread_mutex_destroy(&lock);
    return 0;
}
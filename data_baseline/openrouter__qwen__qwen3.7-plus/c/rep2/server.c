#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdbool.h>
#include <pthread.h>
#include <microhttpd.h>
#include <cjson/cJSON.h>
#include <uuid/uuid.h>

typedef struct {
    int id;
    char *username;
    char *password;
} User;

typedef struct {
    int id;
    int user_id;
    char *title;
    char *description;
    bool completed;
    char *created_at;
    char *updated_at;
} Todo;

typedef struct {
    char *token;
    int user_id;
} Session;

static User *users = NULL;
static int user_count = 0;
static int next_user_id = 1;

static Todo *todos = NULL;
static int todo_count = 0;
static int next_todo_id = 1;

static Session *sessions = NULL;
static int session_count = 0;

static pthread_mutex_t data_mutex = PTHREAD_MUTEX_INITIALIZER;

struct RequestData {
    char *body;
    size_t body_size;
};

static void get_current_iso_time(char *buffer, size_t size) {
    time_t now = time(NULL);
    struct tm *gm = gmtime(&now);
    strftime(buffer, size, "%Y-%m-%dT%H:%M:%SZ", gm);
}

static void generate_uuid(char *buffer, size_t size) {
    uuid_t uuid;
    uuid_generate_random(uuid);
    uuid_unparse_lower(uuid, buffer);
}

static bool is_valid_username(const char *username) {
    if (!username) return false;
    int len = strlen(username);
    if (len < 3 || len > 50) return false;
    for (int i = 0; i < len; i++) {
        char c = username[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) {
            return false;
        }
    }
    return true;
}

static enum MHD_Result send_json_response(struct MHD_Connection *connection, int status_code, const char *json_str) {
    struct MHD_Response *response = MHD_create_response_from_buffer(
        strlen(json_str), (void *)json_str, MHD_RESPMEM_MUST_COPY);
    MHD_add_response_header(response, "Content-Type", "application/json");
    int ret = MHD_queue_response(connection, status_code, response);
    MHD_destroy_response(response);
    return ret;
}

static enum MHD_Result send_json_response_with_cookie(struct MHD_Connection *connection, int status_code, const char *json_str, const char *cookie) {
    struct MHD_Response *response = MHD_create_response_from_buffer(
        strlen(json_str), (void *)json_str, MHD_RESPMEM_MUST_COPY);
    MHD_add_response_header(response, "Content-Type", "application/json");
    if (cookie) {
        MHD_add_response_header(response, "Set-Cookie", cookie);
    }
    int ret = MHD_queue_response(connection, status_code, response);
    MHD_destroy_response(response);
    return ret;
}

static int check_auth(struct MHD_Connection *connection) {
    const char *cookie_header = MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");
    if (!cookie_header) return -1;
    
    pthread_mutex_lock(&data_mutex);
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, cookie_header) == 0) {
            int uid = sessions[i].user_id;
            pthread_mutex_unlock(&data_mutex);
            return uid;
        }
    }
    pthread_mutex_unlock(&data_mutex);
    return -1;
}

static enum MHD_Result handle_register(struct MHD_Connection *connection, struct RequestData *rd) {
    cJSON *body_json = cJSON_Parse(rd->body);
    if (!body_json) {
        return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}");
    }

    cJSON *username_json = cJSON_GetObjectItemCaseSensitive(body_json, "username");
    cJSON *password_json = cJSON_GetObjectItemCaseSensitive(body_json, "password");

    if (!cJSON_IsString(username_json) || !is_valid_username(username_json->valuestring)) {
        cJSON_Delete(body_json);
        return send_json_response(connection, 400, "{\"error\": \"Invalid username\"}");
    }
    if (!cJSON_IsString(password_json) || strlen(password_json->valuestring) < 8) {
        cJSON_Delete(body_json);
        return send_json_response(connection, 400, "{\"error\": \"Password too short\"}");
    }

    pthread_mutex_lock(&data_mutex);
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username_json->valuestring) == 0) {
            pthread_mutex_unlock(&data_mutex);
            cJSON_Delete(body_json);
            return send_json_response(connection, 409, "{\"error\": \"Username already exists\"}");
        }
    }

    User *new_users = realloc(users, (user_count + 1) * sizeof(User));
    if (!new_users) {
        pthread_mutex_unlock(&data_mutex);
        cJSON_Delete(body_json);
        return send_json_response(connection, 500, "{\"error\": \"Internal server error\"}");
    }
    users = new_users;
    
    char *uname = strdup(username_json->valuestring);
    char *pword = strdup(password_json->valuestring);
    if (!uname || !pword) {
        free(uname); free(pword);
        pthread_mutex_unlock(&data_mutex);
        cJSON_Delete(body_json);
        return send_json_response(connection, 500, "{\"error\": \"Internal server error\"}");
    }

    users[user_count].id = next_user_id++;
    users[user_count].username = uname;
    users[user_count].password = pword;
    int new_user_id = users[user_count].id;
    char *new_username = strdup(uname);
    user_count++;
    pthread_mutex_unlock(&data_mutex);

    cJSON_Delete(body_json);

    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", new_user_id);
    cJSON_AddStringToObject(resp, "username", new_username);
    char *resp_str = cJSON_PrintUnformatted(resp);
    cJSON_Delete(resp);
    free(new_username);

    int ret = send_json_response(connection, 201, resp_str);
    free(resp_str);
    return ret;
}

static enum MHD_Result handle_login(struct MHD_Connection *connection, struct RequestData *rd) {
    cJSON *body_json = cJSON_Parse(rd->body);
    if (!body_json) {
        return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}");
    }

    cJSON *username_json = cJSON_GetObjectItemCaseSensitive(body_json, "username");
    cJSON *password_json = cJSON_GetObjectItemCaseSensitive(body_json, "password");

    if (!cJSON_IsString(username_json) || !cJSON_IsString(password_json)) {
        cJSON_Delete(body_json);
        return send_json_response(connection, 401, "{\"error\": \"Invalid credentials\"}");
    }

    int found_user_id = -1;
    char *found_username = NULL;

    pthread_mutex_lock(&data_mutex);
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username_json->valuestring) == 0 &&
            strcmp(users[i].password, password_json->valuestring) == 0) {
            found_user_id = users[i].id;
            found_username = strdup(users[i].username);
            break;
        }
    }
    pthread_mutex_unlock(&data_mutex);

    cJSON_Delete(body_json);

    if (found_user_id == -1 || !found_username) {
        free(found_username);
        return send_json_response(connection, 401, "{\"error\": \"Invalid credentials\"}");
    }

    char token[37];
    generate_uuid(token, sizeof(token));

    pthread_mutex_lock(&data_mutex);
    Session *new_sessions = realloc(sessions, (session_count + 1) * sizeof(Session));
    if (!new_sessions) {
        pthread_mutex_unlock(&data_mutex);
        free(found_username);
        return send_json_response(connection, 500, "{\"error\": \"Internal server error\"}");
    }
    sessions = new_sessions;
    sessions[session_count].token = strdup(token);
    sessions[session_count].user_id = found_user_id;
    session_count++;
    pthread_mutex_unlock(&data_mutex);

    char cookie_header[128];
    snprintf(cookie_header, sizeof(cookie_header), "session_id=%s; Path=/; HttpOnly", token);

    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", found_user_id);
    cJSON_AddStringToObject(resp, "username", found_username);
    char *resp_str = cJSON_PrintUnformatted(resp);
    cJSON_Delete(resp);
    free(found_username);

    int ret = send_json_response_with_cookie(connection, 200, resp_str, cookie_header);
    free(resp_str);
    return ret;
}

static enum MHD_Result handle_logout(struct MHD_Connection *connection) {
    int user_id = check_auth(connection);
    if (user_id == -1) {
        return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}");
    }

    const char *cookie_header = MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");
    pthread_mutex_lock(&data_mutex);
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, cookie_header) == 0) {
            free(sessions[i].token);
            for (int j = i; j < session_count - 1; j++) {
                sessions[j] = sessions[j+1];
            }
            session_count--;
            break;
        }
    }
    pthread_mutex_unlock(&data_mutex);

    return send_json_response(connection, 200, "{}");
}

static enum MHD_Result handle_me(struct MHD_Connection *connection) {
    int user_id = check_auth(connection);
    if (user_id == -1) {
        return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}");
    }

    char *username = NULL;
    pthread_mutex_lock(&data_mutex);
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            username = strdup(users[i].username);
            break;
        }
    }
    pthread_mutex_unlock(&data_mutex);

    if (!username) {
        return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}");
    }

    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", user_id);
    cJSON_AddStringToObject(resp, "username", username);
    char *resp_str = cJSON_PrintUnformatted(resp);
    cJSON_Delete(resp);
    free(username);

    int ret = send_json_response(connection, 200, resp_str);
    free(resp_str);
    return ret;
}

static enum MHD_Result handle_password(struct MHD_Connection *connection, struct RequestData *rd) {
    int user_id = check_auth(connection);
    if (user_id == -1) {
        return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}");
    }

    cJSON *body_json = cJSON_Parse(rd->body);
    if (!body_json) {
        return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}");
    }

    cJSON *old_pw_json = cJSON_GetObjectItemCaseSensitive(body_json, "old_password");
    cJSON *new_pw_json = cJSON_GetObjectItemCaseSensitive(body_json, "new_password");

    if (!cJSON_IsString(old_pw_json) || !cJSON_IsString(new_pw_json)) {
        cJSON_Delete(body_json);
        return send_json_response(connection, 400, "{\"error\": \"Invalid request\"}");
    }

    if (strlen(new_pw_json->valuestring) < 8) {
        cJSON_Delete(body_json);
        return send_json_response(connection, 400, "{\"error\": \"Password too short\"}");
    }

    int match = 0;
    pthread_mutex_lock(&data_mutex);
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            if (strcmp(users[i].password, old_pw_json->valuestring) == 0) {
                match = 1;
                char *new_pword = strdup(new_pw_json->valuestring);
                if (new_pword) {
                    free(users[i].password);
                    users[i].password = new_pword;
                }
            }
            break;
        }
    }
    pthread_mutex_unlock(&data_mutex);
    cJSON_Delete(body_json);

    if (!match) {
        return send_json_response(connection, 401, "{\"error\": \"Invalid credentials\"}");
    }

    return send_json_response(connection, 200, "{}");
}

static enum MHD_Result handle_get_todos(struct MHD_Connection *connection) {
    int user_id = check_auth(connection);
    if (user_id == -1) {
        return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}");
    }

    cJSON *resp = cJSON_CreateArray();
    pthread_mutex_lock(&data_mutex);
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id == user_id) {
            cJSON *todo = cJSON_CreateObject();
            cJSON_AddNumberToObject(todo, "id", todos[i].id);
            cJSON_AddStringToObject(todo, "title", todos[i].title);
            cJSON_AddStringToObject(todo, "description", todos[i].description);
            cJSON_AddBoolToObject(todo, "completed", todos[i].completed);
            cJSON_AddStringToObject(todo, "created_at", todos[i].created_at);
            cJSON_AddStringToObject(todo, "updated_at", todos[i].updated_at);
            cJSON_AddItemToArray(resp, todo);
        }
    }
    pthread_mutex_unlock(&data_mutex);

    char *resp_str = cJSON_PrintUnformatted(resp);
    cJSON_Delete(resp);
    int ret = send_json_response(connection, 200, resp_str);
    free(resp_str);
    return ret;
}

static enum MHD_Result handle_post_todo(struct MHD_Connection *connection, struct RequestData *rd) {
    int user_id = check_auth(connection);
    if (user_id == -1) {
        return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}");
    }

    cJSON *body_json = cJSON_Parse(rd->body);
    if (!body_json) {
        return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}");
    }

    cJSON *title_json = cJSON_GetObjectItemCaseSensitive(body_json, "title");
    cJSON *desc_json = cJSON_GetObjectItemCaseSensitive(body_json, "description");

    if (!cJSON_IsString(title_json) || strlen(title_json->valuestring) == 0) {
        cJSON_Delete(body_json);
        return send_json_response(connection, 400, "{\"error\": \"Title is required\"}");
    }

    const char *desc = (cJSON_IsString(desc_json)) ? desc_json->valuestring : "";

    char created_at[32], updated_at[32];
    get_current_iso_time(created_at, sizeof(created_at));
    get_current_iso_time(updated_at, sizeof(updated_at));

    pthread_mutex_lock(&data_mutex);
    Todo *new_todos = realloc(todos, (todo_count + 1) * sizeof(Todo));
    if (!new_todos) {
        pthread_mutex_unlock(&data_mutex);
        cJSON_Delete(body_json);
        return send_json_response(connection, 500, "{\"error\": \"Internal server error\"}");
    }
    todos = new_todos;
    
    int new_id = next_todo_id++;
    todos[todo_count].id = new_id;
    todos[todo_count].user_id = user_id;
    todos[todo_count].title = strdup(title_json->valuestring);
    todos[todo_count].description = strdup(desc);
    todos[todo_count].completed = false;
    todos[todo_count].created_at = strdup(created_at);
    todos[todo_count].updated_at = strdup(updated_at);
    
    if (!todos[todo_count].title || !todos[todo_count].description || 
        !todos[todo_count].created_at || !todos[todo_count].updated_at) {
        free(todos[todo_count].title);
        free(todos[todo_count].description);
        free(todos[todo_count].created_at);
        free(todos[todo_count].updated_at);
        pthread_mutex_unlock(&data_mutex);
        cJSON_Delete(body_json);
        return send_json_response(connection, 500, "{\"error\": \"Internal server error\"}");
    }
    todo_count++;
    pthread_mutex_unlock(&data_mutex);

    cJSON_Delete(body_json);

    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", new_id);
    cJSON_AddStringToObject(resp, "title", title_json->valuestring);
    cJSON_AddStringToObject(resp, "description", desc);
    cJSON_AddBoolToObject(resp, "completed", false);
    cJSON_AddStringToObject(resp, "created_at", created_at);
    cJSON_AddStringToObject(resp, "updated_at", updated_at);

    char *resp_str = cJSON_PrintUnformatted(resp);
    cJSON_Delete(resp);
    int ret = send_json_response(connection, 201, resp_str);
    free(resp_str);
    return ret;
}

static enum MHD_Result handle_get_todo(struct MHD_Connection *connection, const char *url) {
    char *endptr;
    long todo_id = strtol(url + 7, &endptr, 10);
    if (endptr == url + 7 || (*endptr != '\0' && *endptr != '?')) {
        return send_json_response(connection, 404, "{\"error\": \"Todo not found\"}");
    }

    int user_id = check_auth(connection);
    if (user_id == -1) {
        return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}");
    }

    pthread_mutex_lock(&data_mutex);
    Todo *found = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id) {
            found = &todos[i];
            break;
        }
    }

    if (!found) {
        pthread_mutex_unlock(&data_mutex);
        return send_json_response(connection, 404, "{\"error\": \"Todo not found\"}");
    }

    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", found->id);
    cJSON_AddStringToObject(resp, "title", found->title);
    cJSON_AddStringToObject(resp, "description", found->description);
    cJSON_AddBoolToObject(resp, "completed", found->completed);
    cJSON_AddStringToObject(resp, "created_at", found->created_at);
    cJSON_AddStringToObject(resp, "updated_at", found->updated_at);
    char *resp_str = cJSON_PrintUnformatted(resp);
    cJSON_Delete(resp);
    pthread_mutex_unlock(&data_mutex);

    int ret = send_json_response(connection, 200, resp_str);
    free(resp_str);
    return ret;
}

static enum MHD_Result handle_put_todo(struct MHD_Connection *connection, const char *url, struct RequestData *rd) {
    char *endptr;
    long todo_id = strtol(url + 7, &endptr, 10);
    if (endptr == url + 7 || (*endptr != '\0' && *endptr != '?')) {
        return send_json_response(connection, 404, "{\"error\": \"Todo not found\"}");
    }

    int user_id = check_auth(connection);
    if (user_id == -1) {
        return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}");
    }

    cJSON *body_json = cJSON_Parse(rd->body);
    if (!body_json) {
        return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}");
    }

    cJSON *title_json = cJSON_GetObjectItemCaseSensitive(body_json, "title");
    cJSON *desc_json = cJSON_GetObjectItemCaseSensitive(body_json, "description");
    cJSON *completed_json = cJSON_GetObjectItemCaseSensitive(body_json, "completed");

    if (cJSON_IsString(title_json) && strlen(title_json->valuestring) == 0) {
        cJSON_Delete(body_json);
        return send_json_response(connection, 400, "{\"error\": \"Title is required\"}");
    }

    pthread_mutex_lock(&data_mutex);
    Todo *found = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id) {
            found = &todos[i];
            break;
        }
    }

    if (!found) {
        pthread_mutex_unlock(&data_mutex);
        cJSON_Delete(body_json);
        return send_json_response(connection, 404, "{\"error\": \"Todo not found\"}");
    }

    if (cJSON_IsString(title_json)) {
        char *new_title = strdup(title_json->valuestring);
        if (new_title) { free(found->title); found->title = new_title; }
    }
    if (cJSON_IsString(desc_json)) {
        char *new_desc = strdup(desc_json->valuestring);
        if (new_desc) { free(found->description); found->description = new_desc; }
    }
    if (cJSON_IsBool(completed_json)) {
        found->completed = cJSON_IsTrue(completed_json);
    }

    char updated_at[32];
    get_current_iso_time(updated_at, sizeof(updated_at));
    char *new_updated = strdup(updated_at);
    if (new_updated) { free(found->updated_at); found->updated_at = new_updated; }

    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", found->id);
    cJSON_AddStringToObject(resp, "title", found->title);
    cJSON_AddStringToObject(resp, "description", found->description);
    cJSON_AddBoolToObject(resp, "completed", found->completed);
    cJSON_AddStringToObject(resp, "created_at", found->created_at);
    cJSON_AddStringToObject(resp, "updated_at", found->updated_at);
    char *resp_str = cJSON_PrintUnformatted(resp);
    cJSON_Delete(resp);
    pthread_mutex_unlock(&data_mutex);

    cJSON_Delete(body_json);
    int ret = send_json_response(connection, 200, resp_str);
    free(resp_str);
    return ret;
}

static enum MHD_Result handle_delete_todo(struct MHD_Connection *connection, const char *url) {
    char *endptr;
    long todo_id = strtol(url + 7, &endptr, 10);
    if (endptr == url + 7 || (*endptr != '\0' && *endptr != '?')) {
        return send_json_response(connection, 404, "{\"error\": \"Todo not found\"}");
    }

    int user_id = check_auth(connection);
    if (user_id == -1) {
        return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}");
    }

    pthread_mutex_lock(&data_mutex);
    int found_idx = -1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id) {
            found_idx = i;
            break;
        }
    }

    if (found_idx == -1) {
        pthread_mutex_unlock(&data_mutex);
        return send_json_response(connection, 404, "{\"error\": \"Todo not found\"}");
    }

    free(todos[found_idx].title);
    free(todos[found_idx].description);
    free(todos[found_idx].created_at);
    free(todos[found_idx].updated_at);

    for (int i = found_idx; i < todo_count - 1; i++) {
        todos[i] = todos[i+1];
    }
    todo_count--;
    pthread_mutex_unlock(&data_mutex);

    struct MHD_Response *response = MHD_create_response_from_buffer(0, "", MHD_RESPMEM_MUST_COPY);
    int ret = MHD_queue_response(connection, 204, response);
    MHD_destroy_response(response);
    return ret;
}

static enum MHD_Result ahc_echo(void *cls, struct MHD_Connection *connection,
                    const char *url, const char *method,
                    const char *version, const char *upload_data,
                    size_t *upload_data_size, void **con_cls) {
    struct RequestData *rd = *con_cls;
    if (rd == NULL) {
        rd = calloc(1, sizeof(struct RequestData));
        if (!rd) return MHD_NO; // enum MHD_Result
        *con_cls = rd;
        return MHD_YES; // enum MHD_Result
    }
    if (*upload_data_size > 0) {
        char *new_body = realloc(rd->body, rd->body_size + *upload_data_size + 1);
        if (!new_body) {
            return MHD_NO; // enum MHD_Result
        }
        rd->body = new_body;
        memcpy(rd->body + rd->body_size, upload_data, *upload_data_size);
        rd->body_size += *upload_data_size;
        rd->body[rd->body_size] = '\0';
        *upload_data_size = 0;
        return MHD_YES; // enum MHD_Result
    }

    int ret = MHD_NO;

    if (strcmp(method, "POST") == 0 && strcmp(url, "/register") == 0) {
        ret = handle_register(connection, rd);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/login") == 0) {
        ret = handle_login(connection, rd);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/logout") == 0) {
        ret = handle_logout(connection);
    } else if (strcmp(method, "GET") == 0 && strcmp(url, "/me") == 0) {
        ret = handle_me(connection);
    } else if (strcmp(method, "PUT") == 0 && strcmp(url, "/password") == 0) {
        ret = handle_password(connection, rd);
    } else if (strcmp(method, "GET") == 0 && strcmp(url, "/todos") == 0) {
        ret = handle_get_todos(connection);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/todos") == 0) {
        ret = handle_post_todo(connection, rd);
    } else if (strcmp(method, "GET") == 0 && strncmp(url, "/todos/", 7) == 0) {
        ret = handle_get_todo(connection, url);
    } else if (strcmp(method, "PUT") == 0 && strncmp(url, "/todos/", 7) == 0) {
        ret = handle_put_todo(connection, url, rd);
    } else if (strcmp(method, "DELETE") == 0 && strncmp(url, "/todos/", 7) == 0) {
        ret = handle_delete_todo(connection, url);
    } else {
        ret = send_json_response(connection, 404, "{\"error\": \"Not found\"}");
    }

    free(rd->body);
    free(rd);
    *con_cls = NULL;
    return ret;
}

static void request_completed(void *cls, struct MHD_Connection *connection,
                              void **con_cls, enum MHD_RequestTerminationCode toe) {
    struct RequestData *rd = *con_cls;
    if (rd) {
        free(rd->body);
        free(rd);
        *con_cls = NULL;
    }
}

int main(int argc, char **argv) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i+1]);
            i++;
        }
    }

    struct MHD_Daemon *daemon = MHD_start_daemon(
        MHD_USE_SELECT_INTERNALLY | MHD_USE_DUAL_STACK,
        port, NULL, NULL,
        &ahc_echo, NULL,
        MHD_OPTION_NOTIFY_COMPLETED, request_completed, NULL,
        MHD_OPTION_END);

    if (daemon == NULL) {
        fprintf(stderr, "Failed to start daemon on port %d\n", port);
        return 1;
    }

    printf("Server running on port %d\n", port);
    
    while(1) {
        sleep(1);
    }

    MHD_stop_daemon(daemon);
    return 0;
}
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <microhttpd.h>
#include <cjson/cJSON.h>
#include <uuid/uuid.h>

#define MAX_USERS 1000
#define MAX_SESSIONS 1000
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
    char description[512];
    int completed;
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

pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

#define SAFE_STRCPY(dest, src) do { \
    strncpy(dest, src, sizeof(dest) - 1); \
    dest[sizeof(dest) - 1] = '\0'; \
} while(0)

void get_iso8601_now(char *buf) {
    time_t t = time(NULL);
    struct tm *tm = gmtime(&t);
    strftime(buf, 32, "%Y-%m-%dT%H:%M:%SZ", tm);
}

void generate_uuid(char *buf) {
    uuid_t uuid;
    uuid_generate(uuid);
    uuid_unparse_lower(uuid, buf);
}

int is_valid_username(const char *username) {
    if (!username) return 0;
    size_t len = strlen(username);
    if (len < 3 || len > 50) return 0;
    for (size_t i = 0; i < len; i++) {
        char c = username[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) {
            return 0;
        }
    }
    return 1;
}

int find_session(const char *token) {
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, token) == 0) {
            return sessions[i].user_id;
        }
    }
    return -1;
}

void delete_session(const char *token) {
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, token) == 0) {
            memmove(&sessions[i], &sessions[i+1], (session_count - i - 1) * sizeof(Session));
            session_count--;
            return;
        }
    }
}

enum MHD_Result send_json_response(struct MHD_Connection *connection, int status, const char *json_str) {
    struct MHD_Response *response = MHD_create_response_from_buffer(strlen(json_str), (void *)json_str, MHD_RESPMEM_MUST_COPY);
    MHD_add_response_header(response, "Content-Type", "application/json");
    enum MHD_Result ret = MHD_queue_response(connection, status, response);
    MHD_destroy_response(response);
    return ret;
}

enum MHD_Result send_json_error(struct MHD_Connection *connection, int status, const char *error_msg) {
    cJSON *err = cJSON_CreateObject();
    cJSON_AddStringToObject(err, "error", error_msg);
    char *json_str = cJSON_PrintUnformatted(err);
    enum MHD_Result ret = send_json_response(connection, status, json_str);
    free(json_str);
    cJSON_Delete(err);
    return ret;
}

int check_auth(struct MHD_Connection *connection) {
    const char *token = MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");
    if (!token) {
        send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
        return -1;
    }
    int user_id = find_session(token);
    if (user_id == -1) {
        send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
        return -1;
    }
    return user_id;
}

struct connection_info_struct {
    char *post_data;
    size_t post_data_size;
};

enum MHD_Result handle_register(struct MHD_Connection *connection, const char *post_data) {
    if (!post_data) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid request");
    cJSON *root = cJSON_Parse(post_data);
    if (!root) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");

    cJSON *username_json = cJSON_GetObjectItem(root, "username");
    cJSON *password_json = cJSON_GetObjectItem(root, "password");

    if (!cJSON_IsString(username_json) || !username_json->valuestring) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }
    if (!cJSON_IsString(password_json) || !password_json->valuestring) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }

    const char *username = username_json->valuestring;
    const char *password = password_json->valuestring;

    if (!is_valid_username(username)) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }
    if (strlen(password) < 8) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }

    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            cJSON_Delete(root);
            return send_json_error(connection, MHD_HTTP_CONFLICT, "Username already exists");
        }
    }

    if (user_count >= MAX_USERS) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Server full");
    }

    User *u = &users[user_count++];
    u->id = next_user_id++;
    SAFE_STRCPY(u->username, username);
    SAFE_STRCPY(u->password, password);

    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", u->id);
    cJSON_AddStringToObject(resp, "username", u->username);
    char *json_str = cJSON_PrintUnformatted(resp);
    enum MHD_Result ret = send_json_response(connection, MHD_HTTP_CREATED, json_str);
    free(json_str);
    cJSON_Delete(resp);
    cJSON_Delete(root);
    return ret;
}

enum MHD_Result handle_login(struct MHD_Connection *connection, const char *post_data) {
    if (!post_data) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid request");
    cJSON *root = cJSON_Parse(post_data);
    if (!root) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");

    cJSON *username_json = cJSON_GetObjectItem(root, "username");
    cJSON *password_json = cJSON_GetObjectItem(root, "password");

    if (!cJSON_IsString(username_json) || !cJSON_IsString(password_json) || !username_json->valuestring || !password_json->valuestring) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }

    const char *username = username_json->valuestring;
    const char *password = password_json->valuestring;

    int user_id = -1;
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0 && strcmp(users[i].password, password) == 0) {
            user_id = users[i].id;
            break;
        }
    }

    if (user_id == -1) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }

    char token[64];
    generate_uuid(token);

    if (session_count >= MAX_SESSIONS) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Session limit reached");
    }

    Session *s = &sessions[session_count++];
    SAFE_STRCPY(s->token, token);
    s->user_id = user_id;

    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", user_id);
    cJSON_AddStringToObject(resp, "username", username);
    char *json_str = cJSON_PrintUnformatted(resp);

    char cookie_header[256];
    snprintf(cookie_header, sizeof(cookie_header), "session_id=%s; Path=/; HttpOnly", token);

    struct MHD_Response *response = MHD_create_response_from_buffer(strlen(json_str), (void *)json_str, MHD_RESPMEM_MUST_COPY);
    MHD_add_response_header(response, "Content-Type", "application/json");
    MHD_add_response_header(response, "Set-Cookie", cookie_header);
    enum MHD_Result ret = MHD_queue_response(connection, MHD_HTTP_OK, response);
    MHD_destroy_response(response);

    free(json_str);
    cJSON_Delete(resp);
    cJSON_Delete(root);
    return ret;
}

enum MHD_Result handle_logout(struct MHD_Connection *connection) {
    int user_id = check_auth(connection);
    if (user_id == -1) return MHD_YES;

    const char *token = MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");
    delete_session(token);

    return send_json_response(connection, MHD_HTTP_OK, "{}");
}

enum MHD_Result handle_me(struct MHD_Connection *connection) {
    int user_id = check_auth(connection);
    if (user_id == -1) return MHD_YES;

    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            cJSON *resp = cJSON_CreateObject();
            cJSON_AddNumberToObject(resp, "id", users[i].id);
            cJSON_AddStringToObject(resp, "username", users[i].username);
            char *json_str = cJSON_PrintUnformatted(resp);
            enum MHD_Result ret = send_json_response(connection, MHD_HTTP_OK, json_str);
            free(json_str);
            cJSON_Delete(resp);
            return ret;
        }
    }
    return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "User not found");
}

enum MHD_Result handle_password(struct MHD_Connection *connection, const char *post_data) {
    int user_id = check_auth(connection);
    if (user_id == -1) return MHD_YES;

    if (!post_data) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid request");
    cJSON *root = cJSON_Parse(post_data);
    if (!root) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");

    cJSON *old_pwd_json = cJSON_GetObjectItem(root, "old_password");
    cJSON *new_pwd_json = cJSON_GetObjectItem(root, "new_password");

    if (!cJSON_IsString(old_pwd_json) || !cJSON_IsString(new_pwd_json) || !old_pwd_json->valuestring || !new_pwd_json->valuestring) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid password");
    }

    const char *old_pwd = old_pwd_json->valuestring;
    const char *new_pwd = new_pwd_json->valuestring;

    if (strlen(new_pwd) < 8) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }

    int found = 0;
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            if (strcmp(users[i].password, old_pwd) != 0) {
                cJSON_Delete(root);
                return send_json_error(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
            }
            SAFE_STRCPY(users[i].password, new_pwd);
            found = 1;
            break;
        }
    }

    if (!found) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "User not found");
    }

    cJSON_Delete(root);
    return send_json_response(connection, MHD_HTTP_OK, "{}");
}

enum MHD_Result handle_get_todos(struct MHD_Connection *connection) {
    int user_id = check_auth(connection);
    if (user_id == -1) return MHD_YES;

    cJSON *resp = cJSON_CreateArray();
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
    char *json_str = cJSON_PrintUnformatted(resp);
    enum MHD_Result ret = send_json_response(connection, MHD_HTTP_OK, json_str);
    free(json_str);
    cJSON_Delete(resp);
    return ret;
}

enum MHD_Result handle_create_todo(struct MHD_Connection *connection, const char *post_data) {
    int user_id = check_auth(connection);
    if (user_id == -1) return MHD_YES;

    if (!post_data) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid request");
    cJSON *root = cJSON_Parse(post_data);
    if (!root) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");

    cJSON *title_json = cJSON_GetObjectItem(root, "title");
    if (!cJSON_IsString(title_json) || !title_json->valuestring || strlen(title_json->valuestring) == 0) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
    }

    cJSON *desc_json = cJSON_GetObjectItem(root, "description");
    const char *desc = (cJSON_IsString(desc_json) && desc_json->valuestring) ? desc_json->valuestring : "";

    if (todo_count >= MAX_TODOS) {
        cJSON_Delete(root);
        return send_json_error(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Todo limit reached");
    }

    Todo *t = &todos[todo_count++];
    t->id = next_todo_id++;
    t->user_id = user_id;
    SAFE_STRCPY(t->title, title_json->valuestring);
    SAFE_STRCPY(t->description, desc);
    t->completed = 0;
    get_iso8601_now(t->created_at);
    get_iso8601_now(t->updated_at);

    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", t->id);
    cJSON_AddStringToObject(resp, "title", t->title);
    cJSON_AddStringToObject(resp, "description", t->description);
    cJSON_AddBoolToObject(resp, "completed", t->completed);
    cJSON_AddStringToObject(resp, "created_at", t->created_at);
    cJSON_AddStringToObject(resp, "updated_at", t->updated_at);

    char *json_str = cJSON_PrintUnformatted(resp);
    enum MHD_Result ret = send_json_response(connection, MHD_HTTP_CREATED, json_str);
    free(json_str);
    cJSON_Delete(resp);
    cJSON_Delete(root);
    return ret;
}

enum MHD_Result handle_get_todo(struct MHD_Connection *connection, int id) {
    int user_id = check_auth(connection);
    if (user_id == -1) return MHD_YES;

    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == id && todos[i].user_id == user_id) {
            cJSON *resp = cJSON_CreateObject();
            cJSON_AddNumberToObject(resp, "id", todos[i].id);
            cJSON_AddStringToObject(resp, "title", todos[i].title);
            cJSON_AddStringToObject(resp, "description", todos[i].description);
            cJSON_AddBoolToObject(resp, "completed", todos[i].completed);
            cJSON_AddStringToObject(resp, "created_at", todos[i].created_at);
            cJSON_AddStringToObject(resp, "updated_at", todos[i].updated_at);
            char *json_str = cJSON_PrintUnformatted(resp);
            enum MHD_Result ret = send_json_response(connection, MHD_HTTP_OK, json_str);
            free(json_str);
            cJSON_Delete(resp);
            return ret;
        }
    }
    return send_json_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
}

enum MHD_Result handle_update_todo(struct MHD_Connection *connection, int id, const char *post_data) {
    int user_id = check_auth(connection);
    if (user_id == -1) return MHD_YES;

    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == id && todos[i].user_id == user_id) {
            if (post_data) {
                cJSON *root = cJSON_Parse(post_data);
                if (!root) return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");

                cJSON *title_json = cJSON_GetObjectItem(root, "title");
                if (cJSON_IsString(title_json)) {
                    if (strlen(title_json->valuestring) == 0) {
                        cJSON_Delete(root);
                        return send_json_error(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
                    }
                    SAFE_STRCPY(todos[i].title, title_json->valuestring);
                }

                cJSON *desc_json = cJSON_GetObjectItem(root, "description");
                if (cJSON_IsString(desc_json)) {
                    SAFE_STRCPY(todos[i].description, desc_json->valuestring);
                }

                cJSON *comp_json = cJSON_GetObjectItem(root, "completed");
                if (cJSON_IsBool(comp_json)) {
                    todos[i].completed = cJSON_IsTrue(comp_json) ? 1 : 0;
                }
                
                get_iso8601_now(todos[i].updated_at);
                cJSON_Delete(root);
            }

            cJSON *resp = cJSON_CreateObject();
            cJSON_AddNumberToObject(resp, "id", todos[i].id);
            cJSON_AddStringToObject(resp, "title", todos[i].title);
            cJSON_AddStringToObject(resp, "description", todos[i].description);
            cJSON_AddBoolToObject(resp, "completed", todos[i].completed);
            cJSON_AddStringToObject(resp, "created_at", todos[i].created_at);
            cJSON_AddStringToObject(resp, "updated_at", todos[i].updated_at);
            char *json_str = cJSON_PrintUnformatted(resp);
            enum MHD_Result ret = send_json_response(connection, MHD_HTTP_OK, json_str);
            free(json_str);
            cJSON_Delete(resp);
            return ret;
        }
    }
    return send_json_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
}

enum MHD_Result handle_delete_todo(struct MHD_Connection *connection, int id) {
    int user_id = check_auth(connection);
    if (user_id == -1) return MHD_YES;

    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == id && todos[i].user_id == user_id) {
            memmove(&todos[i], &todos[i+1], (todo_count - i - 1) * sizeof(Todo));
            todo_count--;
            
            struct MHD_Response *response = MHD_create_response_from_buffer(0, "", MHD_RESPMEM_PERSISTENT);
            enum MHD_Result ret = MHD_queue_response(connection, MHD_HTTP_NO_CONTENT, response);
            MHD_destroy_response(response);
            return ret;
        }
    }
    return send_json_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
}

enum MHD_Result process_request(struct MHD_Connection *connection, const char *url, const char *method, const char *post_data) {
    pthread_mutex_lock(&lock);
    enum MHD_Result ret = MHD_NO;

    if (strcmp(url, "/register") == 0 && strcmp(method, "POST") == 0) {
        ret = handle_register(connection, post_data);
    } else if (strcmp(url, "/login") == 0 && strcmp(method, "POST") == 0) {
        ret = handle_login(connection, post_data);
    } else if (strcmp(url, "/logout") == 0 && strcmp(method, "POST") == 0) {
        ret = handle_logout(connection);
    } else if (strcmp(url, "/me") == 0 && strcmp(method, "GET") == 0) {
        ret = handle_me(connection);
    } else if (strcmp(url, "/password") == 0 && strcmp(method, "PUT") == 0) {
        ret = handle_password(connection, post_data);
    } else if (strcmp(url, "/todos") == 0 && strcmp(method, "GET") == 0) {
        ret = handle_get_todos(connection);
    } else if (strcmp(url, "/todos") == 0 && strcmp(method, "POST") == 0) {
        ret = handle_create_todo(connection, post_data);
    } else if (strncmp(url, "/todos/", 7) == 0) {
        char *endptr;
        long id_long = strtol(url + 7, &endptr, 10);
        if (*endptr != '\0' || id_long <= 0 || id_long > 2147483647) {
            ret = send_json_error(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
        } else {
            int id = (int)id_long;
            if (strcmp(method, "GET") == 0) {
                ret = handle_get_todo(connection, id);
            } else if (strcmp(method, "PUT") == 0) {
                ret = handle_update_todo(connection, id, post_data);
            } else if (strcmp(method, "DELETE") == 0) {
                ret = handle_delete_todo(connection, id);
            } else {
                ret = send_json_error(connection, MHD_HTTP_METHOD_NOT_ALLOWED, "Method not allowed");
            }
        }
    } else {
        ret = send_json_error(connection, MHD_HTTP_NOT_FOUND, "Not found");
    }

    pthread_mutex_unlock(&lock);
    return ret;
}

enum MHD_Result handle_request(void *cls, struct MHD_Connection *connection,
                   const char *url, const char *method,
                   const char *version, const char *upload_data,
                   size_t *upload_data_size, void **con_cls) {
    if (strcmp(method, "POST") == 0 || strcmp(method, "PUT") == 0) {
        struct connection_info_struct *con_info = *con_cls;
        if (con_info == NULL) {
            con_info = calloc(1, sizeof(struct connection_info_struct));
            *con_cls = con_info;
            return MHD_YES; // Always return MHD_YES on first call for POST/PUT
        }
        if (*upload_data_size > 0) {
            con_info->post_data = realloc(con_info->post_data, con_info->post_data_size + *upload_data_size + 1);
            memcpy(con_info->post_data + con_info->post_data_size, upload_data, *upload_data_size);
            con_info->post_data_size += *upload_data_size;
            con_info->post_data[con_info->post_data_size] = '\0';
            *upload_data_size = 0;
            return MHD_YES;
        } else {
            enum MHD_Result ret = process_request(connection, url, method, con_info->post_data ? con_info->post_data : "");
            free(con_info->post_data);
            free(con_info);
            *con_cls = NULL;
            return ret;
        }
    } else {
        return process_request(connection, url, method, NULL);
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

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_SELECT_INTERNALLY | MHD_USE_ERROR_LOG,
                                                 port, NULL, NULL,
                                                 &handle_request, NULL,
                                                 MHD_OPTION_END);
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
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <microhttpd.h>
#include <jansson.h>
#include <uuid/uuid.h>
#include <regex.h>
#include <time.h>

#define MAX_USERS 1000
#define MAX_TODOS 10000
#define MAX_SESSIONS 1000

typedef struct {
    int id;
    char username[64];
    char password[256];
} User;

typedef struct {
    int id;
    int user_id;
    char title[256];
    char description[1024];
    int completed;
    char created_at[32];
    char updated_at[32];
} Todo;

typedef struct {
    char token[64];
    int user_id;
    int active;
} Session;

User users[MAX_USERS];
int user_count = 0;
int next_user_id = 1;
pthread_mutex_t users_mutex = PTHREAD_MUTEX_INITIALIZER;

Todo todos[MAX_TODOS];
int todo_count = 0;
int next_todo_id = 1;
pthread_mutex_t todos_mutex = PTHREAD_MUTEX_INITIALIZER;

Session sessions[MAX_SESSIONS];
int session_count = 0;
pthread_mutex_t sessions_mutex = PTHREAD_MUTEX_INITIALIZER;

struct connection_info {
    char *body;
    size_t body_len;
    size_t body_size;
};

void get_iso_time(char *buffer, size_t size) {
    time_t t = time(NULL);
    struct tm tm_buf;
    gmtime_r(&t, &tm_buf);
    strftime(buffer, size, "%Y-%m-%dT%H:%M:%SZ", &tm_buf);
}

void generate_uuid(char *buffer) {
    uuid_t uuid;
    uuid_generate_random(uuid);
    uuid_unparse_lower(uuid, buffer);
}

User* find_user_by_username(const char *username) {
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            return &users[i];
        }
    }
    return NULL;
}

User* find_user_by_id(int id) {
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == id) {
            return &users[i];
        }
    }
    return NULL;
}

Session* find_session(const char *token) {
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, token) == 0 && sessions[i].active) {
            return &sessions[i];
        }
    }
    return NULL;
}

const char* get_session_token(struct MHD_Connection *connection) {
    return MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");
}

enum MHD_Result send_json_response(struct MHD_Connection *connection, unsigned int status_code, const char *json_str) {
    struct MHD_Response *response = MHD_create_response_from_buffer(strlen(json_str), (void *)json_str, MHD_RESPMEM_MUST_COPY);
    MHD_add_response_header(response, MHD_HTTP_HEADER_CONTENT_TYPE, "application/json");
    enum MHD_Result ret = MHD_queue_response(connection, status_code, response);
    MHD_destroy_response(response);
    return ret;
}

enum MHD_Result send_error_response(struct MHD_Connection *connection, unsigned int status_code, const char *error_msg) {
    char json_str[256];
    snprintf(json_str, sizeof(json_str), "{\"error\": \"%s\"}", error_msg);
    return send_json_response(connection, status_code, json_str);
}

enum MHD_Result check_auth(struct MHD_Connection *connection, int *user_id) {
    const char *token = get_session_token(connection);
    if (!token) {
        send_error_response(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
        return MHD_YES;
    }
    
    pthread_mutex_lock(&sessions_mutex);
    Session *session = find_session(token);
    if (!session) {
        pthread_mutex_unlock(&sessions_mutex);
        send_error_response(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
        return MHD_YES;
    }
    *user_id = session->user_id;
    pthread_mutex_unlock(&sessions_mutex);
    return MHD_NO;
}

enum MHD_Result handle_register(struct MHD_Connection *connection, const char *body) {
    json_error_t error;
    json_t *root = json_loads(body, 0, &error);
    if (!root) {
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }

    const char *username = json_string_value(json_object_get(root, "username"));
    const char *password = json_string_value(json_object_get(root, "password"));

    if (!username) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }

    if (!password) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }

    if (strlen(username) < 3 || strlen(username) > 50) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }

    regex_t regex;
    int reti = regcomp(&regex, "^[a-zA-Z0-9_]+$", REG_EXTENDED);
    if (reti) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Internal error");
    }
    reti = regexec(&regex, username, 0, NULL, 0);
    regfree(&regex);
    if (reti != 0) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Invalid username");
    }

    if (strlen(password) < 8) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }

    pthread_mutex_lock(&users_mutex);
    if (find_user_by_username(username)) {
        pthread_mutex_unlock(&users_mutex);
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_CONFLICT, "Username already exists");
    }

    if (user_count >= MAX_USERS) {
        pthread_mutex_unlock(&users_mutex);
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Server full");
    }

    User *new_user = &users[user_count++];
    new_user->id = next_user_id++;
    strncpy(new_user->username, username, sizeof(new_user->username) - 1);
    strncpy(new_user->password, password, sizeof(new_user->password) - 1);
    int new_id = new_user->id;
    char new_username[64];
    strcpy(new_username, new_user->username);
    pthread_mutex_unlock(&users_mutex);

    json_decref(root);

    char response[256];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", new_id, new_username);
    return send_json_response(connection, MHD_HTTP_CREATED, response);
}

enum MHD_Result handle_login(struct MHD_Connection *connection, const char *body) {
    json_error_t error;
    json_t *root = json_loads(body, 0, &error);
    if (!root) {
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }

    const char *username = json_string_value(json_object_get(root, "username"));
    const char *password = json_string_value(json_object_get(root, "password"));

    if (!username || !password) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }

    pthread_mutex_lock(&users_mutex);
    User *user = find_user_by_username(username);
    if (!user || strcmp(user->password, password) != 0) {
        pthread_mutex_unlock(&users_mutex);
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }

    int user_id = user->id;
    char user_username[64];
    strcpy(user_username, user->username);
    pthread_mutex_unlock(&users_mutex);

    char token[64];
    generate_uuid(token);

    pthread_mutex_lock(&sessions_mutex);
    if (session_count >= MAX_SESSIONS) {
        pthread_mutex_unlock(&sessions_mutex);
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Server full");
    }
    Session *new_session = &sessions[session_count++];
    strcpy(new_session->token, token);
    new_session->user_id = user_id;
    new_session->active = 1;
    pthread_mutex_unlock(&sessions_mutex);

    json_decref(root);

    char response[256];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", user_id, user_username);
    
    struct MHD_Response *resp = MHD_create_response_from_buffer(strlen(response), (void *)response, MHD_RESPMEM_MUST_COPY);
    MHD_add_response_header(resp, MHD_HTTP_HEADER_CONTENT_TYPE, "application/json");
    
    char cookie_header[256];
    snprintf(cookie_header, sizeof(cookie_header), "session_id=%s; Path=/; HttpOnly", token);
    MHD_add_response_header(resp, "Set-Cookie", cookie_header);
    
    enum MHD_Result ret = MHD_queue_response(connection, MHD_HTTP_OK, resp);
    MHD_destroy_response(resp);
    return ret;
}

enum MHD_Result handle_logout(struct MHD_Connection *connection) {
    int user_id;
    if (check_auth(connection, &user_id) == MHD_YES) return MHD_YES;

    const char *token = get_session_token(connection);
    pthread_mutex_lock(&sessions_mutex);
    Session *session = find_session(token);
    if (session) {
        session->active = 0;
    }
    pthread_mutex_unlock(&sessions_mutex);

    return send_json_response(connection, MHD_HTTP_OK, "{}");
}

enum MHD_Result handle_me(struct MHD_Connection *connection) {
    int user_id;
    if (check_auth(connection, &user_id) == MHD_YES) return MHD_YES;

    pthread_mutex_lock(&users_mutex);
    User *user = find_user_by_id(user_id);
    if (!user) {
        pthread_mutex_unlock(&users_mutex);
        return send_error_response(connection, MHD_HTTP_UNAUTHORIZED, "Authentication required");
    }
    char response[256];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", user->id, user->username);
    pthread_mutex_unlock(&users_mutex);

    return send_json_response(connection, MHD_HTTP_OK, response);
}

enum MHD_Result handle_password(struct MHD_Connection *connection, const char *body) {
    int user_id;
    if (check_auth(connection, &user_id) == MHD_YES) return MHD_YES;

    json_error_t error;
    json_t *root = json_loads(body, 0, &error);
    if (!root) {
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }

    const char *old_password = json_string_value(json_object_get(root, "old_password"));
    const char *new_password = json_string_value(json_object_get(root, "new_password"));

    if (!old_password || !new_password) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Invalid request");
    }

    if (strlen(new_password) < 8) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Password too short");
    }

    pthread_mutex_lock(&users_mutex);
    User *user = find_user_by_id(user_id);
    if (!user || strcmp(user->password, old_password) != 0) {
        pthread_mutex_unlock(&users_mutex);
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_UNAUTHORIZED, "Invalid credentials");
    }

    strncpy(user->password, new_password, sizeof(user->password) - 1);
    pthread_mutex_unlock(&users_mutex);

    json_decref(root);
    return send_json_response(connection, MHD_HTTP_OK, "{}");
}

enum MHD_Result handle_get_todos(struct MHD_Connection *connection) {
    int user_id;
    if (check_auth(connection, &user_id) == MHD_YES) return MHD_YES;

    json_t *arr = json_array();
    pthread_mutex_lock(&todos_mutex);
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id == user_id) {
            json_t *obj = json_object();
            json_object_set_new(obj, "id", json_integer(todos[i].id));
            json_object_set_new(obj, "title", json_string(todos[i].title));
            json_object_set_new(obj, "description", json_string(todos[i].description));
            json_object_set_new(obj, "completed", json_boolean(todos[i].completed));
            json_object_set_new(obj, "created_at", json_string(todos[i].created_at));
            json_object_set_new(obj, "updated_at", json_string(todos[i].updated_at));
            json_array_append_new(arr, obj);
        }
    }
    pthread_mutex_unlock(&todos_mutex);

    char *resp_str = json_dumps(arr, JSON_COMPACT);
    json_decref(arr);
    enum MHD_Result ret = send_json_response(connection, MHD_HTTP_OK, resp_str);
    free(resp_str);
    return ret;
}

enum MHD_Result handle_post_todo(struct MHD_Connection *connection, const char *body) {
    int user_id;
    if (check_auth(connection, &user_id) == MHD_YES) return MHD_YES;

    json_error_t error;
    json_t *root = json_loads(body, 0, &error);
    if (!root) {
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }

    const char *title = json_string_value(json_object_get(root, "title"));
    const char *description = json_string_value(json_object_get(root, "description"));

    if (!title || strlen(title) == 0) {
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
    }

    if (!description) {
        description = "";
    }

    pthread_mutex_lock(&todos_mutex);
    if (todo_count >= MAX_TODOS) {
        pthread_mutex_unlock(&todos_mutex);
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_INTERNAL_SERVER_ERROR, "Server full");
    }

    Todo *new_todo = &todos[todo_count++];
    new_todo->id = next_todo_id++;
    new_todo->user_id = user_id;
    strncpy(new_todo->title, title, sizeof(new_todo->title) - 1);
    strncpy(new_todo->description, description, sizeof(new_todo->description) - 1);
    new_todo->completed = 0;
    get_iso_time(new_todo->created_at, sizeof(new_todo->created_at));
    strcpy(new_todo->updated_at, new_todo->created_at);

    json_t *obj = json_object();
    json_object_set_new(obj, "id", json_integer(new_todo->id));
    json_object_set_new(obj, "title", json_string(new_todo->title));
    json_object_set_new(obj, "description", json_string(new_todo->description));
    json_object_set_new(obj, "completed", json_boolean(new_todo->completed));
    json_object_set_new(obj, "created_at", json_string(new_todo->created_at));
    json_object_set_new(obj, "updated_at", json_string(new_todo->updated_at));

    char *resp_str = json_dumps(obj, JSON_COMPACT);
    json_decref(obj);
    json_decref(root);
    pthread_mutex_unlock(&todos_mutex);

    enum MHD_Result ret = send_json_response(connection, MHD_HTTP_CREATED, resp_str);
    free(resp_str);
    return ret;
}

enum MHD_Result handle_get_todo(struct MHD_Connection *connection, int id) {
    int user_id;
    if (check_auth(connection, &user_id) == MHD_YES) return MHD_YES;

    pthread_mutex_lock(&todos_mutex);
    Todo *todo = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == id) {
            if (todos[i].user_id == user_id) {
                todo = &todos[i];
            }
            break;
        }
    }

    if (!todo) {
        pthread_mutex_unlock(&todos_mutex);
        return send_error_response(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    }

    json_t *obj = json_object();
    json_object_set_new(obj, "id", json_integer(todo->id));
    json_object_set_new(obj, "title", json_string(todo->title));
    json_object_set_new(obj, "description", json_string(todo->description));
    json_object_set_new(obj, "completed", json_boolean(todo->completed));
    json_object_set_new(obj, "created_at", json_string(todo->created_at));
    json_object_set_new(obj, "updated_at", json_string(todo->updated_at));

    char *resp_str = json_dumps(obj, JSON_COMPACT);
    json_decref(obj);
    pthread_mutex_unlock(&todos_mutex);

    enum MHD_Result ret = send_json_response(connection, MHD_HTTP_OK, resp_str);
    free(resp_str);
    return ret;
}

enum MHD_Result handle_put_todo(struct MHD_Connection *connection, int id, const char *body) {
    int user_id;
    if (check_auth(connection, &user_id) == MHD_YES) return MHD_YES;

    json_error_t error;
    json_t *root = json_loads(body, 0, &error);
    if (!root) {
        return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Invalid JSON");
    }

    pthread_mutex_lock(&todos_mutex);
    Todo *todo = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == id) {
            if (todos[i].user_id == user_id) {
                todo = &todos[i];
            }
            break;
        }
    }

    if (!todo) {
        pthread_mutex_unlock(&todos_mutex);
        json_decref(root);
        return send_error_response(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    }

    json_t *j_title = json_object_get(root, "title");
    if (j_title) {
        const char *title = json_string_value(j_title);
        if (!title || strlen(title) == 0) {
            pthread_mutex_unlock(&todos_mutex);
            json_decref(root);
            return send_error_response(connection, MHD_HTTP_BAD_REQUEST, "Title is required");
        }
        strncpy(todo->title, title, sizeof(todo->title) - 1);
    }

    json_t *j_desc = json_object_get(root, "description");
    if (j_desc) {
        const char *desc = json_string_value(j_desc);
        if (desc) {
            strncpy(todo->description, desc, sizeof(todo->description) - 1);
        }
    }

    json_t *j_completed = json_object_get(root, "completed");
    if (j_completed && json_is_boolean(j_completed)) {
        todo->completed = json_is_true(j_completed) ? 1 : 0;
    }

    get_iso_time(todo->updated_at, sizeof(todo->updated_at));

    json_t *obj = json_object();
    json_object_set_new(obj, "id", json_integer(todo->id));
    json_object_set_new(obj, "title", json_string(todo->title));
    json_object_set_new(obj, "description", json_string(todo->description));
    json_object_set_new(obj, "completed", json_boolean(todo->completed));
    json_object_set_new(obj, "created_at", json_string(todo->created_at));
    json_object_set_new(obj, "updated_at", json_string(todo->updated_at));

    char *resp_str = json_dumps(obj, JSON_COMPACT);
    json_decref(obj);
    json_decref(root);
    pthread_mutex_unlock(&todos_mutex);

    enum MHD_Result ret = send_json_response(connection, MHD_HTTP_OK, resp_str);
    free(resp_str);
    return ret;
}

enum MHD_Result handle_delete_todo(struct MHD_Connection *connection, int id) {
    int user_id;
    if (check_auth(connection, &user_id) == MHD_YES) return MHD_YES;

    pthread_mutex_lock(&todos_mutex);
    int found = -1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == id) {
            if (todos[i].user_id == user_id) {
                found = i;
            }
            break;
        }
    }

    if (found == -1) {
        pthread_mutex_unlock(&todos_mutex);
        return send_error_response(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
    }

    for (int i = found; i < todo_count - 1; i++) {
        todos[i] = todos[i + 1];
    }
    todo_count--;
    pthread_mutex_unlock(&todos_mutex);

    struct MHD_Response *response = MHD_create_response_from_buffer(0, "", MHD_RESPMEM_PERSISTENT);
    enum MHD_Result ret = MHD_queue_response(connection, MHD_HTTP_NO_CONTENT, response);
    MHD_destroy_response(response);
    return ret;
}

enum MHD_Result process_request(struct MHD_Connection *connection, const char *method, const char *url, const char *body) {
    if (strcmp(method, "POST") == 0 && strcmp(url, "/register") == 0) {
        return handle_register(connection, body);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/login") == 0) {
        return handle_login(connection, body);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/logout") == 0) {
        return handle_logout(connection);
    } else if (strcmp(method, "GET") == 0 && strcmp(url, "/me") == 0) {
        return handle_me(connection);
    } else if (strcmp(method, "PUT") == 0 && strcmp(url, "/password") == 0) {
        return handle_password(connection, body);
    } else if (strcmp(method, "GET") == 0 && strcmp(url, "/todos") == 0) {
        return handle_get_todos(connection);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/todos") == 0) {
        return handle_post_todo(connection, body);
    } else if (strcmp(method, "GET") == 0 && strncmp(url, "/todos/", 7) == 0) {
        int id = atoi(url + 7);
        if (id <= 0) return send_error_response(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
        return handle_get_todo(connection, id);
    } else if (strcmp(method, "PUT") == 0 && strncmp(url, "/todos/", 7) == 0) {
        int id = atoi(url + 7);
        if (id <= 0) return send_error_response(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
        return handle_put_todo(connection, id, body);
    } else if (strcmp(method, "DELETE") == 0 && strncmp(url, "/todos/", 7) == 0) {
        int id = atoi(url + 7);
        if (id <= 0) return send_error_response(connection, MHD_HTTP_NOT_FOUND, "Todo not found");
        return handle_delete_todo(connection, id);
    } else {
        return send_error_response(connection, MHD_HTTP_NOT_FOUND, "Endpoint not found");
    }
}

enum MHD_Result handle_request(void *cls,
                   struct MHD_Connection *connection,
                   const char *url,
                   const char *method,
                   const char *version,
                   const char *upload_data,
                   size_t *upload_data_size,
                   void **ptr) {
    struct connection_info *con_info = *ptr;

    if (NULL == con_info) {
        con_info = calloc(1, sizeof(struct connection_info));
        *ptr = con_info;
        return MHD_YES;
    }

    if (strcmp(method, "POST") == 0 || strcmp(method, "PUT") == 0) {
        if (*upload_data_size > 0) {
            if (con_info->body_len + *upload_data_size >= con_info->body_size) {
                con_info->body_size = (con_info->body_size == 0) ? 4096 : con_info->body_size * 2;
                con_info->body = realloc(con_info->body, con_info->body_size);
            }
            memcpy(con_info->body + con_info->body_len, upload_data, *upload_data_size);
            con_info->body_len += *upload_data_size;
            *upload_data_size = 0;
            return MHD_YES;
        }
    }

    if (con_info->body) {
        if (con_info->body_len + 1 > con_info->body_size) {
            con_info->body = realloc(con_info->body, con_info->body_len + 1);
        }
        con_info->body[con_info->body_len] = '\0';
    } else {
        con_info->body = strdup("");
        con_info->body_len = 0;
    }

    enum MHD_Result ret = process_request(connection, method, url, con_info->body);

    free(con_info->body);
    free(con_info);
    *ptr = NULL;
    return ret;
}

int main(int argc, char **argv) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
            i++;
        }
    }

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_SELECT_INTERNALLY,
                                                 port,
                                                 NULL, NULL,
                                                 &handle_request, NULL,
                                                 MHD_OPTION_END);
    if (NULL == daemon) {
        fprintf(stderr, "Failed to start daemon\n");
        return 1;
    }

    fprintf(stderr, "Server running on port %d\n", port);
    
    while (1) {
        sleep(1);
    }

    MHD_stop_daemon(daemon);
    return 0;
}
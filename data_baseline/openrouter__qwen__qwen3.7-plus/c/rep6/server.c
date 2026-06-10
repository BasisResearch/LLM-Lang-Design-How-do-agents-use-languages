#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <pthread.h>
#include <microhttpd.h>
#include <jansson.h>

pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

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
    int active;
} Todo;

typedef struct {
    char token[64];
    int user_id;
} Session;

User users[1000];
int user_count = 0;
int next_user_id = 1;

Todo todos[10000];
int next_todo_id = 1;

Session sessions[10000];

void get_current_time_iso(char *buffer, size_t size) {
    time_t now = time(NULL);
    struct tm utc;
    gmtime_r(&now, &utc);
    strftime(buffer, size, "%Y-%m-%dT%H:%M:%SZ", &utc);
}

void generate_token(char *token) {
    unsigned char bytes[16];
    FILE *f = fopen("/dev/urandom", "r");
    if (f) {
        fread(bytes, 1, 16, f);
        fclose(f);
    } else {
        memset(bytes, 0, 16);
    }
    for (int i = 0; i < 16; i++) {
        sprintf(&token[i*2], "%02x", bytes[i]);
    }
}

int is_valid_username(const char *username) {
    if (!username) return 0;
    size_t len = strlen(username);
    if (len < 3 || len > 50) return 0;
    for (size_t i = 0; i < len; i++) {
        if (!isalnum((unsigned char)username[i]) && username[i] != '_') {
            return 0;
        }
    }
    return 1;
}

int get_user_from_session(const char *cookie) {
    if (!cookie) return -1;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < 10000; i++) {
        if (sessions[i].token[0] != '\0' && strcmp(sessions[i].token, cookie) == 0) {
            int uid = sessions[i].user_id;
            pthread_mutex_unlock(&lock);
            return uid;
        }
    }
    pthread_mutex_unlock(&lock);
    return -1;
}

void send_json_response(struct MHD_Connection *connection, int status_code, json_t *root, const char *cookie_header) {
    char *json_str = json_dumps(root, JSON_COMPACT);
    struct MHD_Response *response = MHD_create_response_from_buffer(strlen(json_str), json_str, MHD_RESPMEM_MUST_FREE);
    MHD_add_response_header(response, "Content-Type", "application/json");
    if (cookie_header) {
        MHD_add_response_header(response, "Set-Cookie", cookie_header);
    }
    MHD_queue_response(connection, status_code, response);
    MHD_destroy_response(response);
}

void send_error(struct MHD_Connection *connection, int status_code, const char *error_msg, const char *cookie_header) {
    json_t *root = json_object();
    json_object_set_new(root, "error", json_string(error_msg));
    send_json_response(connection, status_code, root, cookie_header);
}

struct connection_info_struct {
    char *post_data;
    size_t post_data_len;
};

static void request_completed(void *cls, struct MHD_Connection *connection, void **ptr, enum MHD_RequestTerminationCode toe) {
    struct connection_info_struct *con_info = *ptr;
    if (con_info) {
        free(con_info->post_data);
        free(con_info);
    }
    *ptr = NULL;
}

int parse_todos_id(const char *url, int *id) {
    if (strncmp(url, "/todos/", 7) != 0) return 0;
    const char *id_str = url + 7;
    char *endptr;
    long val = strtol(id_str, &endptr, 10);
    if (endptr == id_str || *endptr != '\0') return 0;
    if (val <= 0 || val > 2147483647) return 0;
    *id = (int)val;
    return 1;
}

static enum MHD_Result
answer_to_connection(void *cls, struct MHD_Connection *connection,
                     const char *url, const char *method,
                     const char *version, const char *upload_data,
                     size_t *upload_data_size, void **ptr)
{
    struct connection_info_struct *con_info = *ptr;

    if (NULL == con_info) {
        con_info = malloc(sizeof(struct connection_info_struct));
        if (NULL == con_info) return MHD_NO;
        con_info->post_data = NULL;
        con_info->post_data_len = 0;
        *ptr = con_info;
        return MHD_YES;
    }

    if (strcmp(method, "POST") == 0 || strcmp(method, "PUT") == 0) {
        if (*upload_data_size > 0) {
            con_info->post_data = realloc(con_info->post_data, con_info->post_data_len + *upload_data_size + 1);
            if (!con_info->post_data) return MHD_NO;
            memcpy(con_info->post_data + con_info->post_data_len, upload_data, *upload_data_size);
            con_info->post_data_len += *upload_data_size;
            con_info->post_data[con_info->post_data_len] = '\0';
            *upload_data_size = 0;
            return MHD_YES;
        }
    }

    const char *cookie = MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");

    if (strcmp(url, "/register") == 0 && strcmp(method, "POST") == 0) {
        if (!con_info->post_data || con_info->post_data_len == 0) {
            send_error(connection, 400, "Invalid request", NULL);
            return MHD_YES;
        }
        json_t *req = json_loads(con_info->post_data, 0, NULL);
        if (!req) {
            send_error(connection, 400, "Invalid JSON", NULL);
            return MHD_YES;
        }
        const char *username = json_string_value(json_object_get(req, "username"));
        const char *password = json_string_value(json_object_get(req, "password"));

        if (!is_valid_username(username)) {
            json_decref(req);
            send_error(connection, 400, "Invalid username", NULL);
            return MHD_YES;
        }
        if (!password || strlen(password) < 8) {
            json_decref(req);
            send_error(connection, 400, "Password too short", NULL);
            return MHD_YES;
        }

        pthread_mutex_lock(&lock);
        for (int i = 0; i < user_count; i++) {
            if (strcmp(users[i].username, username) == 0) {
                pthread_mutex_unlock(&lock);
                json_decref(req);
                send_error(connection, 409, "Username already exists", NULL);
                return MHD_YES;
            }
        }
        users[user_count].id = next_user_id++;
        strncpy(users[user_count].username, username, 63);
        users[user_count].username[63] = '\0';
        strncpy(users[user_count].password, password, 255);
        users[user_count].password[255] = '\0';
        int new_id = users[user_count].id;
        user_count++;
        pthread_mutex_unlock(&lock);

        json_t *resp = json_object();
        json_object_set_new(resp, "id", json_integer(new_id));
        json_object_set_new(resp, "username", json_string(username));
        send_json_response(connection, 201, resp, NULL);
        json_decref(resp);
        json_decref(req);
        return MHD_YES;
    }

    if (strcmp(url, "/login") == 0 && strcmp(method, "POST") == 0) {
        if (!con_info->post_data || con_info->post_data_len == 0) {
            send_error(connection, 400, "Invalid request", NULL);
            return MHD_YES;
        }
        json_t *req = json_loads(con_info->post_data, 0, NULL);
        if (!req) {
            send_error(connection, 400, "Invalid JSON", NULL);
            return MHD_YES;
        }
        const char *username = json_string_value(json_object_get(req, "username"));
        const char *password = json_string_value(json_object_get(req, "password"));

        pthread_mutex_lock(&lock);
        int user_id = -1;
        char found_username[64] = "";
        for (int i = 0; i < user_count; i++) {
            if (strcmp(users[i].username, username) == 0 && strcmp(users[i].password, password) == 0) {
                user_id = users[i].id;
                strncpy(found_username, users[i].username, 63);
                break;
            }
        }
        pthread_mutex_unlock(&lock);

        if (user_id == -1) {
            json_decref(req);
            send_error(connection, 401, "Invalid credentials", NULL);
            return MHD_YES;
        }

        pthread_mutex_lock(&lock);
        int sess_idx = -1;
        for (int i = 0; i < 10000; i++) {
            if (sessions[i].token[0] == '\0') {
                sess_idx = i;
                break;
            }
        }
        if (sess_idx == -1) {
            pthread_mutex_unlock(&lock);
            json_decref(req);
            send_error(connection, 500, "Session limit reached", NULL);
            return MHD_YES;
        }
        generate_token(sessions[sess_idx].token);
        sessions[sess_idx].user_id = user_id;
        char token_copy[64];
        strcpy(token_copy, sessions[sess_idx].token);
        pthread_mutex_unlock(&lock);

        char cookie_header[256];
        snprintf(cookie_header, sizeof(cookie_header), "session_id=%s; Path=/; HttpOnly", token_copy);

        json_t *resp = json_object();
        json_object_set_new(resp, "id", json_integer(user_id));
        json_object_set_new(resp, "username", json_string(found_username));
        send_json_response(connection, 200, resp, cookie_header);
        json_decref(resp);
        json_decref(req);
        return MHD_YES;
    }

    int user_id = get_user_from_session(cookie);
    if (user_id == -1 && (strcmp(url, "/logout") == 0 || strcmp(url, "/me") == 0 || strcmp(url, "/password") == 0 ||
                          strncmp(url, "/todos", 6) == 0)) {
        send_error(connection, 401, "Authentication required", NULL);
        return MHD_YES;
    }

    if (strcmp(url, "/logout") == 0 && strcmp(method, "POST") == 0) {
        pthread_mutex_lock(&lock);
        for (int i = 0; i < 10000; i++) {
            if (sessions[i].token[0] != '\0' && strcmp(sessions[i].token, cookie) == 0) {
                sessions[i].token[0] = '\0';
                break;
            }
        }
        pthread_mutex_unlock(&lock);
        json_t *resp = json_object();
        send_json_response(connection, 200, resp, NULL);
        json_decref(resp);
        return MHD_YES;
    }

    if (strcmp(url, "/me") == 0 && strcmp(method, "GET") == 0) {
        pthread_mutex_lock(&lock);
        char username[64] = "";
        for (int i = 0; i < user_count; i++) {
            if (users[i].id == user_id) {
                strncpy(username, users[i].username, 63);
                break;
            }
        }
        pthread_mutex_unlock(&lock);
        json_t *resp = json_object();
        json_object_set_new(resp, "id", json_integer(user_id));
        json_object_set_new(resp, "username", json_string(username));
        send_json_response(connection, 200, resp, NULL);
        json_decref(resp);
        return MHD_YES;
    }

    if (strcmp(url, "/password") == 0 && strcmp(method, "PUT") == 0) {
        if (!con_info->post_data || con_info->post_data_len == 0) {
            send_error(connection, 400, "Invalid request", NULL);
            return MHD_YES;
        }
        json_t *req = json_loads(con_info->post_data, 0, NULL);
        if (!req) {
            send_error(connection, 400, "Invalid JSON", NULL);
            return MHD_YES;
        }
        const char *old_password = json_string_value(json_object_get(req, "old_password"));
        const char *new_password = json_string_value(json_object_get(req, "new_password"));

        pthread_mutex_lock(&lock);
        int user_idx = -1;
        for (int i = 0; i < user_count; i++) {
            if (users[i].id == user_id) {
                user_idx = i;
                break;
            }
        }
        if (user_idx == -1 || strcmp(users[user_idx].password, old_password) != 0) {
            pthread_mutex_unlock(&lock);
            json_decref(req);
            send_error(connection, 401, "Invalid credentials", NULL);
            return MHD_YES;
        }
        if (!new_password || strlen(new_password) < 8) {
            pthread_mutex_unlock(&lock);
            json_decref(req);
            send_error(connection, 400, "Password too short", NULL);
            return MHD_YES;
        }
        strncpy(users[user_idx].password, new_password, 255);
        users[user_idx].password[255] = '\0';
        pthread_mutex_unlock(&lock);

        json_t *resp = json_object();
        send_json_response(connection, 200, resp, NULL);
        json_decref(resp);
        json_decref(req);
        return MHD_YES;
    }

    if (strcmp(url, "/todos") == 0 && strcmp(method, "GET") == 0) {
        json_t *resp = json_array();
        pthread_mutex_lock(&lock);
        for (int i = 0; i < 10000; i++) {
            if (todos[i].active == 1 && todos[i].user_id == user_id) {
                json_t *todo = json_object();
                json_object_set_new(todo, "id", json_integer(todos[i].id));
                json_object_set_new(todo, "title", json_string(todos[i].title));
                json_object_set_new(todo, "description", json_string(todos[i].description));
                json_object_set_new(todo, "completed", todos[i].completed ? json_true() : json_false());
                json_object_set_new(todo, "created_at", json_string(todos[i].created_at));
                json_object_set_new(todo, "updated_at", json_string(todos[i].updated_at));
                json_array_append_new(resp, todo);
            }
        }
        pthread_mutex_unlock(&lock);
        send_json_response(connection, 200, resp, NULL);
        json_decref(resp);
        return MHD_YES;
    }

    if (strcmp(url, "/todos") == 0 && strcmp(method, "POST") == 0) {
        if (!con_info->post_data || con_info->post_data_len == 0) {
            send_error(connection, 400, "Invalid request", NULL);
            return MHD_YES;
        }
        json_t *req = json_loads(con_info->post_data, 0, NULL);
        if (!req) {
            send_error(connection, 400, "Invalid JSON", NULL);
            return MHD_YES;
        }
        const char *title = json_string_value(json_object_get(req, "title"));
        const char *description = "";
        json_t *desc_node = json_object_get(req, "description");
        if (desc_node) {
            const char *tmp = json_string_value(desc_node);
            if (tmp) description = tmp;
        }

        if (!title || strlen(title) == 0) {
            json_decref(req);
            send_error(connection, 400, "Title is required", NULL);
            return MHD_YES;
        }

        pthread_mutex_lock(&lock);
        int todo_idx = -1;
        for (int i = 0; i < 10000; i++) {
            if (todos[i].active == 0) {
                todo_idx = i;
                break;
            }
        }
        if (todo_idx == -1) {
            pthread_mutex_unlock(&lock);
            json_decref(req);
            send_error(connection, 500, "Todo limit reached", NULL);
            return MHD_YES;
        }
        
        todos[todo_idx].id = next_todo_id++;
        todos[todo_idx].user_id = user_id;
        strncpy(todos[todo_idx].title, title, 255);
        todos[todo_idx].title[255] = '\0';
        strncpy(todos[todo_idx].description, description, 1023);
        todos[todo_idx].description[1023] = '\0';
        todos[todo_idx].completed = 0;
        get_current_time_iso(todos[todo_idx].created_at, 32);
        get_current_time_iso(todos[todo_idx].updated_at, 32);
        todos[todo_idx].active = 1;
        
        json_t *resp = json_object();
        json_object_set_new(resp, "id", json_integer(todos[todo_idx].id));
        json_object_set_new(resp, "title", json_string(todos[todo_idx].title));
        json_object_set_new(resp, "description", json_string(todos[todo_idx].description));
        json_object_set_new(resp, "completed", json_false());
        json_object_set_new(resp, "created_at", json_string(todos[todo_idx].created_at));
        json_object_set_new(resp, "updated_at", json_string(todos[todo_idx].updated_at));
        
        pthread_mutex_unlock(&lock);

        send_json_response(connection, 201, resp, NULL);
        json_decref(resp);
        json_decref(req);
        return MHD_YES;
    }

    int todo_id = 0;
    if (parse_todos_id(url, &todo_id)) {
        if (strcmp(method, "GET") == 0) {
            pthread_mutex_lock(&lock);
            int found = 0;
            json_t *resp = NULL;
            for (int i = 0; i < 10000; i++) {
                if (todos[i].active == 1 && todos[i].id == todo_id && todos[i].user_id == user_id) {
                    found = 1;
                    resp = json_object();
                    json_object_set_new(resp, "id", json_integer(todos[i].id));
                    json_object_set_new(resp, "title", json_string(todos[i].title));
                    json_object_set_new(resp, "description", json_string(todos[i].description));
                    json_object_set_new(resp, "completed", todos[i].completed ? json_true() : json_false());
                    json_object_set_new(resp, "created_at", json_string(todos[i].created_at));
                    json_object_set_new(resp, "updated_at", json_string(todos[i].updated_at));
                    break;
                }
            }
            pthread_mutex_unlock(&lock);
            if (!found) {
                send_error(connection, 404, "Todo not found", NULL);
            } else {
                send_json_response(connection, 200, resp, NULL);
                json_decref(resp);
            }
            return MHD_YES;
        }

        if (strcmp(method, "PUT") == 0) {
            if (!con_info->post_data || con_info->post_data_len == 0) {
                send_error(connection, 400, "Invalid request", NULL);
                return MHD_YES;
            }
            json_t *req = json_loads(con_info->post_data, 0, NULL);
            if (!req) {
                send_error(connection, 400, "Invalid JSON", NULL);
                return MHD_YES;
            }

            pthread_mutex_lock(&lock);
            int found = 0;
            int todo_idx = -1;
            for (int i = 0; i < 10000; i++) {
                if (todos[i].active == 1 && todos[i].id == todo_id && todos[i].user_id == user_id) {
                    found = 1;
                    todo_idx = i;
                    break;
                }
            }

            if (!found) {
                pthread_mutex_unlock(&lock);
                json_decref(req);
                send_error(connection, 404, "Todo not found", NULL);
                return MHD_YES;
            }

            const char *title = json_string_value(json_object_get(req, "title"));
            if (json_object_get(req, "title") != NULL) {
                if (!title || strlen(title) == 0) {
                    pthread_mutex_unlock(&lock);
                    json_decref(req);
                    send_error(connection, 400, "Title is required", NULL);
                    return MHD_YES;
                }
                strncpy(todos[todo_idx].title, title, 255);
                todos[todo_idx].title[255] = '\0';
            }

            json_t *desc_node = json_object_get(req, "description");
            if (desc_node != NULL) {
                const char *description = json_string_value(desc_node);
                if (description) {
                    strncpy(todos[todo_idx].description, description, 1023);
                    todos[todo_idx].description[1023] = '\0';
                } else {
                    todos[todo_idx].description[0] = '\0';
                }
            }

            json_t *completed_val = json_object_get(req, "completed");
            if (completed_val != NULL) {
                todos[todo_idx].completed = json_is_true(completed_val) ? 1 : 0;
            }

            get_current_time_iso(todos[todo_idx].updated_at, 32);

            json_t *resp = json_object();
            json_object_set_new(resp, "id", json_integer(todos[todo_idx].id));
            json_object_set_new(resp, "title", json_string(todos[todo_idx].title));
            json_object_set_new(resp, "description", json_string(todos[todo_idx].description));
            json_object_set_new(resp, "completed", todos[todo_idx].completed ? json_true() : json_false());
            json_object_set_new(resp, "created_at", json_string(todos[todo_idx].created_at));
            json_object_set_new(resp, "updated_at", json_string(todos[todo_idx].updated_at));
            pthread_mutex_unlock(&lock);

            send_json_response(connection, 200, resp, NULL);
            json_decref(resp);
            json_decref(req);
            return MHD_YES;
        }

        if (strcmp(method, "DELETE") == 0) {
            pthread_mutex_lock(&lock);
            int found = 0;
            for (int i = 0; i < 10000; i++) {
                if (todos[i].active == 1 && todos[i].id == todo_id && todos[i].user_id == user_id) {
                    todos[i].active = 0;
                    found = 1;
                    break;
                }
            }
            pthread_mutex_unlock(&lock);

            if (!found) {
                send_error(connection, 404, "Todo not found", NULL);
            } else {
                struct MHD_Response *response = MHD_create_response_from_buffer(0, "", MHD_RESPMEM_PERSISTENT);
                MHD_queue_response(connection, 204, response);
                MHD_destroy_response(response);
            }
            return MHD_YES;
        }
    }

    send_error(connection, 404, "Not found", NULL);
    return MHD_YES;
}

int main(int argc, char **argv) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        }
    }

    for (int i = 0; i < 10000; i++) {
        sessions[i].token[0] = '\0';
        todos[i].active = 0;
    }

    struct MHD_Daemon *daemon = MHD_start_daemon(MHD_USE_INTERNAL_POLLING_THREAD | MHD_USE_ERROR_LOG, port, NULL, NULL,
                                                 &answer_to_connection, NULL,
                                                 MHD_OPTION_NOTIFY_COMPLETED, request_completed, NULL,
                                                 MHD_OPTION_END);
    if (NULL == daemon) {
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
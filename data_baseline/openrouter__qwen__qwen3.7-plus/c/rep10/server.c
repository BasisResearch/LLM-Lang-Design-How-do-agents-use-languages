#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <pthread.h>
#include <ctype.h>
#include <microhttpd.h>
#include <jansson.h>

#define MAX_USERS 10000
#define MAX_SESSIONS 10000
#define MAX_TODOS 100000

typedef struct {
    int id;
    char username[64];
    char password[256];
    int active;
} User;

typedef struct {
    int id;
    char token[64];
    int user_id;
    int active;
} Session;

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

User users[MAX_USERS];
int next_user_id = 1;

Session sessions[MAX_SESSIONS];
int next_session_id = 1;

Todo todos[MAX_TODOS];
int next_todo_id = 1;

pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

struct ConnectionData {
    char *body;
    size_t body_size;
    size_t body_capacity;
};

void generate_uuid(char *out) {
    unsigned char buf[16];
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        read(fd, buf, 16);
        close(fd);
    } else {
        srand(time(NULL) ^ getpid());
        for(int i=0; i<16; i++) buf[i] = rand();
    }
    snprintf(out, 64, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        buf[0], buf[1], buf[2], buf[3],
        buf[4], buf[5], buf[6], buf[7],
        buf[8], buf[9], buf[10], buf[11],
        buf[12], buf[13], buf[14], buf[15]);
}

void get_current_timestamp(char *out) {
    time_t now = time(NULL);
    struct tm *tm = gmtime(&now);
    strftime(out, 32, "%Y-%m-%dT%H:%M:%SZ", tm);
}

const char* get_string(json_t *obj, const char *key) {
    json_t *val = json_object_get(obj, key);
    if (val && json_is_string(val)) {
        return json_string_value(val);
    }
    return NULL;
}

int has_key(json_t *obj, const char *key) {
    return json_object_get(obj, key) != NULL;
}

int get_bool(json_t *obj, const char *key, int *out) {
    json_t *val = json_object_get(obj, key);
    if (val && json_is_boolean(val)) {
        *out = json_is_true(val) ? 1 : 0;
        return 1;
    }
    return 0;
}

int check_auth(struct MHD_Connection *connection, int *user_idx) {
    const char *cookie = MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");
    if (!cookie) return 0;
    
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].active && strcmp(sessions[i].token, cookie) == 0) {
            int u_id = sessions[i].user_id;
            for (int j = 0; j < MAX_USERS; j++) {
                if (users[j].active && users[j].id == u_id) {
                    *user_idx = j;
                    pthread_mutex_unlock(&lock);
                    return 1;
                }
            }
        }
    }
    pthread_mutex_unlock(&lock);
    return 0;
}

int send_json_response(struct MHD_Connection *connection, int status_code, const char *json_str, const char *cookie) {
    struct MHD_Response *response;
    int ret;
    if (json_str) {
        response = MHD_create_response_from_buffer(strlen(json_str), (void *)json_str, MHD_RESPMEM_MUST_COPY);
        MHD_add_response_header(response, "Content-Type", "application/json");
    } else {
        response = MHD_create_response_from_buffer(0, "", MHD_RESPMEM_PERSISTENT);
    }
    if (cookie) {
        MHD_add_response_header(response, "Set-Cookie", cookie);
    }
    ret = MHD_queue_response(connection, status_code, response);
    MHD_destroy_response(response);
    return ret;
}

int is_todos_id_route(const char *url, int *id) {
    if (strncmp(url, "/todos/", 7) != 0) return 0;
    const char *p = url + 7;
    if (*p == '\0') return 0;
    int len = 0;
    while (*p >= '0' && *p <= '9') {
        len++;
        p++;
    }
    if (len == 0) return 0;
    if (*p != '\0' && *p != '?') return 0;
    *id = atoi(url + 7);
    return 1;
}

enum MHD_Result handle_request(void *cls, struct MHD_Connection *connection,
                   const char *url, const char *method,
                   const char *version, const char *upload_data,
                   size_t *upload_data_size, void **con_cls) {
    struct ConnectionData *cdata = *con_cls;
    if (!cdata) {
        cdata = calloc(1, sizeof(struct ConnectionData));
        *con_cls = cdata;
        return MHD_YES;
    }

    if (*upload_data_size > 0) {
        if (cdata->body_size + *upload_data_size + 1 > cdata->body_capacity) {
            cdata->body_capacity = cdata->body_size + *upload_data_size + 1024;
            cdata->body = realloc(cdata->body, cdata->body_capacity);
        }
        memcpy(cdata->body + cdata->body_size, upload_data, *upload_data_size);
        cdata->body_size += *upload_data_size;
        cdata->body[cdata->body_size] = '\0';
        *upload_data_size = 0;
        return MHD_YES;
    }

    json_error_t error;
    
    if (strcmp(method, "POST") == 0) {
        if (strcmp(url, "/register") == 0) {
            json_t *req = json_loads(cdata->body ? cdata->body : "{}", 0, &error);
            if (!req) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}", NULL);
            }
            const char *username = get_string(req, "username");
            const char *password = get_string(req, "password");
            
            if (!username || strlen(username) < 3 || strlen(username) > 50) {
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 400, "{\"error\": \"Invalid username\"}", NULL);
            }
            for (size_t i = 0; username[i]; i++) {
                if (!isalnum((unsigned char)username[i]) && username[i] != '_') {
                    json_decref(req);
                    free(cdata->body); free(cdata); *con_cls = NULL;
                    return send_json_response(connection, 400, "{\"error\": \"Invalid username\"}", NULL);
                }
            }
            if (!password || strlen(password) < 8) {
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 400, "{\"error\": \"Password too short\"}", NULL);
            }
            
            pthread_mutex_lock(&lock);
            for (int i = 0; i < MAX_USERS; i++) {
                if (users[i].active && strcmp(users[i].username, username) == 0) {
                    pthread_mutex_unlock(&lock);
                    json_decref(req);
                    free(cdata->body); free(cdata); *con_cls = NULL;
                    return send_json_response(connection, 409, "{\"error\": \"Username already exists\"}", NULL);
                }
            }
            
            int slot = -1;
            for (int i = 0; i < MAX_USERS; i++) {
                if (!users[i].active) {
                    slot = i;
                    break;
                }
            }
            if (slot == -1) {
                pthread_mutex_unlock(&lock);
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 500, "{\"error\": \"Server full\"}", NULL);
            }
            
            strncpy(users[slot].username, username, sizeof(users[slot].username) - 1);
            strncpy(users[slot].password, password, sizeof(users[slot].password) - 1);
            users[slot].id = next_user_id++;
            users[slot].active = 1;
            
            char resp[256];
            snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", users[slot].id, users[slot].username);
            pthread_mutex_unlock(&lock);
            json_decref(req);
            free(cdata->body); free(cdata); *con_cls = NULL;
            return send_json_response(connection, 201, resp, NULL);
        }
        
        if (strcmp(url, "/login") == 0) {
            json_t *req = json_loads(cdata->body ? cdata->body : "{}", 0, &error);
            if (!req) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}", NULL);
            }
            const char *username = get_string(req, "username");
            const char *password = get_string(req, "password");
            
            int found_user = -1;
            pthread_mutex_lock(&lock);
            for (int i = 0; i < MAX_USERS; i++) {
                if (users[i].active && strcmp(users[i].username, username) == 0 && strcmp(users[i].password, password) == 0) {
                    found_user = i;
                    break;
                }
            }
            
            if (found_user == -1) {
                pthread_mutex_unlock(&lock);
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Invalid credentials\"}", NULL);
            }
            
            int slot = -1;
            for (int i = 0; i < MAX_SESSIONS; i++) {
                if (!sessions[i].active) {
                    slot = i;
                    break;
                }
            }
            if (slot == -1) {
                pthread_mutex_unlock(&lock);
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 500, "{\"error\": \"Server full\"}", NULL);
            }
            
            generate_uuid(sessions[slot].token);
            sessions[slot].user_id = users[found_user].id;
            sessions[slot].active = 1;
            
            char cookie_header[256];
            snprintf(cookie_header, sizeof(cookie_header), "session_id=%s; Path=/; HttpOnly", sessions[slot].token);
            
            char resp[256];
            snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", users[found_user].id, users[found_user].username);
            
            pthread_mutex_unlock(&lock);
            json_decref(req);
            free(cdata->body); free(cdata); *con_cls = NULL;
            return send_json_response(connection, 200, resp, cookie_header);
        }

        if (strcmp(url, "/logout") == 0) {
            int user_idx;
            if (!check_auth(connection, &user_idx)) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}", NULL);
            }
            const char *cookie = MHD_lookup_connection_value(connection, MHD_COOKIE_KIND, "session_id");
            pthread_mutex_lock(&lock);
            for (int i = 0; i < MAX_SESSIONS; i++) {
                if (sessions[i].active && strcmp(sessions[i].token, cookie) == 0) {
                    sessions[i].active = 0;
                    break;
                }
            }
            pthread_mutex_unlock(&lock);
            free(cdata->body); free(cdata); *con_cls = NULL;
            return send_json_response(connection, 200, "{}", NULL);
        }

        if (strcmp(url, "/todos") == 0) {
            int user_idx;
            if (!check_auth(connection, &user_idx)) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}", NULL);
            }
            
            json_t *req = json_loads(cdata->body ? cdata->body : "{}", 0, &error);
            if (!req) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}", NULL);
            }
            
            const char *title = get_string(req, "title");
            if (!title || strlen(title) == 0) {
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 400, "{\"error\": \"Title is required\"}", NULL);
            }
            
            const char *description = get_string(req, "description");
            if (!description) description = "";
            
            int slot = -1;
            pthread_mutex_lock(&lock);
            for (int i = 0; i < MAX_TODOS; i++) {
                if (!todos[i].active) {
                    slot = i;
                    break;
                }
            }
            if (slot == -1) {
                pthread_mutex_unlock(&lock);
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 500, "{\"error\": \"Server full\"}", NULL);
            }
            
            todos[slot].id = next_todo_id++;
            todos[slot].user_id = users[user_idx].id;
            strncpy(todos[slot].title, title, sizeof(todos[slot].title) - 1);
            strncpy(todos[slot].description, description, sizeof(todos[slot].description) - 1);
            todos[slot].completed = 0;
            get_current_timestamp(todos[slot].created_at);
            get_current_timestamp(todos[slot].updated_at);
            todos[slot].active = 1;
            
            json_t *resp_obj = json_object();
            json_object_set_new(resp_obj, "id", json_integer(todos[slot].id));
            json_object_set_new(resp_obj, "title", json_string(todos[slot].title));
            json_object_set_new(resp_obj, "description", json_string(todos[slot].description));
            json_object_set_new(resp_obj, "completed", json_false());
            json_object_set_new(resp_obj, "created_at", json_string(todos[slot].created_at));
            json_object_set_new(resp_obj, "updated_at", json_string(todos[slot].updated_at));
            
            char *resp = json_dumps(resp_obj, JSON_COMPACT);
            json_decref(resp_obj);
            pthread_mutex_unlock(&lock);
            json_decref(req);
            free(cdata->body); free(cdata); *con_cls = NULL;
            
            int ret = send_json_response(connection, 201, resp, NULL);
            free(resp);
            return ret;
        }
    }
    
    if (strcmp(method, "GET") == 0) {
        if (strcmp(url, "/me") == 0) {
            int user_idx;
            if (!check_auth(connection, &user_idx)) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}", NULL);
            }
            char resp[256];
            snprintf(resp, sizeof(resp), "{\"id\": %d, \"username\": \"%s\"}", users[user_idx].id, users[user_idx].username);
            free(cdata->body); free(cdata); *con_cls = NULL;
            return send_json_response(connection, 200, resp, NULL);
        }
        
        if (strcmp(url, "/todos") == 0) {
            int user_idx;
            if (!check_auth(connection, &user_idx)) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}", NULL);
            }
            
            json_t *arr = json_array();
            pthread_mutex_lock(&lock);
            int u_id = users[user_idx].id;
            for (int i = 0; i < MAX_TODOS; i++) {
                if (todos[i].active && todos[i].user_id == u_id) {
                    json_t *obj = json_object();
                    json_object_set_new(obj, "id", json_integer(todos[i].id));
                    json_object_set_new(obj, "title", json_string(todos[i].title));
                    json_object_set_new(obj, "description", json_string(todos[i].description));
                    json_object_set_new(obj, "completed", todos[i].completed ? json_true() : json_false());
                    json_object_set_new(obj, "created_at", json_string(todos[i].created_at));
                    json_object_set_new(obj, "updated_at", json_string(todos[i].updated_at));
                    json_array_append_new(arr, obj);
                }
            }
            pthread_mutex_unlock(&lock);
            
            char *resp = json_dumps(arr, JSON_COMPACT);
            json_decref(arr);
            free(cdata->body); free(cdata); *con_cls = NULL;
            int ret = send_json_response(connection, 200, resp, NULL);
            free(resp);
            return ret;
        }
        
        int todo_id;
        if (is_todos_id_route(url, &todo_id)) {
            int user_idx;
            if (!check_auth(connection, &user_idx)) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}", NULL);
            }
            
            pthread_mutex_lock(&lock);
            int found = -1;
            int u_id = users[user_idx].id;
            for (int i = 0; i < MAX_TODOS; i++) {
                if (todos[i].active && todos[i].id == todo_id && todos[i].user_id == u_id) {
                    found = i;
                    break;
                }
            }
            
            if (found == -1) {
                pthread_mutex_unlock(&lock);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 404, "{\"error\": \"Todo not found\"}", NULL);
            }
            
            json_t *resp_obj = json_object();
            json_object_set_new(resp_obj, "id", json_integer(todos[found].id));
            json_object_set_new(resp_obj, "title", json_string(todos[found].title));
            json_object_set_new(resp_obj, "description", json_string(todos[found].description));
            json_object_set_new(resp_obj, "completed", todos[found].completed ? json_true() : json_false());
            json_object_set_new(resp_obj, "created_at", json_string(todos[found].created_at));
            json_object_set_new(resp_obj, "updated_at", json_string(todos[found].updated_at));
            
            char *resp = json_dumps(resp_obj, JSON_COMPACT);
            json_decref(resp_obj);
            pthread_mutex_unlock(&lock);
            free(cdata->body); free(cdata); *con_cls = NULL;
            
            int ret = send_json_response(connection, 200, resp, NULL);
            free(resp);
            return ret;
        }
    }
    
    if (strcmp(method, "PUT") == 0) {
        if (strcmp(url, "/password") == 0) {
            int user_idx;
            if (!check_auth(connection, &user_idx)) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}", NULL);
            }
            json_t *req = json_loads(cdata->body ? cdata->body : "{}", 0, &error);
            if (!req) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}", NULL);
            }
            
            const char *old_password = get_string(req, "old_password");
            const char *new_password = get_string(req, "new_password");
            
            pthread_mutex_lock(&lock);
            if (!old_password || strcmp(users[user_idx].password, old_password) != 0) {
                pthread_mutex_unlock(&lock);
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Invalid credentials\"}", NULL);
            }
            
            if (!new_password || strlen(new_password) < 8) {
                pthread_mutex_unlock(&lock);
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 400, "{\"error\": \"Password too short\"}", NULL);
            }
            
            strncpy(users[user_idx].password, new_password, sizeof(users[user_idx].password) - 1);
            pthread_mutex_unlock(&lock);
            json_decref(req);
            free(cdata->body); free(cdata); *con_cls = NULL;
            return send_json_response(connection, 200, "{}", NULL);
        }
        
        int todo_id;
        if (is_todos_id_route(url, &todo_id)) {
            int user_idx;
            if (!check_auth(connection, &user_idx)) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}", NULL);
            }
            
            json_t *req = json_loads(cdata->body ? cdata->body : "{}", 0, &error);
            if (!req) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 400, "{\"error\": \"Invalid JSON\"}", NULL);
            }
            
            pthread_mutex_lock(&lock);
            int found = -1;
            int u_id = users[user_idx].id;
            for (int i = 0; i < MAX_TODOS; i++) {
                if (todos[i].active && todos[i].id == todo_id && todos[i].user_id == u_id) {
                    found = i;
                    break;
                }
            }
            
            if (found == -1) {
                pthread_mutex_unlock(&lock);
                json_decref(req);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 404, "{\"error\": \"Todo not found\"}", NULL);
            }
            
            const char *title = get_string(req, "title");
            if (has_key(req, "title")) {
                if (!title || strlen(title) == 0) {
                    pthread_mutex_unlock(&lock);
                    json_decref(req);
                    free(cdata->body); free(cdata); *con_cls = NULL;
                    return send_json_response(connection, 400, "{\"error\": \"Title is required\"}", NULL);
                }
                strncpy(todos[found].title, title, sizeof(todos[found].title) - 1);
            }
            
            const char *description = get_string(req, "description");
            if (has_key(req, "description")) {
                strncpy(todos[found].description, description ? description : "", sizeof(todos[found].description) - 1);
            }
            
            int completed;
            if (get_bool(req, "completed", &completed)) {
                todos[found].completed = completed;
            }
            
            get_current_timestamp(todos[found].updated_at);
            
            json_t *resp_obj = json_object();
            json_object_set_new(resp_obj, "id", json_integer(todos[found].id));
            json_object_set_new(resp_obj, "title", json_string(todos[found].title));
            json_object_set_new(resp_obj, "description", json_string(todos[found].description));
            json_object_set_new(resp_obj, "completed", todos[found].completed ? json_true() : json_false());
            json_object_set_new(resp_obj, "created_at", json_string(todos[found].created_at));
            json_object_set_new(resp_obj, "updated_at", json_string(todos[found].updated_at));
            
            char *resp = json_dumps(resp_obj, JSON_COMPACT);
            json_decref(resp_obj);
            pthread_mutex_unlock(&lock);
            json_decref(req);
            free(cdata->body); free(cdata); *con_cls = NULL;
            
            int ret = send_json_response(connection, 200, resp, NULL);
            free(resp);
            return ret;
        }
    }
    
    if (strcmp(method, "DELETE") == 0) {
        int todo_id;
        if (is_todos_id_route(url, &todo_id)) {
            int user_idx;
            if (!check_auth(connection, &user_idx)) {
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 401, "{\"error\": \"Authentication required\"}", NULL);
            }
            
            pthread_mutex_lock(&lock);
            int found = -1;
            int u_id = users[user_idx].id;
            for (int i = 0; i < MAX_TODOS; i++) {
                if (todos[i].active && todos[i].id == todo_id && todos[i].user_id == u_id) {
                    found = i;
                    break;
                }
            }
            
            if (found == -1) {
                pthread_mutex_unlock(&lock);
                free(cdata->body); free(cdata); *con_cls = NULL;
                return send_json_response(connection, 404, "{\"error\": \"Todo not found\"}", NULL);
            }
            
            todos[found].active = 0;
            pthread_mutex_unlock(&lock);
            
            struct MHD_Response *response = MHD_create_response_from_buffer(0, "", MHD_RESPMEM_PERSISTENT);
            int ret = MHD_queue_response(connection, 204, response);
            MHD_destroy_response(response);
            free(cdata->body); free(cdata); *con_cls = NULL;
            return ret;
        }
    }

    free(cdata->body); free(cdata); *con_cls = NULL;
    return send_json_response(connection, 404, "{\"error\": \"Not found\"}", NULL);
}

int main(int argc, char **argv) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        } else if (strncmp(argv[i], "--port=", 7) == 0) {
            port = atoi(argv[i] + 7);
        }
    }
    
    struct MHD_Daemon *daemon = MHD_start_daemon(
        MHD_USE_SELECT_INTERNALLY | MHD_USE_PEDANTIC_CHECKS,
        port,
        NULL,
        NULL,
        &handle_request,
        NULL,
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

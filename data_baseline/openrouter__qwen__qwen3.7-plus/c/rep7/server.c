#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <fcntl.h>
#include <strings.h>
#include <ctype.h>
#include <cjson/cJSON.h>

#define MAX_USERS 10000
#define MAX_SESSIONS 10000
#define MAX_TODOS 100000
#define MAX_HEADERS 50
#define MAX_BODY 16384

typedef struct {
    int id;
    char username[64];
    char password[256];
    int active;
} User;

typedef struct {
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
int user_count = 0;
int next_user_id = 1;

Session sessions[MAX_SESSIONS];
int session_count = 0;

Todo todos[MAX_TODOS];
int todo_count = 0;
int next_todo_id = 1;

typedef struct {
    char method[16];
    char path[512];
    char headers[MAX_HEADERS][2][512];
    int header_count;
    char body[MAX_BODY];
    int body_length;
} Request;

const char* get_header(Request *req, const char *name) {
    for (int i = 0; i < req->header_count; i++) {
        if (strcasecmp(req->headers[i][0], name) == 0) {
            return req->headers[i][1];
        }
    }
    return NULL;
}

int get_cookie(Request *req, const char *name, char *out, size_t out_size) {
    const char *cookie_header = get_header(req, "Cookie");
    if (!cookie_header) return 0;
    
    char *cookie_str = strdup(cookie_header);
    if (!cookie_str) return 0;
    
    char *saveptr;
    char *token = strtok_r(cookie_str, ";", &saveptr);
    int found = 0;
    while (token) {
        while (*token == ' ') token++;
        char *eq = strchr(token, '=');
        if (eq) {
            *eq = '\0';
            char *key = token;
            char *value = eq + 1;
            if (strcmp(key, name) == 0) {
                char *end = value + strlen(value) - 1;
                while (end > value && *end == ' ') {
                    *end = '\0';
                    end--;
                }
                strncpy(out, value, out_size - 1);
                out[out_size - 1] = '\0';
                found = 1;
                break;
            }
        }
        token = strtok_r(NULL, ";", &saveptr);
    }
    free(cookie_str);
    return found;
}

int parse_request(int client_socket, Request *req) {
    memset(req, 0, sizeof(Request));
    char buffer[MAX_BODY];
    int total_read = 0;
    int headers_end = -1;
    
    while (1) {
        int n = recv(client_socket, buffer + total_read, sizeof(buffer) - total_read - 1, 0);
        if (n <= 0) return -1;
        total_read += n;
        buffer[total_read] = '\0';
        
        char *pos = strstr(buffer, "\r\n\r\n");
        if (pos) {
            headers_end = pos - buffer + 4;
            break;
        }
        if (total_read >= sizeof(buffer) - 1) return -1;
    }
    
    char *line_end = strstr(buffer, "\r\n");
    if (!line_end) return -1;
    *line_end = '\0';
    
    char *p = buffer;
    char *token = strtok(p, " ");
    if (!token) return -1;
    strncpy(req->method, token, sizeof(req->method) - 1);
    
    token = strtok(NULL, " ");
    if (!token) return -1;
    strncpy(req->path, token, sizeof(req->path) - 1);
    
    req->header_count = 0;
    p = line_end + 2;
    while (p < buffer + headers_end - 4) {
        line_end = strstr(p, "\r\n");
        if (!line_end) break;
        *line_end = '\0';
        
        char *colon = strchr(p, ':');
        if (colon) {
            *colon = '\0';
            char *key = p;
            char *value = colon + 1;
            while (*value == ' ') value++;
            
            int vlen = strlen(value);
            if (vlen > 0 && value[vlen - 1] == '\r') {
                value[vlen - 1] = '\0';
            }
            
            if (req->header_count < MAX_HEADERS) {
                strncpy(req->headers[req->header_count][0], key, sizeof(req->headers[0][0]) - 1);
                strncpy(req->headers[req->header_count][1], value, sizeof(req->headers[0][1]) - 1);
                req->header_count++;
            }
        }
        p = line_end + 2;
    }
    
    int content_length = 0;
    for (int i = 0; i < req->header_count; i++) {
        if (strcasecmp(req->headers[i][0], "Content-Length") == 0) {
            content_length = atoi(req->headers[i][1]);
            break;
        }
    }
    
    req->body_length = 0;
    int body_in_buffer = total_read - headers_end;
    if (body_in_buffer > 0) {
        int copy_len = body_in_buffer < content_length ? body_in_buffer : content_length;
        if (copy_len > 0) {
            memcpy(req->body, buffer + headers_end, copy_len);
            req->body_length = copy_len;
        }
    }
    
    while (req->body_length < content_length && req->body_length < MAX_BODY - 1) {
        int n = recv(client_socket, req->body + req->body_length, content_length - req->body_length, 0);
        if (n <= 0) break;
        req->body_length += n;
    }
    req->body[req->body_length] = '\0';
    
    return 0;
}

void send_response(int client_socket, int status_code, const char *status_text, const char *body, const char *extra_headers) {
    char header[1024];
    int header_len = 0;
    
    if (body) {
        header_len = snprintf(header, sizeof(header), 
            "HTTP/1.1 %d %s\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: %zu\r\n"
            "%s"
            "\r\n",
            status_code, status_text, strlen(body), extra_headers ? extra_headers : "");
    } else {
        header_len = snprintf(header, sizeof(header), 
            "HTTP/1.1 %d %s\r\n"
            "%s"
            "\r\n",
            status_code, status_text, extra_headers ? extra_headers : "");
    }
    
    send(client_socket, header, header_len, 0);
    if (body) {
        send(client_socket, body, strlen(body), 0);
    }
}

int is_valid_username(const char *username) {
    if (!username) return 0;
    int len = strlen(username);
    if (len < 3 || len > 50) return 0;
    for (int i = 0; i < len; i++) {
        char c = username[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) {
            return 0;
        }
    }
    return 1;
}

int find_user_by_username(const char *username) {
    for (int i = 0; i < MAX_USERS; i++) {
        if (users[i].active && strcmp(users[i].username, username) == 0) {
            return i;
        }
    }
    return -1;
}

int find_user_by_id(int id) {
    for (int i = 0; i < MAX_USERS; i++) {
        if (users[i].active && users[i].id == id) {
            return i;
        }
    }
    return -1;
}

int create_user(const char *username, const char *password) {
    for (int i = 0; i < MAX_USERS; i++) {
        if (!users[i].active) {
            users[i].active = 1;
            users[i].id = next_user_id++;
            strncpy(users[i].username, username, sizeof(users[i].username) - 1);
            users[i].username[sizeof(users[i].username) - 1] = '\0';
            strncpy(users[i].password, password, sizeof(users[i].password) - 1);
            users[i].password[sizeof(users[i].password) - 1] = '\0';
            return users[i].id;
        }
    }
    return -1;
}

int find_session(const char *token) {
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].active && strcmp(sessions[i].token, token) == 0) {
            return sessions[i].user_id;
        }
    }
    return -1;
}

void invalidate_session(const char *token) {
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].active && strcmp(sessions[i].token, token) == 0) {
            sessions[i].active = 0;
            return;
        }
    }
}

int create_session(int user_id, char *out_token) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    unsigned char buf[16];
    if (read(fd, buf, 16) != 16) {
        close(fd);
        return -1;
    }
    close(fd);
    
    for (int i = 0; i < 16; i++) {
        snprintf(out_token + (i * 2), 3, "%02x", buf[i]);
    }
    out_token[32] = '\0';
    
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (!sessions[i].active) {
            sessions[i].active = 1;
            sessions[i].user_id = user_id;
            strncpy(sessions[i].token, out_token, sizeof(sessions[i].token) - 1);
            sessions[i].token[sizeof(sessions[i].token) - 1] = '\0';
            return 0;
        }
    }
    return -1;
}

int find_todo_by_id_and_user(int id, int user_id) {
    for (int i = 0; i < MAX_TODOS; i++) {
        if (todos[i].active && todos[i].id == id && todos[i].user_id == user_id) {
            return i;
        }
    }
    return -1;
}

int find_todo_by_id(int id) {
    for (int i = 0; i < MAX_TODOS; i++) {
        if (todos[i].active && todos[i].id == id) {
            return i;
        }
    }
    return -1;
}

int create_todo(int user_id, const char *title, const char *description) {
    for (int i = 0; i < MAX_TODOS; i++) {
        if (!todos[i].active) {
            todos[i].active = 1;
            todos[i].id = next_todo_id++;
            todos[i].user_id = user_id;
            strncpy(todos[i].title, title, sizeof(todos[i].title) - 1);
            todos[i].title[sizeof(todos[i].title) - 1] = '\0';
            strncpy(todos[i].description, description, sizeof(todos[i].description) - 1);
            todos[i].description[sizeof(todos[i].description) - 1] = '\0';
            todos[i].completed = 0;
            
            time_t t = time(NULL);
            struct tm *tm = gmtime(&t);
            strftime(todos[i].created_at, sizeof(todos[i].created_at), "%Y-%m-%dT%H:%M:%SZ", tm);
            strncpy(todos[i].updated_at, todos[i].created_at, sizeof(todos[i].updated_at));
            
            return todos[i].id;
        }
    }
    return -1;
}

void handle_register(int client_socket, Request *req) {
    cJSON *root = cJSON_Parse(req->body);
    if (!root) {
        send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid JSON\"}", NULL);
        return;
    }
    
    cJSON *username_json = cJSON_GetObjectItem(root, "username");
    cJSON *password_json = cJSON_GetObjectItem(root, "password");
    
    if (!username_json || username_json->type != cJSON_String || !is_valid_username(username_json->valuestring)) {
        send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid username\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    if (!password_json || password_json->type != cJSON_String || strlen(password_json->valuestring) < 8) {
        send_response(client_socket, 400, "Bad Request", "{\"error\": \"Password too short\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    if (find_user_by_username(username_json->valuestring) != -1) {
        send_response(client_socket, 409, "Conflict", "{\"error\": \"Username already exists\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    int user_id = create_user(username_json->valuestring, password_json->valuestring);
    if (user_id == -1) {
        send_response(client_socket, 500, "Internal Server Error", "{\"error\": \"Server full\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", user_id);
    cJSON_AddStringToObject(resp, "username", username_json->valuestring);
    char *resp_str = cJSON_PrintUnformatted(resp);
    send_response(client_socket, 201, "Created", resp_str, NULL);
    free(resp_str);
    cJSON_Delete(resp);
    cJSON_Delete(root);
}

void handle_login(int client_socket, Request *req) {
    cJSON *root = cJSON_Parse(req->body);
    if (!root) {
        send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid JSON\"}", NULL);
        return;
    }
    
    cJSON *username_json = cJSON_GetObjectItem(root, "username");
    cJSON *password_json = cJSON_GetObjectItem(root, "password");
    
    if (!username_json || username_json->type != cJSON_String || !password_json || password_json->type != cJSON_String) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Invalid credentials\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    int user_idx = find_user_by_username(username_json->valuestring);
    if (user_idx == -1 || strcmp(users[user_idx].password, password_json->valuestring) != 0) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Invalid credentials\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    char token[64];
    if (create_session(users[user_idx].id, token) != 0) {
        send_response(client_socket, 500, "Internal Server Error", "{\"error\": \"Server error\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", users[user_idx].id);
    cJSON_AddStringToObject(resp, "username", users[user_idx].username);
    char *resp_str = cJSON_PrintUnformatted(resp);
    
    char extra[256];
    snprintf(extra, sizeof(extra), "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", token);
    
    send_response(client_socket, 200, "OK", resp_str, extra);
    free(resp_str);
    cJSON_Delete(resp);
    cJSON_Delete(root);
}

void handle_logout(int client_socket, Request *req) {
    char token[64];
    if (!get_cookie(req, "session_id", token, sizeof(token))) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    int user_id = find_session(token);
    if (user_id == -1) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    invalidate_session(token);
    send_response(client_socket, 200, "OK", "{}", NULL);
}

void handle_me(int client_socket, Request *req) {
    char token[64];
    if (!get_cookie(req, "session_id", token, sizeof(token))) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    int user_id = find_session(token);
    if (user_id == -1) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    int user_idx = find_user_by_id(user_id);
    if (user_idx == -1) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", users[user_idx].id);
    cJSON_AddStringToObject(resp, "username", users[user_idx].username);
    char *resp_str = cJSON_PrintUnformatted(resp);
    send_response(client_socket, 200, "OK", resp_str, NULL);
    free(resp_str);
    cJSON_Delete(resp);
}

void handle_password(int client_socket, Request *req) {
    char token[64];
    if (!get_cookie(req, "session_id", token, sizeof(token))) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    int user_id = find_session(token);
    if (user_id == -1) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    int user_idx = find_user_by_id(user_id);
    if (user_idx == -1) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    cJSON *root = cJSON_Parse(req->body);
    if (!root) {
        send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid JSON\"}", NULL);
        return;
    }
    
    cJSON *old_pass_json = cJSON_GetObjectItem(root, "old_password");
    cJSON *new_pass_json = cJSON_GetObjectItem(root, "new_password");
    
    if (!old_pass_json || old_pass_json->type != cJSON_String || strcmp(old_pass_json->valuestring, users[user_idx].password) != 0) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Invalid credentials\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    if (!new_pass_json || new_pass_json->type != cJSON_String || strlen(new_pass_json->valuestring) < 8) {
        send_response(client_socket, 400, "Bad Request", "{\"error\": \"Password too short\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    strncpy(users[user_idx].password, new_pass_json->valuestring, sizeof(users[user_idx].password) - 1);
    users[user_idx].password[sizeof(users[user_idx].password) - 1] = '\0';
    
    send_response(client_socket, 200, "OK", "{}", NULL);
    cJSON_Delete(root);
}

void handle_get_todos(int client_socket, Request *req) {
    char token[64];
    if (!get_cookie(req, "session_id", token, sizeof(token))) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    int user_id = find_session(token);
    if (user_id == -1) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    cJSON *resp = cJSON_CreateArray();
    for (int i = 0; i < MAX_TODOS; i++) {
        if (todos[i].active && todos[i].user_id == user_id) {
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
    
    char *resp_str = cJSON_PrintUnformatted(resp);
    send_response(client_socket, 200, "OK", resp_str, NULL);
    free(resp_str);
    cJSON_Delete(resp);
}

void handle_post_todo(int client_socket, Request *req) {
    char token[64];
    if (!get_cookie(req, "session_id", token, sizeof(token))) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    int user_id = find_session(token);
    if (user_id == -1) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    cJSON *root = cJSON_Parse(req->body);
    if (!root) {
        send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid JSON\"}", NULL);
        return;
    }
    
    cJSON *title_json = cJSON_GetObjectItem(root, "title");
    if (!title_json || title_json->type != cJSON_String || strlen(title_json->valuestring) == 0) {
        send_response(client_socket, 400, "Bad Request", "{\"error\": \"Title is required\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    cJSON *desc_json = cJSON_GetObjectItem(root, "description");
    const char *desc = "";
    if (desc_json && desc_json->type == cJSON_String) {
        desc = desc_json->valuestring;
    }
    
    int todo_id = create_todo(user_id, title_json->valuestring, desc);
    if (todo_id == -1) {
        send_response(client_socket, 500, "Internal Server Error", "{\"error\": \"Server full\"}", NULL);
        cJSON_Delete(root);
        return;
    }
    
    int todo_idx = find_todo_by_id(todo_id);
    cJSON *resp = cJSON_CreateObject();
    cJSON_AddNumberToObject(resp, "id", todos[todo_idx].id);
    cJSON_AddStringToObject(resp, "title", todos[todo_idx].title);
    cJSON_AddStringToObject(resp, "description", todos[todo_idx].description);
    cJSON_AddBoolToObject(resp, "completed", todos[todo_idx].completed);
    cJSON_AddStringToObject(resp, "created_at", todos[todo_idx].created_at);
    cJSON_AddStringToObject(resp, "updated_at", todos[todo_idx].updated_at);
    
    char *resp_str = cJSON_PrintUnformatted(resp);
    send_response(client_socket, 201, "Created", resp_str, NULL);
    free(resp_str);
    cJSON_Delete(resp);
    cJSON_Delete(root);
}

void handle_todo_by_id(int client_socket, Request *req, const char *method) {
    char token[64];
    if (!get_cookie(req, "session_id", token, sizeof(token))) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    int user_id = find_session(token);
    if (user_id == -1) {
        send_response(client_socket, 401, "Unauthorized", "{\"error\": \"Authentication required\"}", NULL);
        return;
    }
    
    const char *p = req->path + 7;
    if (*p == '\0' || !isdigit((unsigned char)*p)) {
        send_response(client_socket, 404, "Not Found", "{\"error\": \"Todo not found\"}", NULL);
        return;
    }
    char *endptr;
    long id = strtol(p, &endptr, 10);
    if (*endptr != '\0' || id <= 0 || id > 2147483647) {
        send_response(client_socket, 404, "Not Found", "{\"error\": \"Todo not found\"}", NULL);
        return;
    }
    
    int todo_idx = find_todo_by_id_and_user(id, user_id);
    if (todo_idx == -1) {
        send_response(client_socket, 404, "Not Found", "{\"error\": \"Todo not found\"}", NULL);
        return;
    }
    
    if (strcmp(method, "GET") == 0) {
        cJSON *resp = cJSON_CreateObject();
        cJSON_AddNumberToObject(resp, "id", todos[todo_idx].id);
        cJSON_AddStringToObject(resp, "title", todos[todo_idx].title);
        cJSON_AddStringToObject(resp, "description", todos[todo_idx].description);
        cJSON_AddBoolToObject(resp, "completed", todos[todo_idx].completed);
        cJSON_AddStringToObject(resp, "created_at", todos[todo_idx].created_at);
        cJSON_AddStringToObject(resp, "updated_at", todos[todo_idx].updated_at);
        
        char *resp_str = cJSON_PrintUnformatted(resp);
        send_response(client_socket, 200, "OK", resp_str, NULL);
        free(resp_str);
        cJSON_Delete(resp);
    } else if (strcmp(method, "PUT") == 0) {
        cJSON *root = cJSON_Parse(req->body);
        if (!root) {
            send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid JSON\"}", NULL);
            return;
        }
        
        cJSON *title_json = cJSON_GetObjectItem(root, "title");
        if (title_json) {
            if (title_json->type != cJSON_String) {
                send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid type for title\"}", NULL);
                cJSON_Delete(root);
                return;
            }
            if (strlen(title_json->valuestring) == 0) {
                send_response(client_socket, 400, "Bad Request", "{\"error\": \"Title is required\"}", NULL);
                cJSON_Delete(root);
                return;
            }
            strncpy(todos[todo_idx].title, title_json->valuestring, sizeof(todos[todo_idx].title) - 1);
            todos[todo_idx].title[sizeof(todos[todo_idx].title) - 1] = '\0';
        }
        
        cJSON *desc_json = cJSON_GetObjectItem(root, "description");
        if (desc_json) {
            if (desc_json->type != cJSON_String) {
                send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid type for description\"}", NULL);
                cJSON_Delete(root);
                return;
            }
            strncpy(todos[todo_idx].description, desc_json->valuestring, sizeof(todos[todo_idx].description) - 1);
            todos[todo_idx].description[sizeof(todos[todo_idx].description) - 1] = '\0';
        }
        
        cJSON *completed_json = cJSON_GetObjectItem(root, "completed");
        if (completed_json) {
            if (completed_json->type != cJSON_True && completed_json->type != cJSON_False) {
                send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid type for completed\"}", NULL);
                cJSON_Delete(root);
                return;
            }
            todos[todo_idx].completed = (completed_json->type == cJSON_True) ? 1 : 0;
        }
        
        time_t t = time(NULL);
        struct tm *tm = gmtime(&t);
        strftime(todos[todo_idx].updated_at, sizeof(todos[todo_idx].updated_at), "%Y-%m-%dT%H:%M:%SZ", tm);
        
        cJSON *resp = cJSON_CreateObject();
        cJSON_AddNumberToObject(resp, "id", todos[todo_idx].id);
        cJSON_AddStringToObject(resp, "title", todos[todo_idx].title);
        cJSON_AddStringToObject(resp, "description", todos[todo_idx].description);
        cJSON_AddBoolToObject(resp, "completed", todos[todo_idx].completed);
        cJSON_AddStringToObject(resp, "created_at", todos[todo_idx].created_at);
        cJSON_AddStringToObject(resp, "updated_at", todos[todo_idx].updated_at);
        
        char *resp_str = cJSON_PrintUnformatted(resp);
        send_response(client_socket, 200, "OK", resp_str, NULL);
        free(resp_str);
        cJSON_Delete(resp);
        cJSON_Delete(root);
    } else if (strcmp(method, "DELETE") == 0) {
        todos[todo_idx].active = 0;
        send_response(client_socket, 204, "No Content", NULL, NULL);
    }
}

void handle_request(int client_socket) {
    Request req;
    if (parse_request(client_socket, &req) != 0) {
        send_response(client_socket, 400, "Bad Request", "{\"error\": \"Invalid request\"}", NULL);
        return;
    }
    
    if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/register") == 0) {
        handle_register(client_socket, &req);
    } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/login") == 0) {
        handle_login(client_socket, &req);
    } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/logout") == 0) {
        handle_logout(client_socket, &req);
    } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/me") == 0) {
        handle_me(client_socket, &req);
    } else if (strcmp(req.method, "PUT") == 0 && strcmp(req.path, "/password") == 0) {
        handle_password(client_socket, &req);
    } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/todos") == 0) {
        handle_get_todos(client_socket, &req);
    } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/todos") == 0) {
        handle_post_todo(client_socket, &req);
    } else if (strcmp(req.method, "GET") == 0 && strncmp(req.path, "/todos/", 7) == 0) {
        handle_todo_by_id(client_socket, &req, "GET");
    } else if (strcmp(req.method, "PUT") == 0 && strncmp(req.path, "/todos/", 7) == 0) {
        handle_todo_by_id(client_socket, &req, "PUT");
    } else if (strcmp(req.method, "DELETE") == 0 && strncmp(req.path, "/todos/", 7) == 0) {
        handle_todo_by_id(client_socket, &req, "DELETE");
    } else {
        send_response(client_socket, 404, "Not Found", "{\"error\": \"Not found\"}", NULL);
    }
}

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
            i++;
        }
    }
    
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }
    
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    
    if (listen(server_fd, 128) < 0) {
        perror("listen");
        return 1;
    }
    
    printf("Server listening on 0.0.0.0:%d\n", port);
    
    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_socket = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_socket < 0) {
            perror("accept");
            continue;
        }
        
        handle_request(client_socket);
        close(client_socket);
    }
    
    return 0;
}

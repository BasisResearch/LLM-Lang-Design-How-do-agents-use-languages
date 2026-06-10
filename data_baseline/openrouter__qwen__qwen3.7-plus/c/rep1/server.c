#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <pthread.h>
#include <time.h>
#include <sys/random.h>
#include <strings.h>
#include <cjson/cJSON.h>
#include <openssl/evp.h>

#define MAX_USERS 10000
#define MAX_TODOS 100000
#define MAX_SESSIONS 10000

typedef struct {
    int id;
    char username[64];
    char password_hash[128];
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
    char token[65];
    int user_id;
    int valid;
} Session;

User users[MAX_USERS];
int user_count = 0;
int next_user_id = 1;
pthread_mutex_t user_mutex = PTHREAD_MUTEX_INITIALIZER;

Todo todos[MAX_TODOS];
int todo_count = 0;
int next_todo_id = 1;
pthread_mutex_t todo_mutex = PTHREAD_MUTEX_INITIALIZER;

Session sessions[MAX_SESSIONS];
int session_count = 0;
pthread_mutex_t session_mutex = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    char method[16];
    char path[512];
    char cookie[1024];
    int content_length;
    char *body;
} Request;

void get_current_time(char *buf, size_t sz) {
    time_t now = time(NULL);
    struct tm tm_info;
    gmtime_r(&now, &tm_info);
    strftime(buf, sz, "%Y-%m-%dT%H:%M:%SZ", &tm_info);
}

void hash_password(const char *password, char *out_hash) {
    unsigned char salt[16];
    if (getrandom(salt, 16, 0) != 16) {
        return;
    }
    
    char salt_hex[33];
    for (int i = 0; i < 16; i++) {
        sprintf(salt_hex + (i * 2), "%02x", salt[i]);
    }
    
    unsigned char hash[EVP_MAX_MD_SIZE];
    unsigned int hash_len;
    EVP_MD_CTX *mdctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(mdctx, EVP_sha256(), NULL);
    EVP_DigestUpdate(mdctx, salt, 16);
    EVP_DigestUpdate(mdctx, password, strlen(password));
    EVP_DigestFinal_ex(mdctx, hash, &hash_len);
    EVP_MD_CTX_free(mdctx);
    
    char hash_hex[65];
    for (unsigned int i = 0; i < hash_len; i++) {
        sprintf(hash_hex + (i * 2), "%02x", hash[i]);
    }
    
    snprintf(out_hash, 128, "%s:%s", salt_hex, hash_hex);
}

int check_password(const char *password, const char *stored_hash) {
    if (strlen(stored_hash) < 97) return 0;
    char salt_hex[33];
    strncpy(salt_hex, stored_hash, 32);
    salt_hex[32] = '\0';
    
    unsigned char salt[16];
    for (int i = 0; i < 16; i++) {
        unsigned int val;
        sscanf(salt_hex + (i * 2), "%2x", &val);
        salt[i] = (unsigned char)val;
    }
    
    unsigned char hash[EVP_MAX_MD_SIZE];
    unsigned int hash_len;
    EVP_MD_CTX *mdctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(mdctx, EVP_sha256(), NULL);
    EVP_DigestUpdate(mdctx, salt, 16);
    EVP_DigestUpdate(mdctx, password, strlen(password));
    EVP_DigestFinal_ex(mdctx, hash, &hash_len);
    EVP_MD_CTX_free(mdctx);
    
    char hash_hex[65];
    for (unsigned int i = 0; i < hash_len; i++) {
        sprintf(hash_hex + (i * 2), "%02x", hash[i]);
    }
    
    return strcmp(hash_hex, stored_hash + 33) == 0;
}

void generate_token(char *token) {
    unsigned char buf[32];
    if (getrandom(buf, 32, 0) != 32) {
        return;
    }
    for (int i = 0; i < 32; i++) {
        sprintf(token + (i * 2), "%02x", buf[i]);
    }
}

int create_session(int user_id, char *out_token) {
    pthread_mutex_lock(&session_mutex);
    if (session_count >= MAX_SESSIONS) {
        pthread_mutex_unlock(&session_mutex);
        return -1;
    }
    generate_token(out_token);
    strcpy(sessions[session_count].token, out_token);
    sessions[session_count].user_id = user_id;
    sessions[session_count].valid = 1;
    session_count++;
    pthread_mutex_unlock(&session_mutex);
    return 0;
}

void invalidate_session(const char *token) {
    pthread_mutex_lock(&session_mutex);
    for (int i = 0; i < session_count; i++) {
        if (sessions[i].valid && strcmp(sessions[i].token, token) == 0) {
            sessions[i].valid = 0;
            break;
        }
    }
    pthread_mutex_unlock(&session_mutex);
}

int get_session_user_id(const char *cookie_str) {
    if (!cookie_str || cookie_str[0] == '\0') return -1;
    
    const char *session_str = strstr(cookie_str, "session_id=");
    if (!session_str) return -1;
    session_str += 11;
    
    char token[65] = {0};
    int i = 0;
    while (session_str[i] && session_str[i] != ';' && session_str[i] != ' ' && i < 64) {
        token[i] = session_str[i];
        i++;
    }
    token[i] = '\0';
    
    if (token[0] == '\0') return -1;
    
    pthread_mutex_lock(&session_mutex);
    for (i = 0; i < session_count; i++) {
        if (sessions[i].valid && strcmp(sessions[i].token, token) == 0) {
            int uid = sessions[i].user_id;
            pthread_mutex_unlock(&session_mutex);
            return uid;
        }
    }
    pthread_mutex_unlock(&session_mutex);
    return -1;
}

int is_valid_username(const char *username) {
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

ssize_t write_all(int fd, const void *buf, size_t count) {
    size_t total = 0;
    const char *ptr = buf;
    while (total < count) {
        ssize_t n = write(fd, ptr + total, count - total);
        if (n <= 0) return n;
        total += n;
    }
    return total;
}

void send_response_with_headers(int fd, int status_code, const char *status_text, const char *extra_headers, const char *body) {
    const char *content_type = "Content-Type: application/json\r\n";
    char content_length_str[32];
    int body_len = body ? strlen(body) : 0;
    snprintf(content_length_str, sizeof(content_length_str), "Content-Length: %d\r\n", body_len);
    
    char header_buf[1024];
    snprintf(header_buf, sizeof(header_buf), 
             "HTTP/1.1 %d %s\r\n"
             "%s"
             "%s"
             "%s"
             "\r\n",
             status_code, status_text, content_type, content_length_str, extra_headers ? extra_headers : "");
             
    write_all(fd, header_buf, strlen(header_buf));
    if (body && body_len > 0) {
        write_all(fd, body, body_len);
    }
}

void send_response(int fd, int status_code, const char *status_text, const char *body) {
    send_response_with_headers(fd, status_code, status_text, NULL, body);
}

void send_response_no_body(int fd, int status_code, const char *status_text) {
    char header_buf[512];
    snprintf(header_buf, sizeof(header_buf), 
             "HTTP/1.1 %d %s\r\n"
             "Content-Length: 0\r\n"
             "\r\n",
             status_code, status_text);
    write_all(fd, header_buf, strlen(header_buf));
}

int parse_request(const char *raw, size_t raw_len, Request *req) {
    const char *ptr = raw;
    const char *end = raw + raw_len;
    
    const char *line_end = strstr(ptr, "\r\n");
    if (!line_end) return -1;
    
    const char *space1 = strchr(ptr, ' ');
    if (!space1 || space1 >= line_end) return -1;
    size_t method_len = space1 - ptr;
    if (method_len >= sizeof(req->method)) return -1;
    strncpy(req->method, ptr, method_len);
    req->method[method_len] = '\0';
    
    ptr = space1 + 1;
    const char *space2 = strchr(ptr, ' ');
    if (!space2 || space2 >= line_end) return -1;
    size_t path_len = space2 - ptr;
    if (path_len >= sizeof(req->path)) return -1;
    strncpy(req->path, ptr, path_len);
    req->path[path_len] = '\0';
    
    const char *headers_end = strstr(ptr, "\r\n\r\n");
    if (!headers_end) return -1;
    
    req->content_length = 0;
    req->cookie[0] = '\0';
    
    const char *h_start = line_end + 2;
    while (h_start < headers_end) {
        const char *h_end = strstr(h_start, "\r\n");
        if (!h_end) break;
        
        if (strncasecmp(h_start, "Content-Length:", 15) == 0) {
            req->content_length = atoi(h_start + 15);
        } else if (strncasecmp(h_start, "Cookie:", 7) == 0) {
            size_t c_len = (h_end - (h_start + 7));
            if (c_len < sizeof(req->cookie)) {
                strncpy(req->cookie, h_start + 7, c_len);
                req->cookie[c_len] = '\0';
                char *c_ptr = req->cookie;
                while (*c_ptr == ' ') c_ptr++;
                if (c_ptr != req->cookie) {
                    memmove(req->cookie, c_ptr, strlen(c_ptr) + 1);
                }
            }
        }
        h_start = h_end + 2;
    }
    
    const char *body_start = headers_end + 4;
    if (body_start + req->content_length > end) {
        return -1;
    }
    
    if (req->content_length > 0) {
        req->body = malloc(req->content_length + 1);
        if (req->body) {
            memcpy(req->body, body_start, req->content_length);
            req->body[req->content_length] = '\0';
        } else {
            return -1;
        }
    } else {
        req->body = NULL;
    }
    
    return 0;
}

void handle_register(int client_fd, Request *req) {
    if (!req->body) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid request body\"}");
        return;
    }
    
    cJSON *json = cJSON_Parse(req->body);
    if (!json) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid JSON\"}");
        return;
    }
    
    cJSON *username_json = cJSON_GetObjectItem(json, "username");
    cJSON *password_json = cJSON_GetObjectItem(json, "password");
    
    if (!username_json || !cJSON_IsString(username_json) || !password_json || !cJSON_IsString(password_json)) {
        cJSON_Delete(json);
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Missing username or password\"}");
        return;
    }
    
    const char *username = username_json->valuestring;
    const char *password = password_json->valuestring;
    
    if (!is_valid_username(username)) {
        cJSON_Delete(json);
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid username\"}");
        return;
    }
    
    if (strlen(password) < 8) {
        cJSON_Delete(json);
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Password too short\"}");
        return;
    }
    
    pthread_mutex_lock(&user_mutex);
    if (user_count >= MAX_USERS) {
        pthread_mutex_unlock(&user_mutex);
        cJSON_Delete(json);
        send_response(client_fd, 500, "Internal Server Error", "{\"error\":\"Server capacity reached\"}");
        return;
    }
    
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            pthread_mutex_unlock(&user_mutex);
            cJSON_Delete(json);
            send_response(client_fd, 409, "Conflict", "{\"error\":\"Username already exists\"}");
            return;
        }
    }
    
    int id = next_user_id++;
    strcpy(users[user_count].username, username);
    hash_password(password, users[user_count].password_hash);
    users[user_count].id = id;
    user_count++;
    pthread_mutex_unlock(&user_mutex);
    
    cJSON_Delete(json);
    
    char response[256];
    snprintf(response, sizeof(response), "{\"id\":%d,\"username\":\"%s\"}", id, username);
    send_response(client_fd, 201, "Created", response);
}

void handle_login(int client_fd, Request *req) {
    if (!req->body) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid request body\"}");
        return;
    }
    
    cJSON *json = cJSON_Parse(req->body);
    if (!json) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid JSON\"}");
        return;
    }
    
    cJSON *username_json = cJSON_GetObjectItem(json, "username");
    cJSON *password_json = cJSON_GetObjectItem(json, "password");
    
    if (!username_json || !cJSON_IsString(username_json) || !password_json || !cJSON_IsString(password_json)) {
        cJSON_Delete(json);
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Invalid credentials\"}");
        return;
    }
    
    const char *username = username_json->valuestring;
    const char *password = password_json->valuestring;
    
    int user_id = -1;
    char safe_username[64] = {0};
    pthread_mutex_lock(&user_mutex);
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            if (check_password(password, users[i].password_hash)) {
                user_id = users[i].id;
                strcpy(safe_username, users[i].username);
            }
            break;
        }
    }
    pthread_mutex_unlock(&user_mutex);
    
    if (user_id == -1) {
        cJSON_Delete(json);
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Invalid credentials\"}");
        return;
    }
    
    char token[65];
    if (create_session(user_id, token) < 0) {
        cJSON_Delete(json);
        send_response(client_fd, 500, "Internal Server Error", "{\"error\":\"Session creation failed\"}");
        return;
    }
    
    cJSON_Delete(json);
    
    char response[256];
    snprintf(response, sizeof(response), "{\"id\":%d,\"username\":\"%s\"}", user_id, safe_username);
    
    char headers[512];
    snprintf(headers, sizeof(headers), "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", token);
    send_response_with_headers(client_fd, 200, "OK", headers, response);
}

void handle_logout(int client_fd, Request *req) {
    int user_id = get_session_user_id(req->cookie);
    if (user_id == -1) {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Authentication required\"}");
        return;
    }
    
    const char *session_str = strstr(req->cookie, "session_id=");
    if (session_str) {
        session_str += 11;
        char token[65] = {0};
        int i = 0;
        while (session_str[i] && session_str[i] != ';' && session_str[i] != ' ' && i < 64) {
            token[i] = session_str[i];
            i++;
        }
        invalidate_session(token);
    }
    
    send_response(client_fd, 200, "OK", "{}");
}

void handle_me(int client_fd, Request *req) {
    int user_id = get_session_user_id(req->cookie);
    if (user_id == -1) {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Authentication required\"}");
        return;
    }
    
    pthread_mutex_lock(&user_mutex);
    char username[64] = {0};
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            strcpy(username, users[i].username);
            break;
        }
    }
    pthread_mutex_unlock(&user_mutex);
    
    if (username[0] == '\0') {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Authentication required\"}");
        return;
    }
    
    char response[256];
    snprintf(response, sizeof(response), "{\"id\":%d,\"username\":\"%s\"}", user_id, username);
    send_response(client_fd, 200, "OK", response);
}

void handle_password(int client_fd, Request *req) {
    int user_id = get_session_user_id(req->cookie);
    if (user_id == -1) {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Authentication required\"}");
        return;
    }
    
    if (!req->body) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid request body\"}");
        return;
    }
    
    cJSON *json = cJSON_Parse(req->body);
    if (!json) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid JSON\"}");
        return;
    }
    
    cJSON *old_pwd_json = cJSON_GetObjectItem(json, "old_password");
    cJSON *new_pwd_json = cJSON_GetObjectItem(json, "new_password");
    
    if (!old_pwd_json || !cJSON_IsString(old_pwd_json) || !new_pwd_json || !cJSON_IsString(new_pwd_json)) {
        cJSON_Delete(json);
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Missing old_password or new_password\"}");
        return;
    }
    
    const char *old_pwd = old_pwd_json->valuestring;
    const char *new_pwd = new_pwd_json->valuestring;
    
    if (strlen(new_pwd) < 8) {
        cJSON_Delete(json);
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Password too short\"}");
        return;
    }
    
    pthread_mutex_lock(&user_mutex);
    int valid = 0;
    int u_idx = -1;
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            if (check_password(old_pwd, users[i].password_hash)) {
                valid = 1;
                u_idx = i;
            }
            break;
        }
    }
    
    if (valid && u_idx != -1) {
        hash_password(new_pwd, users[u_idx].password_hash);
    }
    pthread_mutex_unlock(&user_mutex);
    
    cJSON_Delete(json);
    
    if (!valid) {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Invalid credentials\"}");
        return;
    }
    
    send_response(client_fd, 200, "OK", "{}");
}

void handle_get_todos(int client_fd, Request *req) {
    int user_id = get_session_user_id(req->cookie);
    if (user_id == -1) {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Authentication required\"}");
        return;
    }
    
    pthread_mutex_lock(&todo_mutex);
    cJSON *arr = cJSON_CreateArray();
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id == user_id) {
            cJSON *todo = cJSON_CreateObject();
            cJSON_AddNumberToObject(todo, "id", todos[i].id);
            cJSON_AddStringToObject(todo, "title", todos[i].title);
            cJSON_AddStringToObject(todo, "description", todos[i].description);
            cJSON_AddBoolToObject(todo, "completed", todos[i].completed ? cJSON_True : cJSON_False);
            cJSON_AddStringToObject(todo, "created_at", todos[i].created_at);
            cJSON_AddStringToObject(todo, "updated_at", todos[i].updated_at);
            cJSON_AddItemToArray(arr, todo);
        }
    }
    pthread_mutex_unlock(&todo_mutex);
    
    char *response = cJSON_PrintUnformatted(arr);
    if (response) {
        send_response(client_fd, 200, "OK", response);
        free(response);
    } else {
        send_response(client_fd, 500, "Internal Server Error", "{\"error\":\"Internal Server Error\"}");
    }
    cJSON_Delete(arr);
}

void handle_post_todo(int client_fd, Request *req) {
    int user_id = get_session_user_id(req->cookie);
    if (user_id == -1) {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Authentication required\"}");
        return;
    }
    
    if (!req->body) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid request body\"}");
        return;
    }
    
    cJSON *json = cJSON_Parse(req->body);
    if (!json) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid JSON\"}");
        return;
    }
    
    cJSON *title_json = cJSON_GetObjectItem(json, "title");
    if (!title_json || !cJSON_IsString(title_json) || strlen(title_json->valuestring) == 0) {
        cJSON_Delete(json);
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Title is required\"}");
        return;
    }
    
    const char *title = title_json->valuestring;
    cJSON *desc_json = cJSON_GetObjectItem(json, "description");
    const char *description = (desc_json && cJSON_IsString(desc_json)) ? desc_json->valuestring : "";
    
    char created_at[32], updated_at[32];
    get_current_time(created_at, sizeof(created_at));
    get_current_time(updated_at, sizeof(updated_at));
    
    pthread_mutex_lock(&todo_mutex);
    if (todo_count >= MAX_TODOS) {
        pthread_mutex_unlock(&todo_mutex);
        cJSON_Delete(json);
        send_response(client_fd, 500, "Internal Server Error", "{\"error\":\"Server capacity reached\"}");
        return;
    }
    
    int id = next_todo_id++;
    int idx = todo_count++;
    todos[idx].id = id;
    todos[idx].user_id = user_id;
    strncpy(todos[idx].title, title, sizeof(todos[idx].title) - 1);
    todos[idx].title[sizeof(todos[idx].title) - 1] = '\0';
    strncpy(todos[idx].description, description, sizeof(todos[idx].description) - 1);
    todos[idx].description[sizeof(todos[idx].description) - 1] = '\0';
    todos[idx].completed = 0;
    strcpy(todos[idx].created_at, created_at);
    strcpy(todos[idx].updated_at, updated_at);
    pthread_mutex_unlock(&todo_mutex);
    
    cJSON_Delete(json);
    
    cJSON *todo = cJSON_CreateObject();
    cJSON_AddNumberToObject(todo, "id", id);
    cJSON_AddStringToObject(todo, "title", title);
    cJSON_AddStringToObject(todo, "description", description);
    cJSON_AddBoolToObject(todo, "completed", cJSON_False);
    cJSON_AddStringToObject(todo, "created_at", created_at);
    cJSON_AddStringToObject(todo, "updated_at", updated_at);
    
    char *response = cJSON_PrintUnformatted(todo);
    if (response) {
        send_response(client_fd, 201, "Created", response);
        free(response);
    } else {
        send_response(client_fd, 500, "Internal Server Error", "{\"error\":\"Internal Server Error\"}");
    }
    cJSON_Delete(todo);
}

void handle_get_todo(int client_fd, Request *req, int id) {
    int user_id = get_session_user_id(req->cookie);
    if (user_id == -1) {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Authentication required\"}");
        return;
    }
    
    pthread_mutex_lock(&todo_mutex);
    int found = 0;
    cJSON *todo = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == id && todos[i].user_id == user_id) {
            found = 1;
            todo = cJSON_CreateObject();
            cJSON_AddNumberToObject(todo, "id", todos[i].id);
            cJSON_AddStringToObject(todo, "title", todos[i].title);
            cJSON_AddStringToObject(todo, "description", todos[i].description);
            cJSON_AddBoolToObject(todo, "completed", todos[i].completed ? cJSON_True : cJSON_False);
            cJSON_AddStringToObject(todo, "created_at", todos[i].created_at);
            cJSON_AddStringToObject(todo, "updated_at", todos[i].updated_at);
            break;
        }
    }
    pthread_mutex_unlock(&todo_mutex);
    
    if (!found) {
        send_response(client_fd, 404, "Not Found", "{\"error\":\"Todo not found\"}");
        return;
    }
    
    char *response = cJSON_PrintUnformatted(todo);
    if (response) {
        send_response(client_fd, 200, "OK", response);
        free(response);
    } else {
        send_response(client_fd, 500, "Internal Server Error", "{\"error\":\"Internal Server Error\"}");
    }
    cJSON_Delete(todo);
}

void handle_put_todo(int client_fd, Request *req, int id) {
    int user_id = get_session_user_id(req->cookie);
    if (user_id == -1) {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Authentication required\"}");
        return;
    }
    
    if (!req->body) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid request body\"}");
        return;
    }
    
    cJSON *json = cJSON_Parse(req->body);
    if (!json) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Invalid JSON\"}");
        return;
    }
    
    cJSON *title_json = cJSON_GetObjectItem(json, "title");
    if (title_json && (!cJSON_IsString(title_json) || strlen(title_json->valuestring) == 0)) {
        cJSON_Delete(json);
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Title is required\"}");
        return;
    }
    
    pthread_mutex_lock(&todo_mutex);
    int found = 0;
    int idx = -1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == id && todos[i].user_id == user_id) {
            found = 1;
            idx = i;
            break;
        }
    }
    
    if (!found) {
        pthread_mutex_unlock(&todo_mutex);
        cJSON_Delete(json);
        send_response(client_fd, 404, "Not Found", "{\"error\":\"Todo not found\"}");
        return;
    }
    
    if (title_json) {
        strncpy(todos[idx].title, title_json->valuestring, sizeof(todos[idx].title) - 1);
        todos[idx].title[sizeof(todos[idx].title) - 1] = '\0';
    }
    
    cJSON *desc_json = cJSON_GetObjectItem(json, "description");
    if (desc_json && cJSON_IsString(desc_json)) {
        strncpy(todos[idx].description, desc_json->valuestring, sizeof(todos[idx].description) - 1);
        todos[idx].description[sizeof(todos[idx].description) - 1] = '\0';
    }
    
    cJSON *comp_json = cJSON_GetObjectItem(json, "completed");
    if (comp_json && cJSON_IsBool(comp_json)) {
        todos[idx].completed = cJSON_IsTrue(comp_json) ? 1 : 0;
    }
    
    get_current_time(todos[idx].updated_at, sizeof(todos[idx].updated_at));
    
    cJSON *todo = cJSON_CreateObject();
    cJSON_AddNumberToObject(todo, "id", todos[idx].id);
    cJSON_AddStringToObject(todo, "title", todos[idx].title);
    cJSON_AddStringToObject(todo, "description", todos[idx].description);
    cJSON_AddBoolToObject(todo, "completed", todos[idx].completed ? cJSON_True : cJSON_False);
    cJSON_AddStringToObject(todo, "created_at", todos[idx].created_at);
    cJSON_AddStringToObject(todo, "updated_at", todos[idx].updated_at);
    
    pthread_mutex_unlock(&todo_mutex);
    cJSON_Delete(json);
    
    char *response = cJSON_PrintUnformatted(todo);
    if (response) {
        send_response(client_fd, 200, "OK", response);
        free(response);
    } else {
        send_response(client_fd, 500, "Internal Server Error", "{\"error\":\"Internal Server Error\"}");
    }
    cJSON_Delete(todo);
}

void handle_delete_todo(int client_fd, Request *req, int id) {
    int user_id = get_session_user_id(req->cookie);
    if (user_id == -1) {
        send_response(client_fd, 401, "Unauthorized", "{\"error\":\"Authentication required\"}");
        return;
    }
    
    pthread_mutex_lock(&todo_mutex);
    int found = 0;
    int idx = -1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == id && todos[i].user_id == user_id) {
            found = 1;
            idx = i;
            break;
        }
    }
    
    if (!found) {
        pthread_mutex_unlock(&todo_mutex);
        send_response(client_fd, 404, "Not Found", "{\"error\":\"Todo not found\"}");
        return;
    }
    
    for (int i = idx; i < todo_count - 1; i++) {
        todos[i] = todos[i + 1];
    }
    todo_count--;
    pthread_mutex_unlock(&todo_mutex);
    
    send_response_no_body(client_fd, 204, "No Content");
}

void handle_request(int client_fd) {
    char buffer[65536];
    ssize_t n = read(client_fd, buffer, sizeof(buffer) - 1);
    if (n <= 0) {
        close(client_fd);
        return;
    }
    buffer[n] = '\0';
    
    Request req;
    memset(&req, 0, sizeof(req));
    if (parse_request(buffer, n, &req) < 0) {
        send_response(client_fd, 400, "Bad Request", "{\"error\":\"Bad Request\"}");
        goto cleanup;
    }
    
    if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/register") == 0) {
        handle_register(client_fd, &req);
    } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/login") == 0) {
        handle_login(client_fd, &req);
    } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/logout") == 0) {
        handle_logout(client_fd, &req);
    } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/me") == 0) {
        handle_me(client_fd, &req);
    } else if (strcmp(req.method, "PUT") == 0 && strcmp(req.path, "/password") == 0) {
        handle_password(client_fd, &req);
    } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/todos") == 0) {
        handle_get_todos(client_fd, &req);
    } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/todos") == 0) {
        handle_post_todo(client_fd, &req);
    } else if (strncmp(req.path, "/todos/", 7) == 0) {
        int id;
        if (sscanf(req.path + 7, "%d", &id) == 1) {
            if (strcmp(req.method, "GET") == 0) {
                handle_get_todo(client_fd, &req, id);
            } else if (strcmp(req.method, "PUT") == 0) {
                handle_put_todo(client_fd, &req, id);
            } else if (strcmp(req.method, "DELETE") == 0) {
                handle_delete_todo(client_fd, &req, id);
            } else {
                send_response(client_fd, 405, "Method Not Allowed", "{\"error\":\"Method Not Allowed\"}");
            }
        } else {
            send_response(client_fd, 404, "Not Found", "{\"error\":\"Todo not found\"}");
        }
    } else {
        send_response(client_fd, 404, "Not Found", "{\"error\":\"Not found\"}");
    }
    
cleanup:
    if (req.body) free(req.body);
    close(client_fd);
}

void *handle_request_thread(void *arg) {
    int client_fd = (int)(long)arg;
    handle_request(client_fd);
    return NULL;
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
        close(server_fd);
        return 1;
    }
    
    if (listen(server_fd, 128) < 0) {
        perror("listen");
        close(server_fd);
        return 1;
    }
    
    printf("Server listening on 0.0.0.0:%d\n", port);
    
    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_fd < 0) {
            perror("accept");
            continue;
        }
        
        pthread_t thread;
        if (pthread_create(&thread, NULL, handle_request_thread, (void *)(long)client_fd) != 0) {
            perror("pthread_create");
            close(client_fd);
        } else {
            pthread_detach(thread);
        }
    }
    
    close(server_fd);
    return 0;
}

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <pthread.h>
#include <stdbool.h>
#include <ctype.h>
#include <uuid/uuid.h>
#include <regex.h>
#include <strings.h>  // for strcasecmp and strcasestr
#include <limits.h>

#define MAX_USERS 50
#define MAX_TODOS_PER_USER 100
#define MAX_SESSIONS 50
#define BUFFER_SIZE 8192
#define MIN_PASSWORD_LENGTH 8

// Forward declarations
typedef struct Todo Todo;
typedef struct User User;

// Data structures
struct User {
    int id;
    char username[51];
    char password_hash[256];
    int num_todos;
    Todo *todos[MAX_TODOS_PER_USER];
};

struct Todo {
    int id;
    char title[1024];
    char description[2048];
    bool completed;
    char created_at[32];
    char updated_at[32];
};

typedef struct {
    char session_token[37];  // UUID length
    int user_id;
    time_t expires_at;
} Session;

// Global state (with mutexes for thread safety)
User users[MAX_USERS];
int user_count = 0;
Session sessions[MAX_SESSIONS];
int session_count = 0;
pthread_mutex_t global_mutex = PTHREAD_MUTEX_INITIALIZER;

int next_user_id = 1;
int next_todo_id = 1;

// Utility functions
char* generate_uuid() {
    static char uuid_str[37];
    uuid_t uuid_bin;
    uuid_generate(uuid_bin);
    uuid_unparse_lower(uuid_bin, uuid_str);
    return strdup(uuid_str);
}

void get_current_timestamp(char *timestamp, size_t len) {
    time_t now = time(NULL);
    struct tm *tm_info = gmtime(&now);
    strftime(timestamp, len, "%Y-%m-%dT%H:%M:%SZ", tm_info);
}

bool is_valid_username(const char *username) {
    if (!username || strlen(username) < 3 || strlen(username) > 50) {
        return false;
    }
    
    regex_t regex;
    int compiled_regex = regcomp(&regex, "^[a-zA-Z0-9_]+$", REG_EXTENDED | REG_NOSUB);
    if (compiled_regex != 0) {
        return false;
    }
    
    int result = regexec(&regex, username, 0, NULL, 0);
    regfree(&regex);
    
    return result == 0;
}

int get_user_by_username(const char *username) {
    pthread_mutex_lock(&global_mutex);
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            pthread_mutex_unlock(&global_mutex);
            return i;
        }
    }
    pthread_mutex_unlock(&global_mutex);
    return -1;
}

int get_user_index_by_id(int user_id) {
    pthread_mutex_lock(&global_mutex);
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            pthread_mutex_unlock(&global_mutex);
            return i;
        }
    }
    pthread_mutex_unlock(&global_mutex);
    return -1;
}

User* add_user(const char *username, const char *password) {
    pthread_mutex_lock(&global_mutex);
    if (get_user_by_username(username) != -1) {
        pthread_mutex_unlock(&global_mutex);
        return NULL;
    }

    if (user_count >= MAX_USERS) {
        pthread_mutex_unlock(&global_mutex);
        return NULL;
    }

    User *new_user = &users[user_count];
    new_user->id = next_user_id++;
    strncpy(new_user->username, username, sizeof(new_user->username) - 1);
    new_user->username[sizeof(new_user->username) - 1] = '\0';
    new_user->num_todos = 0;
    strncpy(new_user->password_hash, password, sizeof(new_user->password_hash) - 1);
    new_user->password_hash[sizeof(new_user->password_hash) - 1] = '\0';
    user_count++;
    pthread_mutex_unlock(&global_mutex);
    return new_user;
}

int get_todo_index_for_user(User *user, int todo_id) {
    for (int i = 0; i < user->num_todos; i++) {
        if (user->todos[i]->id == todo_id) {
            return i;
        }
    }
    return -1;
}

Todo* find_todo_by_id(int user_id, int todo_id) {
    int user_idx = get_user_index_by_id(user_id);
    if (user_idx == -1) {
        return NULL;
    }
    
    User *user = &users[user_idx];
    int todo_idx = get_todo_index_for_user(user, todo_id);
    if (todo_idx == -1) {
        return NULL;
    }
    
    return user->todos[todo_idx];
}

void prepare_json_response(char *response_buffer, size_t max_len, const char *key, const char *value) {
    snprintf(response_buffer, max_len, "{\"%s\":\"%s\"}", key, value);
}

int find_json_field_value(const char *json, const char *field, char *target, size_t target_size) {
    char pattern[200];
    snprintf(pattern, sizeof(pattern), "\"%s\"", field);

    char *field_pos = strstr(json, pattern);
    if (field_pos) {
        field_pos = strchr(field_pos, ':');
        if (field_pos) {
            field_pos++; // Skip colon
            while (*field_pos == ' ' || *field_pos == '\t') field_pos++;
            if (*field_pos == '"') {
                field_pos++; // Skip opening quote
                char *end_quote = strchr(field_pos, '"');
                if (end_quote) {
                    size_t len = end_quote - field_pos;
                    if (len < target_size) {
                        strncpy(target, field_pos, len);
                        target[len] = '\0';
                        return 1;
                    }
                }
            }
        }
    }
    return 0;
}

char* extract_cookie_value(const char *headers, const char *cookie_name) {
    static char cookie_value[256];

    const char *cookie_header = strcasestr(headers, "Cookie:");
    if (!cookie_header) {
        cookie_header = strcasestr(headers, "cookie:");
    }
    if (!cookie_header) {
        return NULL;
    }

    const char *colon_pos = strchr(cookie_header, ':');
    if (!colon_pos) return NULL;

    const char *cookie_data_start = colon_pos + 1;
    while (*cookie_data_start == ' ') cookie_data_start++;

    char search_key[260];
    snprintf(search_key, sizeof(search_key), "%s=", cookie_name);

    const char *cookie_start = strstr(cookie_data_start, search_key);
    if (!cookie_start) return NULL;

    cookie_start += strlen(search_key);

    const char *cookie_end = strchr(cookie_start, ';');
    size_t val_len;
    if (cookie_end) {
        val_len = cookie_end - cookie_start;
    } else {
        val_len = strlen(cookie_start);
    }

    if (val_len >= sizeof(cookie_value)) val_len = sizeof(cookie_value) - 1;
    strncpy(cookie_value, cookie_start, val_len);
    cookie_value[val_len] = '\0';

    while (strlen(cookie_value) > 0 && 
           (cookie_value[strlen(cookie_value)-1] == ' ' || cookie_value[strlen(cookie_value)-1] == '\t')) {
        cookie_value[strlen(cookie_value)-1] = '\0';
    }
    
    return (strlen(cookie_value) > 0) ? cookie_value : NULL;
}

int get_user_by_session(const char *session_token) {
    if (!session_token) return -1;
    
    pthread_mutex_lock(&global_mutex);
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].session_token, session_token) == 0) {
            pthread_mutex_unlock(&global_mutex);
            return sessions[i].user_id;
        }
    }
    pthread_mutex_unlock(&global_mutex);
    return -1;
}

int authenticate_user(int client_socket, const char *request_headers, char response_buffer[BUFFER_SIZE]) {
    char *session_token = extract_cookie_value(request_headers, "session_id");
    if (!session_token) {
        prepare_json_response(response_buffer, BUFFER_SIZE, "error", "Authentication required");
        const char *http_resp = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char full_response[BUFFER_SIZE];
        int len = snprintf(full_response, sizeof(full_response), http_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, full_response, len, 0);
        return 0; // Not authenticated
    }
    
    int user_id = get_user_by_session(session_token);
    if (user_id == -1) {
        prepare_json_response(response_buffer, BUFFER_SIZE, "error", "Authentication required");
        const char *http_resp = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char full_response[BUFFER_SIZE];
        int len = snprintf(full_response, sizeof(full_response), http_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, full_response, len, 0);
        return 0;
    }
    
    return 1; // Authenticated
}

// Endpoint handlers with responses
void handle_register(int client_socket, const char *body) {
    char username[51] = {0};
    char password[129] = {0};
    
    char response_buffer[BUFFER_SIZE];
    
    if (!find_json_field_value(body, "username", username, sizeof(username))) {
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Missing username");
        const char *full_resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), full_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
        return;
    }
    
    if (!find_json_field_value(body, "password", password, sizeof(password))) {
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Missing password");
        const char *full_resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), full_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
        return;
    }
    
    if (!is_valid_username(username)) {
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Invalid username");
        const char *full_resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), full_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
        return;
    }
    
    if (get_user_by_username(username) != -1) {
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Username already exists");
        const char *full_resp = "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), full_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
        return;
    }
    
    if (strlen(password) < MIN_PASSWORD_LENGTH) {
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Password too short");
        const char *full_resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), full_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
        return;
    }
    
    User *new_user = add_user(username, password);
    if (!new_user) {
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Failed to create user");
        const char *full_resp = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), full_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
        return;
    }
    
    // Send success response (201):
    int len = snprintf(response_buffer, sizeof(response_buffer), "{\"id\":%d,\"username\":\"%s\"}", new_user->id, new_user->username);
    const char *created_resp = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
    char send_buf[BUFFER_SIZE];
    int full_len = snprintf(send_buf, sizeof(send_buf), created_resp, len, response_buffer);
    send(client_socket, send_buf, full_len, 0);
}

void handle_login(int client_socket, const char *body) {
    char username[51] = {0};
    char password[129] = {0};
    
    if (!find_json_field_value(body, "username", username, sizeof(username)) ||
        !find_json_field_value(body, "password", password, sizeof(password))) {
        char response_buffer[BUFFER_SIZE];
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Missing username or password");
        const char *wrong_resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), wrong_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
        return;
    }
    
    int user_idx = get_user_by_username(username);
    if (user_idx == -1 || strcmp(users[user_idx].password_hash, password) != 0) {
        char response_buffer[BUFFER_SIZE];
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Invalid credentials");
        const char *unauth_resp = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), unauth_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
        return;
    }
    
    pthread_mutex_lock(&global_mutex);
    if (session_count >= MAX_SESSIONS) {
        pthread_mutex_unlock(&global_mutex);
        char response_buffer[BUFFER_SIZE];
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Too many active sessions");
        const char *fail_resp = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), fail_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
        return;
    }
    
    char* session_token = generate_uuid();
    strcpy(sessions[session_count].session_token, session_token);
    sessions[session_count].user_id = users[user_idx].id;
    const char* token_copy = strdup(session_token);
    session_count++;
    pthread_mutex_unlock(&global_mutex);
    
    char response_buffer[BUFFER_SIZE];
    int json_len = snprintf(response_buffer, sizeof(response_buffer), "{\"id\":%d,\"username\":\"%s\"}", users[user_idx].id, users[user_idx].username);
    
    char full_response[BUFFER_SIZE * 2];
    int resp_len = snprintf(full_response, sizeof(full_response), 
                           "HTTP/1.1 200 OK\r\nSet-Cookie: session_id=%s; Path=/; HttpOnly\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", 
                           token_copy, json_len, response_buffer);
    
    send(client_socket, full_response, resp_len, 0);
    free((void*)token_copy);
}

void process_request(int client_socket) {
    char buffer[BUFFER_SIZE];
    memset(buffer, 0, sizeof(buffer));
    
    ssize_t bytes_received = recv(client_socket, buffer, sizeof(buffer) - 1, 0);
    if (bytes_received <= 0) {
        close(client_socket);
        return;
    }
    
    buffer[bytes_received] = '\0';
    
    // Parse first line
    char method[16], url_path[256], http_version[64];
    int n = sscanf(buffer, "%15s %255s %63s", method, url_path, http_version);
    if (n != 3) {
        close(client_socket);
        return;
    }
    
    // Extract request body
    char *body_start = strstr(buffer, "\r\n\r\n");
    if (body_start) {
        body_start += 4;
    } else {
        body_start = "";
    }
    
    if (strcmp(method, "POST") == 0) {
        if (strcmp(url_path, "/register") == 0) {
            handle_register(client_socket, body_start);
        } else if (strcmp(url_path, "/login") == 0) {
            handle_login(client_socket, body_start);
        } else {
            char response_buffer[BUFFER_SIZE];
            prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Not found");
            const char *notfound_resp = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
            char send_buf[BUFFER_SIZE];
            int len = snprintf(send_buf, sizeof(send_buf), notfound_resp, (int)strlen(response_buffer), response_buffer);
            send(client_socket, send_buf, len, 0);
        }
    } else {
        char response_buffer[BUFFER_SIZE];
        prepare_json_response(response_buffer, sizeof(response_buffer), "error", "Method not allowed");
        const char *methodnotallowed_resp = "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s";
        char send_buf[BUFFER_SIZE];
        int len = snprintf(send_buf, sizeof(send_buf), methodnotallowed_resp, (int)strlen(response_buffer), response_buffer);
        send(client_socket, send_buf, len, 0);
    }
    
    close(client_socket);
}

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
            i++;
        }
    }

    // Initialize
    memset(users, 0, sizeof(users));
    memset(sessions, 0, sizeof(sessions));
    
    int server_fd;
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }

    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        exit(EXIT_FAILURE);
    }

    struct sockaddr_in address;
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }

    if (listen(server_fd, 10) < 0) {
        perror("listen failed");
        exit(EXIT_FAILURE);
    }

    printf("Server listening on port %d\n", port);

    while(1) {
        int client_socket = accept(server_fd, NULL, NULL);
        if (client_socket < 0) {
            perror("accept failed");
            continue;
        }
        
        process_request(client_socket);
    }

    close(server_fd);
    return 0;
}
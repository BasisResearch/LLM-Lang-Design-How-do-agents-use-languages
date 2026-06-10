#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <regex.h>
#include <pthread.h>
#include <stdbool.h>
#include <ctype.h>
#include <uuid/uuid.h>
#include <strings.h>  // for strcasecmp and strcasestr
#include <errno.h>  // for errno

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
    char password_hash[256]; // We'll just store original password for this exercise
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
    uuid_generate_random(uuid_bin);  // More secure than time-based
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
        return NULL; // User already exists
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

// JSON utilities for building responses
void json_start_object(char *buffer, size_t *offset, size_t max_size) {
    snprintf(buffer + *offset, max_size - *offset, "{");
    (*offset)++;
}

void json_end_object(char *buffer, size_t *offset, size_t max_size) {
    if (*offset > 0 && *(buffer + *offset - 1) == ',') {
        // Remove a trailing comma if we had one 
        (*offset)--;
        snprintf(buffer + *offset, max_size - *offset, "}");
    } else {
        snprintf(buffer + *offset, max_size - *offset, "}");
    }
    (*offset)++;
}

void json_start_array(char *buffer, size_t *offset, size_t max_size) {
    snprintf(buffer + *offset, max_size - *offset, "[");
    (*offset)++;
}

void json_end_array(char *buffer, size_t *offset, size_t max_size) {
    if (*offset > 0 && *(buffer + *offset - 1) == ',') {
        // Remove a trailing comma if we had one
        (*offset)--;
        snprintf(buffer + *offset, max_size - *offset, "]");
    } else {
        snprintf(buffer + *offset, max_size - *offset, "]");
    }
    (*offset)++;
}

void json_add_string(char *buffer, size_t *offset, size_t max_size, const char *key, const char *value) {
    if (strlen(value) > 0) {
        int written = snprintf(buffer + *offset, max_size - *offset, "\"%s\":\"%s\",", key, value);
        *offset += written;
    } else {
        int written = snprintf(buffer + *offset, max_size - *offset, "\"%s\":\"\",", key);
        *offset += written;
    }
}

void json_add_int(char *buffer, size_t *offset, size_t max_size, const char *key, int value) {
    int written = snprintf(buffer + *offset, max_size - *offset, "\"%s\":%d,", key, value);
    *offset += written;
}

void json_add_bool(char *buffer, size_t *offset, size_t max_size, const char *key, bool value) {
    int written = snprintf(buffer + *offset, max_size - *offset, "\"%s\":%s,", key, value ? "true" : "false");
    *offset += written;
}

int json_create_error(char *buffer, size_t max_size, const char *message) {
    return snprintf(buffer, max_size, "{\"error\":\"%s\"}", message);
}

// HTTP response helpers
void send_response(int client_socket, int status_code, const char *body, size_t body_len, const char *headers) {
    char response[8192];  // Increase buffer size to support larger responses
    int offset = 0;
    
    // Create response status line
    offset = snprintf(response, sizeof(response),
                     "HTTP/1.1 %d %s\r\n",
                     status_code,
                     status_code == 200 ? "OK" :
                     status_code == 201 ? "Created" :
                     status_code == 204 ? "No Content" :
                     status_code == 400 ? "Bad Request" :
                     status_code == 401 ? "Unauthorized" :
                     status_code == 404 ? "Not Found" :
                     status_code == 405 ? "Method Not Allowed" :
                     status_code == 409 ? "Conflict" :
                     "OK");
    
    // Add custom headers if available
    if (headers) {
        offset += snprintf(response + offset, sizeof(response) - offset, "%s", headers);
    } else {
        // Default headers
        offset += snprintf(response + offset, sizeof(response) - offset,
                          "Access-Control-Allow-Origin: *\r\n"
                          "Content-Type: application/json\r\n"
                          "Connection: close\r\n");                        
    }
    
    // For 204 No Content don't send a body or Content-Length header
    if (status_code == 204) {
        offset += snprintf(response + offset, sizeof(response) - offset, "\r\n");
    } else {
        offset += snprintf(response + offset, sizeof(response) - offset,
                          "Content-Length: %zu\r\n\r\n", body_len);
        memcpy(response + offset, body, body_len);
        offset += body_len;
    }
    
    send(client_socket, response, offset, 0);
}

// Helper to find request body without changing original buffer
const char* extract_request_body(const char *request, char *headers_only, size_t max_header_size) {
    const char *body_start = strstr(request, "\r\n\r\n");
    if (body_start) {
        body_start += 4;  // Skip over "\r\n\r\n"
        if (headers_only) {
            size_t header_len = body_start - request;
            strncpy(headers_only, request, header_len > max_header_size-1 ? max_header_size-1 : header_len);
            headers_only[header_len > max_header_size-1 ? max_header_size-1 : header_len] = 0;
        }
        return body_start;
    } else {
        // Check for just double newline (less common)
        const char *alt_body_start = strstr(request, "\n\n");
        if (alt_body_start) {
            alt_body_start += 2;  // Skip over "\n\n"
            if (headers_only) {
                size_t header_len = alt_body_start - request;
                strncpy(headers_only, request, header_len > max_header_size-1 ? max_header_size-1 : header_len);
                headers_only[header_len > max_header_size-1 ? max_header_size-1 : header_len] = 0;
            }
            return alt_body_start;
        }
    }
    if (headers_only) {
        strncpy(headers_only, request, max_header_size-1);
        headers_only[max_header_size-1] = 0;
    }
    return NULL;
}

bool parse_json_field(const char *json, const char *field, char *output, size_t out_len) {
    if (!json || !field || !output || out_len == 0) {
        return false;
    }
    
    char search_pattern[512];
    snprintf(search_pattern, sizeof(search_pattern), "\"%s\":", field);
    
    const char *field_pos = strstr(json, search_pattern);
    if (!field_pos) {
        return false;
    }
    
    // Move after the colon and whitespace
    field_pos += strlen(search_pattern);
    while (*field_pos == ' ' || *field_pos == '\t') field_pos++;
    
    if (*field_pos == '"') {
        // Handle string value
        field_pos++;  // Skip opening quote
        char *dst = output;
        size_t copied = 0;
        
        while (*field_pos && *field_pos != '"' && copied < out_len - 1) {
            if (*field_pos == '\\' && *(field_pos+1) != '\0') {
                if (*(field_pos+1) == '"') {
                    *dst++ = '"';  // Unescape quote
                    field_pos += 2;
                } else {
                    *dst++ = '\\';  // Preserve other escape sequences
                    *dst++ = *(++field_pos);
                    field_pos++;
                }
            } else {
                *dst++ = *field_pos++;
                copied++;
            }
        }
        *dst = '\0';
        return strlen(output) > 0;  // Return true only if something was copied
    } else {
        // Handle non-string value (number, boolean, null)
        char *dst = output;
        size_t copied = 0;
        
        while (*field_pos && 
               *field_pos != ',' && *field_pos != '}' && *field_pos != ']' &&
               copied < out_len - 1) {
            *dst++ = *field_pos++;
            copied++;
        }
        
        // Remove trailing spaces
        while (copied > 0 && (isspace(dst[-1]) || dst[-1] == ',')) {
            dst--;
            copied--;
        }
        *dst = '\0';
        return strlen(output) > 0;  // Return true only if something was captured
    }
}

char* extract_cookie_value(const char *headers, const char *cookie_name) {
    static char cookie_value[256];
    cookie_value[0] = '\0';

    // Find Cookie: header (case insensitive)
    const char *cookie_header = strcasestr(headers, "Cookie:") ? strcasestr(headers, "Cookie:") : strcasestr(headers, "cookie:");
    if (!cookie_header) {
        return NULL;
    }

    const char *colon_pos = strchr(cookie_header, ':');
    if (!colon_pos) return NULL;

    const char *cookie_data_start = colon_pos + 1;
    // Skip whitespace after the colon
    while (*cookie_data_start == ' ') cookie_data_start++;

    // Create pattern for looking for session_id=
    char search_key[260];
    snprintf(search_key, sizeof(search_key), "%s=", cookie_name);

    const char *cookie_found = strstr(cookie_data_start, search_key);
    if (!cookie_found) return NULL;

    cookie_found += strlen(search_key);

    // Find the end of this cookie value (next semicolon or end of cookie data)
    const char *cookie_end = strchr(cookie_found, ';');
    size_t val_len;
    if (cookie_end) {
        val_len = cookie_end - cookie_found;
    } else {
        // No semicolon, means end of the string 
        val_len = strlen(cookie_found);
    }

    if (val_len >= sizeof(cookie_value)) val_len = sizeof(cookie_value) - 1;
    strncpy(cookie_value, cookie_found, val_len);
    cookie_value[val_len] = '\0';

    // Trim any trailing whitespace
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

bool authenticate_user(int client_socket, const char *request_headers) {
    char *session_token = extract_cookie_value(request_headers, "session_id");
    if (!session_token) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Authentication required");
        send_response(client_socket, 401, response_buffer, response_len, NULL);
        return false;
    }
    
    int user_id = get_user_by_session(session_token);
    if (user_id == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Authentication required");
        send_response(client_socket, 401, response_buffer, response_len, NULL);
        return false;
    }
    
    return true;
}

// Endpoint handlers
void handle_register(int client_socket, const char *body) {
    char username[51] = {0};
    char password[129] = {0};
    
    // Extract username and password from body
    if (!parse_json_field(body, "username", username, sizeof(username))) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Missing username");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    if (!parse_json_field(body, "password", password, sizeof(password))) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Missing password");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    if (!is_valid_username(username)) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Invalid username");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    if (get_user_by_username(username) != -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Username already exists");
        send_response(client_socket, 409, response_buffer, response_len, NULL);
        return;
    }
    
    if (strlen(password) < MIN_PASSWORD_LENGTH) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Password too short");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    User *new_user = add_user(username, password);
    if (!new_user) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Failed to create user");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    // Send success response (201 Created)
    char response_buffer[512];
    size_t offset = 0;
    json_start_object(response_buffer, &offset, sizeof(response_buffer));
    json_add_int(response_buffer, &offset, sizeof(response_buffer), "id", new_user->id);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "username", new_user->username);
    // Remove trailing comma and close object
    if (offset > 0 && response_buffer[offset - 1] == ',') {
        response_buffer[offset - 1] = '}';
    } else {
        response_buffer[offset++] = '}';
    }
    response_buffer[offset] = '\0';
    
    send_response(client_socket, 201, response_buffer, offset, NULL);
}

void handle_login(int client_socket, const char *body) {
    char username[51] = {0};
    char password[129] = {0};
    
    if (!parse_json_field(body, "username", username, sizeof(username))) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Missing username");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    } 
    if (!parse_json_field(body, "password", password, sizeof(password))) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Missing password");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    int user_idx = get_user_by_username(username);
    
    if (user_idx == -1 || strcmp(users[user_idx].password_hash, password) != 0) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Invalid credentials");
        send_response(client_socket, 401, response_buffer, response_len, NULL);
        return;
    }
    
    // Generate and store new session
    pthread_mutex_lock(&global_mutex);
    
    if (session_count < MAX_SESSIONS) {
        char* session_token = generate_uuid();
        strcpy(sessions[session_count].session_token, session_token);
        sessions[session_count].user_id = users[user_idx].id;
        session_count++;
        
        // Copy session token to local variable before releasing lock
        char session_token_copy[37];
        strcpy(session_token_copy, sessions[session_count-1].session_token);
        
        pthread_mutex_unlock(&global_mutex);
        
        // Create Set-Cookie header
        char headers[512];
        snprintf(headers, sizeof(headers), 
                 "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\nAccess-Control-Allow-Origin: *\r\nContent-Type: application/json\r\nConnection: close\r\n",
                 session_token_copy);
        
        // Send success response
        User *user = &users[user_idx];
        char response_buffer[512];
        size_t offset = 0;
        json_start_object(response_buffer, &offset, sizeof(response_buffer));
        json_add_int(response_buffer, &offset, sizeof(response_buffer), "id", user->id);
        json_add_string(response_buffer, &offset, sizeof(response_buffer), "username", user->username);
        
        // Remove trailing comma and close object
        if (offset > 0 && response_buffer[offset - 1] == ',') {
            response_buffer[offset - 1] = '}';
        } else {
            response_buffer[offset++] = '}';
        }
        response_buffer[offset] = '\0';
        
        send_response(client_socket, 200, response_buffer, offset, headers);
    } else {
        pthread_mutex_unlock(&global_mutex);
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Too many active sessions");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
    }
}

void handle_logout(int client_socket, const char *headers) {
    if (!authenticate_user(client_socket, headers)) {
        return;  // Error response already sent by authenticate_user
    }
    
    char *session_token = extract_cookie_value(headers, "session_id");
    if (!session_token) {
        return;  // Shouldn't happen since authenticate_user checks above
    }
    
    // Invalidate session by removing it
    pthread_mutex_lock(&global_mutex);
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].session_token, session_token) == 0) {
            // Move the last session to this position to fill the gap
            if (i < session_count - 1) {
                sessions[i] = sessions[session_count - 1];
            }
            session_count--;
            break;
        }
    }
    pthread_mutex_unlock(&global_mutex);
    
    // Send success response
    send_response(client_socket, 200, "{}", 2, NULL);
}

void handle_me(int client_socket, const char *header) {
    if (!authenticate_user(client_socket, header)) {
        return; // Error response already sent by authenticate_user
    }
    
    char *session_token = extract_cookie_value(header, "session_id");
    if (!session_token) {
        return; // Should not happen
    }
    
    int user_id = get_user_by_session(session_token);
    if (user_id == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Internal error");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    int user_idx = get_user_index_by_id(user_id);
    if (user_idx == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "User not found");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    User *user = &users[user_idx];
    
    // Format response
    char response_buffer[512];
    size_t offset = 0;
    json_start_object(response_buffer, &offset, sizeof(response_buffer));
    json_add_int(response_buffer, &offset, sizeof(response_buffer), "id", user->id);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "username", user->username);
    // Remove trailing comma and close object
    if (offset > 0 && response_buffer[offset - 1] == ',') {
        response_buffer[offset - 1] = '}';
    } else {
        response_buffer[offset++] = '}';
    }
    response_buffer[offset] = '\0';
    
    send_response(client_socket, 200, response_buffer, offset, NULL);
}

void handle_change_password(int client_socket, const char *header, const char *body) {
    if (!authenticate_user(client_socket, header)) {
        return; // Error response already sent by authenticate_user
    }
    
    char *session_token = extract_cookie_value(header, "session_id");
    if (!session_token) {
        return; // Should not happen
    }
    
    int user_id = get_user_by_session(session_token);
    if (user_id == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Internal error");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    int user_idx = get_user_index_by_id(user_id);
    if (user_idx == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "User not found");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    User *user = &users[user_idx];
    
    char old_password[129] = {0};
    char new_password[129] = {0};
    
    if (!parse_json_field(body, "old_password", old_password, sizeof(old_password))) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Missing old password");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    if (!parse_json_field(body, "new_password", new_password, sizeof(new_password))) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Missing new password");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    if (strcmp(user->password_hash, old_password) != 0) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Invalid credentials");
        send_response(client_socket, 401, response_buffer, response_len, NULL);
        return;
    }
    
    if (strlen(new_password) < MIN_PASSWORD_LENGTH) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Password too short");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    strncpy(user->password_hash, new_password, sizeof(user->password_hash) - 1);
    user->password_hash[sizeof(user->password_hash) - 1] = '\0';
    
    // Send success response - empty object
    send_response(client_socket, 200, "{}", 2, NULL);
}

void handle_get_todos(int client_socket, const char *header) {
    if (!authenticate_user(client_socket, header)) {
        return; // Error response already sent by authenticate_user
    }
    
    char *session_token = extract_cookie_value(header, "session_id");
    if (!session_token) {
        return; // Should not happen
    }
    
    int user_id = get_user_by_session(session_token);
    if (user_id == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Internal error");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    int user_idx = get_user_index_by_id(user_id);
    if (user_idx == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "User not found");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    User *user = &users[user_idx];
    
    // Format response (JSON array of todos)
    char response_buffer[BUFFER_SIZE * 4];  // Bigger buffer for multiple todos
    size_t offset = 0;
    json_start_array(response_buffer, &offset, sizeof(response_buffer));
    
    for (int i = 0; i < user->num_todos; i++) {
        Todo *todo = user->todos[i];
        
        json_start_object(response_buffer, &offset, sizeof(response_buffer));
        json_add_int(response_buffer, &offset, sizeof(response_buffer), "id", todo->id);
        json_add_string(response_buffer, &offset, sizeof(response_buffer), "title", todo->title);
        json_add_string(response_buffer, &offset, sizeof(response_buffer), "description", todo->description);
        json_add_bool(response_buffer, &offset, sizeof(response_buffer), "completed", todo->completed);
        json_add_string(response_buffer, &offset, sizeof(response_buffer), "created_at", todo->created_at);
        json_add_string(response_buffer, &offset, sizeof(response_buffer), "updated_at", todo->updated_at);
        
        // Remove trailing comma and close object
        if (offset > 0 && response_buffer[offset - 1] == ',') {
            response_buffer[offset - 1] = '}';
        } else {
            response_buffer[offset++] = '}';
        }
        
        if (i < user->num_todos - 1) {
            response_buffer[offset++] = ',';
        }
    }
    
    // Close array
    if (offset > 0 && response_buffer[offset - 1] == ',') {
        response_buffer[offset - 1] = ']';
    } else {
        response_buffer[offset++] = ']';
    }
    response_buffer[offset] = '\0';
    
    send_response(client_socket, 200, response_buffer, offset, NULL);
}

void handle_create_todo(int client_socket, const char *header, const char *body) {
    if (!authenticate_user(client_socket, header)) {
        return; // Error response already sent by authenticate_user
    }
    
    char *session_token = extract_cookie_value(header, "session_id");
    if (!session_token) {
        return; // Should not happen
    }
    
    int user_id = get_user_by_session(session_token);
    if (user_id == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Internal error");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    int user_idx = get_user_index_by_id(user_id);
    if (user_idx == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "User not found");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    char title[1024] = {0};
    char description[2048] = {0};
    
    // Parse title (required) and description (optional)
    if (!parse_json_field(body, "title", title, sizeof(title))) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Title is required");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    if (strlen(title) == 0) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Title is required");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    // Parse description, defaulting to empty if not provided
    parse_json_field(body, "description", description, sizeof(description));
    
    User *user = &users[user_idx];
    
    // Check if user has reached todo limit
    pthread_mutex_lock(&global_mutex);
    if (user->num_todos >= MAX_TODOS_PER_USER) {
        pthread_mutex_unlock(&global_mutex);
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "User has too many todos");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    // Create new todo
    Todo *new_todo = malloc(sizeof(Todo));
    if (!new_todo) {
        pthread_mutex_unlock(&global_mutex);
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Server error creating todo");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    new_todo->id = next_todo_id++;
    strncpy(new_todo->title, title, sizeof(new_todo->title) - 1);
    new_todo->title[sizeof(new_todo->title) - 1] = '\0';
    
    strncpy(new_todo->description, description, sizeof(new_todo->description) - 1);
    new_todo->description[sizeof(new_todo->description) - 1] = '\0';
    
    new_todo->completed = false;
    
    // Record timestamps
    get_current_timestamp(new_todo->created_at, sizeof(new_todo->created_at));
    get_current_timestamp(new_todo->updated_at, sizeof(new_todo->updated_at));
    
    // Add to user's todo list
    user->todos[user->num_todos] = new_todo;
    user->num_todos++;
    user->todos[user->num_todos] = NULL; // Ensure proper termination
    
    pthread_mutex_unlock(&global_mutex);
    
    // Format response - return newly created todo object
    char response_buffer[BUFFER_SIZE];
    size_t offset = 0;
    json_start_object(response_buffer, &offset, sizeof(response_buffer));
    json_add_int(response_buffer, &offset, sizeof(response_buffer), "id", new_todo->id);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "title", new_todo->title);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "description", new_todo->description);
    json_add_bool(response_buffer, &offset, sizeof(response_buffer), "completed", new_todo->completed);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "created_at", new_todo->created_at);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "updated_at", new_todo->updated_at);
    
    // Remove trailing comma and close object
    if (offset > 0 && response_buffer[offset - 1] == ',') {
        response_buffer[offset - 1] = '}';
    } else {
        response_buffer[offset++] = '}';
    }
    response_buffer[offset] = '\0';
    
    send_response(client_socket, 201, response_buffer, offset, NULL);
}

void handle_get_todo(int client_socket, const char *header, const char *url_path) {
    if (!authenticate_user(client_socket, header)) {
        return; // Error response already sent by authenticate_user
    }
    
    char *session_token = extract_cookie_value(header, "session_id");
    int user_id = get_user_by_session(session_token);
    if (user_id == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Authentication required");
        send_response(client_socket, 401, response_buffer, response_len, NULL);
        return;
    }
    
    // Extract todo ID from URL path (after "/todos/")
    const char *todo_path = strstr(url_path, "/todos/");
    if (!todo_path) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Invalid URL");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    todo_path += 7; // Skip past '/todos/'
    // Extract digits at the beginning of the remaining path (until slash, question mark, or end)
    char id_str[32] = {0};
    size_t idx = 0;
    while (todo_path[idx] && isdigit(todo_path[idx]) && idx < sizeof(id_str) - 1) {
        id_str[idx] = todo_path[idx];
        idx++;
    }
    
    int todo_id = atoi(id_str);
    
    if (todo_id <= 0) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Invalid todo ID");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    Todo *found_todo = find_todo_by_id(user_id, todo_id);
    if (!found_todo) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Todo not found");
        send_response(client_socket, 404, response_buffer, response_len, NULL);
        return;
    }
    
    // Format response - return the found todo
    char response_buffer[BUFFER_SIZE];
    size_t offset = 0;
    json_start_object(response_buffer, &offset, sizeof(response_buffer));
    json_add_int(response_buffer, &offset, sizeof(response_buffer), "id", found_todo->id);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "title", found_todo->title);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "description", found_todo->description);
    json_add_bool(response_buffer, &offset, sizeof(response_buffer), "completed", found_todo->completed);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "created_at", found_todo->created_at);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "updated_at", found_todo->updated_at);
    
    // Remove trailing comma and close object
    if (offset > 0 && response_buffer[offset - 1] == ',') {
        response_buffer[offset - 1] = '}';
    } else {
        response_buffer[offset++] = '}';
    }
    response_buffer[offset] = '\0';
    
    send_response(client_socket, 200, response_buffer, offset, NULL);
}

void handle_update_todo(int client_socket, const char *header, const char *url_path, const char *body) {
    if (!authenticate_user(client_socket, header)) {
        return; // Error response already sent by authenticate_user
    }
    
    char *session_token = extract_cookie_value(header, "session_id");
    int user_id = get_user_by_session(session_token);
    if (user_id == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Authentication required");
        send_response(client_socket, 401, response_buffer, response_len, NULL);
        return;
    }
    
    // Extract todo ID from URL path
    const char *todo_path = strstr(url_path, "/todos/");
    if (!todo_path) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Invalid URL");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    todo_path += 7; // Skip past '/todos/'
    // Extract digits at the beginning of the remaining path (until slash, question mark, or end)
    char id_str[32] = {0};
    size_t idx = 0;
    while (todo_path[idx] && isdigit(todo_path[idx]) && idx < sizeof(id_str) - 1) {
        id_str[idx] = todo_path[idx];
        idx++;
    }
    
    int todo_id = atoi(id_str);
    
    if (todo_id <= 0) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Invalid todo ID");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    Todo *todo_to_update = find_todo_by_id(user_id, todo_id);
    if (!todo_to_update) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Todo not found");
        send_response(client_socket, 404, response_buffer, response_len, NULL);
        return;
    }
    
    // Parse fields from request body (only those provided should be updated)
    char title[1024] = {0};
    char description[2048] = {0};
    char completed_str[16] = {0};  // To hold boolean value
    
    bool title_provided = parse_json_field(body, "title", title, sizeof(title));
    bool description_provided = parse_json_field(body, "description", description, sizeof(description));
    bool completed_provided = parse_json_field(body, "completed", completed_str, sizeof(completed_str));
    
    // Validate title if provided
    if (title_provided && strlen(title) == 0) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Title is required");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    // Update fields if they were provided in the request
    if (title_provided) {
        strncpy(todo_to_update->title, title, sizeof(todo_to_update->title) - 1);
        todo_to_update->title[sizeof(todo_to_update->title) - 1] = '\0';
    }
    
    if (description_provided) {
        strncpy(todo_to_update->description, description, sizeof(todo_to_update->description) - 1);
        todo_to_update->description[sizeof(todo_to_update->description) - 1] = '\0';
    }
    
    if (completed_provided) {
        // Convert string to bool, treating "true"/"1" as true, everything else as false
        todo_to_update->completed = 
            (strcasecmp(completed_str, "true") == 0) || 
            (strcasecmp(completed_str, "1") == 0) || 
            (strlen(completed_str) > 0 && strcmp(completed_str, "0") != 0 && strcasecmp(completed_str, "false") != 0);
    }
    
    // Update timestamp
    get_current_timestamp(todo_to_update->updated_at, sizeof(todo_to_update->updated_at));
    
    // Format response - return updated todo object
    char response_buffer[BUFFER_SIZE];
    size_t offset = 0;
    json_start_object(response_buffer, &offset, sizeof(response_buffer));
    json_add_int(response_buffer, &offset, sizeof(response_buffer), "id", todo_to_update->id);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "title", todo_to_update->title);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "description", todo_to_update->description);
    json_add_bool(response_buffer, &offset, sizeof(response_buffer), "completed", todo_to_update->completed);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "created_at", todo_to_update->created_at);
    json_add_string(response_buffer, &offset, sizeof(response_buffer), "updated_at", todo_to_update->updated_at);
    
    // Remove trailing comma and close object
    if (offset > 0 && response_buffer[offset - 1] == ',') {
        response_buffer[offset - 1] = '}';
    } else {
        response_buffer[offset++] = '}';
    }
    response_buffer[offset] = '\0';
    
    send_response(client_socket, 200, response_buffer, offset, NULL);
}

void handle_delete_todo(int client_socket, const char *header, const char *url_path) {
    if (!authenticate_user(client_socket, header)) {
        return; // Error response already sent by authenticate_user
    }
    
    char *session_token = extract_cookie_value(header, "session_id");
    int user_id = get_user_by_session(session_token);
    if (user_id == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Authentication required");
        send_response(client_socket, 401, response_buffer, response_len, NULL);
        return;
    }
    
    // Extract todo ID from URL path
    const char *todo_path = strstr(url_path, "/todos/");
    if (!todo_path) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Invalid URL");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    todo_path += 7; // Skip past '/todos/'
    // Extract digits at the beginning of the remaining path (until slash, question mark, or end)
    char id_str[32] = {0};
    size_t idx = 0;
    while (todo_path[idx] && isdigit(todo_path[idx]) && idx < sizeof(id_str) - 1) {
        id_str[idx] = todo_path[idx];
        idx++;
    }
    
    int todo_id = atoi(id_str);
    
    if (todo_id <= 0) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Invalid todo ID");
        send_response(client_socket, 400, response_buffer, response_len, NULL);
        return;
    }
    
    // Find user
    int user_idx = get_user_index_by_id(user_id);
    if (user_idx == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "User not found");
        send_response(client_socket, 500, response_buffer, response_len, NULL);
        return;
    }
    
    User *user = &users[user_idx];
    
    // Find the todo in the user's todo list
    int todo_idx = get_todo_index_for_user(user, todo_id);
    if (todo_idx == -1) {
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Todo not found");
        send_response(client_socket, 404, response_buffer, response_len, NULL);
        return;
    }
    
    // Free todo memory
    free(user->todos[todo_idx]);
    
    // Shift remaining todos to fill the gap
    pthread_mutex_lock(&global_mutex);
    for (int i = todo_idx; i < user->num_todos - 1; i++) {
        user->todos[i] = user->todos[i + 1];
    }
    user->num_todos--;
    user->todos[user->num_todos] = NULL; // Ensure proper termination
    pthread_mutex_unlock(&global_mutex);
    
    // Send success response - 204 No Content
    send_response(client_socket, 204, NULL, 0, NULL);
}

void process_request(int client_socket) {
    char buffer[BUFFER_SIZE];
    memset(buffer, 0, sizeof(buffer));
    
    // Receive request data
    ssize_t bytes_received = recv(client_socket, buffer, sizeof(buffer) - 1, 0);
    if (bytes_received <= 0) {
        close(client_socket);
        return;
    }
    
    buffer[bytes_received] = '\0';
    
    // Parse first line of request to get method, URL path and version
    char method[16] = {0}, url_path[256] = {0}, http_version[64] = {0};
    int n = sscanf(buffer, "%15s %255s %63s", method, url_path, http_version);
    if (n != 3) {
        close(client_socket);
        return;
    }
    
    // Separate headers and body
    char headers_only[BUFFER_SIZE];
    const char *body_ptr = extract_request_body(buffer, headers_only, sizeof(headers_only));
    if (body_ptr == NULL) {
        body_ptr = "";  // No body
    }
    
    // Route requests based on method and path
    if (strcmp(method, "POST") == 0) {
        if (strcmp(url_path, "/register") == 0) {
            handle_register(client_socket, body_ptr);
        } else if (strcmp(url_path, "/login") == 0) {
            handle_login(client_socket, body_ptr);
        } else if (strcmp(url_path, "/logout") == 0) {
            handle_logout(client_socket, headers_only);
        } else if (strcmp(url_path, "/password") == 0) {
            handle_change_password(client_socket, headers_only, body_ptr);
        } else if (strcmp(url_path, "/todos") == 0) {
            handle_create_todo(client_socket, headers_only, body_ptr);
        }  
    } else if (strcmp(method, "GET") == 0) {
        if (strcmp(url_path, "/me") == 0) {
            handle_me(client_socket, headers_only);
        } else if (strcmp(url_path, "/todos") == 0) {
            handle_get_todos(client_socket, headers_only);
        } else if (strncmp(url_path, "/todos/", 7) == 0) { // URLs starting with "/todos/"
            handle_get_todo(client_socket, headers_only, url_path);
        }
    } else if (strcmp(method, "PUT") == 0) {
        if (strncmp(url_path, "/todos/", 7) == 0) { // URLs starting with "/todos/"
            handle_update_todo(client_socket, headers_only, url_path, body_ptr);
        } else if (strcmp(url_path, "/password") == 0) {
            handle_change_password(client_socket, headers_only, body_ptr);
        }
    } else if (strcmp(method, "DELETE") == 0) {
        if (strncmp(url_path, "/todos/", 7) == 0) { // URLs starting with "/todos/"
            handle_delete_todo(client_socket, headers_only, url_path);
        }
    } else if (strcmp(method, "OPTIONS") == 0) {
        char cors_headers[] = 
            "Access-Control-Allow-Origin: *\r\n"
            "Access-Control-Allow-Methods: GET,POST,PUT,DELETE,OPTIONS\r\n"
            "Access-Control-Allow-Headers: Content-Type, Cookie\r\n"
            "Content-Length: 0\r\n"
            "Connection: close\r\n\r\n";
        send(client_socket, "HTTP/1.1 200 OK\r\n", 17, 0);
        send(client_socket, cors_headers, strlen(cors_headers), 0);
    } else {
        // Method not allowed - unrecognized method
        char response_buffer[512];
        int response_len = json_create_error(response_buffer, sizeof(response_buffer), "Method not allowed");
        send_response(client_socket, 405, response_buffer, response_len, NULL);
    }
    
    close(client_socket);
}

int main(int argc, char *argv[]) {
    int server_fd, port, opt = 1;
    struct sockaddr_in address;
    int addrlen = sizeof(address);
    
    // Parse command line arguments
    port = 8080;  // Default port
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
            i++;  // Skip next argument since it's used
        }
    }
    
    // Initialize global variables
    memset(users, 0, sizeof(users));
    memset(sessions, 0, sizeof(sessions));
    
    // Creating socket file descriptor
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }
    
    // Set socket options to reuse addresses
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        exit(EXIT_FAILURE);
    }
    
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);
    
    // Bind the socket to the address
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }
    
    // Start listening with queue depth of 10
    if (listen(server_fd, 10) < 0) {
        perror("listen failed");
        exit(EXIT_FAILURE);
    }
    
    printf("Server running on port %d\n", port);
    
    // Main event loop - accept and service connections
    while(1) {
        int client_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen);
        
        if (client_socket < 0) {
            perror("accept failed");
            continue;
        }
        
        process_request(client_socket);
    }
    
    close(server_fd);
    return 0;
}
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <ctype.h>
#include <uuid/uuid.h>
#include <pthread.h>
#include <regex.h>
#include <stdint.h>
#include <getopt.h>

// Additional includes for strcasecmp and similar functions
#include <strings.h>

// Define max values
#define MAX_USERS 1000
#define MAX_TODOS_PER_USER 1000
#define MAX_SESSIONS 1000
#define BUFFER_SIZE 8192
#define USERNAME_MAX_LEN 50
#define PASSWORD_MIN_LEN 8

// Data structures
typedef struct {
    int id;
    char username[USERNAME_MAX_LEN + 1];
    char password_hash[65]; // SHA-256 hex string
} User;

typedef struct {
    int id;
    char title[256];
    char description[1024];
    int completed;
    char created_at[21];  // YYYY-MM-DDTHH:MM:SSZ\0
    char updated_at[21];  // YYYY-MM-DDTHH:MM:SSZ\0
} Todo;

typedef struct {
    char token[37];       // UUID string length
    int user_id;
    int active;
} Session;

// Global variables
User users[MAX_USERS];
Todo todos[MAX_USERS * MAX_TODOS_PER_USER];
Session sessions[MAX_SESSIONS];
int user_count = 0;
int todo_count = 0;
int session_count = 0;
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

// Forward declarations
int validate_username(const char* username);
int validate_password(const char* password);
int find_user_by_username(const char* username);
void generate_timestamp(char* buffer);
int get_user_id_from_session(const char* session_token);
char* find_header_value(char* headers, const char* header_name);
int parse_json_field(const char* json, const char* field, char* buffer, size_t buf_size);
char* my_strcasestr(const char* haystack, const char* needle);

// Helper function since strcasestr might not be available on all systems
char* my_strcasestr(const char* haystack, const char* needle) {
    const char* h;
    const char* n;
    const char* start;
    
    if (!haystack || !needle) return NULL;
    
    for (start = haystack; *start != '\0'; start++) {
        for (h = start, n = needle; *h && *n && tolower(*h) == tolower(*n); h++, n++);
        
        if (!*n) return (char*)start;
    }
    
    return NULL;
}

// Generate ISO 8601 timestamp
void generate_timestamp(char* buffer) {
    time_t rawtime;
    struct tm *timeinfo;
    
    time(&rawtime);
    timeinfo = gmtime(&rawtime);
    strftime(buffer, 21, "%Y-%m-%dT%H:%M:%SZ", timeinfo);
}

// Validate username: 3-50 chars, alphanumeric and underscore only
int validate_username(const char* username) {
    if (!username) return 0;
    size_t len = strlen(username);
    if (len < 3 || len > USERNAME_MAX_LEN) return 0;
    
    for (size_t i = 0; i < len; i++) {
        if (!isalnum(username[i]) && username[i] != '_') {
            return 0;
        }
    }
    return 1;
}

// Validate password: minimum 8 characters
int validate_password(const char* password) {
    if (!password || strlen(password) < PASSWORD_MIN_LEN) {
        return 0;
    }
    return 1;
}

// Find user by username (case sensitive)
int find_user_by_username(const char* username) {
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            return i;
        }
    }
    return -1;
}

// Simple "hash" for password storage (just store the actual password for simplicity in this implementation)
void hash_password(const char* plain_password, char* hashed_output) {
    strcpy(hashed_output, plain_password); // In a real app, you'd use proper hashing
}

// Check if password matches (compare directly since we're not using real hashing here)
int check_password(const char* input_password, const char* stored_hash) {
    return strcmp(input_password, stored_hash) == 0;
}

// Get user ID from session token
int get_user_id_from_session(const char* session_token) {
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < session_count; i++) {
        if (sessions[i].active && strcmp(sessions[i].token, session_token) == 0) {
            pthread_mutex_unlock(&mutex);
            return sessions[i].user_id;
        }
    }
    pthread_mutex_unlock(&mutex);
    return -1;  // Invalid or inactive session
}

// Generate a session token
char* generate_session_token() {
    static char token[37];
    uuid_t uuid_bin;
    uuid_generate(uuid_bin);
    uuid_unparse_lower(uuid_bin, token);
    return token;
}

// Create a new session
char* create_session(int user_id) {
    pthread_mutex_lock(&mutex);
    if (session_count >= MAX_SESSIONS) {
        pthread_mutex_unlock(&mutex);
        return NULL;
    }
    
    strncpy(sessions[session_count].token, generate_session_token(), sizeof(sessions[session_count].token)-1);
    sessions[session_count].user_id = user_id;
    sessions[session_count].active = 1;
    session_count++;
    
    pthread_mutex_unlock(&mutex);
    return (char*) &sessions[session_count-1].token;
}

// Invalidate a session
void invalidate_session(const char* token) {
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, token) == 0) {
            sessions[i].active = 0;
            break;
        }
    }
    pthread_mutex_unlock(&mutex);
}

// Find header value in HTTP headers
char* find_header_value(char* headers, const char* header_name) {
    char* pos = my_strcasestr(headers, header_name);
    if (!pos) return NULL;
    
    pos += strlen(header_name);
    while (*pos == ' ' || *pos == ':') pos++; // Skip colon and spaces
    
    char* end = pos;
    while (*end != '\n' && *end != '\r' && *end != '\0') end++;
    *end = '\0';
    
    return pos;
}

// Extract a field from JSON
int parse_json_field(const char* json, const char* field, char* buffer, size_t buf_size) {
    char pattern[256];
    snprintf(pattern, sizeof(pattern), "\"%s\":\\s*\"([^\"]+)\"", field);
    
    regex_t regex;
    regmatch_t matches[2];
    
    if (regcomp(&regex, pattern, REG_EXTENDED | REG_ICASE) != 0) {
        return 0;
    }
    
    if (regexec(&regex, json, 2, matches, 0) == 0) {
        size_t len = matches[1].rm_eo - matches[1].rm_so;
        len = len >= buf_size ? buf_size - 1 : len;
        strncpy(buffer, json + matches[1].rm_so, len);
        buffer[len] = '\0';
        regfree(&regex);
        return 1;
    }
    
    regfree(&regex);
    return 0;
}

// Extract boolean field from JSON - special function for bool because values aren't quoted
int parse_json_field_bool(const char* json, const char* field, int* value) {
    char pattern[256];
    snprintf(pattern, sizeof(pattern), "\"%s\":\\s*(true|false)", field);
    
    regex_t regex;
    regmatch_t matches[2];
    
    if (regcomp(&regex, pattern, REG_EXTENDED | REG_ICASE) != 0) {
        return 0;
    }
    
    if (regexec(&regex, json, 2, matches, 0) == 0) {
        char temp[10] = {0};
        size_t len = matches[1].rm_eo - matches[1].rm_so;
        if(len >= sizeof(temp)) len = sizeof(temp) - 1;
        strncpy(temp, json + matches[1].rm_so, len);
        
        if (strcasecmp(temp, "true") == 0) {
            *value = 1;
        } else if (strcasecmp(temp, "false") == 0) {
            *value = 0;
        } else {
            regfree(&regex);
            return 0;
        }
        
        regfree(&regex);
        return 1;
    }
    
    regfree(&regex);
    return 0;
}

// Extract integer field from JSON
int parse_json_int(const char* json, const char* field, long* value) {
    char pattern[256];
    snprintf(pattern, sizeof(pattern), "\"%s\":\\s*([0-9]+)", field);
    
    regex_t regex;
    regmatch_t matches[2];
    
    if (regcomp(&regex, pattern, REG_EXTENDED | REG_ICASE) != 0) {
        return 0;
    }
    
    if (regexec(&regex, json, 2, matches, 0) == 0) {
        char temp[32] = {0};
        size_t len = matches[1].rm_eo - matches[1].rm_so;
        len = len >= sizeof(temp) ? sizeof(temp) - 1 : len;
        strncpy(temp, json + matches[1].rm_so, len);
        
        *value = atol(temp);
        
        regfree(&regex);
        return 1;
    }
    
    regfree(&regex);
    return 0;
}

// Track todo ownership (in a more complete app, this would be a separate table)
// We'll store user_id with each todo index
int todo_ownerships[MAX_USERS * MAX_TODOS_PER_USER]; // maps todo index to user id

// Send JSON response
void send_json_response(int client_fd, int status_code, const char* json) {
    char response[BUFFER_SIZE];
    
    const char* status_text;
    switch(status_code) {
        case 200: status_text = "OK"; break;
        case 201: status_text = "Created"; break;
        case 204: status_text = "No Content"; break;
        case 400: status_text = "Bad Request"; break;
        case 401: status_text = "Unauthorized"; break;
        case 404: status_text = "Not Found"; break;
        case 409: status_text = "Conflict"; break;
        default: status_text = "Internal Server Error"; break;
    }
    
    snprintf(response, sizeof(response),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %lu\r\n"
        "\r\n"
        "%s",
        status_code,
        status_text,
        json ? strlen(json) : 0,
        json ? json : ""
    );
    
    send(client_fd, response, strlen(response), 0);
}

// Send simple response with custom header
void send_json_response_with_header(int client_fd, int status_code, const char* json, const char* header) {
    char response[BUFFER_SIZE * 2];
    
    const char* status_text;
    switch(status_code) {
        case 200: status_text = "OK"; break;
        case 201: status_text = "Created"; break;
        case 204: status_text = "No Content"; break;
        case 400: status_text = "Bad Request"; break;
        case 401: status_text = "Unauthorized"; break;
        case 404: status_text = "Not Found"; break;
        case 409: status_text = "Conflict"; break;
        default: status_text = "Internal Server Error"; break;
    }
    
    snprintf(response, sizeof(response),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %lu\r\n"
        "%s\r\n"
        "\r\n"
        "%s",
        status_code,
        status_text,
        json ? strlen(json) : 0,
        header ? header : "",
        json ? json : ""
    );
    
    send(client_fd, response, strlen(response), 0);
}

// Send no content (for 204 status)
void send_no_content(int client_fd) {
    const char* response = 
        "HTTP/1.1 204 No Content\r\n"
        "\r\n";
    
    send(client_fd, response, strlen(response), 0);
}

// Handle registration
void handle_register(int client_fd, char* post_data) {
    char username[USERNAME_MAX_LEN + 1] = {0};
    char password[256] = {0};
    
    // Parse JSON
    if (!parse_json_field(post_data, "username", username, sizeof(username))) {
        send_json_response(client_fd, 400, "{\"error\":\"Username is required\"}");
        return;
    }
    
    if (!parse_json_field(post_data, "password", password, sizeof(password))) {
        send_json_response(client_fd, 400, "{\"error\":\"Password is required\"}");
        return;
    }
    
    // Validate
    if (!validate_username(username)) {
        send_json_response(client_fd, 400, "{\"error\":\"Invalid username\"}");
        return;
    }
    
    if (!validate_password(password)) {
        send_json_response(client_fd, 400, "{\"error\":\"Password too short\"}");
        return;
    }
    
    pthread_mutex_lock(&mutex);
    if (find_user_by_username(username) != -1) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 409, "{\"error\":\"Username already exists\"}");
        return;
    }
    
    // Create user
    if (user_count >= MAX_USERS) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 500, "{\"error\":\"Server limit reached\"}");
        return;
    }
    
    users[user_count].id = user_count + 1; // IDs start at 1
    strcpy(users[user_count].username, username);
    hash_password(password, users[user_count].password_hash);
    
    char response[BUFFER_SIZE];
    snprintf(response, sizeof(response),
        "{\"id\":%d,\"username\":\"%s\"}",
        users[user_count].id, username);
    
    user_count++;
    pthread_mutex_unlock(&mutex);
    
    send_json_response(client_fd, 201, response);
}

// Handle login
void handle_login(int client_fd, char* post_data) {
    char username[USERNAME_MAX_LEN + 1] = {0};
    char password[256] = {0};
    
    // Parse JSON
    if (!parse_json_field(post_data, "username", username, sizeof(username))) {
        send_json_response(client_fd, 400, "{\"error\":\"Username is required\"}");
        return;
    }
    
    if (!parse_json_field(post_data, "password", password, sizeof(password))) {
        send_json_response(client_fd, 400, "{\"error\":\"Password is required\"}");
        return;
    }
    
    pthread_mutex_lock(&mutex);
    int user_idx = find_user_by_username(username);
    
    if (user_idx == -1 || !check_password(password, users[user_idx].password_hash)) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 401, "{\"error\":\"Invalid credentials\"}");
        return;
    }
    
    // Create session
    char* session_token = create_session(users[user_idx].id);
    if (!session_token) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 500, "{\"error\":\"Failed to create session\"}");
        return;
    }
    
    char cookie_header[256];
    snprintf(cookie_header, sizeof(cookie_header), 
             "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", session_token);
    
    char response[BUFFER_SIZE];
    snprintf(response, sizeof(response),
        "{\"id\":%d,\"username\":\"%s\"}",
        users[user_idx].id, username);
    
    pthread_mutex_unlock(&mutex);
    
    send_json_response_with_header(client_fd, 200, response, cookie_header);
}

// Handle logout
void handle_logout(int client_fd, const char* session_token) {
    if (!session_token) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    invalidate_session(session_token);
    send_json_response(client_fd, 200, "{}");
}

// Handle GET /me
void handle_me(int client_fd, const char* session_token) {
    if (!session_token) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    int user_id = get_user_id_from_session(session_token);
    if (user_id == -1) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    pthread_mutex_lock(&mutex);
    // Find user details
    int user_idx = -1;
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            user_idx = i;
            break;
        }
    }
    
    if (user_idx == -1) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    char response[BUFFER_SIZE];
    snprintf(response, sizeof(response),
        "{\"id\":%d,\"username\":\"%s\"}",
        users[user_idx].id, users[user_idx].username);
    
    pthread_mutex_unlock(&mutex);
    send_json_response(client_fd, 200, response);
}

// Handle password change
void handle_change_password(int client_fd, const char* session_token, char* post_data) {
    if (!session_token) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    int user_id = get_user_id_from_session(session_token);
    if (user_id == -1) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    char old_password[256] = {0};
    char new_password[256] = {0};
    
    // Parse JSON
    if (!parse_json_field(post_data, "old_password", old_password, sizeof(old_password))) {
        send_json_response(client_fd, 400, "{\"error\":\"Old password is required\"}");
        return;
    }
    
    if (!parse_json_field(post_data, "new_password", new_password, sizeof(new_password))) {
        send_json_response(client_fd, 400, "{\"error\":\"New password is required\"}");
        return;
    }
    
    pthread_mutex_lock(&mutex);
    int user_idx = -1;
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            user_idx = i;
            break;
        }
    }
    
    if (user_idx == -1 ||
        !check_password(old_password, users[user_idx].password_hash)) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 401, "{\"error\":\"Invalid credentials\"}");
        return;
    }
    
    if (!validate_password(new_password)) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 400, "{\"error\":\"Password too short\"}");
        return;
    }
    
    hash_password(new_password, users[user_idx].password_hash);
    pthread_mutex_unlock(&mutex);
    
    send_json_response(client_fd, 200, "{}");
}

// Handle GET /todos
void handle_get_todos(int client_fd, const char* session_token) {
    if (!session_token) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    int user_id = get_user_id_from_session(session_token);
    if (user_id == -1) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    char response[BUFFER_SIZE * MAX_TODOS_PER_USER * 2];
    size_t response_len = 0;
    
    pthread_mutex_lock(&mutex);
    
    response[response_len++] = '[';
    
    int first = 1;
    for (int i = 0; i < todo_count; i++) {
        if (todo_ownerships[i] == user_id) {  // Only send todos owned by this user
            if (!first) response[response_len++] = ',';
            first = 0;
            
            int result = snprintf(response + response_len, 
                                  sizeof(response) - response_len,
                "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
                todos[i].id, todos[i].title, todos[i].description,
                todos[i].completed ? "true" : "false",
                todos[i].created_at, todos[i].updated_at);
                
            if(result < 0 || result >= (int)(sizeof(response) - response_len)) {
                // Handle buffer overflow gracefully
                break;
            }
            response_len += result;
        }
    }
    
    response[response_len++] = ']';
    response[response_len] = 0;
    
    pthread_mutex_unlock(&mutex);
    
    send_json_response(client_fd, 200, response);
}

// Handle POST /todos
void handle_create_todo(int client_fd, const char* session_token, char* post_data) {
    if (!session_token) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    int user_id = get_user_id_from_session(session_token);
    if (user_id == -1) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    char title[256] = {0};
    char description[1024] = {0};
    
    if (!parse_json_field(post_data, "title", title, sizeof(title))) {
        send_json_response(client_fd, 400, "{\"error\":\"Title is required\"}");
        return;
    }
    
    if (strlen(title) == 0) {
        send_json_response(client_fd, 400, "{\"error\":\"Title is required\"}");
        return;
    }
    
    parse_json_field(post_data, "description", description, sizeof(description));
    
    pthread_mutex_lock(&mutex);
    
    if (todo_count >= MAX_USERS * MAX_TODOS_PER_USER) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 500, "{\"error\":\"Too many todos\"}");
        return;
    }
    
    char timestamp[21] = {0};
    generate_timestamp(timestamp);
    
    todos[todo_count].id = todo_count + 1;
    strncpy(todos[todo_count].title, title, sizeof(todos[todo_count].title)-1);
    strncpy(todos[todo_count].description, description, sizeof(todos[todo_count].description)-1);
    todos[todo_count].completed = 0;  // default false
    strncpy(todos[todo_count].created_at, timestamp, sizeof(todos[todo_count].created_at)-1);
    strncpy(todos[todo_count].updated_at, timestamp, sizeof(todos[todo_count].updated_at)-1);
    
    todo_ownerships[todo_count] = user_id;  // Assign ownership
    
    int todo_id = todos[todo_count].id;
    todo_count++;
    
    pthread_mutex_unlock(&mutex);
    
    char response[BUFFER_SIZE];
    snprintf(response, sizeof(response),
        "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":false,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
        todo_id, title, description, timestamp, timestamp);
    
    send_json_response(client_fd, 201, response);
}

// Handle GET /todos/:id
void handle_get_todo(int client_fd, const char* session_token, int todo_id) {
    if (!session_token) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    int user_id = get_user_id_from_session(session_token);
    if (user_id == -1) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    pthread_mutex_lock(&mutex);
    
    int todo_idx = -1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id) {
            todo_idx = i;
            break;
        }
    }
    
    if (todo_idx == -1 || todo_ownerships[todo_idx] != user_id) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 404, "{\"error\":\"Todo not found\"}");
        return;
    }
    
    char response[BUFFER_SIZE];
    snprintf(response, sizeof(response),
        "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
        todos[todo_idx].id, todos[todo_idx].title, todos[todo_idx].description,
        todos[todo_idx].completed ? "true" : "false",
        todos[todo_idx].created_at, todos[todo_idx].updated_at);
    
    pthread_mutex_unlock(&mutex);
    
    send_json_response(client_fd, 200, response);
}

// Handle PUT /todos/:id
void handle_update_todo(int client_fd, const char* session_token, int todo_id, char* post_data) {
    if (!session_token) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    int user_id = get_user_id_from_session(session_token);
    if (user_id == -1) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    pthread_mutex_lock(&mutex);
    
    int todo_idx = -1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id) {
            todo_idx = i;
            break;
        }
    }
    
    if (todo_idx == -1 || todo_ownerships[todo_idx] != user_id) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 404, "{\"error\":\"Todo not found\"}");
        return;
    }
    
    // Update fields that are provided in the request
    char title[256] = {0};
    char description[1024] = {0};
    int completed;
    
    if (parse_json_field(post_data, "title", title, sizeof(title))) {
        if (strlen(title) == 0) {
            pthread_mutex_unlock(&mutex);
            send_json_response(client_fd, 400, "{\"error\":\"Title is required\"}");
            return;
        }
        strncpy(todos[todo_idx].title, title, sizeof(todos[todo_idx].title)-1);
    }
    
    if (parse_json_field(post_data, "description", description, sizeof(description))) {
        strncpy(todos[todo_idx].description, description, sizeof(todos[todo_idx].description)-1);
    }
    
    if (parse_json_field_bool(post_data, "completed", &completed)) {
        todos[todo_idx].completed = completed;
    }
    
    // Update the timestamp
    generate_timestamp(todos[todo_idx].updated_at);
    
    char response[BUFFER_SIZE];
    snprintf(response, sizeof(response),
        "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
        todos[todo_idx].id, todos[todo_idx].title, 
        todos[todo_idx].description, 
        todos[todo_idx].completed ? "true" : "false",
        todos[todo_idx].created_at, 
        todos[todo_idx].updated_at);
    
    pthread_mutex_unlock(&mutex);
    
    send_json_response(client_fd, 200, response);
}

// Handle DELETE /todos/:id
void handle_delete_todo(int client_fd, const char* session_token, int todo_id) {
    if (!session_token) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    int user_id = get_user_id_from_session(session_token);
    if (user_id == -1) {
        send_json_response(client_fd, 401, "{\"error\":\"Authentication required\"}");
        return;
    }
    
    pthread_mutex_lock(&mutex);
    
    int todo_idx = -1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id) {
            todo_idx = i;
            break;
        }
    }
    
    if (todo_idx == -1 || todo_ownerships[todo_idx] != user_id) {
        pthread_mutex_unlock(&mutex);
        send_json_response(client_fd, 404, "{\"error\":\"Todo not found\"}");
        return;
    }
    
    // Shift all subsequent todo items to fill the gap
    for (int i = todo_idx; i < todo_count - 1; i++) {
        todos[i] = todos[i + 1];
        todo_ownerships[i] = todo_ownerships[i + 1];  // Copy ownership
    }
    todo_count--;
    
    pthread_mutex_unlock(&mutex);
    
    send_no_content(client_fd); // 204 No Content
}

void handle_request(int client_fd) {
    char buffer[BUFFER_SIZE];
    int valread = recv(client_fd, buffer, BUFFER_SIZE - 1, 0);
    
    if (valread <= 0) {
        close(client_fd);
        return;
    }
    
    buffer[valread] = '\0';
    
    char method[10];
    char path[512];
    
    sscanf(buffer, "%s %s ", method, path);
    
    // Debug logging
    printf("Received: %s %s\n", method, path);
    
    char* headers_end = strstr(buffer, "\r\n\r\n");
    if (!headers_end) {
        // Look for \n\n as well
        headers_end = strstr(buffer, "\n\n");
        if (!headers_end) {
            send_json_response(client_fd, 400, "{\"error\":\"Invalid request\"}");
            close(client_fd);
            return;
        } else {
            headers_end += 2;  // Point to beginning of body
        }
    } else {
        headers_end += 4;  // Point to beginning of body
    }
    
    char* post_data = headers_end;
    
    // Find Cookie header
    char* cookies_header = find_header_value(buffer, "Cookie:");
    char* session_token = NULL;
    if (cookies_header) {
        char* token_start = strstr(cookies_header, "session_id=");
        if (token_start) {
            token_start += 11; // Length of "session_id="
            char* token_end = strchr(token_start, ';');
            if (token_end) {
                *token_end = '\0';
            } else {
                // Check for end of line/string
                char* next_space_or_tab = token_start;
                while (*next_space_or_tab && *next_space_or_tab != ' ' && *next_space_or_tab != '\t' && 
                       *next_space_or_tab != '\r' && *next_space_or_tab != '\n') {
                    next_space_or_tab++;
                }
                if (next_space_or_tab != token_start) {
                    *next_space_or_tab = '\0';
                }
            }
            session_token = token_start;
        }
    }
    
    // Handle routes
    if (strcmp(method, "POST") == 0 && strcmp(path, "/register") == 0) {
        handle_register(client_fd, post_data);
    } else if (strcmp(method, "POST") == 0 && strcmp(path, "/login") == 0) {
        handle_login(client_fd, post_data);
    } else if (strcmp(method, "POST") == 0 && strcmp(path, "/logout") == 0) {
        handle_logout(client_fd, session_token);
    } else if (strcmp(method, "GET") == 0 && strcmp(path, "/me") == 0) {
        handle_me(client_fd, session_token);
    } else if (strcmp(method, "PUT") == 0 && strcmp(path, "/password") == 0) {
        handle_change_password(client_fd, session_token, post_data);
    } else if (strcmp(method, "GET") == 0 && strcmp(path, "/todos") == 0) {
        handle_get_todos(client_fd, session_token);
    } else if (strcmp(method, "POST") == 0 && strcmp(path, "/todos") == 0) {
        handle_create_todo(client_fd, session_token, post_data);
    } else if (strncmp(path, "/todos/", 7) == 0) {
        int todo_id = -1;
        sscanf(path + 7, "%d", &todo_id);
        
        if (todo_id == -1) {
            send_json_response(client_fd, 404, "{\"error\":\"Not found\"}");
            close(client_fd);
            return;
        }
        
        if (strcmp(method, "GET") == 0) {
            handle_get_todo(client_fd, session_token, todo_id);
        } else if (strcmp(method, "PUT") == 0) {
            handle_update_todo(client_fd, session_token, todo_id, post_data);
        } else if (strcmp(method, "DELETE") == 0) {
            handle_delete_todo(client_fd, session_token, todo_id);
        } else {
            send_json_response(client_fd, 405, "{\"error\":\"Method not allowed\"}");
        }
    } else {
        send_json_response(client_fd, 404, "{\"error\":\"Not found\"}");
    }
    
    close(client_fd);
}

int main(int argc, char *argv[]) {
    int port = 8080; // default port
    int opt = 0;
    
    while ((opt = getopt(argc, argv, "p:")) != -1) {
        switch(opt) {
            case 'p':
                port = atoi(optarg);
                break;
            default:
                fprintf(stderr, "Usage: %s --port PORT\n", argv[0]);
                exit(EXIT_FAILURE);
        }
    }
    
    int server_fd, client_fd;
    struct sockaddr_in address;
    int addrlen = sizeof(address);
    
    // Initialize global counters
    user_count = 0;
    todo_count = 0; 
    session_count = 0;
    
    // Creating socket file descriptor
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }
    
    // Setting socket options
    int opt_val = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR /* Removed SO_REUSEPORT */,
                   &opt_val, sizeof(opt_val))) {
        perror("setsockopt");
        exit(EXIT_FAILURE);
    }
    
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);
    
    // Bind the socket
    if (bind(server_fd, (struct sockaddr*)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }
    
    // Listen
    if (listen(server_fd, 10) < 0) {
        perror("listen");
        exit(EXIT_FAILURE);
    }
    
    printf("Server running on http://0.0.0.0:%d\n", port);
    
    while(1) {
        if ((client_fd = accept(server_fd, (struct sockaddr*)&address, 
                               (socklen_t*)&addrlen)) < 0) {
            perror("accept");
            exit(EXIT_FAILURE);
        }
        
        // Handle request sequentially for now
        handle_request(client_fd);
    }
    
    return 0;
}
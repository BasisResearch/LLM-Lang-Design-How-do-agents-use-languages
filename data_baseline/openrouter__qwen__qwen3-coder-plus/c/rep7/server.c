#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <time.h>
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <signal.h>

#define MAX_USERS 1000
#define MAX_TODOS 10000
#define MAX_SESSIONS 1000
#define MAX_USERNAME_LEN 51
#define MAX_PASSWORD_LEN 100
#define SESSION_ID_LEN 64  // More than enough for generated session tokens
#define ISO_DATE_STR_LEN 21  // YYYY-MM-DDTHH:MM:SSZ + null terminator

typedef enum {
    false = 0,
    true = 1
} bool;

// Forward declarations
typedef struct Todo Todo;
typedef struct User User;
typedef struct Session Session;

struct User {
    int id;
    char username[MAX_USERNAME_LEN];
    char password[MAX_PASSWORD_LEN];  // In real applications would be hashed
    bool active;
};

struct Todo {
    int id;
    int user_id;
    char title[256];
    char description[512];
    bool completed;
    char created_at[ISO_DATE_STR_LEN];
    char updated_at[ISO_DATE_STR_LEN];
    bool active;
};

struct Session {
    char session_id[SESSION_ID_LEN];
    int user_id;
    bool valid;
};

// Global data structures
User users[MAX_USERS];
Todo todos[MAX_TODOS];
Session sessions[MAX_SESSIONS];

// Global counters
int next_user_id_counter = 1;
int next_todo_id_counter = 1;
int next_session_id_counter = 1;

// Mutexes for thread safety
pthread_mutex_t users_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t todos_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t sessions_mutex = PTHREAD_MUTEX_INITIALIZER;

// Helper function to generate unique IDs
int get_next_user_id() {
    int id;
    pthread_mutex_lock(&users_mutex);
    id = next_user_id_counter++;
    pthread_mutex_unlock(&users_mutex);
    return id;
}

int get_next_todo_id() {
    int id;
    pthread_mutex_lock(&todos_mutex);
    id = next_todo_id_counter++;
    pthread_mutex_unlock(&todos_mutex);
    return id;
}

int get_next_session_id_num() {
    int id;
    pthread_mutex_lock(&sessions_mutex);
    id = next_session_id_counter++;
    pthread_mutex_unlock(&sessions_mutex);
    return id;
}

// Time utility functions
void get_current_iso_time(char* buffer) {
    time_t now = time(NULL);
    struct tm *tm_now = gmtime(&now);
    strftime(buffer, ISO_DATE_STR_LEN, "%Y-%m-%dT%H:%M:%SZ", tm_now);
}

// Simple string-based ID generation
void generate_session_id(char* session_id) {
    snprintf(session_id, SESSION_ID_LEN, "sess_%08d_%ld", get_next_session_id_num(), time(NULL));
    session_id[SESSION_ID_LEN - 1] = '\0';  // Ensure null termination
}

// Utility functions
bool validate_username(const char* username) {
    if (!username) return false;
    
    size_t len = strlen(username);
    if (len < 3 || len > 50) {
        return false;
    }
    
    for (size_t i = 0; i < len; i++) {
        char c = username[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || 
              (c >= '0' && c <= '9') || c == '_')) {
            return false;
        }
    }
    return true;
}

bool validate_password(const char* password) {
    if (!password) return false;
    return strlen(password) >= 8;
}

// Enhanced JSON parsing that handles strings safely
char* extract_string_from_json(const char* json_str, const char* field_name) {
    if (!json_str || !field_name) return NULL;
    
    char pattern[256];
    snprintf(pattern, sizeof(pattern), "\"%s\"", field_name);
    
    const char* field_pos = strstr(json_str, pattern);
    if (!field_pos) {
        return NULL;
    }
    
    // Find the colon after the field name
    const char* colon_pos = strchr(field_pos + strlen(field_name) + 2, ':');
    if (!colon_pos) {
        return NULL;
    }
    
    // Move past the colon and any whitespace
    const char* value_start = colon_pos + 1;
    while (*value_start == ' ' || *value_start == '\t') value_start++;
    
    if (*value_start != '"') {
        // Not a string value, for now we return NULL for non-string values
        return NULL;
    }
    
    const char* str_start = value_start + 1; // Skip opening quote
    const char* str_end = strchr(str_start, '"');
    if (!str_end) {
        return NULL;
    }
    
    size_t str_len = str_end - str_start;
    char* result = malloc(str_len + 1);
    if (!result) return NULL;
    
    strncpy(result, str_start, str_len);
    result[str_len] = '\0';
    return result;
}

bool extract_bool_from_json(const char* json_str, const char* field_name, bool* found) {
    if (!json_str || !field_name || !found) {
        if (found) *found = false;
        return false;
    }
    
    char pattern[256];
    snprintf(pattern, sizeof(pattern), "\"%s\":", field_name);
    
    const char* field_pos = strstr(json_str, pattern);
    if (!field_pos) {
        *found = false;
        return false;
    }
    
    // Skip past ":"
    const char* value_start = field_pos + strlen(pattern);
    
    // Skip whitespace
    while (*value_start == ' ' || *value_start == '\t') value_start++;
    
    if (strncmp(value_start, "true", 4) == 0) {
        *found = true;
        return true;
    } else if (strncmp(value_start, "false", 5) == 0) {
        *found = true;
        return false;
    } else {
        *found = false;
        return false; // Not actually a boolean in the input
    }
}

// Find user by ID
User* find_user_by_id(int user_id) {
    pthread_mutex_lock(&users_mutex);
    for (int i = 0; i < MAX_USERS; i++) {
        if (users[i].active && users[i].id == user_id) {
            User* u = &users[i];
            pthread_mutex_unlock(&users_mutex);
            return u;
        }
    }
    pthread_mutex_unlock(&users_mutex);
    return NULL;
}

// Find user by username
User* find_user_by_username(const char* username) {
    if (!username) return NULL;
    
    pthread_mutex_lock(&users_mutex);
    for (int i = 0; i < MAX_USERS; i++) {
        if (users[i].active && strcmp(users[i].username, username) == 0) {
            User* u = &users[i];
            pthread_mutex_unlock(&users_mutex);
            return u;
        }
    }
    pthread_mutex_unlock(&users_mutex);
    return NULL;
}

// Find todo by ID and user
Todo* find_todo_by_id_and_user(int todo_id, int user_id) {
    pthread_mutex_lock(&todos_mutex);
    for (int i = 0; i < MAX_TODOS; i++) {
        if (todos[i].active && todos[i].id == todo_id && todos[i].user_id == user_id) {
            Todo* t = &todos[i];
            pthread_mutex_unlock(&todos_mutex);
            return t;
        }
    }
    pthread_mutex_unlock(&todos_mutex);
    return NULL;
}

// Find session by ID
Session* find_session_by_id(const char* session_id) {
    if (!session_id) return NULL;
    
    pthread_mutex_lock(&sessions_mutex);
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].valid && strcmp(sessions[i].session_id, session_id) == 0) {
            Session* s = &sessions[i];
            pthread_mutex_unlock(&sessions_mutex);
            return s;
        }
    }
    pthread_mutex_unlock(&sessions_mutex);
    return NULL;
}

// Extract session ID from headers
const char* extract_session_id(const char* headers) {
    if (!headers) return NULL;
    
    const char* cookie_ptr = strcasestr(headers, "Cookie:");
    if (!cookie_ptr) {
        cookie_ptr = strcasestr(headers, "cookie:");
        if (!cookie_ptr) return NULL;
    }
    
    // Point to after 'Cookie:' plus 7 characters (or 7 for 'cookie:')
    cookie_ptr += 7;
    while (*cookie_ptr == ' ') cookie_ptr++;
    
    const char* session_start = strcasestr(cookie_ptr, "session_id=");
    if (!session_start) {
        return NULL;
    }
    
    session_start += 11;  // Length of "session_id="
    static char extracted_session_id[SESSION_ID_LEN];
    
    int i = 0;
    while (i < SESSION_ID_LEN - 1 && session_start[i] && session_start[i] != ';' && 
           session_start[i] != ' ' && session_start[i] != '\r' && session_start[i] != '\n' && 
           session_start[i] != ',') {   // Stop at comma as well
        extracted_session_id[i] = session_start[i];
        i++;
    }
    extracted_session_id[i] = '\0';
    
    return extracted_session_id;
}

// Missing strcasestr implementation if unavailable
#ifndef __USE_GNU
const char* strcasestr(const char* haystack, const char* needle) {
    size_t needle_len = strlen(needle);
    for (size_t i = 0; i < strlen(haystack); i++) {
        if (i + needle_len > strlen(haystack)) break; // Ensure bounds checking
        if (strncasecmp(&haystack[i], needle, needle_len) == 0) {
            return &haystack[i];
        }
    }
    return NULL;
}
#endif

// Initialize data structures
void init_data() {
    for (int i = 0; i < MAX_USERS; i++) {
        users[i].active = false;
    }
    
    for (int i = 0; i < MAX_TODOS; i++) {
        todos[i].active = false;
    }
    
    for (int i = 0; i < MAX_SESSIONS; i++) {
        sessions[i].valid = false;
    }
}

// Send HTTP response
void send_response(int client_fd, int status_code, const char* content_type, 
                  const char* body, const char* additional_headers) {
    char response[16384]; // Increase size to handle longer responses
    const char* status_text;
    
    switch(status_code) {
        case 200: status_text = "OK"; break;
        case 201: status_text = "Created"; break;
        case 204: status_text = "No Content"; break;
        case 400: status_text = "Bad Request"; break;
        case 401: status_text = "Unauthorized"; break;
        case 404: status_text = "Not Found"; break;
        case 405: status_text = "Method Not Allowed"; break;
        case 409: status_text = "Conflict"; break;
        default: status_text = "Internal Server Error"; break;
    }
    
    if (additional_headers) {
        if (body && body[0]) {  // Only include Content-Length header if body exists and is not empty
            snprintf(response, sizeof(response), 
                    "HTTP/1.1 %d %s\r\nContent-Type: %s\r\n%s\r\nContent-Length: %zu\r\n\r\n%s",
                    status_code, status_text, content_type, additional_headers, 
                    strlen(body), body);
        } else { // Body is NULL or empty, so Content-Length is 0
            snprintf(response, sizeof(response), 
                    "HTTP/1.1 %d %s\r\nContent-Type: %s\r\n%s\r\nContent-Length: 0\r\n\r\n",
                    status_code, status_text, content_type, additional_headers);
        }
    } else {
        if (body && body[0]) {
            snprintf(response, sizeof(response), 
                    "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n\r\n%s",
                    status_code, status_text, content_type, 
                    strlen(body), body);
        } else {
            snprintf(response, sizeof(response), 
                    "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: 0\r\n\r\n",
                    status_code, status_text, content_type);
        }
    }
    
    send(client_fd, response, strlen(response), 0);
}

// Handle Register Endpoint
void handle_register(int client_fd, const char* body) {
    char* username = extract_string_from_json(body, "username");
    char* password = extract_string_from_json(body, "password");
    
    if (!username || !password) {
        const char* error = "{\"error\": \"Username and password required\"}";
        send_response(client_fd, 400, "application/json", error, NULL);
        if (username) free(username);
        if (password) free(password);
        return;
    }
    
    if (!validate_username(username)) {
        const char* error = "{\"error\": \"Invalid username\"}";
        send_response(client_fd, 400, "application/json", error, NULL);
        if (username) free(username);
        if (password) free(password);
        return;
    }
    
    if (!validate_password(password)) {
        const char* error = "{\"error\": \"Password too short\"}";
        send_response(client_fd, 400, "application/json", error, NULL);
        if (username) free(username);
        if (password) free(password);
        return;
    }
    
    pthread_mutex_lock(&users_mutex);
    
    if (find_user_by_username(username)) {
        pthread_mutex_unlock(&users_mutex);
        const char* error = "{\"error\": \"Username already exists\"}";
        send_response(client_fd, 409, "application/json", error, NULL);
        if (username) free(username);
        if (password) free(password);
        return;
    }
    
    // Find an empty slot in the users array
    int user_index = -1;
    for (int i = 0; i < MAX_USERS; i++) {
        if (!users[i].active) {
            user_index = i;
            break;
        }
    }
    
    if (user_index == -1) {
        pthread_mutex_unlock(&users_mutex);
        const char* error = "{\"error\": \"Server capacity exceeded\"}";
        send_response(client_fd, 500, "application/json", error, NULL);
        if (username) free(username);
        if (password) free(password);
        return;
    }
    
    users[user_index].id = get_next_user_id();
    strncpy(users[user_index].username, username, MAX_USERNAME_LEN - 1);
    users[user_index].username[MAX_USERNAME_LEN - 1] = '\0';
    strncpy(users[user_index].password, password, MAX_PASSWORD_LEN - 1);
    users[user_index].password[MAX_PASSWORD_LEN - 1] = '\0';
    users[user_index].active = true;
    
    char success_response[256];
    snprintf(success_response, sizeof(success_response), 
             "{\"id\": %d, \"username\": \"%s\"}", 
             users[user_index].id, users[user_index].username);
    
    send_response(client_fd, 201, "application/json", success_response, NULL);
    
    free(username);
    free(password);
    pthread_mutex_unlock(&users_mutex);
}

// Handle Login Endpoint
void handle_login(int client_fd, const char* body) {
    char* username = extract_string_from_json(body, "username");
    char* password = extract_string_from_json(body, "password");
    
    if (!username || !password) {
        const char* error = "{\"error\": \"Username and password required\"}";
        send_response(client_fd, 400, "application/json", error, NULL);
        if (username) free(username);
        if (password) free(password);
        return;
    }
    
    pthread_mutex_lock(&users_mutex);
    User* user = find_user_by_username(username);
    
    if (!user || strcmp(user->password, password) != 0) {
        pthread_mutex_unlock(&users_mutex);
        const char* error = "{\"error\": \"Invalid credentials\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        if (username) free(username);
        if (password) free(password);
        return;
    }
    
    // Create a session
    pthread_mutex_lock(&sessions_mutex);
    
    int session_index = -1;
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (!sessions[i].valid) {
            session_index = i;
            break;
        }
    }
    
    if (session_index == -1) {
        pthread_mutex_unlock(&sessions_mutex);
        pthread_mutex_unlock(&users_mutex);
        const char* error = "{\"error\": \"Too many sessions\"}";
        send_response(client_fd, 500, "application/json", error, NULL);
        if (username) free(username);
        if (password) free(password);
        return;
    }
    
    generate_session_id(sessions[session_index].session_id);
    sessions[session_index].user_id = user->id;
    sessions[session_index].valid = true;
    
    char session_header[256];
    snprintf(session_header, sizeof(session_header), 
             "Set-Cookie: session_id=%s; Path=/; HttpOnly", 
             sessions[session_index].session_id);
    
    char success_response[256];
    snprintf(success_response, sizeof(success_response), 
             "{\"id\": %d, \"username\": \"%s\"}", 
             user->id, user->username);
    
    send_response(client_fd, 200, "application/json", success_response, session_header);
    
    free(username);
    free(password);
    pthread_mutex_unlock(&sessions_mutex);
    pthread_mutex_unlock(&users_mutex);
}

// Handle Logout Endpoint
void handle_logout(int client_fd, const char* headers) {
    const char* session_id = extract_session_id(headers);
    if (!session_id) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Session* session = find_session_by_id(session_id);
    if (!session) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    // Invalidate the session
    pthread_mutex_lock(&sessions_mutex);
    session->valid = false;
    pthread_mutex_unlock(&sessions_mutex);
    
    send_response(client_fd, 200, "application/json", "{}", NULL);
}

// Handle GET /me
void handle_get_me(int client_fd, const char* headers) {
    const char* session_id = extract_session_id(headers);
    if (!session_id) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Session* session = find_session_by_id(session_id);
    if (!session) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    User* user = find_user_by_id(session->user_id);
    if (!user) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    char success_response[256];
    snprintf(success_response, sizeof(success_response), 
             "{\"id\": %d, \"username\": \"%s\"}", 
             user->id, user->username);
    
    send_response(client_fd, 200, "application/json", success_response, NULL);
}

// Handle Password Change
void handle_change_password(int client_fd, const char* headers, const char* body) {
    const char* session_id = extract_session_id(headers);
    if (!session_id) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Session* session = find_session_by_id(session_id);
    if (!session) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    char* old_password = extract_string_from_json(body, "old_password");
    char* new_password = extract_string_from_json(body, "new_password");
    
    if (!old_password || !new_password) {
        const char* error = "{\"error\": \"old_password and new_password required\"}";
        send_response(client_fd, 400, "application/json", error, NULL);
        if (old_password) free(old_password);
        if (new_password) free(new_password);
        return;
    }
    
    User* user = find_user_by_id(session->user_id);
    if (!user || strcmp(user->password, old_password) != 0) {
        const char* error = "{\"error\": \"Invalid credentials\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        if (old_password) free(old_password);
        if (new_password) free(new_password);
        return;
    }
    
    if (!validate_password(new_password)) {
        const char* error = "{\"error\": \"Password too short\"}";
        send_response(client_fd, 400, "application/json", error, NULL);
        if (old_password) free(old_password);
        if (new_password) free(new_password);
        return;
    }
    
    pthread_mutex_lock(&users_mutex);
    strncpy(user->password, new_password, MAX_PASSWORD_LEN - 1);
    user->password[MAX_PASSWORD_LEN - 1] = '\0';
    pthread_mutex_unlock(&users_mutex);
    
    send_response(client_fd, 200, "application/json", "{}", NULL);
    
    free(old_password);
    free(new_password);
}

// Handle List Todos
void handle_list_todos(int client_fd, const char* headers) {
    const char* session_id = extract_session_id(headers);
    if (!session_id) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Session* session = find_session_by_id(session_id);
    if (!session) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    // Calculate how many todos the user has to allocate appropriately
    int count = 0, indexes[1000];  // Assuming max 1000 todos for this user for practical purposes
    
    pthread_mutex_lock(&todos_mutex);
    for (int i = 0; i < MAX_TODOS && count < 1000; i++) {
        if (todos[i].active && todos[i].user_id == session->user_id) {
            indexes[count++] = i;
        }
    }
    
    // Build the JSON array dynamically
    char* response = malloc(32768); // Buffer to hold the response
    if (!response) {
        pthread_mutex_unlock(&todos_mutex);
        const char* error = "{\"error\": \"Server error\"}";
        send_response(client_fd, 500, "application/json", error, NULL);
        return;
    }
    
    strcpy(response, "[");
    for (int i = 0; i < count; i++) {
        int idx = indexes[i];
        // Check for space before appending
        int remaining_space = 32768 - strlen(response) - 10; // leave some buffer
        if (remaining_space < 1024) {  // If we get low on space, stop adding entries
            break;  // Avoid buffer overflow
        }
        
        char todo_json[1024];
        snprintf(todo_json, sizeof(todo_json), 
                 "%s{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", "
                 "\"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}", 
                 i > 0 ? "," : "", 
                 todos[idx].id, todos[idx].title, todos[idx].description,
                 todos[idx].completed ? "true" : "false",
                 todos[idx].created_at, todos[idx].updated_at);

        // Double-check bounds before concatenating
        if (strlen(response) + strlen(todo_json) >= 32000) {
            break;  // Prevent buffer overflow
        }
        strcat(response, todo_json);
    }
    strcat(response, "]");
    pthread_mutex_unlock(&todos_mutex);
    
    send_response(client_fd, 200, "application/json", response, NULL);
    free(response);
}

// Handle Create Todo
void handle_create_todo(int client_fd, const char* headers, const char* body) {
    const char* session_id = extract_session_id(headers);
    if (!session_id) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Session* session = find_session_by_id(session_id);
    if (!session) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    char* title = extract_string_from_json(body, "title");
    char* description = extract_string_from_json(body, "description");  // Optional field
    
    if (!title || strlen(title) == 0) {
        if (title) free(title);
        const char* error = "{\"error\": \"Title is required\"}";
        send_response(client_fd, 400, "application/json", error, NULL);
        return;
    }
    
    pthread_mutex_lock(&todos_mutex);
    
    // Find an empty slot
    int todo_index = -1;
    for (int i = 0; i < MAX_TODOS; i++) {
        if (!todos[i].active) {
            todo_index = i;
            break;
        }
    }
    
    if (todo_index == -1) {
        pthread_mutex_unlock(&todos_mutex);
        free(title);
        if (description) free(description);
        const char* error = "{\"error\": \"Too many todos\"}";
        send_response(client_fd, 500, "application/json", error, NULL);
        return;
    }
    
    // Create new todo
    todos[todo_index].id = get_next_todo_id();
    todos[todo_index].user_id = session->user_id;
    strncpy(todos[todo_index].title, title, sizeof(todos[todo_index].title) - 1);
    todos[todo_index].title[sizeof(todos[todo_index].title) - 1] = '\0';
    
    if (description) {
        strncpy(todos[todo_index].description, description, sizeof(todos[todo_index].description) - 1);
        todos[todo_index].description[sizeof(todos[todo_index].description) - 1] = '\0';
    } else {
        strcpy(todos[todo_index].description, ""); // Default empty string
    }
    
    todos[todo_index].completed = false;  // Defaults to false on creation
    get_current_iso_time(todos[todo_index].created_at);
    strcpy(todos[todo_index].updated_at, todos[todo_index].created_at);
    todos[todo_index].active = true;
    
    // Create response
    char response[1024];
    snprintf(response, sizeof(response), 
             "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", "
             "\"completed\": false, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
             todos[todo_index].id, todos[todo_index].title, 
             todos[todo_index].description,
             todos[todo_index].created_at, todos[todo_index].updated_at);
    
    send_response(client_fd, 201, "application/json", response, NULL);
    
    free(title);
    if (description) free(description);
    pthread_mutex_unlock(&todos_mutex);
}

// Handle Get Todo
void handle_get_todo(int client_fd, const char* headers, int todo_id) {
    const char* session_id = extract_session_id(headers);
    if (!session_id) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Session* session = find_session_by_id(session_id);
    if (!session) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Todo* todo = find_todo_by_id_and_user(todo_id, session->user_id);
    if (!todo) {
        const char* error = "{\"error\": \"Todo not found\"}";
        send_response(client_fd, 404, "application/json", error, NULL);
        return;
    }
    
    char response[1024];
    snprintf(response, sizeof(response), 
             "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", "
             "\"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
             todo->id, todo->title, todo->description,
             todo->completed ? "true" : "false",
             todo->created_at, todo->updated_at);
    
    send_response(client_fd, 200, "application/json", response, NULL);
}

// Handle Update Todo
void handle_update_todo(int client_fd, const char* headers, int todo_id, const char* body) {
    const char* session_id = extract_session_id(headers);
    if (!session_id) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Session* session = find_session_by_id(session_id);
    if (!session) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Todo* todo = find_todo_by_id_and_user(todo_id, session->user_id);
    if (!todo) {
        const char* error = "{\"error\": \"Todo not found\"}";
        send_response(client_fd, 404, "application/json", error, NULL);
        return;
    }
    
    // Extract possible fields
    char* new_title = extract_string_from_json(body, "title");
    char* new_description = extract_string_from_json(body, "description");

    // Check if "completed" field exists and if it's a boolean
    bool completed_exists, completed_value;
    completed_value = extract_bool_from_json(body, "completed", &completed_exists);

    // Validate title if provided
    if (new_title && strlen(new_title) == 0) {
        const char* error = "{\"error\": \"Title is required\"}";
        send_response(client_fd, 400, "application/json", error, NULL);
        if (new_title) free(new_title);
        if (new_description) free(new_description);
        return;
    }

    pthread_mutex_lock(&todos_mutex);

    // Update fields if provided
    if (new_title) {
        strncpy(todo->title, new_title, sizeof(todo->title) - 1);
        todo->title[sizeof(todo->title) - 1] = '\0';
        free(new_title);
    }

    if (new_description) {
        strncpy(todo->description, new_description, sizeof(todo->description) - 1);
        todo->description[sizeof(todo->description) - 1] = '\0';
        free(new_description);
    }

    if (completed_exists) {
        todo->completed = completed_value;
    }

    // Update the updated_at field
    get_current_iso_time(todo->updated_at);

    // Create response
    char response[1024];
    snprintf(response, sizeof(response), 
             "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", "
             "\"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
             todo->id, todo->title, todo->description,
             todo->completed ? "true" : "false",
             todo->created_at, todo->updated_at);

    send_response(client_fd, 200, "application/json", response, NULL);
    pthread_mutex_unlock(&todos_mutex);
}

// Handle Delete Todo - returns no content on success (204)
void handle_delete_todo(int client_fd, const char* headers, int todo_id) {
    const char* session_id = extract_session_id(headers);
    if (!session_id) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Session* session = find_session_by_id(session_id);
    if (!session) {
        const char* error = "{\"error\": \"Authentication required\"}";
        send_response(client_fd, 401, "application/json", error, NULL);
        return;
    }
    
    Todo* todo = find_todo_by_id_and_user(todo_id, session->user_id);
    if (!todo) {
        const char* error = "{\"error\": \"Todo not found\"}";
        send_response(client_fd, 404, "application/json", error, NULL);
        return;
    }
    
    pthread_mutex_lock(&todos_mutex);
    todo->active = false;
    pthread_mutex_unlock(&todos_mutex);
    
    // For delete operation, no content is returned (204), so we send an empty body
    send_response(client_fd, 204, "text/plain", NULL, NULL);
}

// Process a single request
void handle_request(int client_fd) {
    char buffer[4096];
    int bytes_read = recv(client_fd, buffer, sizeof(buffer) - 1, 0);
    if (bytes_read <= 0) {
        close(client_fd);
        return;
    }
    
    buffer[bytes_read] = '\0';
    
    // Parse the request line - format: METHOD PATH HTTP/1.1
    char method[16], path[512];
    if (sscanf(buffer, "%15s %511s ", method, path) != 2) {
        const char* error = "{\"error\": \"Invalid request format\"}";
        send_response(client_fd, 400, "application/json", error, NULL);
        close(client_fd);
        return;
    }
    
    // Make sure we're only processing a reasonable size path
    for (int i = 0; path[i]; i++) {
        if (path[i] == '?' || path[i] == '#') {
            path[i] = '\0';  // Truncate at query params or fragment
            break;
        }
    }
    
    // Find where headers end and body begins (if applicable)
    const char* headers_end = strstr(buffer, "\r\n\r\n");
    const char* body = NULL;
    if (headers_end) {
        body = headers_end + 4;  // Skip \r\n\r\n
    }
    
    // Process the request based on path and method
    if (strcmp(method, "POST") == 0) {
        if (strcmp(path, "/register") == 0) {
            handle_register(client_fd, body);
        } else if (strcmp(path, "/login") == 0) {
            handle_login(client_fd, body);
        } else if (strcmp(path, "/logout") == 0) {
            handle_logout(client_fd, buffer);
        } else if (strcmp(path, "/password") == 0) {
            handle_change_password(client_fd, buffer, body);
        } else if (strcmp(path, "/todos") == 0) {
            handle_create_todo(client_fd, buffer, body);
        } else {
            const char* error = "{\"error\": \"Endpoint not found\"}";
            send_response(client_fd, 404, "application/json", error, NULL);
        }
    } else if (strcmp(method, "GET") == 0) {
        if (strcmp(path, "/me") == 0) {
            handle_get_me(client_fd, buffer);
        } else if (strcmp(path, "/todos") == 0) {
            handle_list_todos(client_fd, buffer);
        } else if (strncmp(path, "/todos/", 7) == 0) {
            int todo_id;
            if (sscanf(path + 7, "%d", &todo_id) == 1 && todo_id > 0) {
                handle_get_todo(client_fd, buffer, todo_id);
            } else {
                const char* error = "{\"error\": \"Invalid todo ID\"}";
                send_response(client_fd, 400, "application/json", error, NULL);
            }
        } else {
            const char* error = "{\"error\": \"Endpoint not found\"}";
            send_response(client_fd, 404, "application/json", error, NULL);
        }
    } else if (strcmp(method, "PUT") == 0) {
        if (strcmp(path, "/password") == 0) {
            handle_change_password(client_fd, buffer, body);
        } else if (strncmp(path, "/todos/", 7) == 0) {
            int todo_id;
            if (sscanf(path + 7, "%d", &todo_id) == 1 && todo_id > 0) {
                handle_update_todo(client_fd, buffer, todo_id, body);
            } else {
                const char* error = "{\"error\": \"Invalid todo ID\"}";
                send_response(client_fd, 400, "application/json", error, NULL);
            }
        } else {
            const char* error = "{\"error\": \"Endpoint not found\"}";
            send_response(client_fd, 404, "application/json", error, NULL);
        }
    } else if (strcmp(method, "DELETE") == 0) {
        if (strncmp(path, "/todos/", 7) == 0) {
            int todo_id;
            if (sscanf(path + 7, "%d", &todo_id) == 1 && todo_id > 0) {
                handle_delete_todo(client_fd, buffer, todo_id);
            } else {
                const char* error = "{\"error\": \"Invalid todo ID\"}";
                send_response(client_fd, 400, "application/json", error, NULL);
            }
        } else {
            const char* error = "{\"error\": \"Endpoint not found\"}";
            send_response(client_fd, 404, "application/json", error, NULL);
        }
    } else {
        const char* error = "{\"error\": \"Method not allowed\"}";
        send_response(client_fd, 405, "application/json", error, NULL);
    }
    
    close(client_fd);
}

int main(int argc, char* argv[]) {
    // Parse the command-line argument for the port
    int port = -1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
            break;
        }
    }
    
    if (port == -1) {
        fprintf(stderr, "Usage: %s --port PORT\n", argv[0]);
        return 1;
    }
    
    // Initialize data
    init_data();
    
    // Create socket
    int server_fd;
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }
    
    // Set socket options to reuse address - important for quick restart
    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        close(server_fd);
        exit(EXIT_FAILURE);
    }
    
    // Configure the address
    struct sockaddr_in address;
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;  // Bind to all interfaces
    address.sin_port = htons(port);
    
    // Bind the socket
    if (bind(server_fd, (struct sockaddr*)&address, sizeof(address)) < 0) {
        perror("bind failed");
        close(server_fd);
        exit(EXIT_FAILURE);
    }
    
    // Start listening - backlog of up to 10 pending connections
    if (listen(server_fd, 10) < 0) {
        perror("listen failed");
        close(server_fd);
        exit(EXIT_FAILURE);
    }
    
    printf("Server listening on 0.0.0.0:%d\n", port);
    
    // Ignore SIGPIPE signals (when writing to closed socket)
    signal(SIGPIPE, SIG_IGN);
    
    // Main event loop - accept client connections and handle them
    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        
        int client_fd = accept(server_fd, (struct sockaddr*)&client_addr, &client_len);
        if (client_fd < 0) {
            perror("accept failed");
            continue;
        }
        
        // Use fork to handle the request
        pid_t pid = fork();
        if (pid == 0) {
            // Child process - handle the request
            close(server_fd); // Close listener in child
            handle_request(client_fd);
            exit(0); // Exit child process
        } else if (pid > 0) {
            // Parent process - close client fd and continue
            close(client_fd);
        } else {
            // Fork failed
            perror("fork failed");
            close(client_fd);
        }
    }
    
    // Should never reach here since infinite loop, but for completeness
    close(server_fd);
    return 0;
}
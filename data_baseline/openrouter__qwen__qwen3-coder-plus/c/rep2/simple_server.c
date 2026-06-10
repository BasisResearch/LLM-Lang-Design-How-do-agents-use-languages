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

#define MAX_USERS 1000
#define MAX_TODOS 10000
#define USERNAME_MAX_LEN 50
#define PASSWORD_MAX_LEN 100
#define TITLE_MAX_LEN 255
#define DESC_MAX_LEN 1000
#define SESSION_ID_LEN 37 // UUID length

// User structure
typedef struct {
    int id;
    char username[USERNAME_MAX_LEN + 1];
    char password[PASSWORD_MAX_LEN + 1];
    int active;
} User;

// Todo structure  
typedef struct {
    int id;
    int user_id;
    char title[TITLE_MAX_LEN + 1];
    char description[DESC_MAX_LEN + 1];
    int completed;
    char created_at[21]; // YYYY-MM-DDTHH:MM:SSZ + null terminating 
    char updated_at[21];
    int active;
} Todo;

// Session structure
typedef struct {
    char session_id[SESSION_ID_LEN];
    int user_id;
    int active;
} Session;

// Global data structures
User users[MAX_USERS];
Todo todos[MAX_TODOS];
Session sessions[MAX_USERS * 2]; // More sessions than users possible
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

// Global counters
int next_user_id = 1;
int next_todo_id = 1;
int users_count = 0;
int todos_count = 0;
int sessions_count = 0;

// Helper function to generate UUID
void generate_uuid(char *buf) {
    uuid_t uuid;
    uuid_generate(uuid);
    uuid_unparse_lower(uuid, buf);
}

// Get current time in ISO 8601 format
void get_current_time_iso8601(char *buffer) {
    time_t rawtime;
    struct tm *timeinfo;
    
    time(&rawtime);
    timeinfo = gmtime(&rawtime);
    strftime(buffer, 21, "%Y-%m-%dT%H:%M:%SZ", timeinfo);
}

// Check if username is valid (alphanumeric and underscore only, 3-50 chars)
int is_valid_username(const char *username) {
    if (!username || strlen(username) < 3 || strlen(username) > 50) {
        return 0;
    }
    
    for (int i = 0; username[i] != '\0'; i++) {
        if (!isalnum(username[i]) && username[i] != '_') {
            return 0;
        }
    }
    
    return 1;
}

// Find user by username
User* find_user_by_username(const char *username) {
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < MAX_USERS; i++) {
        if (users[i].active && strcmp(users[i].username, username) == 0) {
            pthread_mutex_unlock(&mutex);
            return &users[i];
        }
    }
    pthread_mutex_unlock(&mutex);
    return NULL;
}

// Find user by ID
User* find_user_by_id(int user_id) {
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < MAX_USERS; i++) {
        if (users[i].active && users[i].id == user_id) {
            pthread_mutex_unlock(&mutex);
            return &users[i];
        }
    }
    pthread_mutex_unlock(&mutex);
    return NULL;
}

// Find todo by ID
Todo* find_todo_by_id(int todo_id) {
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < MAX_TODOS; i++) {
        if (todos[i].active && todos[i].id == todo_id) {
            pthread_mutex_unlock(&mutex);
            return &todos[i];
        }
    }
    pthread_mutex_unlock(&mutex);
    return NULL;
}

// Find todo by ID for specific user
Todo* find_todo_by_id_for_user(int todo_id, int user_id) {
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < MAX_TODOS; i++) {
        if (todos[i].active && todos[i].id == todo_id && todos[i].user_id == user_id) {
            pthread_mutex_unlock(&mutex);
            return &todos[i];
        }
    }
    pthread_mutex_unlock(&mutex);
    return NULL;
}

// Find session by session ID
Session* find_session(const char *session_id) {
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < MAX_USERS * 2; i++) {
        if (sessions[i].active && strcmp(sessions[i].session_id, session_id) == 0) {
            pthread_mutex_unlock(&mutex);
            return &sessions[i];
        }
    }
    pthread_mutex_unlock(&mutex);
    return NULL;
}

// Create a new user
int create_user(const char *username, const char *password) {
    pthread_mutex_lock(&mutex);
    
    // Check if username already exists
    for (int i = 0; i < MAX_USERS; i++) {
        if (users[i].active && strcmp(users[i].username, username) == 0) {
            pthread_mutex_unlock(&mutex);
            return -1; // Username already exists
        }
    }
    
    // Find an available slot
    for (int i = 0; i < MAX_USERS; i++) {
        if (!users[i].active) {
            users[i].id = next_user_id++;
            strcpy(users[i].username, username);
            strcpy(users[i].password, password);
            users[i].active = 1;
            users_count++;
            pthread_mutex_unlock(&mutex);
            return users[i].id;
        }
    }
    
    pthread_mutex_unlock(&mutex);
    return -2; // No space for more users
}

// Create a new todo
Todo* create_todo(int user_id, const char *title, const char *description) {
    pthread_mutex_lock(&mutex);
    
    // Find an available slot
    for (int i = 0; i < MAX_TODOS; i++) {
        if (!todos[i].active) {
            todos[i].id = next_todo_id++;
            todos[i].user_id = user_id;
            strcpy(todos[i].title, title);
            
            if (description) {
                strcpy(todos[i].description, description);
            } else {
                strcpy(todos[i].description, "");
            }
            
            todos[i].completed = 0;
            get_current_time_iso8601(todos[i].created_at);
            strcpy(todos[i].updated_at, todos[i].created_at);
            todos[i].active = 1;
            todos_count++;
            pthread_mutex_unlock(&mutex);
            return &todos[i];
        }
    }
    
    pthread_mutex_unlock(&mutex);
    return NULL; // No space for more todos
}

// Create a new session
char* create_session(int user_id) {
    pthread_mutex_lock(&mutex);
    
    // Find an available slot
    for (int i = 0; i < MAX_USERS * 2; i++) {
        if (!sessions[i].active) {
            generate_uuid(sessions[i].session_id);
            sessions[i].user_id = user_id;
            sessions[i].active = 1;
            sessions_count++;
            char* result = malloc(SESSION_ID_LEN);
            strcpy(result, sessions[i].session_id);
            pthread_mutex_unlock(&mutex);
            return result;
        }
    }
    
    pthread_mutex_unlock(&mutex);
    return NULL; // No space for more sessions
}

// Invalidate a session
int invalidate_session(const char *session_id) {
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < MAX_USERS * 2; i++) {
        if (sessions[i].active && strcmp(sessions[i].session_id, session_id) == 0) {
            sessions[i].active = 0;
            sessions_count--;
            pthread_mutex_unlock(&mutex);
            return 1;
        }
    }
    pthread_mutex_unlock(&mutex);
    return 0; // Session not found
}

// Safe extraction of field from JSON
char* extract_json_field(const char *body, const char* field_name) {
    if (!body) return NULL;
    
    char search_pattern[200];
    snprintf(search_pattern, sizeof(search_pattern), "\"%s\":", field_name);
    
    char *field_start = strstr((char*)body, search_pattern);
    if (!field_start) {
        return NULL;
    }
    
    field_start += strlen(search_pattern);
    
    while (*field_start == ' ' || *field_start == '\t') {
        field_start++;
    }
    
    if (*field_start == '"') {
        // String value
        field_start++; // Skip opening quote
        char *end_quote = strchr(field_start, '"');
        if (end_quote) {
            int length = end_quote - field_start;
            char *result = malloc(length + 1);
            strncpy(result, field_start, length);
            result[length] = '\0';
            return result;
        }
    } else {
        // Non-string value extraction
        char *end = field_start;
        while (*end && *end != ',' && *end != '}' && *end != ']' && 
               *end != ' ' && *end != '\t' && *end != '\n' && *end != '\r') {
            end++;
        }
        int length = end - field_start;
        char *result = malloc(length + 1);
        strncpy(result, field_start, length);
        result[length] = '\0';
        return result;
    }
    
    return NULL;
}

// String case-insensitive search 
char* custom_strcasestr(const char* haystack, const char* needle) {
    const char* h = haystack;
    const char* n = needle;
    
    while (*h) {
        // Find first letter match ignoring case
        while (*h && tolower(*h) != tolower(*n))
            h++;
			
        if (!*h) // Not found
            return NULL;
		
        // Save pointers to compare rest
        const char* h_saved = h;
        const char* n_saved = n;
		
        // Compare remaining characters ignoring case
        while (*n_saved && tolower(*h_saved) == tolower(*n_saved)) {
            h_saved++;
            n_saved++;
        }
        
        if (!*n_saved) // Full match
            return (char*)h;
            
        h++; // Try next position
    }
    
    return NULL;
}

// Extract session ID from headers
char* get_session_id_from_headers(const char* headers) {
    // Case insensitive search for cookie-related headers
    char* cookie_header = custom_strcasestr(headers, "Cookie:");
    if (!cookie_header) {
        return NULL;
    }
    
    // Look for session_id inside the cookie value
    char* session_start = custom_strcasestr(cookie_header, "session_id=");
    if (!session_start) {
        return NULL;
    }
    
    session_start += 11; // Skip "session_id="
    
    // Find end of session ID
    char* session_end = session_start;
    while (*session_end && *session_end != ';' && *session_end != ' ' && 
           *session_end != '\r' && *session_end != '\n') {
        session_end++;
    }
    
    if (session_end > session_start) {
        int length = session_end - session_start;
        char* session_id = malloc(length + 1);
        strncpy(session_id, session_start, length);
        session_id[length] = '\0';
        return session_id;
    }
    
    return NULL;
}

// Send HTTP response
void send_response(int client_fd, int status_code, const char* content_type, const char* body) {
    if(status_code == 204) {
        // Special handling for 204 No Content
        char response[256];
        snprintf(response, sizeof(response),
                 "HTTP/1.1 204 No Content\r\n"
                 "Connection: close\r\n\r\n");
        send(client_fd, response, strlen(response), 0);
        return;
    }
    
    char response_header[512];
    int body_length = body ? strlen(body) : 0;
    snprintf(response_header, sizeof(response_header), 
             "HTTP/1.1 %d OK\r\n"
             "Content-Type: %s\r\n"
             "Content-Length: %d\r\n"
             "Connection: close\r\n\r\n",
             status_code, content_type, body_length);
    
    send(client_fd, response_header, strlen(response_header), 0);
    if (body) {
        send(client_fd, body, body_length, 0);
    }
}

// Send response with custom headers (for setting cookies)
void send_cookie_response(int client_fd, int status_code, const char* session_id, const char* body) {
    char response_header[1024];
    snprintf(response_header, sizeof(response_header),
             "HTTP/1.1 %d OK\r\n"
             "Content-Type: application/json\r\n",
             status_code);
    
    if(session_id) {
        char cookie_buf[400];
        snprintf(cookie_buf, sizeof(cookie_buf), 
                 "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", 
                 session_id);
        strcat(response_header, cookie_buf);
    }
    
    int body_length = body ? strlen(body) : 0;
    char len_header[64];
    snprintf(len_header, sizeof(len_header), 
             "Content-Length: %d\r\n"
             "Connection: close\r\n\r\n", 
             body_length);
    strcat(response_header, len_header);
    
    send(client_fd, response_header, strlen(response_header), 0);
    if (body) {
        send(client_fd, body, body_length, 0);
    }
}

// Send authorized error response
void send_unauthorized(int client_fd) {
    send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
}

// Send custom error response
void send_error(int client_fd, int status_code, const char* message) {
    char error_body[512];
    snprintf(error_body, sizeof(error_body), "{\"error\": \"%s\"}", message);
    send_response(client_fd, status_code, "application/json", error_body);
}

// Handle register endpoint
void handle_register(int client_fd, const char* request_body) {
    char* username = extract_json_field(request_body, "username");
    char* password = extract_json_field(request_body, "password");
    
    if (!username || !password) {
        if (username) free(username);
        if (password) free(password);
        send_error(client_fd, 400, "Missing username or password");
        return;
    }
    
    if (!is_valid_username(username)) {
        free(username);
        free(password);
        send_error(client_fd, 400, "Invalid username");
        return;
    }
    
    if (strlen(password) < 8) {
        free(username);
        free(password);
        send_error(client_fd, 400, "Password too short");
        return;
    }
    
    int user_id = create_user(username, password);
    
    if (user_id == -1) {
        free(username);
        free(password);
        send_error(client_fd, 409, "Username already exists");
        return;
    } else if (user_id == -2) {
        free(username);
        free(password);
        send_error(client_fd, 500, "Server full");
        return;
    }
    
    char response_body[200];
    snprintf(response_body, sizeof(response_body), 
             "{\"id\": %d, \"username\": \"%s\"}", user_id, username);
    
    send_response(client_fd, 201, "application/json", response_body);
    
    free(username);
    free(password);
}

// Handle login endpoint
void handle_login(int client_fd, const char* request_body) {
    char* username = extract_json_field(request_body, "username");
    char* password = extract_json_field(request_body, "password");
    
    if (!username || !password) {
        if (username) free(username);
        if (password) free(password);
        send_error(client_fd, 400, "Missing username or password");
        return;
    }
    
    User* user = find_user_by_username(username);
    
    if (!user || strcmp(user->password, password) != 0) {
        if (username) free(username);
        if (password) free(password);
        send_error(client_fd, 401, "Invalid credentials");
        return;
    }
    
    char* session_id = create_session(user->id);
    if (!session_id) {
        if (username) free(username);
        if (password) free(password);
        send_error(client_fd, 500, "Failed to create session");
        return;
    }
    
    char response_body[200];
    snprintf(response_body, sizeof(response_body),
             "{\"id\": %d, \"username\": \"%s\"}", user->id, user->username);
    
    send_cookie_response(client_fd, 200, session_id, response_body);
    
    free(username);
    free(password);
    free(session_id);
}

// Handle logout endpoint
void handle_logout(int client_fd, const char* headers) {
    char* session_id = get_session_id_from_headers(headers);
    
    if (!session_id) {
        if (session_id) free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Session* session = find_session(session_id);
    
    if (!session) {
        free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    invalidate_session(session_id);
    free(session_id);
    
    send_response(client_fd, 200, "application/json", "{}");
}

// Handle GET /me endpoint
void handle_get_me(int client_fd, const char* headers) {
    char* session_id = get_session_id_from_headers(headers);
    
    if (!session_id) {
        if (session_id) free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Session* session = find_session(session_id);
    free(session_id);
    
    if (!session) {
        send_unauthorized(client_fd);
        return;
    }
    
    User* user = find_user_by_id(session->user_id);
    if (!user) {
        send_unauthorized(client_fd);
        return;
    }
    
    char response_body[200];
    snprintf(response_body, sizeof(response_body),
             "{\"id\": %d, \"username\": \"%s\"}", user->id, user->username);
             
    send_response(client_fd, 200, "application/json", response_body);
}

// Handle change password endpoint
void handle_change_password(int client_fd, const char* headers, const char* request_body) {
    char* session_id = get_session_id_from_headers(headers);
    
    if (!session_id) {
        if (session_id) free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Session* session = find_session(session_id);
    if (!session) {
        free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    char* old_password = extract_json_field(request_body, "old_password");
    char* new_password = extract_json_field(request_body, "new_password");
    
    free(session_id);
    
    if (!old_password || !new_password) {
        if (old_password) free(old_password);
        if (new_password) free(new_password);
        send_error(client_fd, 400, "Missing old_password or new_password");
        return;
    }
    
    User* user = find_user_by_id(session->user_id);
    if (!user || strcmp(user->password, old_password) != 0) {
        free(old_password);
        free(new_password);
        send_error(client_fd, 401, "Invalid credentials");
        return;
    }
    
    if (strlen(new_password) < 8) {
        free(old_password);
        free(new_password);
        send_error(client_fd, 400, "Password too short");
        return;
    }
    
    strcpy(user->password, new_password);
    
    free(old_password);
    free(new_password);
    
    send_response(client_fd, 200, "application/json", "{}");
}

// Handle GET /todos endpoint
void handle_get_todos(int client_fd, const char* headers) {
    char* session_id = get_session_id_from_headers(headers);
    
    if (!session_id) {
        if (session_id) free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Session* session = find_session(session_id);
    free(session_id);
    
    if (!session) {
        send_unauthorized(client_fd);
        return;
    }
    
    // Count how many todos belong to user
    int count = 0;
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < MAX_TODOS; i++) {
        if (todos[i].active && todos[i].user_id == session->user_id) {
            count++;
        }
    }
    pthread_mutex_unlock(&mutex);
    
    // Prepare JSON array - create a large enough buffer
    char* response_body = malloc(count * 1500 + 20);
    strcpy(response_body, "[");
    
    int first_item = 1;
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < MAX_TODOS; i++) {
        if (todos[i].active && todos[i].user_id == session->user_id) {
            if (!first_item) {
                strcat(response_body, ",");
            }
            
            char item_buffer[1500];  // Increased buffer to accommodate all JSON
            snprintf(item_buffer, sizeof(item_buffer),
                     "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", "
                     "\"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                     todos[i].id, todos[i].title, todos[i].description,
                     todos[i].completed ? "true" : "false",
                     todos[i].created_at, todos[i].updated_at);
                     
            strcat(response_body, item_buffer);
            first_item = 0;
        }
    }
    pthread_mutex_unlock(&mutex);
    
    strcat(response_body, "]");
    
    send_response(client_fd, 200, "application/json", response_body);
    free(response_body);
}

// Handle POST /todos endpoint
void handle_create_todo(int client_fd, const char* headers, const char* request_body) {
    char* session_id = get_session_id_from_headers(headers);
    
    if (!session_id) {
        if (session_id) free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Session* session = find_session(session_id);
    if (!session) {
        free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    char* title = extract_json_field(request_body, "title");
    char* description = extract_json_field(request_body, "description");
    
    free(session_id);
    
    if (!title || strlen(title) == 0) {
        if (title) free(title);
        if (description) free(description);
        send_error(client_fd, 400, "Title is required");
        return;
    }
    
    Todo* todo = create_todo(session->user_id, title, description ? description : "");
    
    if (!todo) {
        if (title) free(title);
        if (description) free(description);
        send_error(client_fd, 500, "Failed to create todo");
        return;
    }
    
    char response_body[2000];
    snprintf(response_body, sizeof(response_body),
             "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", "
             "\"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
             todo->id, todo->title, todo->description,
             todo->completed ? "true" : "false",
             todo->created_at, todo->updated_at);
             
    if (title) free(title);
    if (description) free(description);
    
    send_response(client_fd, 201, "application/json", response_body);
}

// Handle GET /todos/:id endpoint
void handle_get_todo(int client_fd, const char* headers, int todo_id) {
    char* session_id = get_session_id_from_headers(headers);
    
    if (!session_id) {
        if (session_id) free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Session* session = find_session(session_id);
    free(session_id);
    
    if (!session) {
        send_unauthorized(client_fd);
        return;
    }
    
    Todo* todo = find_todo_by_id_for_user(todo_id, session->user_id);
    
    if (!todo) {
        send_error(client_fd, 404, "Todo not found");
        return;
    }
    
    char response_body[2000];
    snprintf(response_body, sizeof(response_body),
             "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", "
             "\"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
             todo->id, todo->title, todo->description,
             todo->completed ? "true" : "false",
             todo->created_at, todo->updated_at);
             
    send_response(client_fd, 200, "application/json", response_body);
}

// Handle PUT /todos/:id endpoint
void handle_update_todo(int client_fd, const char* headers, const char* request_body, int todo_id) {
    char* session_id = get_session_id_from_headers(headers);
    
    if (!session_id) {
        if (session_id) free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Session* session = find_session(session_id);
    if (!session) {
        free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Todo* todo = find_todo_by_id_for_user(todo_id, session->user_id);
    free(session_id);
    
    if (!todo) {
        send_error(client_fd, 404, "Todo not found");
        return;
    }
    
    char* title = extract_json_field(request_body, "title");
    char* description = extract_json_field(request_body, "description");
    char* completed_str = extract_json_field(request_body, "completed");
    
    // Validate title if provided
    if (title && strlen(title) == 0) {
        if (title) free(title);
        if (description) free(description);
        if (completed_str) free(completed_str);
        send_error(client_fd, 400, "Title is required");
        return;
    }
    
    // Update fields if provided
    if (title) {
        strcpy(todo->title, title);
    }
    
    if (description) {
        strcpy(todo->description, description);
    }
    
    if (completed_str) {
        if (strlen(completed_str) <= 5) {
            if (strncasecmp(completed_str, "true", 4) == 0) {
                todo->completed = 1;
            } else if (strncasecmp(completed_str, "false", 5) == 0) {
                todo->completed = 0;
            }
        } else if (strlen(completed_str) == 1) {
            todo->completed = (completed_str[0] == '1');
        }
    }
    
    // Update timestamp
    get_current_time_iso8601(todo->updated_at);
    
    if (title) free(title);
    if (description) free(description);
    if (completed_str) free(completed_str);
    
    char response_body[2000];
    snprintf(response_body, sizeof(response_body),
             "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", "
             "\"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
             todo->id, todo->title, todo->description,
             todo->completed ? "true" : "false",
             todo->created_at, todo->updated_at);
             
    send_response(client_fd, 200, "application/json", response_body);
}

// Handle DELETE /todos/:id endpoint
void handle_delete_todo(int client_fd, const char* headers, int todo_id) {
    char* session_id = get_session_id_from_headers(headers);
    
    if (!session_id) {
        if (session_id) free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Session* session = find_session(session_id);
    if (!session) {
        free(session_id);
        send_unauthorized(client_fd);
        return;
    }
    
    Todo* todo = find_todo_by_id_for_user(todo_id, session->user_id);
    free(session_id);
    
    if (!todo) {
        send_error(client_fd, 404, "Todo not found");
        return;
    }
    
    // Mark as inactive instead of deleting to avoid index issues
    pthread_mutex_lock(&mutex);
    todo->active = 0;
    todos_count--;
    pthread_mutex_unlock(&mutex);
    
    send_response(client_fd, 204, "application/json", NULL);
}

// Structure to pass data to thread
typedef struct {
    int client_fd;
} thread_data_t;

void* handle_request_thread(void* arg) {
    thread_data_t* data = (thread_data_t*)arg;
    int client_fd = data->client_fd;
    
    char request[8192];
    int bytes_received = recv(client_fd, request, sizeof(request)-1, 0);
    if (bytes_received <= 0) {
        close(client_fd);
        free(data);
        pthread_exit(NULL);
    }
    
    request[bytes_received] = '\0';

    // Parse HTTP request details 
    char method[10], path[256], version[20];
    sscanf(request, "%s %s %s", method, path, version);
    
    // Extract body (after \r\n\r\n)
    char* headersEnd = strstr(request, "\r\n\r\n");
    char* body = NULL;
    if (headersEnd) {
        body = headersEnd + 4;
    }
    
    // Route based on method and path
    if (strcmp(method, "POST") == 0 && strcmp(path, "/register") == 0) {
        handle_register(client_fd, body);
    } 
    else if (strcmp(method, "POST") == 0 && strcmp(path, "/login") == 0) {
        handle_login(client_fd, body);
    } 
    else if (strcmp(method, "POST") == 0 && strcmp(path, "/logout") == 0) {
        handle_logout(client_fd, request);
    } 
    else if (strcmp(method, "GET") == 0 && strcmp(path, "/me") == 0) {
        handle_get_me(client_fd, request);
    } 
    else if (strcmp(method, "PUT") == 0 && strcmp(path, "/password") == 0) {
        handle_change_password(client_fd, request, body);
    } 
    else if (strcmp(method, "GET") == 0 && strcmp(path, "/todos") == 0) {
        handle_get_todos(client_fd, request);
    } 
    else if (strcmp(method, "POST") == 0 && strcmp(path, "/todos") == 0) {
        handle_create_todo(client_fd, request, body);
    }
    else if (strncmp(path, "/todos/", 7) == 0) {
        // Extract todo ID
        int todo_id;
        if (sscanf(path + 7, "%d", &todo_id) == 1) {
            if (strcmp(method, "GET") == 0) {
                handle_get_todo(client_fd, request, todo_id);
            } else if (strcmp(method, "PUT") == 0) {
                handle_update_todo(client_fd, request, body, todo_id);
            } else if (strcmp(method, "DELETE") == 0) {
                handle_delete_todo(client_fd, request, todo_id);
            } else {
                send_error(client_fd, 405, "Method not allowed");
            }
        } else {
            send_error(client_fd, 404, "Not found");
        }
    }
    else {
        send_error(client_fd, 404, "Not found");
    }
    
    close(client_fd);
    free(data);
    pthread_exit(NULL);
}

int main(int argc, char *argv[]) {
    int port = 8080;
    
    // Parse port argument
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        }
    }
    
    // Initialize users, todos, and sessions arrays
    for (int i = 0; i < MAX_USERS; i++) {
        users[i].active = 0;
    }
    for (int i = 0; i < MAX_TODOS; i++) {
        todos[i].active = 0;
    }
    for (int i = 0; i < MAX_USERS * 2; i++) {
        sessions[i].active = 0;
    }
    
    int server_fd, client_fd;
    struct sockaddr_in address;
    int opt = 1;
    socklen_t addrlen = sizeof(address);
    
    // Create socket
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }
    
    // Set socket options to reuse address
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        exit(EXIT_FAILURE);
    }
    
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;  // Bind to all interfaces (0.0.0.0)
    address.sin_port = htons(port);
    
    // Bind socket
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }
    
    // Listen for connections
    if (listen(server_fd, 10) < 0) {
        perror("listen failed");
        exit(EXIT_FAILURE);
    }
    
    printf("Server started on 0.0.0.0:%d\n", port);
    
    while (1) {
        if ((client_fd = accept(server_fd, (struct sockaddr *)&address, &addrlen)) < 0) {
            perror("accept failed");
            continue;
        }
        
        // Create a thread to handle the request
        pthread_t thread;
        thread_data_t* data = malloc(sizeof(thread_data_t));
        data->client_fd = client_fd;
        
        if (pthread_create(&thread, NULL, handle_request_thread, data) != 0) {
            perror("pthread_create failed");
            close(client_fd);
            free(data);
        } else {
            // Detach the thread to clean up resources when it exits
            pthread_detach(thread);
        }
    }
    
    return 0;
}
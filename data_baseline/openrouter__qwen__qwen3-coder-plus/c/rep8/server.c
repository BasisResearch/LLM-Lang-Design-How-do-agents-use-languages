#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ctype.h>
#include <time.h>
#include <uuid/uuid.h>

// Data Structures
typedef struct {
    int id;
    char* username;
    char* password_hash;  // In production, we'd hash passwords, for simplicity, storing plain
} User;

typedef struct {
    int id;
    int user_id;
    char* title;
    char* description;
    int completed;
    char* created_at;
    char* updated_at;
} Todo;

typedef struct {
    char session_id[37];  // UUID string length
    int user_id;
} Session;

// Global variables to store in-memory data
User users[1000];
int user_count = 0;
int next_user_id = 1;

Todo todos[10000];
int todo_count = 0;
int next_todo_id = 1;

Session sessions[1000];
int session_count = 0;

// Generate a UUID for session IDs
void generate_session_id(char* session_id) {
    uuid_t uuid;
    uuid_generate_random(uuid);
    uuid_unparse(uuid, session_id);
}

// Check if a username already exists
int find_user_by_username(const char* username) {
    for(int i = 0; i < user_count; i++) {
        if(strcmp(users[i].username, username) == 0) {
            return i;
        }
    }
    return -1;  // Not found
}

int find_user_by_id(int user_id) {
    for(int i = 0; i < user_count; i++) {
        if(users[i].id == user_id) {
            return i;
        }
    }
    return -1;  // Not found
}

// Find a todo by id and user_id
int find_todo(int todo_id, int user_id) {
    for(int i = 0; i < todo_count; i++) {
        if(todos[i].id == todo_id && todos[i].user_id == user_id) {
            return i;
        }
    }
    return -1;  // Not found
}

// Find session by session_id
int find_session(const char* session_id) {
    for(int i = 0; i < session_count; i++) {
        if(strcmp(sessions[i].session_id, session_id) == 0) {
            return i;
        }
    }
    return -1;  // Not found
}

// Get current time in ISO 8601 format  
char* get_current_time() {
    time_t now;
    struct tm *tm_info;
    static char time_str[21];  // Format: YYYY-MM-DDTHH:MM:SSZ + null
    
    time(&now);
    tm_info = gmtime(&now);
    
    strftime(time_str, sizeof(time_str), "%Y-%m-%dT%H:%M:%SZ", tm_info);
    
    return time_str;
}

// Extract a field from JSON request body
char* extract_json_field(const char* json, const char* field, size_t* len) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\":", field);

    const char* pos = strstr(json, search);
    if (!pos) {
        *len = 0;
        return NULL;
    }

    pos += strlen(search);  // Move to after the colon

    // Skip any whitespace
    while (*pos == ' ') pos++;

    if (*pos == '"') {
        pos++;  // Skip opening quote
        const char* start = pos;
        
        // Find closing quote
        while (*pos && *pos != '"') {
            if (*pos == '\\' && *(pos + 1)) {  // Handle escape sequences
                pos += 2;
            } else {
                pos++;
            }
        }
        
        *len = pos - start;
        char* result = malloc(*len + 1);
        strncpy(result, start, *len);
        result[*len] = '\0';
        return result;
    } else if (*pos == '{') {
        // For nested objects - find matching brace
        const char* start = pos;
        int brace_count = 0;
        do {
            if (*pos == '{') brace_count++;
            else if (*pos == '}') brace_count--;
            pos++;
        } while (brace_count > 0 && *pos);
        
        *len = pos - start;
        char* result = malloc(*len + 1);
        strncpy(result, start, *len);
        result[*len] = '\0';
        return result;
    } else if (*pos == '[') {
        // For arrays - find matching bracket
        const char* start = pos;
        int bracket_count = 0;
        do {
            if (*pos == '[') bracket_count++;
            else if (*pos == ']') bracket_count--;
            pos++;
        } while (bracket_count > 0 && *pos);
        
        *len = pos - start;
        char* result = malloc(*len + 1);
        strncpy(result, start, *len);
        result[*len] = '\0';
        return result;
    } else {
        // Number, boolean, or null
        const char* start = pos;
        while ((*pos >= '0' && *pos <= '9') || *pos == '.' || *pos == 't' || 
               *pos == 'r' || *pos == 'u' || *pos == 'e' || *pos == 'f' || 
               *pos == 'a' || *pos == 'l' || *pos == 's' || *pos == 'n' || 
               *pos == 'o' || *pos == 'u' || *pos == 'l') {
            pos++;
        }
        
        *len = pos - start;
        char* result = malloc(*len + 1);
        strncpy(result, start, *len);
        result[*len] = '\0';
        return result;
    }

    *len = 0;
    return NULL;
}

// Extract user ID from session cookie in HTTP headers
int get_user_from_cookie(const char* headers) {
    const char* cookie_header = strstr(headers, "Cookie:");
    if (!cookie_header) return -1;

    cookie_header += 7;  // Length of "Cookie:"
    // Skip any leading spaces
    while (*cookie_header == ' ') cookie_header++;

    char* cookies_copy = strdup(cookie_header);
    char* cookie_line_end = strstr(cookies_copy, "\r\n");
    if (cookie_line_end) *cookie_line_end = '\0';

    char* session_start = strstr(cookies_copy, "session_id=");
    if (!session_start) {
        free(cookies_copy);
        return -1;
    }

    session_start += 11;  // Length of "session_id="
    char* session_end = strchr(session_start, ';');
    if (session_end) {
        *session_end = '\0';
    } else {
        // Find end of line or end of string
        char* temp = strchr(session_start, ' ');
        if (temp) *temp = '\0';
    }

    int session_idx = find_session(session_start);
    free(cookies_copy);

    if (session_idx == -1) return -1;
    
    return sessions[session_idx].user_id;
}

// Send HTTP response
void send_response(int client_socket, int status_code, const char* content_type, const char* body) {
    char response[16384];

    if (status_code == 204) {  // No Content
        snprintf(response, sizeof(response), 
                 "HTTP/1.1 %d No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                 status_code);
        send(client_socket, response, strlen(response), 0);
        return;
    }

    int content_length = body ? strlen(body) : 0;
    snprintf(response, sizeof(response), 
             "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
             status_code,
             status_code == 200 ? "OK" : 
             status_code == 201 ? "Created" :
             status_code == 204 ? "No Content" :
             status_code == 400 ? "Bad Request" :
             status_code == 401 ? "Unauthorized" :
             status_code == 404 ? "Not Found" :
             status_code == 409 ? "Conflict" : "Unknown",
             content_type,
             content_length,
             body ? body : "");
    
    send(client_socket, response, strlen(response), 0);
}

void send_error_response(int client_socket, int status_code, const char* message) {
    char error_json[1024];
    snprintf(error_json, sizeof(error_json), "{\"error\":\"%s\"}", message);
    send_response(client_socket, status_code, "application/json", error_json);
}

void send_set_cookie_response_with_json(int client_socket, int status_code, const char* session_id, const char* json_body) {
    char response[16384];
    int content_length = strlen(json_body);
    snprintf(response, sizeof(response), 
             "HTTP/1.1 %d OK\r\nSet-Cookie: session_id=%s; Path=/; HttpOnly\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
             status_code,
             session_id,
             content_length,
             json_body);
    
    send(client_socket, response, strlen(response), 0);
}

// Register endpoint
void handle_register(int client_socket, const char* body) {
    size_t len;
    char* username = extract_json_field(body, "username", &len);
    char* password = extract_json_field(body, "password", &len);

    if (!username) {
        send_error_response(client_socket, 400, "Invalid username");
        goto cleanup;
    }

    if (!password) {
        send_error_response(client_socket, 400, "Password too short");
        goto cleanup;
    }

    // Validate username (3-50 chars, alphanumeric and underscore only)
    if (strlen(username) < 3 || strlen(username) > 50) {
        send_error_response(client_socket, 400, "Invalid username");
        goto cleanup;
    }

    for (size_t i = 0; i < strlen(username); i++) {
        if (!((username[i] >= 'a' && username[i] <= 'z') || 
              (username[i] >= 'A' && username[i] <= 'Z') || 
              (username[i] >= '0' && username[i] <= '9') || 
              username[i] == '_')) {
            send_error_response(client_socket, 400, "Invalid username");
            goto cleanup;
        }
    }

    // Validate password (min 8 chars)
    if (strlen(password) < 8) {
        send_error_response(client_socket, 400, "Password too short");
        goto cleanup;
    }

    // Check if username already exists
    if (find_user_by_username(username) != -1) {
        send_error_response(client_socket, 409, "Username already exists");
        goto cleanup;
    }

    // Create new user
    int user_idx = user_count;
    users[user_idx].id = next_user_id++;
    users[user_idx].username = malloc(strlen(username) + 1);
    strcpy(users[user_idx].username, username);
    users[user_idx].password_hash = malloc(strlen(password) + 1);
    strcpy(users[user_idx].password_hash, password);  // Simple storage

    user_count++;

    // Send success response
    char response[512];
    snprintf(response, sizeof(response), "{\"id\":%d,\"username\":\"%s\"}", 
             users[user_idx].id, users[user_idx].username);
    send_response(client_socket, 201, "application/json", response);

cleanup:
    if (username) free(username);
    if (password) free(password);
}

// Login endpoint
void handle_login(int client_socket, const char* body) {
    size_t len;
    char* username = extract_json_field(body, "username", &len);
    char* password = extract_json_field(body, "password", &len);

    if (!username || !password) {
        send_error_response(client_socket, 401, "Invalid credentials");
        if (username) free(username);
        if (password) free(password);
        return;
    }

    int user_idx = find_user_by_username(username);
    if (user_idx == -1 || strcmp(users[user_idx].password_hash, password) != 0) {
        send_error_response(client_socket, 401, "Invalid credentials");
        free(username);
        free(password);
        return;
    }

    free(password);

    // Create session
    int session_idx = session_count;
    generate_session_id(sessions[session_idx].session_id);
    sessions[session_idx].user_id = users[user_idx].id;
    session_count++;

    // Send success response with Set-Cookie header
    char response[512];
    snprintf(response, sizeof(response), "{\"id\":%d,\"username\":\"%s\"}", 
             users[user_idx].id, users[user_idx].username);
    
    send_set_cookie_response_with_json(client_socket, 200, sessions[session_idx].session_id, response);
    free(username);
}

// Logout endpoint
void handle_logout(int client_socket, const char* headers) {
    int user_id = get_user_from_cookie(headers);
    if (user_id == -1) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    // Find the session and remove it
    const char* cookie_header = strstr(headers, "Cookie:");
    if (!cookie_header) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    cookie_header += 7;  // Length of "Cookie:"
    while (*cookie_header == ' ') cookie_header++;

    char* cookies_copy = strdup(cookie_header);
    char* cookie_line_end = strstr(cookies_copy, "\r\n");
    if (cookie_line_end) *cookie_line_end = '\0';

    char* session_start = strstr(cookies_copy, "session_id=");
    if (session_start) {
        session_start += 11;  // Length of "session_id="
        char* session_end = strchr(session_start, ';');
        if (session_end) {
            *session_end = '\0';
        } else {
            char* temp = strchr(session_start, ' ');
            if (temp) *temp = '\0';
        }

        int session_idx = find_session(session_start);
        if (session_idx != -1) {
            // Remove the session (shift remaining sessions)
            for (int i = session_idx; i < session_count - 1; i++) {
                sessions[i] = sessions[i+1];
            }
            session_count--;
        }
    }

    free(cookies_copy);

    send_response(client_socket, 200, "application/json", "{}");
}

// Get user info (me endpoint)
void handle_me(int client_socket, const char* headers) {
    int user_id = get_user_from_cookie(headers);
    if (user_id == -1) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    int user_idx = find_user_by_id(user_id);
    if (user_idx == -1) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    char response[512];
    snprintf(response, sizeof(response), "{\"id\":%d,\"username\":\"%s\"}", 
             users[user_idx].id, users[user_idx].username);
    
    send_response(client_socket, 200, "application/json", response);
}

// Change password
void handle_change_password(int client_socket, const char* headers, const char* body) {
    int user_id = get_user_from_cookie(headers);
    if (user_id == -1) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    size_t len;
    char* old_password = extract_json_field(body, "old_password", &len);
    char* new_password = extract_json_field(body, "new_password", &len);

    if (!old_password || !new_password) {
        send_error_response(client_socket, 401, "Invalid credentials");
        if (old_password) free(old_password);
        if (new_password) free(new_password);
        return;
    }

    // Validate password (min 8 chars)
    if (strlen(new_password) < 8) {
        send_error_response(client_socket, 400, "Password too short");
        free(old_password);
        free(new_password);
        return;
    }

    int user_idx = find_user_by_id(user_id);
    if (user_idx == -1 || strcmp(users[user_idx].password_hash, old_password) != 0) {
        send_error_response(client_socket, 401, "Invalid credentials");
        free(old_password);
        free(new_password);
        return;
    }

    // Update password
    free(users[user_idx].password_hash);
    users[user_idx].password_hash = malloc(strlen(new_password) + 1);
    strcpy(users[user_idx].password_hash, new_password);

    send_response(client_socket, 200, "application/json", "{}");

    free(old_password);
    free(new_password);
}

// List all user's todos
void handle_list_todos(int client_socket, const char* headers) {
    int user_id = get_user_from_cookie(headers);
    if (user_id == -1) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    char response[32768] = "["; // Start building the array
    size_t response_offset = 1; // Start after opening bracket

    int first = 1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id != user_id) continue;

        if (!first) {
            response[response_offset++] = ',';
        } 
        first = 0;

        // Create individual todo JSON with appropriate escaping for strings
        char* escaped_title = malloc(strlen(todos[i].title) * 2 + 1);
        char* escaped_desc = malloc(strlen(todos[i].description) * 2 + 1);
        
        // Simple escaping algorithm - replace quotes with escaped quotes
        int j = 0, k = 0;
        while(todos[i].title[k]) {
            if(todos[i].title[k] == '"' || todos[i].title[k] == '\\') {
                escaped_title[j++] = '\\';
            }
            escaped_title[j++] = todos[i].title[k++];
        }
        escaped_title[j] = '\0';
        
        j = k = 0;
        while(todos[i].description[k]) {
            if(todos[i].description[k] == '"' || todos[i].description[k] == '\\') {
                escaped_desc[j++] = '\\';
            }
            escaped_desc[j++] = todos[i].description[k++];
        }
        escaped_desc[j] = '\0';

        // Create the JSON fragment
        char todo_json[2048];
        snprintf(todo_json, sizeof(todo_json), 
                 "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\","  
                 "\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
                 todos[i].id, escaped_title, escaped_desc,
                 todos[i].completed ? "true" : "false", 
                 todos[i].created_at, todos[i].updated_at);
        
        free(escaped_title);
        free(escaped_desc);

        size_t todo_len = strlen(todo_json);
        size_t remaining_space = sizeof(response) - response_offset;
        if (todo_len + 2 >= remaining_space) {  // Add extra check to avoid overflow
            break;  // Preventing buffer overrun
        }

        memcpy(response + response_offset, todo_json, todo_len);
        response_offset += todo_len;
    }

    response[response_offset++] = ']';
    response[response_offset] = '\0';
    
    send_response(client_socket, 200, "application/json", response);
}

// Create a new todo
void handle_create_todo(int client_socket, const char* headers, const char* body) {
    int user_id = get_user_from_cookie(headers);
    if (user_id == -1) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    size_t len;
    char* title = extract_json_field(body, "title", &len);
    char* desc = extract_json_field(body, "description", &len);

    if (!title || strlen(title) == 0) {
        send_error_response(client_socket, 400, "Title is required");
        if (title) free(title);
        if (desc) free(desc);
        return;
    }

    // Create new todo
    int todo_idx = todo_count;
    todos[todo_idx].id = next_todo_id++;
    todos[todo_idx].user_id = user_id;
    todos[todo_idx].title = malloc(strlen(title) + 1);
    strcpy(todos[todo_idx].title, title);
    
    if (desc) {
        todos[todo_idx].description = malloc(strlen(desc) + 1);
        strcpy(todos[todo_idx].description, desc);
    } else {
        todos[todo_idx].description = malloc(1);
        todos[todo_idx].description[0] = '\0';
    }
    
    todos[todo_idx].completed = 0;
    todos[todo_idx].created_at = malloc(21);
    strcpy(todos[todo_idx].created_at, get_current_time());
    todos[todo_idx].updated_at = malloc(21);
    strcpy(todos[todo_idx].updated_at, get_current_time());

    todo_count++;

    // Properly escape the response for JSON
    char* escaped_title = malloc(strlen(todos[todo_idx].title) * 2 + 1);
    char* escaped_desc = malloc(strlen(todos[todo_idx].description) * 2 + 1);
    
    int j = 0, k = 0;
    while(todos[todo_idx].title[k]) {
        if(todos[todo_idx].title[k] == '"' || todos[todo_idx].title[k] == '\\') {
            escaped_title[j++] = '\\';
        }
        escaped_title[j++] = todos[todo_idx].title[k++];
    }
    escaped_title[j] = '\0';
    
    j = k = 0;
    while(todos[todo_idx].description[k]) {
        if(todos[todo_idx].description[k] == '"' || todos[todo_idx].description[k] == '\\') {
            escaped_desc[j++] = '\\';
        }
        escaped_desc[j++] = todos[todo_idx].description[k++];
    }
    escaped_desc[j] = '\0';

    // Send success response with created todo
    char response[4096];
    snprintf(response, sizeof(response), 
             "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\","  
             "\"completed\":false,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
             todos[todo_idx].id, escaped_title, escaped_desc,
             todos[todo_idx].created_at, todos[todo_idx].updated_at);
    
    free(escaped_title);
    free(escaped_desc);
    
    send_response(client_socket, 201, "application/json", response);

    free(title);
    if (desc) free(desc);
}

// Get a specific todo
void handle_get_todo(int client_socket, int todo_id, const char* headers) {
    int user_id = get_user_from_cookie(headers);
    if (user_id == -1) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    int todo_idx = find_todo(todo_id, user_id);
    if (todo_idx == -1) {
        // Also check if the todo exists at all (for proper 404 instead of 401 if owned by different user)
        int global_todo_idx = -1;
        for(int i = 0; i < todo_count; i++) {
            if(todos[i].id == todo_id) {
                global_todo_idx = i;
                break;
            }
        }
        
        // If todo exists anywhere but not for this user, return 404 per the spec to prevent enumeration
        if(global_todo_idx != -1) {
            send_error_response(client_socket, 404, "Todo not found");
        } else {
            send_error_response(client_socket, 404, "Todo not found");
        }
        return;
    }

    // Escape strings in JSON response
    char* escaped_title = malloc(strlen(todos[todo_idx].title) * 2 + 1);
    char* escaped_desc = malloc(strlen(todos[todo_idx].description) * 2 + 1);
    
    int j = 0, k = 0;
    while(todos[todo_idx].title[k]) {
        if(todos[todo_idx].title[k] == '"' || todos[todo_idx].title[k] == '\\') {
            escaped_title[j++] = '\\';
        }
        escaped_title[j++] = todos[todo_idx].title[k++];
    }
    escaped_title[j] = '\0';
    
    j = k = 0;
    while(todos[todo_idx].description[k]) {
        if(todos[todo_idx].description[k] == '"' || todos[todo_idx].description[k] == '\\') {
            escaped_desc[j++] = '\\';
        }
        escaped_desc[j++] = todos[todo_idx].description[k++];
    }
    escaped_desc[j] = '\0';

    char response[4096];
    snprintf(response, sizeof(response), 
             "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\","  
             "\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
             todos[todo_idx].id, escaped_title, escaped_desc,
             todos[todo_idx].completed ? "true" : "false", 
             todos[todo_idx].created_at, todos[todo_idx].updated_at);
    
    free(escaped_title);
    free(escaped_desc);
    
    send_response(client_socket, 200, "application/json", response);
}

// Update a specific todo
void handle_update_todo(int client_socket, int todo_id, const char* headers, const char* body) {
    int user_id = get_user_from_cookie(headers);
    if (user_id == -1) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    int todo_idx = find_todo(todo_id, user_id);
    if (todo_idx == -1) {
        // Check if the todo exists at all (to distinguish between 404 and access issues)
        int global_todo_idx = -1;
        for(int i = 0; i < todo_count; i++) {
            if(todos[i].id == todo_id) {
                global_todo_idx = i;
                break;
            }
        }
        
        // Per spec: return 404 even if owned by different user (prevent enumeration)
        if(global_todo_idx != -1) {
            send_error_response(client_socket, 404, "Todo not found");
        } else {
            send_error_response(client_socket, 404, "Todo not found");
        }
        return;
    }

    // Extract possible fields (but we need to be more careful with our JSON parsing)
    char* title = NULL;
    char* desc = NULL;
    char* completed_str = NULL;
    
    size_t len;
    
    // Search specifically for "title"
    if (strstr(body, "\"title\"") && strstr(body, ":")) {
        title = extract_json_field(body, "title", &len);
        if (title && strlen(title) == 0) {
            send_error_response(client_socket, 400, "Title is required");
            
            // Clean up previously extracted values
            if (title) free(title);
            return;
        }
    }
    
    if (strstr(body, "\"description\"")) {
        desc = extract_json_field(body, "description", &len);
    }
    
    if (strstr(body, "\"completed\"")) {
        completed_str = extract_json_field(body, "completed", &len);
    }

    // Update fields that were provided
    if (title) {
        free(todos[todo_idx].title);
        todos[todo_idx].title = malloc(strlen(title) + 1);
        strcpy(todos[todo_idx].title, title);
    }

    if (desc) {
        free(todos[todo_idx].description);
        todos[todo_idx].description = malloc(strlen(desc) + 1);
        strcpy(todos[todo_idx].description, desc);
    }

    if (completed_str) {
        if (strcmp(completed_str, "true") == 0) {
            todos[todo_idx].completed = 1;
        } else if (strcmp(completed_str, "false") == 0) {
            todos[todo_idx].completed = 0;
        }
    }

    // Update the updated_at timestamp
    free(todos[todo_idx].updated_at);
    todos[todo_idx].updated_at = malloc(21);
    strcpy(todos[todo_idx].updated_at, get_current_time());

    // Prepare escaped version for response
    char* escaped_title = malloc(strlen(todos[todo_idx].title) * 2 + 1);
    char* escaped_desc = malloc(strlen(todos[todo_idx].description) * 2 + 1);
    
    int j = 0, k = 0;
    while(todos[todo_idx].title[k]) {
        if(todos[todo_idx].title[k] == '"' || todos[todo_idx].title[k] == '\\') {
            escaped_title[j++] = '\\';
        }
        escaped_title[j++] = todos[todo_idx].title[k++];
    }
    escaped_title[j] = '\0';
    
    j = k = 0;
    while(todos[todo_idx].description[k]) {
        if(todos[todo_idx].description[k] == '"' || todos[todo_idx].description[k] == '\\') {
            escaped_desc[j++] = '\\';
        }
        escaped_desc[j++] = todos[todo_idx].description[k++];
    }
    escaped_desc[j] = '\0';

    // Respond with updated todo
    char response[4096];
    snprintf(response, sizeof(response), 
             "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\","  
             "\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
             todos[todo_idx].id, escaped_title, escaped_desc,
             todos[todo_idx].completed ? "true" : "false", 
             todos[todo_idx].created_at, todos[todo_idx].updated_at);
    
    free(escaped_title);
    free(escaped_desc);
    
    send_response(client_socket, 200, "application/json", response);

    if (title) free(title);
    if (desc) free(desc);
    if (completed_str) free(completed_str);
}

// Delete a specific todo
void handle_delete_todo(int client_socket, int todo_id, const char* headers) {
    int user_id = get_user_from_cookie(headers);
    if (user_id == -1) {
        send_error_response(client_socket, 401, "Authentication required");
        return;
    }

    int todo_idx = find_todo(todo_id, user_id);
    if (todo_idx == -1) {
        // Return 404 for security reasons (prevent ID enumeration)
        int global_todo_idx = -1;
        for(int i = 0; i < todo_count; i++) {
            if(todos[i].id == todo_id) {
                global_todo_idx = i;
                break;
            }
        }
        
        if(global_todo_idx != -1) {
            send_error_response(client_socket, 404, "Todo not found");
        } else {
            send_error_response(client_socket, 404, "Todo not found");
        }
        return;
    }

    // Remove the todo (shift remaining todos)
    free(todos[todo_idx].title);
    free(todos[todo_idx].description);
    free(todos[todo_idx].created_at);
    free(todos[todo_idx].updated_at);
    
    for (int i = todo_idx; i < todo_count - 1; i++) {
        todos[i] = todos[i+1];
    }
    todo_count--;

    send_response(client_socket, 204, "application/json", NULL);
}

// Parse HTTP request
void parse_http_request(int client_socket, const char* buffer) {
    char method[16], uri[512], version[16];
    int parsed = sscanf(buffer, "%15s %511s %15s", method, uri, version);

    if (parsed != 3) {
        send_error_response(client_socket, 400, "Bad Request");
        return;
    }

    const char* body = strstr(buffer, "\r\n\r\n");
    if (body) {
        body += 4;  // Skip \r\n\r\n
    } else {
        body = "";
    }

    // Find end of headers for authentication purposes
    const char* headers_end = strstr(buffer, "\r\n\r\n");
    size_t headers_length = headers_end ? (size_t)(headers_end + 4 - buffer) : strlen(buffer);
    char* headers = malloc(headers_length + 1);
    strncpy(headers, buffer, headers_length);
    headers[headers_length] = '\0';

    if (strcmp(method, "POST") == 0 && strcmp(uri, "/register") == 0) {
        handle_register(client_socket, body);
    } else if (strcmp(method, "POST") == 0 && strcmp(uri, "/login") == 0) {
        handle_login(client_socket, body);
    } else if (strcmp(method, "POST") == 0 && strcmp(uri, "/logout") == 0) {
        handle_logout(client_socket, headers);
    } else if (strcmp(method, "GET") == 0 && strcmp(uri, "/me") == 0) {
        handle_me(client_socket, headers);
    } else if (strcmp(method, "PUT") == 0 && strcmp(uri, "/password") == 0) {
        handle_change_password(client_socket, headers, body);
    } else if (strcmp(method, "GET") == 0 && strcmp(uri, "/todos") == 0) {
        handle_list_todos(client_socket, headers);
    } else if (strcmp(method, "POST") == 0 && strcmp(uri, "/todos") == 0) {
        handle_create_todo(client_socket, headers, body);
    } else if (strncmp(method, "GET", 3) == 0 && strncmp(uri, "/todos/", 7) == 0) {
        int todo_id = atoi(uri + 7);
        if (todo_id <= 0) {
            send_error_response(client_socket, 400, "Bad Request");
        } else {
            handle_get_todo(client_socket, todo_id, headers);
        }
    } else if (strncmp(method, "PUT", 3) == 0 && strncmp(uri, "/todos/", 7) == 0) {
        int todo_id = atoi(uri + 7);
        if (todo_id <= 0) {
            send_error_response(client_socket, 400, "Bad Request");
        } else {
            handle_update_todo(client_socket, todo_id, headers, body);
        }
    } else if (strncmp(method, "DELETE", 6) == 0 && strncmp(uri, "/todos/", 7) == 0) {
        int todo_id = atoi(uri + 7);
        if (todo_id <= 0) {
            send_error_response(client_socket, 400, "Bad Request");
        } else {
            handle_delete_todo(client_socket, todo_id, headers);
        }
    } else {
        send_error_response(client_socket, 404, "Not Found");
    }

    free(headers);
}

// Main server function
int main(int argc, char *argv[]) {
    int port = 8080; // default
    
    // Parse command-line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        }
    }

    int server_fd;
    struct sockaddr_in address;
    int opt = 1;
    int addrlen = sizeof(address);

    // Creating socket file descriptor
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }

    // Forcefully attaching socket to the port
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt");
        exit(EXIT_FAILURE);
    }

    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);

    // Forcefully binding socket to the port
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }

    if (listen(server_fd, 3) < 0) {
        perror("listen");
        exit(EXIT_FAILURE);
    }

    printf("Server running on port %d\n", port);

    while(1) {
        // Accept a connection
        int client_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen);
        if (client_socket < 0) {
            perror("accept failed");
            continue;
        }

        // Read the request
        char buffer[8192];
        int valread = read(client_socket, buffer, sizeof(buffer)-1);
        if (valread > 0) {
            buffer[valread] = '\0';
            parse_http_request(client_socket, buffer);
        }

        close(client_socket);
    }

    return 0;
}
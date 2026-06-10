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

#define MAX_USERS 100
#define MAX_TODOS 1000
#define MAX_SESSIONS 100
#define MAX_REQUEST_SIZE 8192
#define MIN_PASSWORD_LENGTH 8
#define MIN_USERNAME_LENGTH 3
#define MAX_USERNAME_LENGTH 50

typedef struct {
    int id;
    char username[MAX_USERNAME_LENGTH + 1];
    char password[256]; // Hash would be better in real implementation
    int active;
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
    char session_id[37]; // UUID length is 36 chars + null terminator
    int user_id;
    int active;
} Session;

User users[MAX_USERS];
Todo todos[MAX_TODOS];
Session sessions[MAX_SESSIONS];
int user_count = 0;
int todo_count = 0;
int session_count = 0;
int next_user_id = 1;
int next_todo_id = 1;

// Utility functions
char* get_current_time_str() {
    static char time_str[32];
    time_t rawtime;
    struct tm * timeinfo;
    
    time(&rawtime);
    timeinfo = gmtime(&rawtime);
    strftime(time_str, sizeof(time_str), "%Y-%m-%dT%H:%M:%SZ", timeinfo);
    return time_str;
}

int validate_username(const char* username) {
    int len = strlen(username);
    if (len < MIN_USERNAME_LENGTH || len > MAX_USERNAME_LENGTH) {
        return 0;
    }
    
    for (int i = 0; i < len; i++) {
        if (!isalnum(username[i]) && username[i] != '_') {
            return 0;
        }
    }
    return 1;
}

void send_response(int client_socket, int status_code, const char* content_type, const char* body) {
    char response[8192]; // Increased size to accommodate longer responses
    
    if (body == NULL) {
        if (status_code == 204) {
            snprintf(response, sizeof(response), 
                    "HTTP/1.1 %d No Content\r\nConnection: close\r\n\r\n", status_code);
        } else {
            snprintf(response, sizeof(response), 
                    "HTTP/1.1 %d No Content\r\nContent-Type: %s\r\nConnection: close\r\n\r\n", 
                    status_code, content_type ? content_type : "application/json");
        }
        send(client_socket, response, strlen(response), 0);
        return;
    }
    
    snprintf(response, sizeof(response), 
            "HTTP/1.1 %d OK\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s", 
            status_code, content_type, strlen(body), body);
    send(client_socket, response, strlen(response), 0);
}

// Safely extract a string value from JSON (does not handle escaped quotes)
char* extract_json_value(const char* json, const char* field, int* out_len) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", field);
    
    const char* field_pos = strstr(json, search);
    if (!field_pos) return NULL;
    
    const char* colon_pos = strchr(field_pos, ':');
    if (!colon_pos) return NULL;
    
    const char* start = colon_pos + 1;
    // Skip whitespace after colon
    while (*start && isspace(*start)) start++;
    
    if (*start == '"') {
        start++; // Skip opening quote
        const char* end = start;
        while (*end && *end != '"') {
            // For now, not handling escape sequences correctly. Simple implementation.
            if (*end == '\\') end++; // Skip next character (assuming it's escaped quote)
            if (*end) end++;
        }
        *out_len = end - start;
        char* result = malloc(*out_len + 1);
        if (result) {
            memcpy(result, start, *out_len);
            result[*out_len] = '\0';
            return result;
        }
    } else if (*start == '{' || *start == '[') {
        // For objects or arrays, find matching brackets
        int brace_count = 0;
        const char* end = start;
        int is_object = (*start == '{');
        int opener = is_object ? '{' : '[';
        int closer = is_object ? '}' : ']';
        
        do {
            if (*end == opener) {
                brace_count++;
            } else if (*end == closer) {
                brace_count--;
            } else if (*end == '"' && brace_count > 0) {
                // Skip strings inside the object/array
                end++;
                while (*end && *end != '"') {
                    if (*end == '\\' && *(end + 1)) end++;  // Skip escaped chars
                    end++;
                }
                if (*end) end--; // Because of increment at loop end
            }
            if (*end) end++;
        } while (brace_count > 0 && *end != '\0');
        
        *out_len = end - start;
        char* result = malloc(*out_len + 1);
        if (result) {
            memcpy(result, start, *out_len);
            result[*out_len] = '\0';
            return result;
        }
    } else {
        // Handle non-string values (numbers, booleans)
        const char* end = start;
        while (*end && *end != ',' && *end != '}' && *end != ']' && *end != '\n' && *end != '\r') {
            end++;
        }
        // Backtrack to trim whitespace
        while (end > start && isspace(*(end-1))) end--;
        *out_len = end - start;
        char* result = malloc(*out_len + 1);
        if (result) {
            memcpy(result, start, *out_len);
            result[*out_len] = '\0';
            return result;
        }
    }
    return NULL;
}

char* extract_session_id_from_header(const char* headers) {
    const char* cookie_start = strstr(headers, "Cookie: ");
    if (!cookie_start) {
        return NULL;
    }
    cookie_start += 8; // Skip "Cookie: "
    
    const char* session_start = strstr(cookie_start, "session_id=");
    if (!session_start) {
        return NULL;
    }
    session_start += 11; // Skip "session_id="
    
    const char* session_end = strchr(session_start, ';');
    if (!session_end) {
        session_end = strpbrk(session_start, "\n\r "); // Look for newline, space, or carriage return
        if (!session_end) {
            session_end = session_start + strlen(session_start);
        }
    }
    
    if (session_end - session_start > 36) return NULL; // UUID should be exactly 36 chars
    
    static char session_id[37];
    int len = session_end - session_start;
    if (len >= 36) len = 36; // UUID length
    
    strncpy(session_id, session_start, len);
    session_id[len] = '\0';
    return session_id[0] ? session_id : NULL;
}

int get_user_by_session_id(const char* session_id) {
    for (int i = 0; i < session_count; i++) {
        if (sessions[i].active && strcmp(sessions[i].session_id, session_id) == 0) {
            return sessions[i].user_id; // Return user_id
        }
    }
    return -1; // Invalid session
}

int authenticate_request(const char* headers) {
    char* session_id = (char*)extract_session_id_from_header(headers);
    if (!session_id) {
        return -1; // No session ID found
    }
    
    return get_user_by_session_id(session_id);
}

int register_session(int user_id) {
    if (session_count >= MAX_SESSIONS) {
        return -1; // Too many sessions
    }
    
    uuid_t uuid;
    uuid_generate_random(uuid);
    uuid_unparse_lower(uuid, sessions[session_count].session_id);
    sessions[session_count].user_id = user_id;
    sessions[session_count].active = 1;
    session_count++;
    
    return session_count - 1; // Return index of new session
}

// Find user by username. Return index or -1 if not found.
int find_user_by_username(const char* username) {
    for (int i = 0; i < user_count; i++) {
        if (users[i].active && strcmp(users[i].username, username) == 0) {
            return i;
        }
    }
    return -1;
}

// Find todo by ID and user_id. Return index or -1 if not found.
int find_todo_by_id_for_user(int todo_id, int user_id) {
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id && todos[i].id > 0) {
            return i;
        }
    }
    return -1;
}

void handle_register(int client_socket, const char* body) {
    // Extract username
    int user_len = 0;
    char* user_name = extract_json_value(body, "username", &user_len);
    if (!user_name || user_len == 0) {
        send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid request\"}");
        if (user_name) free(user_name);
        return;
    }
    
    // Extract password
    int pass_len = 0;
    char* pass_word = extract_json_value(body, "password", &pass_len);
    if (!pass_word || pass_len == 0) {
        send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid request\"}");
        if (user_name) free(user_name);
        if (pass_word) free(pass_word);
        return;
    }
    
    // Validation
    if (!validate_username(user_name)) {
        send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid username\"}");
        free(user_name);
        free(pass_word);
        return;
    }
    
    if (pass_len < MIN_PASSWORD_LENGTH) {
        send_response(client_socket, 400, "application/json", "{\"error\": \"Password too short\"}");
        free(user_name);
        free(pass_word);
        return;
    }
    
    // Check if username already exists
    if (find_user_by_username(user_name) != -1) {
        send_response(client_socket, 409, "application/json", "{\"error\": \"Username already exists\"}");
        free(user_name);
        free(pass_word);
        return;
    }
    
    // Add new user
    if (user_count >= MAX_USERS) {
        send_response(client_socket, 500, "application/json", "{\"error\": \"Server limit reached\"}");
        free(user_name);
        free(pass_word);
        return;
    }
    
    int pos = user_count++;
    users[pos].id = next_user_id++;
    strncpy(users[pos].username, user_name, sizeof(users[pos].username) - 1);
    users[pos].username[sizeof(users[pos].username) - 1] = '\0';
    strncpy(users[pos].password, pass_word, sizeof(users[pos].password) - 1);
    users[pos].password[sizeof(users[pos].password) - 1] = '\0';
    users[pos].active = 1;
    
    // Prepare success response
    char response[512];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", 
             users[pos].id, users[pos].username);
    
    send_response(client_socket, 201, "application/json", response);
    
    free(user_name);
    free(pass_word);
}

void handle_login(int client_socket, const char* body) {
    // Extract username
    int user_len = 0;
    char* user_name = extract_json_value(body, "username", &user_len);
    if (!user_name || user_len == 0) {
        send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid request\"}");
        if (user_name) free(user_name);
        return;
    }
    
    // Extract password
    int pass_len = 0;
    char* pass_word = extract_json_value(body, "password", &pass_len);
    if (!pass_word || pass_len == 0) {
        send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid request\"}");
        free(user_name);
        if (pass_word) free(pass_word);
        return;
    }
    
    int user_idx = find_user_by_username(user_name);
    if (user_idx == -1 || strcmp(users[user_idx].password, pass_word) != 0) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Invalid credentials\"}");
        free(user_name);
        free(pass_word);
        return;
    }
    
    // Register a new session
    int session_idx = register_session(users[user_idx].id);
    if (session_idx == -1) {
        send_response(client_socket, 500, "application/json", "{\"error\": \"Server error\"}");
        free(user_name);
        free(pass_word);
        return;
    }
    
    // Send success response with set-cookie header
    char response_with_cookie[2048];
    snprintf(response_with_cookie, sizeof(response_with_cookie), 
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n\r\n"
        "{\"id\": %d, \"username\": \"%s\"}",
        sessions[session_idx].session_id,
        30 + strlen(users[user_idx].username),
        users[user_idx].id, 
        users[user_idx].username);
    send(client_socket, response_with_cookie, strlen(response_with_cookie), 0);
    
    free(user_name);
    free(pass_word);
}

void handle_logout(int client_socket, const char* headers) {
    char* session_id = (char*)extract_session_id_from_header(headers);
    if (!session_id) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    int session_found = 0;
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].session_id, session_id) == 0 && sessions[i].active) {
            sessions[i].active = 0;
            session_found = 1;
            break;
        }
    }
    
    if (!session_found) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    send_response(client_socket, 200, "application/json", "{}");
}

void handle_get_me(int client_socket, const char* headers) {
    int user_id = authenticate_request(headers);
    if (user_id == -1) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Find user by its ID
    int user_idx = -1;
    for (int i = 0; i < user_count; i++) {
        if (users[i].active && users[i].id == user_id) {
            user_idx = i;
            break;
        }
    }
    
    if (user_idx == -1) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    char response[512];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", 
            users[user_idx].id, users[user_idx].username);
    send_response(client_socket, 200, "application/json", response);
}

void handle_change_password(int client_socket, const char* headers, const char* body) {
    int user_id = authenticate_request(headers);
    if (user_id == -1) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    int user_idx = -1;
    for (int i = 0; i < user_count; i++) {
        if (users[i].active && users[i].id == user_id) {
            user_idx = i;
            break;
        }
    }
    
    if (user_idx == -1) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Get old and new passwords
    int old_pass_len = 0, new_pass_len = 0;
    char* old_pass = extract_json_value((char*)body, "old_password", &old_pass_len);
    char* new_pass = extract_json_value((char*)body, "new_password", &new_pass_len);
    
    if (!old_pass || !new_pass) {
        if (old_pass) free(old_pass);
        if (new_pass) free(new_pass);
        send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid request\"}");
        return;
    }
    
    // Verify old password
    if (strcmp(users[user_idx].password, old_pass) != 0) {
        free(old_pass);
        free(new_pass);
        send_response(client_socket, 401, "application/json", "{\"error\": \"Invalid credentials\"}");
        return;
    }
    
    if (new_pass_len < MIN_PASSWORD_LENGTH) {
        free(old_pass);
        free(new_pass);
        send_response(client_socket, 400, "application/json", "{\"error\": \"Password too short\"}");
        return;
    }
    
    strncpy(users[user_idx].password, new_pass, sizeof(users[user_idx].password) - 1);
    users[user_idx].password[sizeof(users[user_idx].password) - 1] = '\0';
    free(old_pass);
    free(new_pass);
    send_response(client_socket, 200, "application/json", "{}");
}

void handle_list_todos(int client_socket, const char* headers) {
    int user_id = authenticate_request(headers);
    if (user_id == -1) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Count user's todos
    int count = 0;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id == user_id && todos[i].id > 0) {
            count++;
        }
    }
    
    if (count == 0) {
        send_response(client_socket, 200, "application/json", "[]");
        return;
    }
    
    // Create JSON array of todos - use a larger buffer
    int max_buffer_size = 128 + count * 1000; // Estimate ~1000 chars per todo
    char* todos_array = malloc(max_buffer_size);
    if (!todos_array) {
        send_response(client_socket, 500, "application/json", "{\"error\": \"Server error\"}");
        return;
    }
    
    strcpy(todos_array, "[");
    int pos = 1; // Current position after "["
    int first = 1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id == user_id && todos[i].id > 0) {
            // Escape quotes in title and description for JSON
            // For simplicity, assume titles/descriptions don't have special JSON chars
            int chars_written = snprintf(
                todos_array + pos,
                max_buffer_size - pos,
                "%s{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                first ? "" : ",",
                todos[i].id,
                todos[i].title,
                todos[i].description,
                todos[i].completed ? "true" : "false",
                todos[i].created_at,
                todos[i].updated_at
            );
            pos += chars_written;
            first = 0;
            
            if (pos >= max_buffer_size - 200) { // Add padding to avoid overflow
                // Resize if needed
                max_buffer_size *= 2;
                char* new_todos_array = realloc(todos_array, max_buffer_size);
                if (!new_todos_array) {
                    free(todos_array);
                    send_response(client_socket, 500, "application/json", "{\"error\": \"Server error\"}");
                    return;
                }
                todos_array = new_todos_array;
            }
        }
    }
    snprintf(todos_array + pos, max_buffer_size - pos, "]");
    
    send_response(client_socket, 200, "application/json", todos_array);
    free(todos_array);
}

void handle_create_todo(int client_socket, const char* headers, const char* body) {
    int user_id = authenticate_request(headers);
    if (user_id == -1) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Extract title and optional description
    int title_len = 0;
    char* title = extract_json_value((char*)body, "title", &title_len);
    if (!title || title_len == 0) {
        send_response(client_socket, 400, "application/json", "{\"error\": \"Title is required\"}");
        if (title) free(title);
        return;
    }
    
    // Extract description if present
    int desc_len = 0;
    char* desc = extract_json_value((char*)body, "description", &desc_len);
    
    // Validate title is non-empty (already done by extraction func returning non-empty)
    if (title_len == 0) {
        free(title);
        if (desc) free(desc);
        send_response(client_socket, 400, "application/json", "{\"error\": \"Title is required\"}");
        return;
    }
    
    if (todo_count >= MAX_TODOS) {
        free(title);
        if (desc) free(desc);
        send_response(client_socket, 500, "application/json", "{\"error\": \"Server limit reached\"}");
        return;
    }
    
    // Create new todo
    int pos = todo_count++;
    
    todos[pos].id = next_todo_id++;
    todos[pos].user_id = user_id;
    strncpy(todos[pos].title, title, sizeof(todos[pos].title) - 1);
    todos[pos].title[sizeof(todos[pos].title) - 1] = '\0';
    
    if (desc) {
        strncpy(todos[pos].description, desc, sizeof(todos[pos].description) - 1);
        todos[pos].description[sizeof(todos[pos].description) - 1] = '\0';
        free(desc);
    } else {
        todos[pos].description[0] = '\0';
    }
    
    todos[pos].completed = 0;
    strcpy(todos[pos].created_at, get_current_time_str());
    strcpy(todos[pos].updated_at, get_current_time_str());
    
    // Prepare response
    char response[2048];
    snprintf(response, sizeof(response),
        "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": false, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
        todos[pos].id,
        todos[pos].title, 
        todos[pos].description, 
        todos[pos].created_at,
        todos[pos].updated_at
    );
    
    free(title);
    send_response(client_socket, 201, "application/json", response);
}

void handle_get_todo(int client_socket, const char* headers, int todo_id) {
    int user_id = authenticate_request(headers);
    if (user_id == -1) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    int todo_idx = find_todo_by_id_for_user(todo_id, user_id);
    if (todo_idx == -1) {
        send_response(client_socket, 404, "application/json", "{\"error\": \"Todo not found\"}");
        return;
    }
    
    // Send todo object
    char response[2048];
    snprintf(response, sizeof(response),
        "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
        todos[todo_idx].id,
        todos[todo_idx].title,
        todos[todo_idx].description,
        todos[todo_idx].completed ? "true" : "false",
        todos[todo_idx].created_at,
        todos[todo_idx].updated_at
    );
    
    send_response(client_socket, 200, "application/json", response);
}

void handle_update_todo(int client_socket, const char* headers, const char* body, int todo_id) {
    int user_id = authenticate_request(headers);
    if (user_id == -1) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    int todo_idx = find_todo_by_id_for_user(todo_id, user_id);
    if (todo_idx == -1) {
        send_response(client_socket, 404, "application/json", "{\"error\": \"Todo not found\"}");
        return;
    }
    
    // Extract fields that might be updated
    int title_len = 0;
    char* title = extract_json_value((char*)body, "title", &title_len);
    
    int desc_len = 0;
    char* desc = extract_json_value((char*)body, "description", &desc_len);
    
    int completed_len = 0;
    char* completed = extract_json_value((char*)body, "completed", &completed_len);
    
    int is_error = 0;
    if (title && title_len == 0) {
        is_error = 1;
    } else if (title) {
        strncpy(todos[todo_idx].title, title, sizeof(todos[todo_idx].title) - 1);
        todos[todo_idx].title[sizeof(todos[todo_idx].title) - 1] = '\0';
    }
    
    if (desc) {
        strncpy(todos[todo_idx].description, desc, sizeof(todos[todo_idx].description) - 1);
        todos[todo_idx].description[sizeof(todos[todo_idx].description) - 1] = '\0';
    }
    
    if (completed) {
        // Parse boolean value - compare with true or false
        if (completed_len == 4 && strncmp(completed, "true", 4) == 0) {
            todos[todo_idx].completed = 1;
        } else if (completed_len == 5 && strncmp(completed, "false", 5) == 0) {
            todos[todo_idx].completed = 0;
        }
    }
    
    if (is_error) {
        if (title) free(title);
        if (desc) free(desc);
        if (completed) free(completed);
        send_response(client_socket, 400, "application/json", "{\"error\": \"Title is required\"}");
        return;
    }
    
    if (title) free(title);
    if (desc) free(desc);
    if (completed) free(completed);
    
    // Update timestamp
    strcpy(todos[todo_idx].updated_at, get_current_time_str());
    
    // Send updated todo
    char response[2048];
    snprintf(response, sizeof(response),
        "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
        todos[todo_idx].id,
        todos[todo_idx].title,
        todos[todo_idx].description,
        todos[todo_idx].completed ? "true" : "false",
        todos[todo_idx].created_at,
        todos[todo_idx].updated_at
    );
    
    send_response(client_socket, 200, "application/json", response);
}

void handle_delete_todo(int client_socket, const char* headers, int todo_id) {
    int user_id = authenticate_request(headers);
    if (user_id == -1) {
        send_response(client_socket, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    int todo_idx = find_todo_by_id_for_user(todo_id, user_id);
    if (todo_idx == -1) {
        send_response(client_socket, 404, "application/json", "{\"error\": \"Todo not found\"}");
        return;
    }
    
    // Instead of removing elements, just flag the todo as deleted
    // In a real implementation, we might want to actually remove from array
    todos[todo_idx].id = -1; // Mark as deleted
    
    send_response(client_socket, 204, "application/json", NULL);
}

void process_request(int client_socket, const char* request) {
    char method[16], path[256], version[16];
    
    // Parse request line
    if (sscanf(request, "%15s %255s %15s", method, path, version) != 3) {
        send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid request\"}");
        return;
    }
    
    // Divide request into headers and body
    const char* body = strstr(request, "\r\n\r\n");
    if (body) {
        body += 4; // Skip \r\n\r\n
        body = strdup(body); // Make modifiable copy for processing
    } else {
        body = NULL;
    }
    
    // Headers part of original string until body separator
    char* headers_only = strdup(request);
    char* end_of_headers = strstr(headers_only, "\r\n\r\n");
    if (end_of_headers) {
        *(end_of_headers + 2) = '\0'; // Just keep until \r\n
    }
    
    // Handle different endpoints with different methods
    if (strcmp(method, "POST") == 0 && strcmp(path, "/register") == 0) {
        handle_register(client_socket, !body ? "" : body);
    } else if (strcmp(method, "POST") == 0 && strcmp(path, "/login") == 0) {
        handle_login(client_socket, !body ? "" : body);
    } else if (strcmp(method, "POST") == 0 && strcmp(path, "/logout") == 0) {
        handle_logout(client_socket, headers_only);
    } else if (strcmp(method, "GET") == 0 && strcmp(path, "/me") == 0) {
        handle_get_me(client_socket, headers_only);
    } else if (strcmp(method, "PUT") == 0 && strcmp(path, "/password") == 0) {
        handle_change_password(client_socket, headers_only, !body ? "" : body);
    } else if (strcmp(method, "GET") == 0 && strcmp(path, "/todos") == 0) {
        handle_list_todos(client_socket, headers_only);
    } else if (strcmp(method, "POST") == 0 && strcmp(path, "/todos") == 0) {
        handle_create_todo(client_socket, headers_only, !body ? "" : body);
    } else if (strcmp(method, "GET") == 0 && strncmp(path, "/todos/", 7) == 0) {
        // Parse todo id
        int todo_id;
        if (sscanf(path + 7, "%d", &todo_id) == 1) {
            handle_get_todo(client_socket, headers_only, todo_id);
        } else {
            send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid todo ID\"}");
        }
    } else if (strcmp(method, "PUT") == 0 && strncmp(path, "/todos/", 7) == 0) {
        // Parse todo id
        int todo_id;
        if (sscanf(path + 7, "%d", &todo_id) == 1) {
            handle_update_todo(client_socket, headers_only, !body ? "" : body, todo_id);
        } else {
            send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid todo ID\"}");
        }
    } else if (strcmp(method, "DELETE") == 0 && strncmp(path, "/todos/", 7) == 0) {
        // Parse todo id
        int todo_id;
        if (sscanf(path + 7, "%d", &todo_id) == 1) {
            handle_delete_todo(client_socket, headers_only, todo_id);
        } else {
            send_response(client_socket, 400, "application/json", "{\"error\": \"Invalid todo ID\"}");
        }
    } else {
        send_response(client_socket, 404, "application/json", "{\"error\": \"Endpoint not found\"}");
    }
    
    // Clean up
    if (body != NULL) {
        free((char*)body);
    }
    free(headers_only);
}

int main(int argc, char *argv[]) {
    int opt = 0;
    int port = 0;
    
    // Parse --port argument
    for (int i = 1; i < argc; i += 2) {
        if (i + 1 < argc && strcmp(argv[i], "--port") == 0) {
            port = atoi(argv[i + 1]);
            if (port <= 0) {
                printf("Error: Invalid port number\n");
                exit(1);
            }
        } else if (strcmp(argv[i], "--port") == 0) {
            printf("Error: No port number specified\n");
            exit(1);
        }
    }
    
    if (port == 0) {
        printf("Usage: %s --port PORT\n", argv[0]);
        exit(1);
    }
    
    // Initialize data structures
    memset(users, 0, sizeof(users));
    memset(todos, 0, sizeof(todos));
    memset(sessions, 0, sizeof(sessions));
    user_count = 0;
    todo_count = 0;
    session_count = 0;
    next_user_id = 1;
    next_todo_id = 1;
    
    int server_fd, client_socket;
    struct sockaddr_in address;
    int addrlen = sizeof(address);
    
    // Create socket
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }
    
    // Set socket options
    opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt");
        exit(EXIT_FAILURE);
    }
    
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);
    
    // Bind to port
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }
    
    // Start listening
    if (listen(server_fd, 10) < 0) {
        perror("listen");
        exit(EXIT_FAILURE);
    }
    
    printf("Server listening on 0.0.0.0:%d\n", port);
    
    while (1) {
        if ((client_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen)) < 0) {
            perror("accept failed");
            continue;
        }
        
        char buffer[MAX_REQUEST_SIZE];
        int valread = recv(client_socket, buffer, MAX_REQUEST_SIZE - 1, 0);
        if (valread > 0) {
            buffer[valread] = '\0';
            process_request(client_socket, buffer);
        }
        
        close(client_socket);
    }
    
    return 0;
}
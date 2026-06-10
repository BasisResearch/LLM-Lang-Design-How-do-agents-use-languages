#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <ctype.h>
#include <uuid/uuid.h>
#include <regex.h>

#define MAX_USERS 1000
#define MAX_TODOS 10000
#define MAX_SESSIONS 1000
#define BUFFER_SIZE 8192
#define USERNAME_MAX_LENGTH 50
#define PASSWORD_MIN_LENGTH 8

typedef struct {
    char id[37]; // UUID string length (including null terminator)
    int user_id;
    time_t created_at;
    int active; // boolean to track if session is valid
} Session;

typedef struct {
    int id;
    char username[USERNAME_MAX_LENGTH + 1];
    char password_hash[256]; // Store hashed passwords
    time_t created_at;
    int active; // Boolean to track if user is active
} User;

typedef struct {
    int id;
    int user_id;
    char title[500];
    char description[2000];
    int completed; // boolean
    time_t created_at;
    time_t updated_at;
    int active; // Boolean to track if todo is active
} Todo;

User users[MAX_USERS];
int num_users = 0;
Todo todos[MAX_TODOS];
int num_todos = 0;
Session sessions[MAX_SESSIONS];
int num_sessions = 0;

char* format_time(time_t t) {
    static char buffer[30];
    strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", gmtime(&t));
    return buffer;
}

void generate_uuid(char *str) {
    uuid_t uuid;
    uuid_generate_random(uuid);
    uuid_unparse(uuid, str);
}

int find_user_by_username(const char* username) {
    for (int i = 0; i < num_users; i++) {
        if (users[i].active && strcmp(users[i].username, username) == 0) {
            return i;
        }
    }
    return -1;
}

// Check for exact session match
int find_session_by_id(const char* session_id) {
    for (int i = 0; i < num_sessions; i++) {
        if (sessions[i].active && strcmp(sessions[i].id, session_id) == 0) {
            return i;
        }
    }
    return -1;
}

// Fixed cookie extraction - read just the Cookie header value
char* extract_cookie_value(const char* headers, const char* cookie_name) {
    static char value[512];
    
    // Find the start of the Cookie header
    const char* cookie_line = strstr(headers, "Cookie:");
    if (!cookie_line) {
        // Also try lowercase which might appear in different client implementations
        cookie_line = strstr(headers, "cookie:");
    }
    
    if (!cookie_line) {
        return NULL;
    }
    
    // Find end of cookie line (next newline)
    const char* end_of_line = strchr(cookie_line, '\n');
    if (!end_of_line) {
        return NULL;
    }
    
    // Extract just the line content
    static char cookie_header[512];
    int len = end_of_line - cookie_line;
    len = len < sizeof(cookie_header) - 1 ? len : sizeof(cookie_header) - 1;
    strncpy(cookie_header, cookie_line, len);
    cookie_header[len] = '\0';
    
    // Search for format "Cookie: ...session_id=value..."
    char pattern[100];
    snprintf(pattern, sizeof(pattern), "%s=", cookie_name);
    
    const char* pos = strstr(cookie_header, pattern);
    if (!pos) {
        return NULL;
    }
    
    pos += strlen(pattern);  // Move to start of value
    
    // Value ends at semicolon, comma, or end of cookie_header line
    const char* end = pos;
    while (*end && *end != ';' && *end != ',' && *end != '\r' && *end != '\n' && *end != ' ') {
        end++;
    }
    
    int val_len = end - pos;
    if (val_len >= sizeof(value)) {
        val_len = sizeof(value) - 1;
    }
    
    strncpy(value, pos, val_len);
    value[val_len] = '\0';
    
    // Trim trailing spaces
    while (val_len > 0 && value[val_len - 1] == ' ') {
        val_len--;
        value[val_len] = '\0';
    }
    
    return value[0] ? value : NULL;  // Return NULL if empty
}

void send_response(int client_socket, int status_code, const char* body, int has_body) {
    char response[BUFFER_SIZE * 2];
    
    switch(status_code) {
        case 200:
            strcpy(response, "HTTP/1.1 200 OK\r\n");
            break;
        case 201:
            strcpy(response, "HTTP/1.1 201 Created\r\n");
            break;
        case 204:
            strcpy(response, "HTTP/1.1 204 No Content\r\n");
            break;
        case 400:
            strcpy(response, "HTTP/1.1 400 Bad Request\r\n");
            break;
        case 401:
            strcpy(response, "HTTP/1.1 401 Unauthorized\r\n");
            break;
        case 403:
            strcpy(response, "HTTP/1.1 403 Forbidden\r\n");
            break;
        case 404:
            strcpy(response, "HTTP/1.1 404 Not Found\r\n");
            break;
        case 405:
            strcpy(response, "HTTP/1.1 405 Method Not Allowed\r\n");
            break;
        case 409:
            strcpy(response, "HTTP/1.1 409 Conflict\r\n");
            break;
        case 507:
            strcpy(response, "HTTP/1.1 507 Insufficient Storage\r\n");
            break;
        default:
            snprintf(response, sizeof(response), "HTTP/1.1 %d Unknown\r\n", status_code);
            break;
    }
    
    strcat(response, "Content-Type: application/json\r\n");
    
    if (has_body) {
        char content_length[50];
        snprintf(content_length, sizeof(content_length), "Content-Length: %d\r\n", (int)strlen(body));
        strcat(response, content_length);
        strcat(response, "\r\n");
        strcat(response, body);
    } else {
        strcat(response, "Content-Length: 0\r\n");
        strcat(response, "\r\n");
    }
    
    write(client_socket, response, strlen(response));
}

int validate_username(const char* username) {
    int len = strlen(username);
    if (len < 3 || len > USERNAME_MAX_LENGTH) {
        return 0; // invalid
    }
    
    regex_t regex;
    int reti;
    
    reti = regcomp(&regex, "^[a-zA-Z0-9_]+$", REG_EXTENDED | REG_NOSUB);
    if (reti) {
        return 0; // regex compilation failed
    }
    
    reti = regexec(&regex, username, 0, NULL, 0);
    regfree(&regex);
    
    return reti == 0; // 0 means match found
}

// Safe JSON field extraction with explicit copying
int extract_json_string_field(const char* json, const char* field_name, char* output, int output_size) {
    char search_pattern[200];
    snprintf(search_pattern, sizeof(search_pattern), "\"%s\":", field_name);
    
    const char* pos = strstr(json, search_pattern);
    if (!pos) return 0;
    
    pos += strlen(search_pattern);
    while (*pos && isspace((unsigned char)*pos)) pos++;
    
    if (*pos != '"') return 0;  // Value should start with quote 
    pos++;  // Skip the quote
    
    const char* start = pos;
    int escaped = 0;
    int copied = 0;
    
    while (*pos) {
        if (!escaped && *pos == '\\') {
            escaped = 1;
        } else if (!escaped && *pos == '"') {
            // Found unescaped closing quote
            output[copied < output_size-1 ? copied : output_size-1] = '\0';
            return 1;  // Success
        } else {
            if (copied < output_size-1) {
                output[copied] = *pos;
            }
            copied++;
            escaped = 0;  // Reset escape flag for next iteration
        }
        pos++;
    }
    
    // Did not find closing quote
    output[copied < output_size-1 ? copied : output_size-1] = '\0';
    return 0;  // Failed to find end quote
}

void handle_register(int client_socket, const char* body) {
    if (!body || strlen(body) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Missing request body\"}", 1);
        return;
    }
    
    char username[USERNAME_MAX_LENGTH + 10], password[256];
    if (!extract_json_string_field(body, "username", username, sizeof(username)) ||
        !extract_json_string_field(body, "password", password, sizeof(password))) {
        send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
        return;
    }
    
    if (strlen(username) == 0 || strlen(password) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Username and password required\"}", 1);
        return;
    }
    
    if (!validate_username(username)) {
        send_response(client_socket, 400, "{\"error\": \"Invalid username\"}", 1);
        return;
    }
    
    if (find_user_by_username(username) != -1) {
        send_response(client_socket, 409, "{\"error\": \"Username already exists\"}", 1);
        return;
    }
    
    if (strlen(password) < PASSWORD_MIN_LENGTH) {
        send_response(client_socket, 400, "{\"error\": \"Password too short\"}", 1);
        return;
    }
    
    if (num_users >= MAX_USERS) {
        send_response(client_socket, 507, "{\"error\": \"Storage limit exceeded\"}", 1);
        return;
    }
    
    User* user = &users[num_users];
    user->id = num_users + 1;
    strncpy(user->username, username, USERNAME_MAX_LENGTH);
    user->username[USERNAME_MAX_LENGTH] = '\0';
    strncpy(user->password_hash, password, sizeof(user->password_hash)-1);
    user->password_hash[sizeof(user->password_hash)-1] = '\0';
    time(&user->created_at);
    user->active = 1;
    
    num_users++;
    
    char response[500];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", user->id, user->username);
    send_response(client_socket, 201, response, 1);
}

void handle_login(int client_socket, const char* body) {
    if (!body || strlen(body) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Missing request body\"}", 1);
        return;
    }
    
    char username[USERNAME_MAX_LENGTH + 10], password[256];
    if (!extract_json_string_field(body, "username", username, sizeof(username)) ||
        !extract_json_string_field(body, "password", password, sizeof(password))) {
        send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
        return;
    }
    
    int user_index = find_user_by_username(username);
    if (user_index == -1 || strcmp(users[user_index].password_hash, password) != 0) {
        send_response(client_socket, 401, "{\"error\": \"Invalid credentials\"}", 1);
        return;
    }
    
    if (num_sessions >= MAX_SESSIONS) {
        send_response(client_socket, 507, "{\"error\": \"Storage limit exceeded\"}", 1);
        return;
    }
    
    Session* session = &sessions[num_sessions];
    generate_uuid(session->id);
    session->user_id = users[user_index].id;
    time(&session->created_at);
    session->active = 1;
    num_sessions++;
    
    char response[BUFFER_SIZE * 2];
    char user_data[500];
    snprintf(user_data, sizeof(user_data), "{\"id\": %d, \"username\": \"%s\"}", users[user_index].id, users[user_index].username);
    snprintf(response, sizeof(response), 
             "HTTP/1.1 200 OK\r\n"
             "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n"
             "Content-Type: application/json\r\n"
             "Content-Length: %d\r\n\r\n%s",
             session->id,
             (int)strlen(user_data),
             user_data);
    
    write(client_socket, response, strlen(response));
}

int get_current_user_id_from_header(const char* headers) {
    char* session_id = extract_cookie_value(headers, "session_id");
    if (!session_id) {
        return -1;
    }
    
    int session_idx = find_session_by_id(session_id);
    if (session_idx == -1 || !sessions[session_idx].active) {
        return -1;
    }
    
    return sessions[session_idx].user_id;
}

void handle_logout(int client_socket, const char* headers) {
    char* session_id = extract_cookie_value(headers, "session_id");
    if (!session_id) {
        send_response(client_socket, 401, "{\"error\": \"Authentication required\"}", 1);
        return;
    }
    
    int session_idx = find_session_by_id(session_id);
    if (session_idx == -1 || !sessions[session_idx].active) {
        send_response(client_socket, 401, "{\"error\": \"Authentication required\"}", 1);
        return;
    }
    
    sessions[session_idx].active = 0;
    send_response(client_socket, 200, "{}", 1);
}

void handle_get_me(int client_socket, int user_id) {
    for (int i = 0; i < num_users; i++) {
        if (users[i].active && users[i].id == user_id) {
            char response[500];
            snprintf(response, sizeof(response), 
                     "{\"id\": %d, \"username\": \"%s\"}", 
                     users[i].id, users[i].username);
            send_response(client_socket, 200, response, 1);
            return;
        }
    }
    send_response(client_socket, 401, "{\"error\": \"Authentication required\"}", 1);
}

void handle_update_password(int client_socket, int user_id, const char* body) {
    if (!body || strlen(body) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Missing request body\"}", 1);
        return;
    }
    
    // Find the user
    int user_idx = -1;
    for (int i = 0; i < num_users; i++) {
        if (users[i].active && users[i].id == user_id) {
            user_idx = i;
            break;
        }
    }
    
    if (user_idx == -1) {
        send_response(client_socket, 401, "{\"error\": \"Authentication required\"}", 1);
        return;
    }
    
    // Extract old and new passwords from JSON
    char old_password[256], new_password[256];
    if (!extract_json_string_field(body, "old_password", old_password, sizeof(old_password)) ||
        !extract_json_string_field(body, "new_password", new_password, sizeof(new_password))) {
        send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
        return;
    }
    
    // Validate new password length
    if (strlen(new_password) < PASSWORD_MIN_LENGTH) {
        send_response(client_socket, 400, "{\"error\": \"Password too short\"}", 1);
        return;
    }
    
    // Check if old password matches
    if (strcmp(users[user_idx].password_hash, old_password) != 0) {
        send_response(client_socket, 401, "{\"error\": \"Invalid credentials\"}", 1);
        return;
    }
    
    // Update password
    strncpy(users[user_idx].password_hash, new_password, sizeof(users[user_idx].password_hash)-1);
    users[user_idx].password_hash[sizeof(users[user_idx].password_hash)-1] = '\0';
    
    send_response(client_socket, 200, "{}", 1);
}

void handle_get_todos(int client_socket, int user_id) {
    int count = 0;
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id) {
            count++;
        }
    }
    
    char* response = malloc(BUFFER_SIZE * 100);
    if (!response) {
        send_response(client_socket, 507, "{\"error\": \"Storage limit exceeded\"}", 1);
        return;
    }
    
    int offset = 0;
    offset += snprintf(response + offset, BUFFER_SIZE * 100 - offset, "[");
    
    int first = 1;
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id) {
            if (!first) {
                offset += snprintf(response + offset, BUFFER_SIZE * 100 - offset, ",");
            }
            
            char created_at_str[30], updated_at_str[30];
            strcpy(created_at_str, format_time(todos[i].created_at));
            strcpy(updated_at_str, format_time(todos[i].updated_at));
            
            offset += snprintf(response + offset, BUFFER_SIZE * 100 - offset,
                     "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                     todos[i].id,
                     todos[i].title,
                     todos[i].description,
                     todos[i].completed ? "true" : "false",
                     created_at_str,
                     updated_at_str
            );
            first = 0;
        }
    }
    
    offset += snprintf(response + offset, BUFFER_SIZE * 100 - offset, "]");
    send_response(client_socket, 200, response, 1);
    free(response);
}

void handle_create_todo(int client_socket, int user_id, const char* body) {
    if (!body || strlen(body) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Missing request body\"}", 1);
        return;
    }
    
    char title[500], description[2000];
    if (!extract_json_string_field(body, "title", title, sizeof(title))) {
        send_response(client_socket, 400, "{\"error\": \"Title is required\"}", 1);
        return;
    }
    
    int desc_provided = extract_json_string_field(body, "description", description, sizeof(description));
    if(!desc_provided) {
        description[0] = '\0';
    }
    
    if (strlen(title) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Title is required\"}", 1);
        return;
    }
    
    if (num_todos >= MAX_TODOS) {
        send_response(client_socket, 507, "{\"error\": \"Storage limit exceeded\"}", 1);
        return;
    }
    
    Todo* todo = &todos[num_todos];
    todo->id = num_todos + 1;
    todo->user_id = user_id;
    strncpy(todo->title, title, sizeof(todo->title)-1);
    todo->title[sizeof(todo->title)-1] = '\0';
    strncpy(todo->description, description, sizeof(todo->description)-1);
    todo->description[sizeof(todo->description)-1] = '\0';
    todo->completed = 0;
    time(&todo->created_at);
    todo->updated_at = todo->created_at;
    todo->active = 1;
    
    num_todos++;
    
    char response[5000];
    snprintf(response, sizeof(response),
             "{\"id\": %d, "
             "\"title\": \"%s\", "
             "\"description\": \"%s\", "
             "\"completed\": %s, "
             "\"created_at\": \"%s\", "
             "\"updated_at\": \"%s\"}",
             todo->id,
             todo->title,
             todo->description,
             todo->completed ? "true" : "false",
             format_time(todo->created_at),
             format_time(todo->updated_at)
    );
    
    send_response(client_socket, 201, response, 1);
}

void handle_get_specific_todo(int client_socket, int user_id, int todo_id) {
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id && todos[i].id == todo_id) {
            char response[5000];
            snprintf(response, sizeof(response),
                     "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                     todos[i].id,
                     todos[i].title,
                     todos[i].description,
                     todos[i].completed ? "true" : "false",
                     format_time(todos[i].created_at),
                     format_time(todos[i].updated_at)
            );
            send_response(client_socket, 200, response, 1);
            return;
        }
    }
    send_response(client_socket, 404, "{\"error\": \"Todo not found\"}", 1);
}

void handle_update_todo(int client_socket, int user_id, int todo_id, const char* body) {
    if (!body || strlen(body) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Missing request body\"}", 1);
        return;
    }
    
    Todo* target_todo = NULL;
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id && todos[i].id == todo_id) {
            target_todo = &todos[i];
            break;
        }
    }
    
    if (!target_todo) {
        send_response(client_socket, 404, "{\"error\": \"Todo not found\"}", 1);
        return;
    }
    
    char temp_val[2000];
    
    if (extract_json_string_field(body, "title", temp_val, sizeof(temp_val))) {
        if (strlen(temp_val) == 0) {
            send_response(client_socket, 400, "{\"error\": \"Title is required\"}", 1);
            return;
        }
        strncpy(target_todo->title, temp_val, sizeof(target_todo->title)-1);
        target_todo->title[sizeof(target_todo->title)-1] = '\0';
    }
    
    if (extract_json_string_field(body, "description", temp_val, sizeof(temp_val))) {
        strncpy(target_todo->description, temp_val, sizeof(target_todo->description)-1);
        target_todo->description[sizeof(target_todo->description)-1] = '\0';
    }
    
    const char* completed_pos = strstr(body, "\"completed\"");
    if (completed_pos) {
        completed_pos = strstr(completed_pos, ":");
        if (completed_pos) {
            completed_pos++;
            while (*completed_pos && isspace((unsigned char)*completed_pos)) completed_pos++;
            
            if (*completed_pos == 't' && strncmp(completed_pos, "true", 4) == 0) {
                target_todo->completed = 1;
            } else if (*completed_pos == 'f' && strncmp(completed_pos, "false", 5) == 0) {
                target_todo->completed = 0;
            } else if (*completed_pos == '1') {
                target_todo->completed = 1;
            } else if (*completed_pos == '0') {
                target_todo->completed = 0;
            }
        }
    }
    
    time(&target_todo->updated_at);
    
    char response[5000];
    snprintf(response, sizeof(response),
             "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
             target_todo->id,
             target_todo->title,
             target_todo->description,
             target_todo->completed ? "true" : "false",
             format_time(target_todo->created_at),
             format_time(target_todo->updated_at)
    );
    
    send_response(client_socket, 200, response, 1);
}

void handle_delete_todo(int client_socket, int user_id, int todo_id) {
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id && todos[i].id == todo_id) {
            todos[i].active = 0;
            send_response(client_socket, 204, "", 0);
            return;
        }
    }
    send_response(client_socket, 404, "{\"error\": \"Todo not found\"}", 1);
}

void handle_request(int client_socket, const char* method, const char* url, const char* headers, const char* body) {
    int auth_required = 0;
    if (strncmp(url, "/me", 3) == 0   || 
        strncmp(url, "/password", 9) == 0 || 
        strncmp(url, "/todos", 6) == 0 || 
        strncmp(url, "/todos/", 7) == 0) {
        auth_required = 1;
    }
    
    if (auth_required) {
        int user_id = get_current_user_id_from_header(headers);
        if (user_id == -1) {
            send_response(client_socket, 401, "{\"error\": \"Authentication required\"}", 1);
            return;
        }
        
        if (strcmp(method, "GET") == 0 && strcmp(url, "/me") == 0) {
            handle_get_me(client_socket, user_id);
        } else if (strcmp(method, "PUT") == 0 && strcmp(url, "/password") == 0) {
            handle_update_password(client_socket, user_id, body);
        } else if (strcmp(method, "GET") == 0 && strcmp(url, "/todos") == 0) {
            handle_get_todos(client_socket, user_id);
        } else if (strcmp(method, "POST") == 0 && strcmp(url, "/todos") == 0) {
            handle_create_todo(client_socket, user_id, body);
        } else if (strncmp(url, "/todos/", 7) == 0) {
            int todo_id;
            if (sscanf(url + 7, "%d", &todo_id) == 1) {
                if (strcmp(method, "GET") == 0) {
                    handle_get_specific_todo(client_socket, user_id, todo_id);
                } else if (strcmp(method, "PUT") == 0) {
                    handle_update_todo(client_socket, user_id, todo_id, body);
                } else if (strcmp(method, "DELETE") == 0) {
                    handle_delete_todo(client_socket, user_id, todo_id);
                } else {
                    send_response(client_socket, 405, "{\"error\": \"Method not allowed\"}", 1);
                }
            } else {
                send_response(client_socket, 404, "{\"error\": \"Not found\"}", 1);
            }
        } else {
            send_response(client_socket, 404, "{\"error\": \"Not found\"}", 1);
        }
    } else {
        if (strcmp(method, "POST") == 0 && strcmp(url, "/register") == 0) {
            handle_register(client_socket, body);
        } else if (strcmp(method, "POST") == 0 && strcmp(url, "/login") == 0) {
            handle_login(client_socket, body);
        } else if (strcmp(method, "POST") == 0 && strcmp(url, "/logout") == 0) {
            handle_logout(client_socket, headers);
        } else {
            send_response(client_socket, 404, "{\"error\": \"Not found\"}", 1);
        }
    }
}

int main(int argc, char *argv[]) {
    memset(users, 0, sizeof(users));
    memset(todos, 0, sizeof(todos)); 
    memset(sessions, 0, sizeof(sessions));
    
    int port = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
            break;
        } else if (strncmp(argv[i], "--port=", 7) == 0) {
            port = atoi(argv[i] + 7);
            break;
        }
    }
    
    if (port <= 0) {
        fprintf(stderr, "Usage: %s --port PORT\n", argv[0]);
        return 1;
    }
    
    int server_fd, new_socket;
    struct sockaddr_in address;
    int addrlen = sizeof(address);
    
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        return -1;
    }
    
    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        return -1;
    }
    
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);
    
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        return -1;
    }
    
    if (listen(server_fd, 10) < 0) {
        perror("listen failed");
        return -1;
    }
    
    printf("Server is listening on 0.0.0.0:%d\n", port);
    
    while(1) {
        if ((new_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen)) < 0) {
            perror("accept failed");
            return -1;
        }
        
        char buffer[BUFFER_SIZE * 4];
        int valread = read(new_socket, buffer, BUFFER_SIZE * 4 - 1);
        if (valread <= 0) {
            close(new_socket);
            continue;
        }
        buffer[valread] = '\0';
        
        char method[16], url[2048], protocol[16];
        if (sscanf(buffer, "%15s %2047s %15s", method, url, protocol) != 3) {
            send_response(new_socket, 400, "{\"error\": \"Bad request\"}", 1);
            close(new_socket);
            continue;
        }
        
        const char* body = "";
        char* headers_end = strstr(buffer, "\r\n\r\n");
        if (headers_end) {
            body = headers_end + 4;  // Point to after the \r\n\r\n
        } else {
            headers_end = strstr(buffer, "\n\n");
            if (headers_end) {
                body = headers_end + 2;  // Point to after the \n\n
            }
        }
        
        handle_request(new_socket, method, url, buffer, body);
        
        close(new_socket);
    }
    
    return 0;
}
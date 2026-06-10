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
#include <regex.h>
#include <pthread.h>

#define MAX_USERS 1000
#define MAX_TODOS_PER_USER 1000
#define MAX_SESSIONS 1000
#define MAX_USERNAME_LENGTH 51
#define MAX_PASSWORD_LENGTH 100
#define BUFFER_SIZE 8192
#define UUID_STRING_LENGTH 37

// Helper function to trim leading/trailing spaces
char* trim_spaces(char *str) {
    if (!str) return NULL;
    
    // Move start pointer past leading whitespace
    while (isspace((unsigned char)*str)) str++;

    if (*str == '\0') return str;

    // Move end pointer back from trailing whitespace
    char *end = str + strlen(str) - 1;
    while (end > str && isspace((unsigned char)*end)) end--;

    // Null terminate after the last non-space character
    *(end + 1) = '\0';
    
    return str;
}

// Forward declarations
typedef struct user User;
typedef struct todo Todo;
typedef struct session Session;

// Define data structures
struct user {
    int id;
    char username[MAX_USERNAME_LENGTH];
    char password[MAX_PASSWORD_LENGTH];
};

struct todo {
    int id;
    int user_id;
    char title[500];
    char description[1000];
    int completed;
    char created_at[32];
    char updated_at[32];
};

struct session {
    char token[UUID_STRING_LENGTH];
    int user_id;
    int active;
};

// Global variables
User users[MAX_USERS];
int user_count = 0;
int next_user_id = 1;

Todo todos[MAX_USERS * MAX_TODOS_PER_USER];
int todo_count = 0;
int next_todo_id = 1;

Session sessions[MAX_SESSIONS];

pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

// Helper functions
char* get_current_timestamp() {
    static char buffer[32];
    time_t now = time(NULL);
    struct tm *tm_info = gmtime(&now);
    strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", tm_info);
    return buffer;
}

void generate_uuid(char *str) {
    uuid_t uuid;
    uuid_generate(uuid);
    uuid_unparse(uuid, str);
}

int validate_username(const char *username) {
    if (!username || strlen(username) < 3 || strlen(username) > 50) {
        return 0;
    }
    
    regex_t regex;
    int reti = regcomp(&regex, "^[a-zA-Z0-9_]+$", REG_EXTENDED);
    if (reti) {
        return 0;
    }
    
    reti = regexec(&regex, username, 0, NULL, 0);
    regfree(&regex);
    
    // regexec returns 0 on match
    return !reti;
}

int find_user_by_username(const char *username) {
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            return i;
        }
    }
    return -1;
}

int find_session_by_token(const char *token) {
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].active && strcmp(sessions[i].token, token) == 0) {
            return i;
        }
    }
    return -1;
}

int get_user_from_auth(const char *headers_str) {
    char headers_copy[BUFFER_SIZE];
    strncpy(headers_copy, headers_str, BUFFER_SIZE - 1);
    headers_copy[BUFFER_SIZE - 1] = '\0';
    
    char *session_cookie = strstr(headers_copy, "Cookie:");
    if (!session_cookie) {
        return -1;
    }
    
    session_cookie += 7; // Skip "Cookie:"
    while (*session_cookie == ' ') session_cookie++;
    
    // Look for session_id
    char *session_start = strstr(session_cookie, "session_id=");
    if (!session_start) {
        return -1;
    }
    
    session_start += 11; // Skip "session_id="
    char *session_end = strchr(session_start, ';');
    if (session_end) {
        *session_end = '\0';
    } else {
        // Find end of line with \r\n or just newlines
        for (int i = 0; session_start[i]; i++) {
            if (session_start[i] == '\r' || session_start[i] == '\n') {
                session_start[i] = '\0';
                break;
            }
        }
    }
    
    int session_idx = find_session_by_token(session_start);
    if (session_idx == -1) {
        return -1;
    }
    
    return sessions[session_idx].user_id;
}

int is_user_valid(int user_id) {
    if (user_id <= 0) return 0;
    
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            return 1;
        }
    }
    return 0;
}

int find_todo_by_id(int todo_id, int user_id) {
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id && todos[i].user_id == user_id) {
            return i;
        }
    }
    return -1;
}

char* escape_json_string(const char* input) {
    static char escaped[2000];
    char *out = escaped;
    const char *in = input;
    
    *out = '"'; out++; // Start with quote
    while (*in) {
        switch (*in) {
            case '"': *out++ = '\\'; *out++ = '"'; break;
            case '\\': *out++ = '\\'; *out++ = '\\'; break;
            case '\b': *out++ = '\\'; *out++ = 'b'; break;
            case '\f': *out++ = '\\'; *out++ = 'f'; break;
            case '\n': *out++ = '\\'; *out++ = 'n'; break;
            case '\r': *out++ = '\\'; *out++ = 'r'; break;
            case '\t': *out++ = '\\'; *out++ = 't'; break;
            default: 
                if ((unsigned char)*in < 0x20) {
                    sprintf(out, "\\u%04x", (unsigned char)*in);
                    out += 6;
                } else {
                    *out++ = *in;
                }
                break;
        }
        in++;
    }
    *out = '"'; out++; // End with quote
    *out = '\0';
    return escaped;
}

void send_response(int client_fd, int status_code, const char *content_type, const char *body) {
    char response[BUFFER_SIZE * 4];
    const char *status_text;
    
    switch (status_code) {
        case 200: status_text = "OK"; break;
        case 201: status_text = "Created"; break;
        case 204: status_text = "No Content"; break;
        case 400: status_text = "Bad Request"; break;
        case 401: status_text = "Unauthorized"; break;
        case 403: status_text = "Forbidden"; break;
        case 404: status_text = "Not Found"; break;
        case 409: status_text = "Conflict"; break;
        default: status_text = "Internal Server Error"; break;
    }
    
    if (body && strlen(body) > 0) {
        snprintf(response, sizeof(response), 
                "HTTP/1.1 %d %s\r\n"
                "Content-Type: %s\r\n"
                "Connection: close\r\n"
                "Content-Length: %lu\r\n\r\n"
                "%s", 
                status_code, status_text, content_type, strlen(body), body);
    } else {
        snprintf(response, sizeof(response), 
                "HTTP/1.1 %d %s\r\n"
                "Content-Type: %s\r\n"
                "Connection: close\r\n"
                "Content-Length: 0\r\n\r\n", 
                status_code, status_text, content_type);
    }
    
    send(client_fd, response, strlen(response), 0);
}

// Advanced JSON parsing helper
char* extract_json_field(const char *json, const char *field_name) {
    // Build search pattern: "field_name":"...")
    char search_pattern[256];
    snprintf(search_pattern, sizeof(search_pattern), "\"%s\"", field_name);
    
    const char *start = strstr(json, search_pattern);
    if (!start) return NULL;
    
    start = strstr(start + strlen(field_name) + 2, ":"); // Find colon after field name
    if (!start) return NULL;
    
    start++; // Move past colon
    while (*start && isspace((unsigned char)*start)) start++; // Skip whitespace after colon
    
    if (*start != '"') return NULL; // Expect quoted value
    start++; // Skip opening quote
    
    const char *end = strchr(start, '"');
    if (!end) return NULL;
    
    int length = end - start;
    char *result = malloc(length + 1);
    if (result) {
        strncpy(result, start, length);
        result[length] = '\0';
    }
    
    return result;
}

void handle_register(int client_fd, const char *request_body) {
    // Extract parameters using improved JSON parsing
    char *username = extract_json_field(request_body, "username");
    char *password = extract_json_field(request_body, "password");
    
    if (!username || !password) {
        free(username);
        free(password);
        
        // Fall back to sscanf if JSON parsing didn't work - try variations with spaces
        username = malloc(MAX_USERNAME_LENGTH);
        password = malloc(MAX_PASSWORD_LENGTH);
        
        int scanned = sscanf(request_body, "{\"username\":\"%50[^\"]\",\"password\":\"%99[^\"]\"}", username, password);
        if (scanned != 2) {
            scanned = sscanf(request_body, "{\"username\": \"%50[^\"]\", \"password\": \"%99[^\"]\"}", username, password);
        }
        if (scanned != 2) {
            scanned = sscanf(request_body, "{\"username\":\"%50[^\"]\", \"password\":\"%99[^\"]\"}", username, password);
        }
        if (scanned != 2) {
            scanned = sscanf(request_body, "{\"username\": \"%50[^\"]\",\"password\":\"%99[^\"]\"}", username, password);
        }
        
        trim_spaces(username);
        trim_spaces(password);
    }

    // Validate username
    if (!validate_username(username) || !username || strlen(username) == 0) {
        send_response(client_fd, 400, "application/json", "{\"error\": \"Invalid username\"}");
        free(username);
        free(password);
        return;
    }
    
    // Check if username already exists
    if (find_user_by_username(username) != -1) {
        send_response(client_fd, 409, "application/json", "{\"error\": \"Username already exists\"}");
        free(username);
        free(password);
        return;
    }
    
    // Validate password
    if (!password || strlen(password) < 8) {
        send_response(client_fd, 400, "application/json", "{\"error\": \"Password too short\"}");
        free(username);
        free(password);
        return;
    }
    
    // Create new user
    if (user_count >= MAX_USERS) {
        send_response(client_fd, 500, "application/json", "{\"error\": \"Server capacity reached\"}");
        free(username);
        free(password);
        return;
    }
    
    User new_user;
    new_user.id = next_user_id++;
    strcpy(new_user.username, username);
    strcpy(new_user.password, password);
    
    users[user_count++] = new_user;
    
    char response[200];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", new_user.id, new_user.username);
    send_response(client_fd, 201, "application/json", response);
    
    free(username);
    free(password);
}

void handle_login(int client_fd, const char *request_body) {
    char *username = extract_json_field(request_body, "username");
    char *password = extract_json_field(request_body, "password");
    
    if (!username || !password) {
        free(username);
        free(password);
        
        // Fall back to alternative parsing
        username = malloc(MAX_USERNAME_LENGTH);
        password = malloc(MAX_PASSWORD_LENGTH);
        
        int scanned = sscanf(request_body, "{\"username\":\"%50[^\"]\",\"password\":\"%99[^\"]\"}", username, password);
        if (scanned != 2) {
            scanned = sscanf(request_body, "{\"username\": \"%50[^\"]\", \"password\": \"%99[^\"]\"}", username, password);
        }
        if (scanned != 2) {
            scanned = sscanf(request_body, "{\"username\":\"%50[^\"]\", \"password\":\"%99[^\"]\"}", username, password);
        }
        if (scanned != 2) {
            scanned = sscanf(request_body, "{\"username\": \"%50[^\"]\",\"password\":\"%99[^\"]\"}", username, password);
        }
        
        trim_spaces(username);
        trim_spaces(password);
    }
    
    // Find user
    int user_idx = find_user_by_username(username);
    if (user_idx == -1 || strcmp(users[user_idx].password, password) != 0) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Invalid credentials\"}");
        free(username);
        free(password);
        return;
    }
    
    // Generate session
    char session_token[UUID_STRING_LENGTH];
    generate_uuid(session_token);
    
    // Find an empty slot for session
    int session_slot = -1;
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (!sessions[i].active) {
            session_slot = i;
            break;
        }
    }
    
    if (session_slot == -1) {
        send_response(client_fd, 500, "application/json", "{\"error\": \"Server capacity reached\"}");
        free(username);
        free(password);
        return;
    }
    
    strcpy(sessions[session_slot].token, session_token);
    sessions[session_slot].user_id = users[user_idx].id;
    sessions[session_slot].active = 1;
    
    // Send response with session cookie
    char response[200];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", 
             users[user_idx].id, users[user_idx].username);
    
    char full_response[BUFFER_SIZE * 4];
    snprintf(full_response, sizeof(full_response),
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/json\r\n"
            "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n"
            "Connection: close\r\n"
            "Content-Length: %lu\r\n\r\n"
            "%s",
            session_token, strlen(response), response);
    
    send(client_fd, full_response, strlen(full_response), 0);
    
    free(username);
    free(password);
}

void handle_logout(int client_fd, const char *headers_str) {
    int user_id = get_user_from_auth(headers_str);
    if (user_id == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Deactivate the session
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].active && sessions[i].user_id == user_id) {
            sessions[i].active = 0;
            break;
        }
    }
    
    send_response(client_fd, 200, "application/json", "{}");
}

void handle_get_me(int client_fd, const char *headers_str) {
    int user_id = get_user_from_auth(headers_str);
    if (user_id == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Find user details
    int user_idx = -1;
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            user_idx = i;
            break;
        }
    }
    
    if (user_idx == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    char response[200];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", 
             users[user_idx].id, users[user_idx].username);
    send_response(client_fd, 200, "application/json", response);
}

void handle_change_password(int client_fd, const char *request_body, const char *headers_str) {
    int user_id = get_user_from_auth(headers_str);
    if (user_id == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    char *old_password = extract_json_field(request_body, "old_password");
    char *new_password = extract_json_field(request_body, "new_password");
    
    if (!old_password || !new_password) {
        free(old_password);
        free(new_password);
        
        old_password = malloc(MAX_PASSWORD_LENGTH);
        new_password = malloc(MAX_PASSWORD_LENGTH);
        
        int scanned = sscanf(request_body, "{\"old_password\":\"%99[^\"]\",\"new_password\":\"%99[^\"]\"}", old_password, new_password);
        if (scanned != 2) {
            scanned = sscanf(request_body, "{\"old_password\": \"%99[^\"]\", \"new_password\": \"%99[^\"]\"}", old_password, new_password);
        }
        if (scanned != 2) {
            scanned = sscanf(request_body, "{\"old_password\":\"%99[^\"]\", \"new_password\":\"%99[^\"]\"}", old_password, new_password);
        }
        if (scanned != 2) {
            scanned = sscanf(request_body, "{\"old_password\": \"%99[^\"]\",\"new_password\":\"%99[^\"]\"}", old_password, new_password);
        }
        
        trim_spaces(old_password);
        trim_spaces(new_password);
    }
    
    // Find user
    int user_idx = -1;
    for (int i = 0; i < user_count; i++) {
        if (users[i].id == user_id) {
            user_idx = i;
            break;
        }
    }
    
    if (user_idx == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        free(old_password);
        free(new_password);
        return;
    }
    
    // Verify old password
    if (strcmp(users[user_idx].password, old_password) != 0) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Invalid credentials\"}");
        free(old_password);
        free(new_password);
        return;
    }
    
    // Validate new password
    if (strlen(new_password) < 8) {
        send_response(client_fd, 400, "application/json", "{\"error\": \"Password too short\"}");
        free(old_password);
        free(new_password);
        return;
    }
    
    // Update password
    strcpy(users[user_idx].password, new_password);
    send_response(client_fd, 200, "application/json", "{}");
    
    free(old_password);
    free(new_password);
}

void handle_get_todos(int client_fd, const char *headers_str) {
    int user_id = get_user_from_auth(headers_str);
    if (user_id == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Find relevant todos for this user
    char response[BUFFER_SIZE * 10];
    strcpy(response, "[");
    
    int first = 1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id == user_id) {
            char todo_str[1000];
            snprintf(todo_str, sizeof(todo_str),
                    first ? "{\"id\": %d, \"title\": %s, \"description\": %s, \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}" :
                            ",{\"id\": %d, \"title\": %s, \"description\": %s, \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                    todos[i].id,
                    escape_json_string(todos[i].title),
                    escape_json_string(todos[i].description),
                    todos[i].completed ? "true" : "false",
                    todos[i].created_at,
                    todos[i].updated_at);
            
            strcat(response, todo_str);
            first = 0;
        }
    }
    strcat(response, "]");
    
    send_response(client_fd, 200, "application/json", response);
}

void handle_create_todo(int client_fd, const char *request_body, const char *headers_str) {
    int user_id = get_user_from_auth(headers_str);
    if (user_id == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    char *title = extract_json_field(request_body, "title");
    // description may be undefined, so provide a fallback
    char *description = extract_json_field(request_body, "description");
    if (!description) {
        description = malloc(2);
        strcpy(description, "");
    }
    
    if (!title) {
        free(description);
        
        // Use alternative extraction
        title = malloc(500);
        description = malloc(1000);
        strcpy(description, "");
        
        int scanned = sscanf(request_body, "{\"title\":\"%499[^\"]\",\"description\":\"%999[^\"]\"}", title, description);
        if (scanned < 1) {
            scanned = sscanf(request_body, "{\"title\": \"%499[^\"]\", \"description\": \"%999[^\"]\"}", title, description);
        }
        if (scanned < 1) {
            scanned = sscanf(request_body, "{\"title\":\"%499[^\"]\", \"description\":\"%999[^\"]\"}", title, description);
        }
        if (scanned < 1) {
            scanned = sscanf(request_body, "{\"title\": \"%499[^\"]\",\"description\":\"%999[^\"]\"}", title, description);
        }
        if (scanned < 1) {
            scanned = sscanf(request_body, "{\"title\":\"%499[^\"]\"}", title); // title-only
            if (scanned < 1) {
                scanned = sscanf(request_body, "{\"title\": \"%499[^\"]\"}", title);
            }
        }
        
        trim_spaces(title);
        trim_spaces(description);
    }
    
    // Validate title
    if (!title || strlen(title) == 0) {
        send_response(client_fd, 400, "application/json", "{\"error\": \"Title is required\"}");
        free(title);
        free(description);
        return;
    }
    
    // Create new todo
    if (todo_count >= MAX_USERS * MAX_TODOS_PER_USER) {
        send_response(client_fd, 500, "application/json", "{\"error\": \"Server capacity reached\"}");
        free(title);
        free(description);
        return;
    }
    
    Todo new_todo;
    new_todo.id = next_todo_id++;
    new_todo.user_id = user_id;
    strcpy(new_todo.title, title);
    strcpy(new_todo.description, description);
    new_todo.completed = 0;
    
    char *timestamp = get_current_timestamp();
    strcpy(new_todo.created_at, timestamp);
    strcpy(new_todo.updated_at, timestamp);
    
    todos[todo_count++] = new_todo;
    
    char response[1000];
    snprintf(response, sizeof(response),
            "{\"id\": %d, \"title\": %s, \"description\": %s, \"completed\": false, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
            new_todo.id,
            escape_json_string(new_todo.title),
            escape_json_string(new_todo.description),
            new_todo.created_at,
            new_todo.updated_at);
    
    send_response(client_fd, 201, "application/json", response);
    
    free(title);
    free(description);
}

void handle_get_todo(int client_fd, const char *headers_str, const char *url) {
    int user_id = get_user_from_auth(headers_str);
    if (user_id == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Extract todo ID from URL
    const char *id_str = url + 9; // Skip "/todos/"
    while (*id_str && !isdigit((int)*id_str)) id_str++;
    
    char *end_ptr;
    long id = strtol(id_str, &end_ptr, 10);
    
    // Check if parsing worked and we have the right pattern
    if (id <= 0 || (end_ptr && *end_ptr && *end_ptr != '?' && *end_ptr != ' ')) {
        send_response(client_fd, 404, "application/json", "{\"error\": \"Todo not found\"}");
        return;
    }
    
    // Find the todo
    int todo_idx = find_todo_by_id((int)id, user_id);
    if (todo_idx == -1) {
        send_response(client_fd, 404, "application/json", "{\"error\": \"Todo not found\"}");
        return;
    }
    
    char response[1000];
    snprintf(response, sizeof(response),
            "{\"id\": %d, \"title\": %s, \"description\": %s, \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
            todos[todo_idx].id,
            escape_json_string(todos[todo_idx].title),
            escape_json_string(todos[todo_idx].description),
            todos[todo_idx].completed ? "true" : "false",
            todos[todo_idx].created_at,
            todos[todo_idx].updated_at);
    
    send_response(client_fd, 200, "application/json", response);
}

void handle_update_todo(int client_fd, const char *request_body, const char *headers_str, const char *url) {
    int user_id = get_user_from_auth(headers_str);
    if (user_id == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Extract todo ID from URL
    const char *id_str = url + 9; // Skip "/todos/"
    while (*id_str && !isdigit((int)*id_str)) id_str++;
    
    char *end_ptr;
    long id = strtol(id_str, &end_ptr, 10);
    
    if (id <= 0 || (end_ptr && *end_ptr && *end_ptr != '?' && *end_ptr != ' ')) {
        send_response(client_fd, 404, "application/json", "{\"error\": \"Todo not found\"}");
        return;
    }
    
    // Find the todo for this user
    int todo_idx = find_todo_by_id((int)id, user_id);
    if (todo_idx == -1) {
        send_response(client_fd, 404, "application/json", "{\"error\": \"Todo not found\"}");
        return;
    }
    
    char title_buffer[500] = {0};
    char desc_buffer[1000] = {0};
    char completed_buffer[10] = {0};
    
    // Use JSON extractor to try and get all potential properties
    char *title = extract_json_field(request_body, "title");
    char *description = extract_json_field(request_body, "description"); 
    
    if (title) {
        int len = strlen(title);
        if (len == 0) {
            send_response(client_fd, 400, "application/json", "{\"error\": \"Title is required\"}");
            free(title);
            free(description);
            return;
        }
        strncpy(title_buffer, title, sizeof(title_buffer) - 1);
    }
    
    // Process description
    if (description) {
        strncpy(desc_buffer, description, sizeof(desc_buffer) - 1);
    }
    
    // For completed, handle boolean specially by scanning for literal boolean values
    // Since the extract_json_field function only handles quoted strings
    if (strstr(request_body, "\"completed\"")) {
        // Try to find the value after the colon manually, looking for "true" or "false"
        const char *completed_pos = strstr(request_body, "\"completed\"");
        if (completed_pos) {
            completed_pos = strchr(completed_pos, ':');
            if (completed_pos) {
                completed_pos++; // skip ':'
                while (isspace((unsigned char)*completed_pos)) completed_pos++;
                
                // Check what comes after the colon
                if (strncmp(completed_pos, "true", 4) == 0) {
                    strcpy(completed_buffer, "true");
                } else if (strncmp(completed_pos, "false", 5) == 0) {
                    strcpy(completed_buffer, "false");
                }
            }
        }
    }
    
    // Update the todo if new values were provided
    if (title_buffer[0] != '\0') {
        strcpy(todos[todo_idx].title, title_buffer);
    }
    
    if (description) {
        strcpy(todos[todo_idx].description, desc_buffer);
    }
    
    if (completed_buffer[0] != '\0') {
        todos[todo_idx].completed = (strcmp(completed_buffer, "true") == 0);
    }
    
    // Update the updated_at timestamp
    strcpy(todos[todo_idx].updated_at, get_current_timestamp());
    
    // Free allocated memory
    free(title);
    free(description);
    
    // Send response
    char response[1000];
    snprintf(response, sizeof(response),
            "{\"id\": %d, \"title\": %s, \"description\": %s, \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
            todos[todo_idx].id,
            escape_json_string(todos[todo_idx].title),
            escape_json_string(todos[todo_idx].description),
            todos[todo_idx].completed ? "true" : "false",
            todos[todo_idx].created_at,
            todos[todo_idx].updated_at);
    
    send_response(client_fd, 200, "application/json", response);
}

void handle_delete_todo(int client_fd, const char *headers_str, const char *url) {
    int user_id = get_user_from_auth(headers_str);
    if (user_id == -1) {
        send_response(client_fd, 401, "application/json", "{\"error\": \"Authentication required\"}");
        return;
    }
    
    // Extract todo ID from URL
    const char *id_str = url + 9; // Skip "/todos/"
    while (*id_str && !isdigit((int)*id_str)) id_str++;
    
    char *end_ptr;
    long id = strtol(id_str, &end_ptr, 10);
    
    if (id <= 0 || (end_ptr && *end_ptr && *end_ptr != '?' && *end_ptr != ' ')) {
        send_response(client_fd, 404, "application/json", "{\"error\": \"Todo not found\"}");
        return;
    }
    
    // Find the todo for this user
    int todo_idx = find_todo_by_id((int)id, user_id);
    if (todo_idx == -1) {
        send_response(client_fd, 404, "application/json", "{\"error\": \"Todo not found\"}");
        return;
    }
    
    // Remove the todo by shifting elements
    if (todo_idx < todo_count - 1) {
        memmove(&todos[todo_idx], &todos[todo_idx + 1], 
                (todo_count - todo_idx - 1) * sizeof(Todo));
    }
    todo_count--;
    
    // Send successful deletion response (204 No Content)
    send_response(client_fd, 204, "application/json", "");
}

void handle_request(int client_fd) {
    char buffer[BUFFER_SIZE];
    int bytes_read = recv(client_fd, buffer, BUFFER_SIZE - 1, 0);
    if (bytes_read <= 0) {
        close(client_fd);
        return;
    }
    buffer[bytes_read] = '\0';
    
    // Parse request line and method
    char method[10], url[500], version[10];
    if (sscanf(buffer, "%s %s %s", method, url, version) != 3) {
        send_response(client_fd, 400, "application/json", "{\"error\": \"Invalid request\"}");
        close(client_fd);
        return;
    }
    
    // Separate headers string from body
    char *headers_end = strstr(buffer, "\r\n\r\n");
    char headers_str[BUFFER_SIZE];
    char request_body[BUFFER_SIZE];
    
    if (headers_end) {
        headers_end += 4; // Skip over "\r\n\r\n"
        
        // Copy headers to a separate string
       	strncpy(headers_str, buffer, (headers_end - buffer));
        headers_str[(headers_end - buffer)] = '\0';
        
        // Copy the request body
        strcpy(request_body, headers_end);
    } else {
        strcpy(headers_str, buffer);
        strcpy(request_body, "");
    }
    
    pthread_mutex_lock(&mutex);
    
    // Route handling
    if (strcmp(method, "POST") == 0 && strcmp(url, "/register") == 0) {
        handle_register(client_fd, request_body);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/login") == 0) {
        handle_login(client_fd, request_body);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/logout") == 0) {
        handle_logout(client_fd, headers_str);
    } else if (strcmp(method, "GET") == 0 && strcmp(url, "/me") == 0) {
        handle_get_me(client_fd, headers_str);
    } else if (strcmp(method, "PUT") == 0 && strcmp(url, "/password") == 0) {
        handle_change_password(client_fd, request_body, headers_str);
    } else if (strcmp(method, "GET") == 0 && strcmp(url, "/todos") == 0) {
        handle_get_todos(client_fd, headers_str);
    } else if (strcmp(method, "POST") == 0 && strcmp(url, "/todos") == 0) {
        handle_create_todo(client_fd, request_body, headers_str);
    } else if (strcmp(method, "GET") == 0 && strncmp(url, "/todos/", 7) == 0) {
        handle_get_todo(client_fd, headers_str, url);
    } else if (strcmp(method, "PUT") == 0 && strncmp(url, "/todos/", 7) == 0) {
        handle_update_todo(client_fd, request_body, headers_str, url);
    } else if (strcmp(method, "DELETE") == 0 && strncmp(url, "/todos/", 7) == 0) {
        handle_delete_todo(client_fd, headers_str, url);
    } else {
        send_response(client_fd, 404, "application/json", "{\"error\": \"Endpoint not found\"}");
    }
    
    pthread_mutex_unlock(&mutex);
    
    close(client_fd);
}

int main(int argc, char *argv[]) {
    // Initialize sessions array
    for (int i = 0; i < MAX_SESSIONS; i++) {
        sessions[i].active = 0;
    }
    
    int port = -1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
            break;
        }
    }
    
    if (port == -1) {
        fprintf(stderr, "Usage: %s --port PORT\n", argv[0]);
        exit(1);
    }
    
    int server_fd, client_fd;
    struct sockaddr_in address;
    int opt = 1;
    int addrlen = sizeof(address);
    
    // Create server socket
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }
    
    // Set socket options
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        exit(EXIT_FAILURE);
    }
    
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
    
    printf("Server running on port %d\n", port);
    
    while (1) {
        if ((client_fd = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen)) < 0) {
            perror("accept failed");
            continue;
        }
        
        handle_request(client_fd);
    }
    
    return 0;
}
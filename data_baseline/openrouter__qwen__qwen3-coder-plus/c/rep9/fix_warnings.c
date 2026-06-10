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
#define BUFFER_SIZE 4096
#define USERNAME_MAX_LENGTH 50
#define PASSWORD_MIN_LENGTH 8

// Forward declarations
struct User;
struct Todo;

typedef struct {
    char id[37]; // UUID string length
    int user_id;
    time_t created_at;
    int active; // boolean to track if session is valid
} Session;

typedef struct {
    int id;
    char username[USERNAME_MAX_LENGTH + 1];
    char password_hash[256]; // Store salted hashes
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

// Global data structures
User users[MAX_USERS];
int num_users = 0;
Todo todos[MAX_TODOS];
int num_todos = 0;
Session sessions[MAX_SESSIONS];
int num_sessions = 0;

// Utility functions
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

int find_session_by_id(const char* session_id) {
    for (int i = 0; i < num_sessions; i++) {
        if (sessions[i].active && strcmp(sessions[i].id, session_id) == 0) {
            return i;
        }
    }
    return -1;
}

char* extract_cookie_value(const char* headers, const char* cookie_name) {
    static char value[1000];
    char pattern[1000];
    snprintf(pattern, sizeof(pattern), "%s=([^;\\s]*)", cookie_name);
    
    regex_t regex;
    regmatch_t matches[2];
    
    if (regcomp(&regex, pattern, REG_EXTENDED | REG_ICASE) != 0) {
        return NULL;
    }
    
    if (regexec(&regex, headers, 2, matches, 0) == 0) {
        int start = matches[1].rm_so;
        int end = matches[1].rm_eo;
        int len = end - start;
        if (len >= sizeof(value)) {
            len = sizeof(value) - 1;
        }
        strncpy(value, headers + start, len);
        value[len] = '\0';
        regfree(&regex);
        return value;
    }
    
    regfree(&regex);
    return NULL;
}

void send_response(int client_socket, int status_code, const char* body, int has_body) {
    char response[BUFFER_SIZE * 10];
    
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
        case 409:
            strcpy(response, "HTTP/1.1 409 Conflict\r\n");
            break;
        default:
            sprintf(response, "HTTP/1.1 %d Unknown\r\n", status_code);
            break;
    }
    
    strcat(response, "Content-Type: application/json\r\n");
    if (has_body) {
        char content_length[50];
        sprintf(content_length, "Content-Length: %lu\r\n", strlen(body));
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

void handle_register(int client_socket, const char* body) {
    // Parse the request body
    if (!body || strlen(body) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Missing request body\"}", 1);
        return;
    }
    
    // Extract username and password from JSON body
    char username[USERNAME_MAX_LENGTH + 2], password[256];
    if (sscanf(body, "{\"username\": \"%[^\"]\", \"password\": \"%[^\"]\"", username, password) != 2) {
        // Try parsing without quotes in case of special chars
        const char* username_start = strstr(body, "\"username\":\"");
        const char* password_start = strstr(body, "\",\"password\":\"");
        
        if (username_start && password_start) {
            username_start += 12; // length of "\"username\":\""
            int username_len = password_start - username_start;
            
            const char* pwd_temp = password_start + 14; // length of "\",\"password\":\""
            const char* pwd_end = strrchr(pwd_temp, '\"');
            
            if (username_len <= USERNAME_MAX_LENGTH && pwd_end) {
                strncpy(username, username_start, username_len);
                username[username_len] = '\0';
                
                int pwd_len = pwd_end - pwd_temp;
                if (pwd_len < sizeof(password)) {
                    strncpy(password, pwd_temp, pwd_len);
                    password[pwd_len] = '\0';
                } else {
                    send_response(client_socket, 400, "{\"error\": \"Password too long\"}", 1);
                    return;
                }
            } else {
                send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
                return;
            }
        } else {
            send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
            return;
        }
    }
    
    // Validate username format
    if (!validate_username(username)) {
        send_response(client_socket, 400, "{\"error\": \"Invalid username\"}", 1);
        return;
    }
    
    // Check for duplicate username
    if (find_user_by_username(username) != -1) {
        send_response(client_socket, 409, "{\"error\": \"Username already exists\"}", 1);
        return;
    }
    
    // Validate password strength
    if (strlen(password) < PASSWORD_MIN_LENGTH) {
        send_response(client_socket, 400, "{\"error\": \"Password too short\"}", 1);
        return;
    }
    
    // Create new user
    if (num_users >= MAX_USERS) {
        send_response(client_socket, 507, "{\"error\": \"Storage limit exceeded\"}", 1);
        return;
    }
    
    User* user = &users[num_users];
    user->id = num_users + 1;  // IDs start at 1
    strcpy(user->username, username);
    
    // For simplicity, just hash the password by storing it (we'd use real hashing in production)
    strcpy(user->password_hash, password); // In a real app, use bcrypt or similar
    
    time(&user->created_at);
    user->active = 1;
    
    num_users++;
    
    // Prepare response with new user details
    char response[500];
    snprintf(response, sizeof(response), "{\"id\": %d, \"username\": \"%s\"}", 
             user->id, user->username);
    
    send_response(client_socket, 201, response, 1);
}

void handle_login(int client_socket, const char* body) {
    if (!body || strlen(body) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Missing request body\"}", 1);
        return;
    }
    
    // Extract username and password from JSON body
    char username[USERNAME_MAX_LENGTH + 1], password[256];
    const char* username_start = strstr(body, "\"username\":\"");
    const char* password_start = strstr(body, "\",\"password\":\"");
    
    if (username_start && password_start) {
        username_start += 12; // length of "\"username\":\""
        int username_len = password_start - username_start;
        
        const char* pwd_temp = password_start + 14; // length of "\",\"password\":\""
        const char* pwd_end = strrchr(pwd_temp, '\"');
        
        if (username_len <= USERNAME_MAX_LENGTH && pwd_end) {
            strncpy(username, username_start, username_len);
            username[username_len] = '\0';
            
            int pwd_len = pwd_end - pwd_temp;
            if (pwd_len < sizeof(password)) {
                strncpy(password, pwd_temp, pwd_len);
                password[pwd_len] = '\0';
            } else {
                send_response(client_socket, 400, "{\"error\": \"Password too long\"}", 1);
                return;
            }
        } else {
            send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
            return;
        }
    } else {
        send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
        return;
    }
    
    // Find the user
    int user_index = find_user_by_username(username);
    if (user_index == -1) {
        send_response(client_socket, 401, "{\"error\": \"Invalid credentials\"}", 1);
        return;
    }
    
    User* user = &users[user_index];
    
    // Compare passwords (simple comparison for example)
    if (strcmp(user->password_hash, password) != 0) {
        send_response(client_socket, 401, "{\"error\": \"Invalid credentials\"}", 1);
        return;
    }
    
    // Generate a new session for the user
    if (num_sessions >= MAX_SESSIONS) {
        send_response(client_socket, 507, "{\"error\": \"Storage limit exceeded\"}", 1);
        return;
    }
    
    Session* session = &sessions[num_sessions];
    generate_uuid(session->id);
    session->user_id = user->id;
    time(&session->created_at);
    session->active = 1;
    num_sessions++;
    
    // Prepare set-cookie header and response - fixed calculation for content-length
    char user_data[500];
    snprintf(user_data, sizeof(user_data), "{\"id\": %d, \"username\": \"%s\"}", user->id, user->username);
    int body_len = strlen(user_data);
    
    char response[BUFFER_SIZE * 2];
    snprintf(response, sizeof(response), 
             "HTTP/1.1 200 OK\r\n"
             "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n"
             "Content-Type: application/json\r\n"
             "Content-Length: %d\r\n\r\n"
             "%s",
             session->id,  // session_id
             body_len,     // calculated length
             user_data);   // JSON body
    
    write(client_socket, response, strlen(response));
}

// Helper function to get current session ID from headers
int get_current_user_id_from_header(const char* headers) {
    const char* cookie_header = strstr(headers, "Cookie:");
    if (!cookie_header) return -1;
    
    cookie_header += 7; // Skip "Cookie:"
    
    char* session_id = extract_cookie_value(cookie_header, "session_id");
    if (!session_id) return -1;
    
    int session_idx = find_session_by_id(session_id);
    if (session_idx == -1 || !sessions[session_idx].active) return -1;
    
    return sessions[session_idx].user_id;
}

void handle_logout(int client_socket, const char* headers) {
    const char* cookie_header = strstr(headers, "Cookie:");
    if (!cookie_header) {
        send_response(client_socket, 401, "{\"error\": \"Authentication required\"}", 1);
        return;
    }
    
    cookie_header += 7; // Skip "Cookie:"
    
    char* session_id = extract_cookie_value(cookie_header, "session_id");
    if (!session_id) {
        send_response(client_socket, 401, "{\"error\": \"Authentication required\"}", 1);
        return;
    }
    
    int session_idx = find_session_by_id(session_id);
    if (session_idx == -1 || !sessions[session_idx].active) {
        send_response(client_socket, 401, "{\"error\": \"Authentication required\"}", 1);
        return;
    }
    
    // Invalidate the session
    sessions[session_idx].active = 0;
    
    send_response(client_socket, 200, "{}", 1);
}

void handle_get_me(int client_socket, int user_id) {
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
    
    User* user = &users[user_idx];
    
    char response[500];
    snprintf(response, sizeof(response), 
             "{\"id\": %d, \"username\": \"%s\"}", 
             user->id, user->username);
    
    send_response(client_socket, 200, response, 1);
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
    
    User* user = &users[user_idx];
    
    // Extract old and new passwords from JSON
    const char* old_pwd_start = strstr(body, "\"old_password\":\"");
    const char* new_pwd_start = strstr(body, "\",\"new_password\":\"");
    
    if (old_pwd_start && new_pwd_start) {
        old_pwd_start += 16; // length of "\"old_password\":\""
        int old_pwd_len = new_pwd_start - old_pwd_start;
        
        const char* new_pwd_actual = new_pwd_start + 19; // length of "\",\"new_password\":\""
        const char* new_pwd_end = strrchr(new_pwd_actual, '\"');
        
        // Handle case where new_password is the last field
        if (!new_pwd_end || (new_pwd_end <= new_pwd_actual)) {
            // Find correct end for new password when it's the last field before '}'
            const char* temp_end = strchr(new_pwd_actual, '}');
            if (temp_end) {
                temp_end--;  // Move back from '}'
                while (temp_end > new_pwd_actual && *temp_end != '\"') {
                    if (*(temp_end-1) == '\\' && *temp_end == '\"') {
                        // Handle escaped quotes
                        temp_end -= 2;
                        continue;
                    }
                    temp_end--;
                }
                if (*temp_end == '\"') {
                    new_pwd_end = temp_end;
                } else {
                    send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
                    return;
                }
            } else {
                send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
                return;
            }
        }
        
        char old_password[256], new_password[256];
        
        if (old_pwd_len < sizeof(old_password)) {
            strncpy(old_password, old_pwd_start, old_pwd_len);
            old_password[old_pwd_len] = '\0';
        } else {
            send_response(client_socket, 400, "{\"error\": \"Old password too long\"}", 1); 
            return;
        }
        
        int new_pwd_len_calc = new_pwd_end - new_pwd_actual;
        if (new_pwd_len_calc < sizeof(new_password)) {
            strncpy(new_password, new_pwd_actual, new_pwd_len_calc);
            new_password[new_pwd_len_calc] = '\0';
        } else {
            send_response(client_socket, 400, "{\"error\": \"New password too long\"}", 1);
            return;
        }
        
        // Validate new password length
        if (strlen(new_password) < PASSWORD_MIN_LENGTH) {
            send_response(client_socket, 400, "{\"error\": \"Password too short\"}", 1);
            return;
        }
        
        // Check if old password matches
        if (strcmp(user->password_hash, old_password) != 0) {
            send_response(client_socket, 401, "{\"error\": \"Invalid credentials\"}", 1);
            return;
        }
        
        // Update password
        strcpy(user->password_hash, new_password);
        
        send_response(client_socket, 200, "{}", 1);
    } else {
        send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
        return;
    }
}

void handle_get_todos(int client_socket, int user_id) {
    // Count user's todos
    int count = 0;
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id) {
            count++;
        }
    }
    
    // Allocate memory for result array - with a much larger buffer
    char* response = malloc(BUFFER_SIZE * 200); // Increased allocation
    char* ptr = response;
    int remaining = BUFFER_SIZE * 200;
    
    *ptr = '[';
    ptr++;
    remaining--;
    
    // Add each todo to the response
    int first = 1;
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id) {
            if (!first) {
                snprintf(ptr, remaining, ",");
                ptr++;
                remaining--;
            }
            
            // Calculate space needed ahead of time to avoid truncation
            char created_at_str[30], updated_at_str[30];
            strcpy(created_at_str, format_time(todos[i].created_at));
            strcpy(updated_at_str, format_time(todos[i].updated_at));
            
            int space_needed = snprintf(NULL, 0,
                     "{\"id\": %d, "
                     "\"title\": \"%s\", "
                     "\"description\": \"%s\", "
                     "\"completed\": %s, "
                     "\"created_at\": \"%s\", "
                     "\"updated_at\": \"%s\"}",
                     todos[i].id,
                     todos[i].title,
                     todos[i].description,
                     todos[i].completed ? "true" : "false",
                     created_at_str,
                     updated_at_str
            );
            
            if (space_needed < remaining) {
                snprintf(ptr, remaining,
                         "{\"id\": %d, "
                         "\"title\": \"%s\", "
                         "\"description\": \"%s\", "
                         "\"completed\": %s, "
                         "\"created_at\": \"%s\", "
                         "\"updated_at\": \"%s\"}",
                         todos[i].id,
                         todos[i].title,
                         todos[i].description,
                         todos[i].completed ? "true" : "false",
                         created_at_str,
                         updated_at_str
                );
            }
            
            int written = strlen(ptr);
            ptr += written;
            remaining -= written;
            first = 0;
        }
    }
    
    snprintf(ptr, remaining, "]");
    
    send_response(client_socket, 200, response, 1);
    free(response);
}

void handle_create_todo(int client_socket, int user_id, const char* body) {
    if (!body || strlen(body) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Missing request body\"}", 1);
        return;
    }
    
    // Define storage space for title and description
    char title[500], description[2000] = {0};
    
    // Extract title and description using basic JSON parsing
    const char* title_start = strstr(body, "\"title\":\"");
    const char* desc_start = NULL;
    
    if (title_start) {
        title_start += 9; // length of "\"title\":\""
        const char* title_end = strstr(title_start, "\",\"");
        if (!title_end) {
            title_end = strchr(title_start, '"');
            // Handle escaped quotes
            while (title_end && *(title_end-1) == '\\' && title_end > title_start) {
                title_end = strchr(title_end + 1, '"');
            }
            // If we're at the last field before closing brace  
            if (!title_end) {
                const char* temp = strchr(title_start, '}');
                if (temp) {
                    temp--;  // Back up from '}'
                    while (temp > title_start && *temp != '"') temp--;
                    if (*temp == '"' && temp > title_start) title_end = temp;
                }
            }
        }
        
        if (title_end) {
            int title_len = title_end - title_start;
            if (title_len >= sizeof(title)) {
                title_len = sizeof(title) - 1;
            }
            strncpy(title, title_start, title_len);
            title[title_len] = '\0';
        } else {
            send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
            return;
        }
        
        // Find the rest of the body for extracting description
        const char* desc_pos = strstr(body, "\"description\":\"");
        if (desc_pos) {
            desc_pos += 15; // length of "\"description\":\""
            const char* desc_end = strchr(desc_pos, '"');
            if (desc_end) {
                // Make sure this quote isn't escaped
                const char* temp_desc_end = desc_end;
                while (temp_desc_end > desc_pos && *(temp_desc_end-1) == '\\') {
                    temp_desc_end = strchr(temp_desc_end + 1, '"');
                    if (!temp_desc_end) break;
                }
                desc_end = temp_desc_end;
            }
            
            if (desc_end) {
                int desc_len = desc_end - desc_pos;
                if (desc_len >= sizeof(description)) {
                    desc_len = sizeof(description) - 1;
                }
                strncpy(description, desc_pos, desc_len);
                description[desc_len] = '\0';
            } else {
                strcpy(description, ""); // Default to empty
            }
        } else {
            strcpy(description, ""); // Default to empty
        }
    } else {
        send_response(client_socket, 400, "{\"error\": \"Invalid request format\"}", 1);
        return;
    }
    
    // Validate that title is non-empty
    if (strlen(title) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Title is required\"}", 1);
        return;
    }
    
    // Create new todo
    if (num_todos >= MAX_TODOS) {
        send_response(client_socket, 507, "{\"error\": \"Storage limit exceeded\"}", 1);
        return;
    }
    
    Todo* todo = &todos[num_todos];
    todo->id = num_todos + 1;  // IDs start at 1
    todo->user_id = user_id;
    strcpy(todo->title, title);
    strcpy(todo->description, description);
    todo->completed = 0;  // Default to false
    
    time(&todo->created_at);
    todo->updated_at = todo->created_at;
    todo->active = 1;
    
    num_todos++;
    
    // Prepare response with new todo details - increased size to handle large descriptions
    char response[5000];  // Increased size to handle longer text safely
    
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
    // Find the specific todo belonging to the user
    int found = 0;
    Todo* target_todo = NULL;
    
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id && todos[i].id == todo_id) {
            target_todo = &todos[i];
            found = 1;
            break;
        }
    }
    
    if (!found) {
        send_response(client_socket, 404, "{\"error\": \"Todo not found\"}", 1);
        return;
    }
    
    // Prepare response with todo details - increased size
    char response[5000];  // Increased size to handle longer text safely
    snprintf(response, sizeof(response),
             "{\"id\": %d, "
             "\"title\": \"%s\", "
             "\"description\": \"%s\", "
             "\"completed\": %s, "
             "\"created_at\": \"%s\", "
             "\"updated_at\": \"%s\"}",
             target_todo->id,
             target_todo->title,
             target_todo->description,
             target_todo->completed ? "true" : "false",
             format_time(target_todo->created_at),
             format_time(target_todo->updated_at)
    );
    
    send_response(client_socket, 200, response, 1);
}

void handle_update_todo(int client_socket, int user_id, int todo_id, const char* body) {
    if (!body || strlen(body) == 0) {
        send_response(client_socket, 400, "{\"error\": \"Missing request body\"}", 1);
        return;
    }
    
    // Find the specific todo belonging to the user
    int found = 0;
    Todo* target_todo = NULL;
    
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id && todos[i].id == todo_id) {
            target_todo = &todos[i];
            found = 1;
            break;
        }
    }
    
    if (!found) {
        send_response(client_socket, 404, "{\"error\": \"Todo not found\"}", 1);
        return;
    }
    
    // Extract individual fields from JSON, updating only those that are present
    
    // Check if any fields exist in the request body
    int any_field_exists = 0;
    
    // Check for title in body
    const char* title_ptr = strstr(body, "\"title\":\"");
    if (title_ptr) {
        title_ptr += 9; // length of "\"title\":\""
        const char* temp_end = strchr(title_ptr, '"');
        const char* scan_ptr = temp_end;
        // Handle escaped quotes correctly
        while (scan_ptr && *(scan_ptr-1) == '\\' && scan_ptr > title_ptr) {
            scan_ptr = strchr(scan_ptr + 1, '"');
        }
        
        if (scan_ptr) {
            int title_len = scan_ptr - title_ptr;
            if (title_len > 0 && title_len < sizeof(target_todo->title)) {
                strncpy(target_todo->title, title_ptr, title_len);
                target_todo->title[title_len] = '\0';
                any_field_exists = 1;
                
                // Validate title is non-empty
                if (strlen(target_todo->title) == 0) {
                    send_response(client_socket, 400, "{\"error\": \"Title is required\"}", 1);
                    return;
                }
            }
        }
    }

    // Check for description in body
    const char* desc_ptr = strstr(body, "\"description\":\"");
    if (desc_ptr) {
        desc_ptr += 15; // length of "\"description\":\""
        const char* temp_desc_ptr = desc_ptr;
        const char* desc_end = strchr(temp_desc_ptr, '"');
        // Handle cases where there might be escaped quotes
        while(desc_end && *(desc_end-1) == '\\' && desc_end > temp_desc_ptr) {
            desc_end = strchr(desc_end + 1, '"'); 
        }
        
        if(desc_end) {
            int desc_len = desc_end - temp_desc_ptr;
            if(desc_len < sizeof(target_todo->description)) {
                strncpy(target_todo->description, temp_desc_ptr, desc_len);
                target_todo->description[desc_len] = '\0';
                any_field_exists = 1;
            }
        }
    }
    
    // Check for completed field in body  
    const char* completed_pos = strstr(body, "\"completed\":");
    if(completed_pos) {
        completed_pos += 12; // length of "\"completed\":"
        while(isspace((unsigned char)*completed_pos)) completed_pos++;
        
        if(*completed_pos == 't' && strncmp(completed_pos, "true", 4) == 0) {
            target_todo->completed = 1;
            any_field_exists = 1;
        } else if(*completed_pos == 'f' && strncmp(completed_pos, "false", 5) == 0) {
            target_todo->completed = 0;
            any_field_exists = 1;
        } else if(*completed_pos == '1') {
            target_todo->completed = 1;
            any_field_exists = 1;
        } else if(*completed_pos == '0') {
            target_todo->completed = 0;
            any_field_exists = 1;
        } 
    }
    
    // Update the updated timestamp regardless of changes made
    time(&target_todo->updated_at);
    
    // Prepare response with the updated todo details - increased size
    char response[5000];  // Increased size to handle longer text safely
    snprintf(response, sizeof(response),
             "{\"id\": %d, "
             "\"title\": \"%s\", "
             "\"description\": \"%s\", "
             "\"completed\": %s, "
             "\"created_at\": \"%s\", "
             "\"updated_at\": \"%s\"}",
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
    // Find the specific todo belonging to the user
    int found = 0;
    
    for (int i = 0; i < num_todos; i++) {
        if (todos[i].active && todos[i].user_id == user_id && todos[i].id == todo_id) {
            todos[i].active = 0;  // Mark as not active instead of truly deleting
            found = 1;
            break;
        }
    }
    
    if (!found) {
        send_response(client_socket, 404, "{\"error\": \"Todo not found\"}", 1);
        return;
    }
    
    send_response(client_socket, 204, "", 0);  // 204 No Content
}

void handle_request(int client_socket, const char* method, const char* url, const char* headers, const char* body) {
    // Check if the request needs authentication
    int auth_required = 0;
    if (strncmp(url, "/me", 3) == 0   || 
        strncmp(url, "/password", 9) == 0 || 
        strncmp(url, "/todos", 6) == 0) {
        auth_required = 1;
    }
    
    if (auth_required) {
        int user_id = get_current_user_id_from_header(headers);
        if (user_id == -1) {
            send_response(client_socket, 401, "{\"error\": \"Authentication required\"}", 1);
            return;
        }
        
        // Handle protected routes based on method and resource
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
            // Parse the URL to check if it's like `/todos/123`
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
                // Invalid URL format 
                send_response(client_socket, 404, "{\"error\": \"Not found\"}", 1);
            }
        } else {
            // Some other auth-required route that doesn't exist
            send_response(client_socket, 404, "{\"error\": \"Not found\"}", 1);
        }
    } else {
        // Public routes
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
    // Initialize globals
    memset(users, 0, sizeof(users));
    memset(todos, 0, sizeof(todos)); 
    memset(sessions, 0, sizeof(sessions));
    
    int port = 0;
    // Parse --port argument
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
    
    // Creating socket file descriptor
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        return -1;
    }
    
    // Forcefully attaching socket to the port
    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        perror("setsockopt");
        return -1;
    }
    
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);
    
    // Bind the socket
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        return -1;
    }
    
    // Listen for connections
    if (listen(server_fd, 10) < 0) {
        perror("listen");
        return -1;
    }
    
    printf("Server is listening on port %d\n", port);
    
    while(1) {
        // Accept new connection
        if ((new_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen)) < 0) {
            perror("accept");
            return -1;
        }
        
        // Read the request
        char buffer[BUFFER_SIZE * 4];
        int valread = read(new_socket, buffer, BUFFER_SIZE * 4 - 1);
        if (valread <= 0) {
            close(new_socket);
            continue;
        }
        buffer[valread] = '\0';
        
        // Parse the request
        char method[10], url[2048], protocol[10];
        if (sscanf(buffer, "%9s %2047s %9s", method, url, protocol) != 3) {
            send_response(new_socket, 400, "{\"error\": \"Bad request\"}", 1);
            close(new_socket);
            continue;
        } 
        
        // Extract body if present (after \r\n\r\n)
        char* body_start = strstr(buffer, "\r\n\r\n");
        const char* body = "";
        if (body_start) {
            body_start += 4; // Move past \r\n\r\n
            if (*body_start != '\0') {
                body = body_start;
            }
        }
        
        // Process the request
        handle_request(new_socket, method, url, buffer, body);
        
        close(new_socket);
    }
    
    return 0;
}
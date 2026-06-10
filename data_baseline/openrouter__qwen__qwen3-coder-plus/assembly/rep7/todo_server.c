/*
 * Simple Todo API Server in C
 * This implementation uses standard system calls for networking,
 * and implements all required endpoints
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <ctype.h>
#include <time.h>

// User structure
typedef struct {
    int id;
    char username[100];
    char password[100];  // For simplicity, storing password in clear (not secure in real apps)
} User;

// Todo structure  
typedef struct {
    int id;
    int owner_id;  // User who owns this todo
    char title[200];
    char description[500];
    int completed;
    char created_at[30];
    char updated_at[30];
} Todo;

// Session structure for tracking logged in users
typedef struct {
    char token[65];  // Hex representation of session ID
    int user_id;
    int valid;       // Track if session is still active
} Session;

// Global state (for in-memory storage)
User users[1000];
int user_count = 0;
int next_user_id = 1;

Todo todos[10000];
int todo_count = 0;
int next_todo_id = 1;

Session sessions[1000];
int session_count = 0;

// Forward declarations
void handle_client(int client_fd);
int extract_method_path(char* request, char* method, char* path, int max_len);
int check_auth(const char* headers);
int get_user_by_session(const char* session_token);
void send_response(int client_fd, int status_code, const char* body, const char* cookie);
char* get_current_time_iso8601();
char* find_header_value(const char* headers, const char* header_name);

int main(int argc, char *argv[]) {
    // Parse command line arguments
    int port = 8080;  // default
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "--port") == 0) {
            port = atoi(argv[i + 1]);
            break;
        }
    }

    // Create socket
    int server_fd;
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }

    // Set socket options
    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt");
        exit(EXIT_FAILURE);
    }

    // Configure address
    struct sockaddr_in address;
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);

    // Bind
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }

    // Listen
    if (listen(server_fd, 10) < 0) {
        perror("listen");
        exit(EXIT_FAILURE);
    }

    printf("Server listening on 0.0.0.0:%d\n", port);

    // Accept loop
    while(1) {
        int client_fd;
        int addrlen = sizeof(address);
        
        if ((client_fd = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen)) < 0) {
            perror("accept failed");
            continue;
        }

        handle_client(client_fd);
        close(client_fd); 
    }
    
    return 0;
}

void handle_client(int client_fd) {
    char buffer[4096];
    char method[10];
    char path[256];
    char headers[4096];

    int bytes_read = read(client_fd, buffer, 4095);
    if (bytes_read <= 0) return;
    buffer[bytes_read] = '\0';

    if (!extract_method_path(buffer, method, path, sizeof(path))) {
        const char* error = "{\"error\": \"Request parsing error\"}";
        send_response(client_fd, 400, error, NULL);
        return;
    }

    // Extract headers part from the buffer
    char* body_start = strstr(buffer, "\r\n\r\n");
    if (body_start) {
        body_start += 4; // skip the \r\n\r\n
        strncpy(headers, buffer, body_start - buffer - 1);
        headers[body_start - buffer - 1] = '\0';
    } else {
        strcpy(headers, buffer);
    }

    // Route request based on path and method
    if (strcmp(method, "GET") == 0 && strcmp(path, "/me") == 0) {
        // Check if user is authenticated
        const char* session_cookie = find_header_value(headers, "Cookie: session_id=");
        if (!session_cookie || get_user_by_session(session_cookie) <= 0) {
            const char* error = "{\"error\": \"Authentication required\"}";
            send_response(client_fd, 401, error, NULL);
            return;
        }
        
        // Find and return user data
        int user_id = get_user_by_session(session_cookie);
        char response[512];
        for (int i = 0; i < user_count; i++) {
            if (users[i].id == user_id) {
                snprintf(response, sizeof(response), 
                        "{\"id\": %d, \"username\": \"%s\"}", 
                        users[i].id, users[i].username);
                send_response(client_fd, 200, response, NULL);
                return;
            }
        }
        const char* error = "{\"error\": \"Authentication required\"}"; 
        send_response(client_fd, 401, error, NULL);
    }
    else if (strcmp(method, "POST") == 0 && strcmp(path, "/register") == 0) {
        // Extract body
        char* body_start = strstr(buffer, "\r\n\r\n");
        if (!body_start) {
            const char* error = "{\"error\": \"No request body\"}";
            send_response(client_fd, 400, error, NULL);
            return;
        }
        body_start += 4;
        
        // Parse username and password from JSON in body
        char username[100] = {0};
        char password[100] = {0};
        if (sscanf(body_start, "{\"username\": \"%99[^\"]\", \"password\": \"%99[^\"]\"", 
                   username, password) != 2) {
            const char* error = "{\"error\": \"Invalid request body\"}";
            send_response(client_fd, 400, error, NULL);
            return;
        }
        
        // Validate username format
        if (strlen(username) < 3 || strlen(username) > 50) {
            const char* error = "{\"error\": \"Invalid username\"}";
            send_response(client_fd, 400, error, NULL);
            return;
        }
        for (int i = 0; i < strlen(username); i++) {
            if (!isalnum(username[i]) && username[i] != '_') {
                const char* error = "{\"error\": \"Invalid username\"}";
                send_response(client_fd, 400, error, NULL);
                return;
            }
        }
        
        // Validate password length
        if (strlen(password) < 8) {
            const char* error = "{\"error\": \"Password too short\"}";
            send_response(client_fd, 400, error, NULL);
            return;
        }
        
        // Check for duplicate username
        for (int i = 0; i < user_count; i++) {
            if (strcmp(users[i].username, username) == 0) {
                const char* error = "{\"error\": \"Username already exists\"}";
                send_response(client_fd, 409, error, NULL);
                return;
            }
        }
        
        // Create new user
        users[user_count].id = next_user_id++;
        strcpy(users[user_count].username, username);
        strcpy(users[user_count].password, password);
        user_count++;
        
        char response[256];
        snprintf(response, sizeof(response), 
                "{\"id\": %d, \"username\": \"%s\"}", 
                users[user_count-1].id, users[user_count-1].username);
                
        send_response(client_fd, 201, response, NULL);
    }
    else if (strcmp(method, "POST") == 0 && strcmp(path, "/login") == 0) {
        // Extract body
        char* body_start = strstr(buffer, "\r\n\r\n");
        if (!body_start) {
            const char* error = "{\"error\": \"No request body\"}";
            send_response(client_fd, 400, error, NULL);
            return;
        }
        body_start += 4;
        
        // Parse username and password from JSON in body  
        char username[100] = {0};
        char password[100] = {0};
        if (sscanf(body_start, "{\"username\": \"%99[^\"]\", \"password\": \"%99[^\"]\"", 
                   username, password) != 2) {
            const char* error = "{\"error\": \"Invalid request body\"}";
            send_response(client_fd, 400, error, NULL);
            return;
        }
        
        // Find user and validate password
        int user_id = -1;
        for (int i = 0; i < user_count; i++) {
            if (strcmp(users[i].username, username) == 0 && 
                strcmp(users[i].password, password) == 0) {
                user_id = users[i].id;
                break;
            }
        }
        
        if (user_id == -1) {
            const char* error = "{\"error\": \"Invalid credentials\"}";
            send_response(client_fd, 401, error, NULL);
            return;
        }
        
        // Create new session
        char session_token[65]; // Randomly generated ID-like thing
        snprintf(session_token, sizeof(session_token), "%d%d", user_id, rand());
        
        sessions[session_count].user_id = user_id;
        strcpy(sessions[session_count].token, session_token);
        sessions[session_count].valid = 1;  // Mark as valid
        session_count++;
        
        char response[256];
        snprintf(response, sizeof(response), 
                "{\"id\": %d, \"username\": \"%s\"}", 
                users[user_id-1].id, users[user_id-1].username);
        
        send_response(client_fd, 200, response, session_token);
    }
    else if (strcmp(method, "POST") == 0 && strcmp(path, "/logout") == 0) {
        // Check if user is authenticated
        const char* session_cookie = find_header_value(headers, "Cookie: session_id=");
        if (!session_cookie) {
            const char* error = "{\"error\": \"Authentication required\"}";
            send_response(client_fd, 401, error, NULL);
            return;
        }
        
        int session_idx = -1;
        for (int i = 0; i < session_count; i++) {
            if (strcmp(sessions[i].token, session_cookie) == 0 && sessions[i].valid) {
                session_idx = i;
                break;
            }
        }
        
        if (session_idx == -1) {
            const char* error = "{\"error\": \"Authentication required\"}";
            send_response(client_fd, 401, error, NULL);
            return;
        }
        
        // Invalidate session
        sessions[session_idx].valid = 0;
        
        send_response(client_fd, 200, "{}", NULL);
    }
    else if (strcmp(method, "POST") == 0 && strcmp(path, "/todos") == 0) {
        // Check if user is authenticated
        const char* session_cookie = find_header_value(headers, "Cookie: session_id=");
        if (!session_cookie) {
            const char* error = "{\"error\": \"Authentication required\"}";
            send_response(client_fd, 401, error, NULL);
            return;
        }
        
        int user_id = get_user_by_session(session_cookie);
        if (user_id <= 0) {
            const char* error = "{\"error\": \"Authentication required\"}";
            send_response(client_fd, 401, error, NULL);
            return;
        }
        
        // Extract body
        char* body_start = strstr(buffer, "\r\n\r\n");
        if (!body_start) {
            const char* error = "{\"error\": \"No request body\"}";
            send_response(client_fd, 400, error, NULL);
            return;
        }
        body_start += 4;
        
        // Parse title and description from JSON in body
        char title[200] = {0};  
        char desc[500] = {0};
        
        // Try with just title
        if (sscanf(body_start, "{\"title\": \"%199[^\"]\", \"description\": \"%499[^\"]\"", 
                   title, desc) != 2 &&
            sscanf(body_start, "{\"title\": \"%199[^\"]\"}", title) != 1) {
            const char* error = "{\"error\": \"Invalid request body\"}";
            send_response(client_fd, 400, error, NULL);
            return;
        }
        
        // Validate title is required
        if (strlen(title) == 0) {
            const char* error = "{\"error\": \"Title is required\"}";
            send_response(client_fd, 400, error, NULL);
            return;
        }
        
        // If description wasn't provided, set to empty string
        if (desc[0] == '\0') {
            strcpy(desc, "");
        }
        
        // Create new todo
        char* time_now = get_current_time_iso8601();
        todos[todo_count].id = next_todo_id++;
        todos[todo_count].owner_id = user_id;
        strcpy(todos[todo_count].title, title);
        strcpy(todos[todo_count].description, desc);
        todos[todo_count].completed = 0; // Default to false
        strcpy(todos[todo_count].created_at, time_now);
        strcpy(todos[todo_count].updated_at, time_now);
        todo_count++;
        
        // Build response JSON
        char response[1000];
        snprintf(response, sizeof(response), 
                "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                todos[todo_count-1].id, 
                todos[todo_count-1].title, 
                todos[todo_count-1].description, 
                todos[todo_count-1].completed ? "true" : "false",
                todos[todo_count-1].created_at,
                todos[todo_count-1].updated_at);
        
        send_response(client_fd, 201, response, NULL);
    }
    else if (strcmp(method, "GET") == 0 && strcmp(path, "/todos") == 0) {
        // Check if user is authenticated
        const char* session_cookie = find_header_value(headers, "Cookie: session_id=");
        if (!session_cookie) {
            const char* error = "{\"error\": \"Authentication required\"}";
            send_response(client_fd, 401, error, NULL);
            return;
        }
        
        int user_id = get_user_by_session(session_cookie);
        if (user_id <= 0) {
            const char* error = "{\"error\": \"Authentication required\"}";
            send_response(client_fd, 401, error, NULL);
            return;
        }
        
        // Build JSON array of todos for this user
        char response[5000] = "[";
        int first = 1;
        
        for (int i = 0; i < todo_count; i++) {
            if (todos[i].owner_id == user_id) {
                if (!first) strcat(response, ",");
                
                char todo_json[1000];
                snprintf(todo_json, sizeof(todo_json),
                         "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                         todos[i].id, 
                         todos[i].title, 
                         todos[i].description, 
                         todos[i].completed ? "true" : "false",
                         todos[i].created_at,
                         todos[i].updated_at);
                         
                strcat(response, todo_json);
                first = 0;
            }
        }
        
        strcat(response, "]");
        send_response(client_fd, 200, response, NULL);
    }
    else {
        // Check for /todos/{id} routes
        if (strncmp(path, "/todos/", 7) == 0) {
            int todo_id;
            sscanf(path + 7, "%d", &todo_id);
            
            // Check if user is authenticated
            const char* session_cookie = find_header_value(headers, "Cookie: session_id=");
            int user_id = 0;
            if (session_cookie) {
                user_id = get_user_by_session(session_cookie);
            }
            
            if (user_id <= 0) {
                const char* error = "{\"error\": \"Authentication required\"}";
                send_response(client_fd, 401, error, NULL);
                return;
            }
            
            // Find the todo and check ownership
            int todo_idx = -1;
            for (int i = 0; i < todo_count; i++) {
                if (todos[i].id == todo_id && todos[i].owner_id == user_id) {
                    todo_idx = i;
                    break;
                }
            }
            
            if (todo_idx == -1) {
                // Either doesn't exist or isn't owned by user (per spec this shows 404)
                const char* error = "{\"error\": \"Todo not found\"}";
                send_response(client_fd, 404, error, NULL);
                return;
            }
            
            // Now process the specific todo request based on method
            if (strcmp(method, "GET") == 0) {
                char response[1000];
                snprintf(response, sizeof(response),
                         "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                         todos[todo_idx].id,
                         todos[todo_idx].title,
                         todos[todo_idx].description,
                         todos[todo_idx].completed ? "true" : "false",
                         todos[todo_idx].created_at,
                         todos[todo_idx].updated_at);
                send_response(client_fd, 200, response, NULL);
            }
            else if (strcmp(method, "PUT") == 0) {
                // Extract body for updates
                char* body_start = strstr(buffer, "\r\n\r\n");
                if (!body_start) {
                    const char* error = "{\"error\": \"No request body\"}";
                    send_response(client_fd, 400, error, NULL);
                    return;
                }
                body_start += 4;

                // Parse any present fields in update
                char new_title[200] = {0};
                char new_desc[500] = {0};
                int new_completed = -1;  // -1 means not present
                
                if (strstr(body_start, "\"title\"")) {
                    sscanf(strstr(body_start, "\"title\""), "\"title\": \"%199[^\"]\"", new_title);
                    // If title is empty, return error
                    if (strlen(new_title) == 0) {
                        const char* error = "{\"error\": \"Title is required\"}";
                        send_response(client_fd, 400, error, NULL);
                        return;
                    }
                }
                
                if (strstr(body_start, "\"description\"")) {
                    sscanf( (char*)strstr(body_start, "\"description\""), "\"description\": \"%499[^\"]\"", new_desc);
                }
                
                if (strstr(body_start, "\"completed\"")) {
                    if (strstr((char*)strstr(body_start, "\"completed\":"), "true")) {
                        new_completed = 1;
                    } else if (strstr((char*)strstr(body_start, "\"completed\":"), "false")) {
                        new_completed = 0;
                    }
                }
                
                // Update the fields that were present
                bool changed = false;
                if (strlen(new_title) > 0) {
                    strcpy(todos[todo_idx].title, new_title);
                    changed = true;
                }
                if (strlen(new_desc) > 0) {
                    strcpy(todos[todo_idx].description, new_desc);
                    changed = true;
                } 
                if (new_completed != -1) {
                    todos[todo_idx].completed = (new_completed == 1) ? 1: 0;
                    changed = true;
                }
                
                // Update the timestamp if anything was changed
                if (changed) {
                    char* time_now = get_current_time_iso8601();
                    strcpy(todos[todo_idx].updated_at, time_now);
                }
                
                // Respond with full updated todo
                char response[1000];
                snprintf(response, sizeof(response),
                         "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", \"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
                         todos[todo_idx].id,
                         todos[todo_idx].title,
                         todos[todo_idx].description,
                         todos[todo_idx].completed ? "true" : "false",
                         todos[todo_idx].created_at,
                         todos[todo_idx].updated_at);
                send_response(client_fd, 200, response, NULL);
            }
            else if (strcmp(method, "DELETE") == 0) {
                // Remove the todo
                // Shift all todos after this index left by 1
                for (int i = todo_idx; i < todo_count - 1; i++) {
                    todos[i] = todos[i+1];
                }
                todo_count--;
                // Decrement the max todo_id if this was the last one
                if (todo_idx == todo_count) {
                    next_todo_id--;
                }
                send_response(client_fd, 204, "", NULL);
            }
        }
        else {
            const char* error = "{\"error\": \"Endpoint not found\"}";
            send_response(client_fd, 404, error, NULL);
        }
    }
}

int extract_method_path(char* request, char* method, char* path, int max_len) {
    char* line_end = strstr(request, "\r\n"); 
    if (!line_end) return 0;  // Malformed request
    
    // Get first line which contains: METHOD PATH HTTP/N.N
    *line_end = '\0';
    char temp[512];
    strcpy(temp, request);
    *line_end = '\r';  // Restore original char
    
    // Extract method
    char* token = strtok(temp, " ");
    if (!token) return 0;
    strncpy(method, token, max_len-1);
    method[max_len-1] = '\0';
    
    // Extract path
    token = strtok(NULL, " ");
    if (!token) return 0;
    strncpy(path, token, max_len-1);
    path[max_len-1] = '\0';
    
    return 1;
}

int check_auth(const char* headers) {
    // For now just return 1 to continue with auth implementation below
    return 1;
}

int get_user_by_session(const char* session_token) {
    for (int i = 0; i < session_count; i++) {
        if (sessions[i].valid && strcmp(sessions[i].token, session_token) == 0) {
            return sessions[i].user_id;
        }
    }
    return 0;  // no authenticated user
}

void send_response(int client_fd, int status_code, const char* body, const char* cookie) {
    char response[6000];
    
    // Build response based on status
    char* status_text = "OK";
    switch(status_code) {
        case 200: status_text = "OK"; break;
        case 201: status_text = "Created"; break;
        case 204: status_text = "No Content"; break;
        case 400: status_text = "Bad Request"; break;
        case 401: status_text = "Unauthorized"; break;
        case 404: status_text = "Not Found"; break;
        case 409: status_text = "Conflict"; break;
    }
    
    int offset = sprintf(response, "HTTP/1.1 %d %s\r\n", status_code, status_text);
    offset += sprintf(response + offset, "Content-Type: application/json\r\n");
    
    // Add Set-Cookie header if provided
    if (cookie) {
        offset += sprintf(response + offset, "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", cookie);
    }
    
    offset += sprintf(response + offset, "Content-Length: %zu\r\n", strlen(body));
    offset += sprintf(response + offset, "\r\n");
    offset += sprintf(response + offset, "%s", body);
    
    send(client_fd, response, offset, 0);
}

char* find_header_value(const char* headers, const char* header_name) {
    static char value[512];
    const char* pos = strstr(headers, header_name);
    if (!pos) return NULL;
    
    pos += strlen(header_name);
    int len = 0;
    while(pos[len] && pos[len] != '\r' && pos[len] != '\n' && len < sizeof(value)-1) {
        value[len] = pos[len];
        len++;
    }
    value[len] = '\0';
    
    // Strip trailing whitespace 
    while(len > 0 && (value[len-1] == ' ' || value[len-1] == '\t')) {
        value[--len] = '\0';
    }
    
    // Remove leading semicolon if it exists
    if (value[0] == ';')
        return strchr(value+1, '=') ? strchr(value+1, '=')+1 : NULL;
    
    return value[0] ? value : NULL;
}

char* get_current_time_iso8601() {
    static char time_buf[30];
    time_t now = time(0);
    struct tm tmbuf;
    gmtime_r(&now, &tmbuf);
    strftime(time_buf, sizeof(time_buf), "%Y-%m-%dT%H:%M:%SZ", &tmbuf);
    return time_buf;
}
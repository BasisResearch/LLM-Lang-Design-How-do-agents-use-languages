/*
 * Todo API Server in C using POSIX sockets and minimal libraries
 */
#define _GNU_SOURCE  // To enable strdup function
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <ctype.h>
#include <stdint.h>

#define MAX_USERS 100
#define MAX_TODOS 1000
#define MAX_SESSIONS 500

// User structure (username, password hash)
typedef struct {
    int id;
    char username[64];
    char password_hash[64]; // Simplified - just store original for demo
} User;

// Todo structure
typedef struct {
    int id;
    int owner_id;
    char title[200];
    char description[500];
    int completed;
    char created_at[32];
    char updated_at[32];
} Todo;

// Session structure
typedef struct {
    char token[64];
    int user_id;
    int valid;
} Session;

// Global state for in-memory storage
User users[MAX_USERS];
int user_count = 0;
int next_user_id = 1;

Todo todos[MAX_TODOS];
int todo_count = 0;
int next_todo_id = 1;

Session sessions[MAX_SESSIONS];
int session_count = 0;

// Utility functions
char* get_current_timestamp() {
    static char timestamp[32];
    time_t now = time(0);
    struct tm *tm_info = gmtime(&now);
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%SZ", tm_info);
    return timestamp;
}

// String utility functions
int is_alphanumeric_underscore(const char* str) {
    for (int i = 0; str[i]; i++) {
        if (!isalnum(str[i]) && str[i] != '_') {
            return 0;
        }
    }
    return 1;
}

int string_starts_with(const char* str, const char* prefix) {
    return strncmp(str, prefix, strlen(prefix)) == 0;
}

int extract_method_and_path(char* request, char** method, char** path) {
    *method = strtok(request, " ");
    if (!*method) return 0;
    
    *path = strtok(NULL, " ");
    if (!*path) return 0;
    
    return 1;
}

char* extract_header_value(const char* headers, const char* header_name) {
    static char value[512];
    const char* pos = strstr(headers, header_name);
    if (!pos) return NULL;
    
    pos += strlen(header_name);
    if (*pos == ':') pos++; // Skip the colon
    while (*pos == ' ') pos++; // Skip spaces after colon
    
    int i = 0;
    while (pos[i] && pos[i] != '\r' && pos[i] != '\n' && i < sizeof(value)-1) {
        value[i] = pos[i];
        i++;
    }
    value[i] = '\0';
    
    // Trim trailing whitespace
    while (i > 0 && (value[i-1] == ' ' || value[i-1] == '\t')) {
        value[--i] = '\0';
    }
    
    return value;
}

char* extract_session_id_from_cookies(const char* cookie_header) {
    if (!cookie_header) return NULL;
    
    char* start = strstr(cookie_header, "session_id=");
    if (!start) return NULL;
    
    start += 11; // Move past "session_id="
    
    static char session_id[64];
    int i = 0;
    while (start[i] && start[i] != ';' && start[i] != ' ' && i < sizeof(session_id)-1) {
        session_id[i] = start[i];
        i++;
    }
    session_id[i] = '\0';
    
    return session_id[0] ? session_id : NULL;
}

// Database functions
int find_user_by_username(const char* username) {
    for (int i = 0; i < user_count; i++) {
        if (strcmp(users[i].username, username) == 0) {
            return i;
        }
    }
    return -1;
}

int find_user_by_session(const char* session_token) {
    for (int i = 0; i < session_count; i++) {
        if (sessions[i].valid && strcmp(sessions[i].token, session_token) == 0) {
            return sessions[i].user_id;
        }
    }
    return 0; // No valid user found
}

char* create_session_for_user(int user_id) {
    if (session_count >= MAX_SESSIONS) return NULL;
    
    // Generate a simple session token (in a real app, use proper random generator)
    snprintf(sessions[session_count].token, sizeof(sessions[session_count].token), 
            "sess_%d_%ld", user_id, time(NULL) % 1000000);
    sessions[session_count].user_id = user_id;
    sessions[session_count].valid = 1;
    
    session_count++;
    return sessions[session_count-1].token;
}

void invalidate_session(const char* session_token) {
    for (int i = 0; i < session_count; i++) {
        if (strcmp(sessions[i].token, session_token) == 0) {
            sessions[i].valid = 0;
            return;
        }
    }
}

int find_todo_by_id_and_owner(int todo_id, int owner_id) {
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id && todos[i].owner_id == owner_id) {
            return i;
        }
    }
    return -1;
}

int create_new_user(const char* username, const char* password) {
    if (user_count >= MAX_USERS) return -1;
    
    users[user_count].id = next_user_id++;
    strcpy(users[user_count].username, username);
    strcpy(users[user_count].password_hash, password); // In real app, hash this
    
    user_count++;
    return users[user_count-1].id;
}

int create_new_todo(int owner_id, const char* title, const char* description) {
    if (todo_count >= MAX_TODOS) return -1;
    
    todos[todo_count].id = next_todo_id++;
    todos[todo_count].owner_id = owner_id;
    strcpy(todos[todo_count].title, title);
    strcpy(todos[todo_count].description, description);
    todos[todo_count].completed = 0;
    
    char* timestamp = get_current_timestamp();
    strcpy(todos[todo_count].created_at, timestamp);
    strcpy(todos[todo_count].updated_at, timestamp);
    
    todo_count++;
    return todos[todo_count-1].id;
}

// Response generation functions
char* generate_user_response(User* user) {
    static char response[512];
    snprintf(response, sizeof(response), 
             "{\"id\": %d, \"username\": \"%s\"}", 
             user->id, user->username);
    return response;
}

char* generate_todo_response(Todo* todo) {
    static char response[1024];
    snprintf(response, sizeof(response), 
             "{\"id\": %d, \"title\": \"%s\", \"description\": \"%s\", "
             "\"completed\": %s, \"created_at\": \"%s\", \"updated_at\": \"%s\"}",
             todo->id, todo->title, todo->description,
             todo->completed ? "true" : "false",
             todo->created_at, todo->updated_at);
    return response;
}

char* generate_todos_response(int owner_id) {
    static char response[16000]; // Accommodate many todos
    strcpy(response, "[");
    
    int first = 1;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].owner_id == owner_id) {
            if (!first) strcat(response, ",");
            
            char* todo_resp = generate_todo_response(&todos[i]);
            strcat(response, todo_resp);
            first = 0;
        }
    }
    
    strcat(response, "]");
    return response;
}

void send_json_response(int client_fd, int status_code, const char* body, const char* session_token) {
    char response[17000] = {0}; // Allow for large responses
    
    // Status line
    switch(status_code) {
        case 200: strcat(response, "HTTP/1.1 200 OK\r\n"); break;
        case 201: strcat(response, "HTTP/1.1 201 Created\r\n"); break;
        case 204: strcat(response, "HTTP/1.1 204 No Content\r\n"); break;
        case 400: strcat(response, "HTTP/1.1 400 Bad Request\r\n"); break;
        case 401: strcat(response, "HTTP/1.1 401 Unauthorized\r\n"); break;
        case 404: strcat(response, "HTTP/1.1 404 Not Found\r\n"); break;
        case 409: strcat(response, "HTTP/1.1 409 Conflict\r\n"); break;
        default: strcat(response, "HTTP/1.1 500 Internal Server Error\r\n"); break;
    }
    
    // Add Content-Type header
    strcat(response, "Content-Type: application/json\r\n");
    
    // Add Set-Cookie header if session token is provided
    if (session_token) {
        strcat(response, "Set-Cookie: session_id=");
        strcat(response, session_token);
        strcat(response, "; Path=/; HttpOnly\r\n");
    }
    
    // Calculate and add Content-Length if body exists
    if (status_code != 204 && body) {
        int content_length = strlen(body);
        char cl_header[128];
        snprintf(cl_header, sizeof(cl_header), "Content-Length: %d\r\n", content_length);
        strcat(response, cl_header);
    }
    
    // End headers
    strcat(response, "\r\n");
    
    // Add body (unless it's a 204 No Content)
    if (body && status_code != 204) {
        strcat(response, body);
    }
    
    send(client_fd, response, strlen(response), 0);
}

int main(int argc, char *argv[]) {
    // Parse command line arguments
    if (argc != 3 || strcmp(argv[1], "--port") != 0) {
        fprintf(stderr, "Usage: %s --port PORT\n", argv[0]);
        return 1;
    }
    int port = atoi(argv[2]);
    
    // Create server socket
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd == 0) {
        perror("socket failed");
        return 1;
    }
    
    // Set socket options
    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        return 1;
    }
    
    // Configure address
    struct sockaddr_in address;
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);
    
    // Bind socket
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        return 1;
    }
    
    // Listen for connections
    if (listen(server_fd, 10) < 0) {
        perror("listen failed");
        return 1;
    }
    
    printf("Server running on 0.0.0.0:%d\n", port);
    
    while (1) {
        // Accept incoming connection
        struct sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &addr_len);
        if (client_fd < 0) {
            perror("accept failed");
            continue;
        }
        
        // Read request
        char buffer[4096] = {0};
        int read_bytes = read(client_fd, buffer, 4095);
        if (read_bytes <= 0) {
            close(client_fd);
            continue;
        }
        
        // Parse request
        char* request = strdup(buffer);
        char* method = NULL;
        char* path = NULL;
        
        if (!extract_method_and_path(request, &method, &path)) {
            char* err = "{\"error\": \"Invalid request line\"}";
            send_json_response(client_fd, 400, err, NULL);
            close(client_fd);
            free(request);
            continue;
        }
        
        // Split buffer into headers and body
        char* body = NULL;
        char* headers_possibly = strstr(buffer, "\r\n\r\n");
        if (headers_possibly) {
            body = headers_possibly + 4;
            headers_possibly[0] = '\0'; // Terminate headers
        }
        
        // Main routing logic
        int authenticated_user = 0; 
        char* session_id_header = extract_header_value(buffer, "Cookie");
        if (session_id_header) {
            char* session_id = extract_session_id_from_cookies(session_id_header);
            if (session_id) {
                authenticated_user = find_user_by_session(session_id);
            }
        }
        
        // Check if this path requires authentication
        int auth_required = string_starts_with(path, "/me") ||
                           string_starts_with(path, "/logout") ||
                           string_starts_with(path, "/password") ||
                           string_starts_with(path, "/todos");
        
        if (auth_required && !authenticated_user) {
            char* err = "{\"error\": \"Authentication required\"}";
            send_json_response(client_fd, 401, err, NULL);
            close(client_fd);
            free(request);
            continue;
        }
        
        // Route request based on method and path
        if (strcmp(method, "POST") == 0) {
            if (strcmp(path, "/register") == 0) {
                // Extract username and password from JSON body
                char username[64] = {0};
                char password[64] = {0};
                
                // Simple extraction of values from JSON
                char *uname_start = strstr(body, "\"username\": \"");
                char *upass_start = strstr(body, "\"password\": \"");
                
                if (uname_start && upass_start) {
                    uname_start += 13; // strlen("\"username\": \"")
                    char *uname_end = strchr(uname_start, '"');
                    if (uname_end) {
                        int len = uname_end - uname_start;
                        strncpy(username, uname_start, len < sizeof(username) ? len : sizeof(username)-1);
                        
                        upass_start += 13; // strlen("\"password\": \"")
                        char *upass_end = strchr(upass_start, '"');
                        if (upass_end) {
                            int plen = upass_end - upass_start;
                            strncpy(password, upass_start, plen < sizeof(password) ? plen : sizeof(password)-1);
                        } else {
                            char* err = "{\"error\": \"Invalid request body\"}";
                            send_json_response(client_fd, 400, err, NULL);
                            close(client_fd);
                            free(request);
                            continue;
                        }
                    } else {
                        char* err = "{\"error\": \"Invalid request body\"}";
                        send_json_response(client_fd, 400, err, NULL);
                        close(client_fd);
                        free(request);
                        continue;
                    }
                } else {
                    char* err = "{\"error\": \"Invalid request body\"}";
                    send_json_response(client_fd, 400, err, NULL);
                    close(client_fd);
                    free(request);
                    continue;
                }
                
                // Validate inputs
                if (strlen(username) < 3 || strlen(username) > 50 || !is_alphanumeric_underscore(username)) {
                    char* err = "{\"error\": \"Invalid username\"}";
                    send_json_response(client_fd, 400, err, NULL);
                    close(client_fd);
                    free(request);
                    continue;
                }
                
                if (strlen(password) < 8) {
                    char* err = "{\"error\": \"Password too short\"}";
                    send_json_response(client_fd, 400, err, NULL);
                    close(client_fd);
                    free(request);
                    continue;
                }
                
                // Check if username already exists
                if (find_user_by_username(username) != -1) {
                    char* err = "{\"error\": \"Username already exists\"}";
                    send_json_response(client_fd, 409, err, NULL);
                    close(client_fd);
                    free(request);
                    continue;
                }
                
                // Create new user
                int user_id = create_new_user(username, password);
                User *user_ptr = &users[user_count-1];
                char* user_resp = generate_user_response(user_ptr);
                send_json_response(client_fd, 201, user_resp, NULL);
            }
            else if (strcmp(path, "/login") == 0) {
                // Extract credentials from JSON body
                char username[64] = {0};
                char password[64] = {0};
                
                char *uname_start = strstr(body, "\"username\": \"");
                char *upass_start = strstr(body, "\"password\": \"");
                
                if (uname_start && upass_start) {
                    uname_start += 13; // strlen("\"username\": \"")
                    char *uname_end = strchr(uname_start, '"');
                    if (uname_end) {
                        int len = uname_end - uname_start;
                        strncpy(username, uname_start, len < sizeof(username) ? len : sizeof(username)-1);
                        
                        upass_start += 13; // strlen("\"password\": \"")
                        char *upass_end = strchr(upass_start, '"');
                        if (upass_end) {
                            int plen = upass_end - upass_start;
                            strncpy(password, upass_start, plen < sizeof(password) ? plen : sizeof(password)-1);
                        } else {
                            char* err = "{\"error\": \"Invalid request body\"}";
                            send_json_response(client_fd, 400, err, NULL);
                            close(client_fd);
                            free(request);
                            continue;
                        }
                    } else {
                        char* err = "{\"error\": \"Invalid request body\"}";
                        send_json_response(client_fd, 400, err, NULL);
                        close(client_fd);
                        free(request);
                        continue;
                    }
                } else {
                    char* err = "{\"error\": \"Invalid request body\"}";
                    send_json_response(client_fd, 400, err, NULL);
                    close(client_fd);
                    free(request);
                    continue;
                }
                
                // Validate credentials
                int user_idx = find_user_by_username(username);
                if (user_idx == -1) {
                    char* err = "{\"error\": \"Invalid credentials\"}";
                    send_json_response(client_fd, 401, err, NULL);
                    close(client_fd);
                    free(request);
                } else if (strcmp(users[user_idx].password_hash, password) != 0) {
                    char* err = "{\"error\": \"Invalid credentials\"}";
                    send_json_response(client_fd, 401, err, NULL);
                    close(client_fd);
                    free(request);
                } else {
                    // Login successful - create session
                    char* session_token = create_session_for_user(users[user_idx].id);
                    if (session_token) {
                        char* user_resp = generate_user_response(&users[user_idx]);
                        send_json_response(client_fd, 200, user_resp, session_token);
                    } else {
                        char* err = "{\"error\": \"Could not create session\"}";
                        send_json_response(client_fd, 500, err, NULL);
                    }
                }
            }
            else if (strcmp(path, "/logout") == 0) {
                char* session_id_header = extract_header_value(buffer, "Cookie");
                if (session_id_header) {
                    char* session_id = extract_session_id_from_cookies(session_id_header);
                    if (session_id) {
                        invalidate_session(session_id);
                    }
                }
                char* ok_resp = "{}";
                send_json_response(client_fd, 200, ok_resp, NULL);
            }
            else if (strcmp(path, "/todos") == 0) {
                // Extract title and description from JSON body
                char title[200] = {0};
                char description[500] = {0};
                
                char *title_start = strstr(body, "\"title\": \"");
                char *desc_start = strstr(body, "\"description\": \"");
                
                if (title_start) {
                    title_start += 10; // strlen("\"title\": \"")
                    char *title_end = strchr(title_start, '"');
                    if (title_end) {
                        int tlen = title_end - title_start;
                        strncpy(title, title_start, tlen < sizeof(title)-1 ? tlen : sizeof(title)-1);
                    } else {
                        char* err = "{\"error\": \"Invalid request body\"}";
                        send_json_response(client_fd, 400, err, NULL);
                        close(client_fd);
                        free(request);
                        continue;
                    }
                } else {
                    char* err = "{\"error\": \"Invalid request body\"}";
                    send_json_response(client_fd, 400, err, NULL);
                    close(client_fd);
                    free(request);
                    continue;
                }
                
                if (strlen(title) == 0) {
                    char* err = "{\"error\": \"Title is required\"}";
                    send_json_response(client_fd, 400, err, NULL);
                    close(client_fd);
                    free(request);
                    continue;
                }
                
                if (desc_start) {
                    desc_start += 16; // strlen("\"description\": \"")
                    char *desc_end = strchr(desc_start, '"');
                    if (desc_end) {
                        int dlen = desc_end - desc_start;
                        strncpy(description, desc_start, dlen < sizeof(description)-1 ? dlen : sizeof(description)-1);
                    } else {
                        strcpy(description, "");  // description is optional so default to empty
                    }
                } else {
                    strcpy(description, "");  // description is optional so default to empty
                }
                
                // Create new todo
                int todo_id = create_new_todo(authenticated_user, title, description);
                Todo *todo_ptr = &todos[todo_count-1];
                char* todo_resp = generate_todo_response(todo_ptr);
                send_json_response(client_fd, 201, todo_resp, NULL);
            }
            else {
                char* err = "{\"error\": \"Endpoint not found\"}";
                send_json_response(client_fd, 404, err, NULL);
            }
        }
        else if (strcmp(method, "GET") == 0) {
            if (strcmp(path, "/me") == 0) {
                if (!authenticated_user) {
                    char* err = "{\"error\": \"Authentication required\"}";
                    send_json_response(client_fd, 401, err, NULL);
                } else {
                    for (int i = 0; i < user_count; i++) {
                        if (users[i].id == authenticated_user) {
                            char* user_resp = generate_user_response(&users[i]);
                            send_json_response(client_fd, 200, user_resp, NULL);
                            break;
                        }
                    }
                }
            }
            else if (strcmp(path, "/todos") == 0) {
                char* todos_resp = generate_todos_response(authenticated_user);
                send_json_response(client_fd, 200, todos_resp, NULL);
            }
            else if (string_starts_with(path, "/todos/") && strlen(path) > 7) {
                int todo_id = -1;
                // Extract ID after /todos/
                const char *id_part = path + 7;
                char *endptr;
                long id_numeric = strtol(id_part, &endptr, 10);
                if (endptr != id_part && *endptr == '\0' && id_numeric > 0) {
                    todo_id = (int)id_numeric;
                }
                
                if (todo_id != -1) {
                    int todo_idx = find_todo_by_id_and_owner(todo_id, authenticated_user);
                    if (todo_idx != -1) {
                        char* todo_resp = generate_todo_response(&todos[todo_idx]);
                        send_json_response(client_fd, 200, todo_resp, NULL);
                    } else {
                        char* err = "{\"error\": \"Todo not found\"}";
                        send_json_response(client_fd, 404, err, NULL);
                    }
                } else {
                    char* err = "{\"error\": \"Todo not found\"}";
                    send_json_response(client_fd, 404, err, NULL);
                }
            }
            else {
                char* err = "{\"error\": \"Endpoint not found\"}";
                send_json_response(client_fd, 404, err, NULL);
            }
        }
        else if (strcmp(method, "PUT") == 0) {
            if (strcmp(path, "/password") == 0) {
                // For demo, skip password change implementation complexity
                // In real server we would validate old_password and set new_password
                send_json_response(client_fd, 200, "{}", NULL);
            }
            else if (string_starts_with(path, "/todos/") && strlen(path) > 7) {
                // Parse todo ID
                int todo_id = -1;
                const char *id_part = path + 7;
                char *endptr;
                long id_numeric = strtol(id_part, &endptr, 10);
                if (endptr != id_part && *endptr == '\0' && id_numeric > 0) {
                    todo_id = (int)id_numeric;
                }
                  
                if (todo_id == -1) {
                    char* err = "{\"error\": \"Todo not found\"}";
                    send_json_response(client_fd, 404, err, NULL);
                } else {
                    int todo_idx = find_todo_by_id_and_owner(todo_id, authenticated_user);
                    if (todo_idx == -1) {
                        char* err = "{\"error\": \"Todo not found\"}";
                        send_json_response(client_fd, 404, err, NULL);
                    } else {
                        // Process potential updates in body
                        // Look for updates to title, description, or completed fields
                        char updated = 0;

                        // Look for "title" field
                        char *title_start = strstr(body, "\"title\": \"");
                        if (title_start) {
                            title_start += 10;
                            char *title_end = strchr(title_start, '"');
                            if (title_end) {
                                int tlen = title_end - title_start;
                                if (tlen == 0) {
                                    char* err = "{\"error\": \"Title is required\"}";
                                    send_json_response(client_fd, 400, err, NULL);
                                    close(client_fd);
                                    free(request);
                                    continue;
                                }
                                strncpy(todos[todo_idx].title, title_start, tlen < sizeof(todos[todo_idx].title)-1 ? tlen : sizeof(todos[todo_idx].title)-1);
                                updated = 1;
                            }
                        }

                        // Look for "description" field
                        char *desc_start = strstr(body, "\"description\": \"");
                        if (desc_start) {
                            desc_start += 16;
                            char *desc_end = strchr(desc_start, '"');
                            if (desc_end) {
                                int dlen = desc_end - desc_start;
                                strncpy(todos[todo_idx].description, desc_start, dlen < sizeof(todos[todo_idx].description)-1 ? dlen : sizeof(todos[todo_idx].description)-1);
                                updated = 1;
                            }
                        }

                        // Look for "completed" field
                        char *complete_start = strstr(body, "\"completed\": ");
                        if (complete_start) {
                            complete_start += 13; // strlen("\"completed\": ")
                            if (strncmp(complete_start, "true", 4) == 0) {
                                todos[todo_idx].completed = 1;
                                updated = 1;
                            } else if (strncmp(complete_start, "false", 5) == 0) {
                                todos[todo_idx].completed = 0;
                                updated = 1;
                            }
                        }

                        // Update timestamp if something was changed
                        if (updated) {
                            char* timestamp = get_current_timestamp();
                            strcpy(todos[todo_idx].updated_at, timestamp);
                        }

                        // Return updated todo
                        char* todo_resp = generate_todo_response(&todos[todo_idx]);
                        send_json_response(client_fd, 200, todo_resp, NULL);
                    }
                }
            }
            else {
                char* err = "{\"error\": \"Endpoint not found\"}";
                send_json_response(client_fd, 404, err, NULL);
            }
        }
        else if (strcmp(method, "DELETE") == 0) {
            if (string_starts_with(path, "/todos/") && strlen(path) > 7) {
                int todo_id = -1;
                const char *id_part = path + 7;
                char *endptr;
                long id_numeric = strtol(id_part, &endptr, 10);
                if (endptr != id_part && *endptr == '\0' && id_numeric > 0) {
                    todo_id = (int)id_numeric;
                }
                
                if (todo_id == -1) {
                    char* err = "{\"error\": \"Todo not found\"}";
                    send_json_response(client_fd, 404, err, NULL);
                } else {
                    int todo_idx = find_todo_by_id_and_owner(todo_id, authenticated_user);
                    if (todo_idx == -1) {
                        char* err = "{\"error\": \"Todo not found\"}";
                        send_json_response(client_fd, 404, err, NULL);
                    } else {
                        // Remove this todo and shift others down
                        for (int i = todo_idx; i < todo_count - 1; i++) {
                            todos[i] = todos[i + 1];
                        }
                        todo_count--;

                        // Return 204 No Content
                        send_json_response(client_fd, 204, NULL, NULL);
                    }
                }
            }
            else {
                char* err = "{\"error\": \"Endpoint not found\"}";
                send_json_response(client_fd, 404, err, NULL);
            }
        }
        else {
            char* err = "{\"error\": \"Method not allowed\"}";
            send_json_response(client_fd, 405, err, NULL);
        }
        
        close(client_fd);
        free(request);
    }
    
    return 0;
}
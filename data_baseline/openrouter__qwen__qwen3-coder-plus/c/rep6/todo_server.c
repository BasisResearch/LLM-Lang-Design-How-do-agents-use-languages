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
#include <regex.h>
#include <json-c/json.h>

#define MAX_USERS 1000
#define MAX_TODOS_PER_USER 1000
#define MAX_SESSIONS 1000
#define BUFFER_SIZE 8192
#define USERNAME_MIN_LENGTH 3
#define USERNAME_MAX_LENGTH 50
#define PASSWORD_MIN_LENGTH 8

typedef struct {
    int id;
    char username[USERNAME_MAX_LENGTH + 1];
    char password_hash[256]; // We'll just store original password for simplicity
    int active;
} User;

typedef struct {
    int id;
    char title[1024];
    char description[1024];
    int completed;
    char created_at[32];
    char updated_at[32];
    int user_id;
    int active;
} Todo;

typedef struct {
    char session_token[37]; // UUID string length is 36 + '\0'
    int user_id;
    int active;
} Session;

User users[MAX_USERS];
Todo todos[MAX_USERS * MAX_TODOS_PER_USER];
Session sessions[MAX_SESSIONS];

int next_user_id = 1;
int next_todo_id = 1;
int next_session_slot = 0;

// Utility functions
void get_current_timestamp(char *buffer, size_t size) {
    time_t now = time(0);
    struct tm *tm_info = gmtime(&now);
    strftime(buffer, size, "%Y-%m-%dT%H:%M:%SZ", tm_info);
}

void generate_session_id(char *session_id) {
    uuid_t uuid;
    uuid_generate(uuid);
    uuid_unparse(uuid, session_id);
}

int is_valid_username(const char *username) {
    if (!username || strlen(username) < USERNAME_MIN_LENGTH || strlen(username) > USERNAME_MAX_LENGTH) {
        return 0;
    }
    
    regex_t regex;
    int result = regcomp(&regex, "^[a-zA-Z0-9_]+$", REG_EXTENDED | REG_NOSUB);
    if (result != 0) {
        return 0;
    }
    
    result = regexec(&regex, username, 0, NULL, 0);
    regfree(&regex);
    
    return (result == 0) ? 1 : 0;
}

// Data structures management
int find_user_by_id(int user_id) {
    for (int i = 0; i < MAX_USERS; i++) {
        if (users[i].active && users[i].id == user_id) {
            return i;
        }
    }
    return -1;
}

int find_user_by_username(const char *username) {
    for (int i = 0; i < MAX_USERS; i++) {
        if (users[i].active && strcmp(users[i].username, username) == 0) {
            return i;
        }
    }
    return -1;
}

int find_todo_by_id_and_user(int todo_id, int user_id) {
    for (int i = 0; i < MAX_USERS * MAX_TODOS_PER_USER; i++) {
        if (todos[i].active && todos[i].id == todo_id && todos[i].user_id == user_id) {
            return i;
        }
    }
    return -1;
}

int find_inactive_user_slot() {
    for (int i = 0; i < MAX_USERS; i++) {
        if (!users[i].active) {
            return i;
        }
    }
    return -1;
}

int find_inactive_todo_slot() {
    for (int i = 0; i < MAX_USERS * MAX_TODOS_PER_USER; i++) {
        if (!todos[i].active) {
            return i;
        }
    }
    return -1;
}

int find_session_by_token(const char *token) {
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].active && strcmp(sessions[i].session_token, token) == 0) {
            return i;
        }
    }
    return -1;
}

int find_inactive_session_slot() {
    // Look circularly for the next slot, potentially overwriting old sessions
    for (int attempts = 0; attempts < MAX_SESSIONS; attempts++) {
        int index = (next_session_slot + attempts) % MAX_SESSIONS;
        if (!sessions[index].active) {
            next_session_slot = index;
            return index;
        }
    }
    return -1; // This shouldn't happen if we properly clean up expired sessions
}

// Authentication
int authenticate_request(const char *all_headers, int *user_id) {
    // Look for Cookie header, handling both formats "Cookie: " and "cookie: "
    const char *pos = all_headers;
    const char *end = pos + strlen(pos);  // Set a reasonable upper bound for searching
    
    // First find start and end of the first line containing "Cookie:" ignoring case
    const char *cookie_line;
    cookie_line = strcasestr(pos, "Cookie:");
    if (!cookie_line) return 0; // No cookie header found

    // Move forward past "Cookie:"
    cookie_line += 7; // Length of "Cookie:"
    
    // Find beginning of cookie value by skipping spaces
    while (*cookie_line == ' ' || *cookie_line == ':') cookie_line++;

    // Look for session_id in the cookie values
    const char *session_id_pos = strstr(cookie_line, "session_id=");
    if (!session_id_pos) {
        return 0; // session_id not found in cookies
    }
    
    session_id_pos += 11; // Skip "session_id="
    
    // Extract the token value (until semicolon or space or end of line)
    char session_token[256];
    int token_idx = 0;
    while (*session_id_pos && *session_id_pos != ';' && *session_id_pos != ' ' && 
          *session_id_pos != '\r' && *session_id_pos != '\n' && token_idx < 255) {
        session_token[token_idx++] = *session_id_pos;
        session_id_pos++;
    }
    session_token[token_idx] = '\0';
    
    // Look up session by token
    int session_idx = find_session_by_token(session_token);
    if (session_idx != -1 && sessions[session_idx].active) {
        *user_id = sessions[session_idx].user_id;
        return 1;
    }
    
    return 0; // Invalid or inactive session
}

// Parse a specific route like "/todos/123" to extract the ID
int parse_todo_id_from_uri(const char *uri) {
    const char *prefix = "/todos/";
    int prefix_len = 7; // length of "/todos/"
    
    if (strncmp(uri, prefix, prefix_len) == 0) {
        // Extract the ID part after "/todos/"
        const char *id_str = uri + prefix_len;
        char *endptr;
        long id = strtol(id_str, &endptr, 10);
        
        // Make sure we consumed only digits and nothing more
        if (endptr && *endptr == '\0' && id > 0) {
            return (int)id;
        }
    }
    return -1;
}

// Endpoints
int handle_register(int client_fd, const char *req_body, const char *headers) {
    json_object *jobj = json_tokener_parse(req_body);
    if (!jobj) {
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid JSON\"}");
        return 0;
    }

    json_object *username_obj, *password_obj;
    if (!json_object_object_get_ex(jobj, "username", &username_obj) ||
        !json_object_object_get_ex(jobj, "password", &password_obj)) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Missing username or password\"}");
        return 0;
    }

    const char *username = json_object_get_string(username_obj);
    const char *password = json_object_get_string(password_obj);

    if (!is_valid_username(username)) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid username\"}");
        return 0;
    }

    if (strlen(password) < PASSWORD_MIN_LENGTH) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Password too short\"}");
        return 0;
    }

    if (find_user_by_username(username) != -1) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Username already exists\"}");
        return 0;
    }

    int slot = find_inactive_user_slot();
    if (slot == -1) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 507 Insufficient Storage\r\nContent-Type: application/json\r\n\r\n{\"error\": \"System full\"}");
        return 0;
    }

    users[slot].id = next_user_id++;
    strcpy(users[slot].username, username);
    strcpy(users[slot].password_hash, password); // In real app, hash this
    users[slot].active = 1;

    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(users[slot].id));
    json_object_object_add(response, "username", json_object_new_string(username));

    dprintf(client_fd, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n\r\n");
    dprintf(client_fd, "%s", json_object_to_json_string(response));

    json_object_put(response);
    json_object_put(jobj);
    return 0;
}

int handle_login(int client_fd, const char *req_body, const char *headers) {
    json_object *jobj = json_tokener_parse(req_body);
    if (!jobj) {
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid JSON\"}");
        return 0;
    }

    json_object *username_obj, *password_obj;
    if (!json_object_object_get_ex(jobj, "username", &username_obj) ||
        !json_object_object_get_ex(jobj, "password", &password_obj)) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Missing username or password\"}");
        return 0;
    }

    const char *username = json_object_get_string(username_obj);
    const char *password = json_object_get_string(password_obj);

    int user_idx = find_user_by_username(username);
    if (user_idx == -1 || strcmp(users[user_idx].password_hash, password) != 0) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid credentials\"}");
        return 0;
    }

    // Create session
    int slot = find_inactive_session_slot();
    if (slot == -1) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 507 Insufficient Storage\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Could not create session\"}");
        return 0;
    }

    generate_session_id(sessions[slot].session_token);
    sessions[slot].user_id = users[user_idx].id;
    sessions[slot].active = 1;

    // Set response
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(users[user_idx].id));
    json_object_object_add(response, "username", json_object_new_string(users[user_idx].username));

    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nSet-Cookie: session_id=%s; Path=/; HttpOnly\r\n\r\n", sessions[slot].session_token);
    dprintf(client_fd, "%s", json_object_to_json_string(response));

    json_object_put(response);
    json_object_put(jobj);
    return 0;
}

int handle_logout(int client_fd, const char *req_body, const char *headers) {
    int user_id;
    if (!authenticate_request(headers, &user_id)) {
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    // Find and invalidate all sessions for this user
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (sessions[i].active && sessions[i].user_id == user_id) {
            sessions[i].active = 0;
        }
    }
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}");
    return 0;
}

int handle_me(int client_fd, const char *req_body, const char *headers) {
    int user_id;
    if (!authenticate_request(headers, &user_id)) {
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    int user_idx = find_user_by_id(user_id);
    if (user_idx == -1) {
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(users[user_idx].id));
    json_object_object_add(response, "username", json_object_new_string(users[user_idx].username));
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n");
    dprintf(client_fd, "%s", json_object_to_json_string(response));
    
    json_object_put(response);
    return 0;
}

int handle_change_password(int client_fd, const char *req_body, const char *headers) {
    int user_id;
    if (!authenticate_request(headers, &user_id)) {
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    json_object *jobj = json_tokener_parse(req_body);
    if (!jobj) {
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid JSON\"}");
        return 0;
    }
    
    json_object *old_password_obj, *new_password_obj;
    if (!json_object_object_get_ex(jobj, "old_password", &old_password_obj) ||
        !json_object_object_get_ex(jobj, "new_password", &new_password_obj)) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Missing old_password or new_password\"}");
        return 0;
    }
    
    const char *old_password = json_object_get_string(old_password_obj);
    const char *new_password = json_object_get_string(new_password_obj);
    
    if (strlen(new_password) < PASSWORD_MIN_LENGTH) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Password too short\"}");
        return 0;
    }
    
    int user_idx = find_user_by_id(user_id);
    if (user_idx == -1) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    if (strcmp(users[user_idx].password_hash, old_password) != 0) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid credentials\"}");
        return 0;
    }
    
    strcpy(users[user_idx].password_hash, new_password);
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}");
    
    json_object_put(jobj);
    return 0;
}

int handle_get_todos(int client_fd, const char *req_body, const char *headers) {
    int user_id;
    if (!authenticate_request(headers, &user_id)) {
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    json_object *response = json_object_new_array();
    for (int i = 0; i < MAX_USERS * MAX_TODOS_PER_USER; i++) {
        if (todos[i].active && todos[i].user_id == user_id) {
            json_object *todo_obj = json_object_new_object();
            json_object_object_add(todo_obj, "id", json_object_new_int(todos[i].id));
            json_object_object_add(todo_obj, "title", json_object_new_string(todos[i].title));
            json_object_object_add(todo_obj, "description", json_object_new_string(todos[i].description));
            json_object_object_add(todo_obj, "completed", json_object_new_boolean(todos[i].completed));
            json_object_object_add(todo_obj, "created_at", json_object_new_string(todos[i].created_at));
            json_object_object_add(todo_obj, "updated_at", json_object_new_string(todos[i].updated_at));
            json_object_array_add(response, todo_obj);
        }
    }
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n");
    dprintf(client_fd, "%s", json_object_to_json_string(response));
    
    json_object_put(response);
    return 0;
}

int handle_create_todo(int client_fd, const char *req_body, const char *headers) {
    int user_id;
    if (!authenticate_request(headers, &user_id)) {
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    json_object *jobj = json_tokener_parse(req_body);
    if (!jobj) {
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid JSON\"}");
        return 0;
    }
    
    json_object *title_obj, *desc_obj;
    if (!json_object_object_get_ex(jobj, "title", &title_obj)) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Title is required\"}");
        return 0;
    }
    
    const char *title = json_object_get_string(title_obj);
    if (strlen(title) == 0) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Title is required\"}");
        return 0;
    }
    
    const char *description = "";
    if (json_object_object_get_ex(jobj, "description", &desc_obj)) {
        description = json_object_get_string(desc_obj);
    } else {
        description = "";
    }
    
    int slot = find_inactive_todo_slot();
    if (slot == -1) {
        json_object_put(jobj);
        dprintf(client_fd, "HTTP/1.1 507 Insufficient Storage\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Too many todos\"}");
        return 0;
    }
    
    char timestamp[32];
    get_current_timestamp(timestamp, sizeof(timestamp));
    
    todos[slot].id = next_todo_id++;
    strcpy(todos[slot].title, title);
    strcpy(todos[slot].description, description);
    todos[slot].completed = 0;
    strcpy(todos[slot].created_at, timestamp);
    strcpy(todos[slot].updated_at, timestamp);  // Set to same as created_at since this is new  
    todos[slot].user_id = user_id;
    todos[slot].active = 1;
    
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(todos[slot].id));
    json_object_object_add(response, "title", json_object_new_string(todos[slot].title));
    json_object_object_add(response, "description", json_object_new_string(todos[slot].description));
    json_object_object_add(response, "completed", json_object_new_boolean(todos[slot].completed));
    json_object_object_add(response, "created_at", json_object_new_string(todos[slot].created_at));
    json_object_object_add(response, "updated_at", json_object_new_string(todos[slot].updated_at));
    
    dprintf(client_fd, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n\r\n");
    dprintf(client_fd, "%s", json_object_to_json_string(response));
    
    json_object_put(response);
    json_object_put(jobj);
    return 0;
}

int handle_get_todo(int client_fd, const char *uri, const char *req_body, const char *headers) {
    int user_id;
    if (!authenticate_request(headers, &user_id)) {
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    int requested_todo_id = parse_todo_id_from_uri(uri);
    if (requested_todo_id <= 0) {
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Todo not found\"}");
        return 0;
    }
    
    int todo_idx = find_todo_by_id_and_user(requested_todo_id, user_id);
    if (todo_idx == -1) {
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Todo not found\"}");
        return 0;
    }
    
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(todos[todo_idx].id));
    json_object_object_add(response, "title", json_object_new_string(todos[todo_idx].title));
    json_object_object_add(response, "description", json_object_new_string(todos[todo_idx].description));
    json_object_object_add(response, "completed", json_object_new_boolean(todos[todo_idx].completed));
    json_object_object_add(response, "created_at", json_object_new_string(todos[todo_idx].created_at));
    json_object_object_add(response, "updated_at", json_object_new_string(todos[todo_idx].updated_at));
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n");
    dprintf(client_fd, "%s", json_object_to_json_string(response));
    
    json_object_put(response);
    return 0;
}

int handle_update_todo(int client_fd, const char *uri, const char *req_body, const char *headers) {
    int user_id;
    if (!authenticate_request(headers, &user_id)) {
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    int requested_todo_id = parse_todo_id_from_uri(uri);
    if (requested_todo_id <= 0) {
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Todo not found\"}");
        return 0;
    }
    
    int todo_idx = find_todo_by_id_and_user(requested_todo_id, user_id);
    if (todo_idx == -1) {
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Todo not found\"}");
        return 0;
    }
    
    json_object *jobj = json_tokener_parse(req_body);
    if (!jobj) {
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid JSON\"}");
        return 0;
    }
    
    // Update applicable fields
    json_object *title_obj, *desc_obj, *completed_obj;
    
    if (json_object_object_get_ex(jobj, "title", &title_obj)) {
        const char *new_title = json_object_get_string(title_obj);
        if (strlen(new_title) == 0) {
            json_object_put(jobj);
            dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Title is required\"}");
            return 0;
        }
        strcpy(todos[todo_idx].title, new_title);
    }
    
    if (json_object_object_get_ex(jobj, "description", &desc_obj)) {
        const char *new_description = json_object_get_string(desc_obj);
        strcpy(todos[todo_idx].description, new_description);
    }
    
    if (json_object_object_get_ex(jobj, "completed", &completed_obj)) {
        todos[todo_idx].completed = json_object_get_boolean(completed_obj);
    }
    
    // Update timestamp
    char timestamp[32];
    get_current_timestamp(timestamp, sizeof(timestamp));
    strcpy(todos[todo_idx].updated_at, timestamp);
    
    // Create response
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(todos[todo_idx].id));
    json_object_object_add(response, "title", json_object_new_string(todos[todo_idx].title));
    json_object_object_add(response, "description", json_object_new_string(todos[todo_idx].description));
    json_object_object_add(response, "completed", json_object_new_boolean(todos[todo_idx].completed));
    json_object_object_add(response, "created_at", json_object_new_string(todos[todo_idx].created_at));
    json_object_object_add(response, "updated_at", json_object_new_string(todos[todo_idx].updated_at));
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n");
    dprintf(client_fd, "%s", json_object_to_json_string(response));
    
    json_object_put(response);
    json_object_put(jobj);
    return 0;
}

int handle_delete_todo(int client_fd, const char *uri, const char *req_body, const char *headers) {
    int user_id;
    if (!authenticate_request(headers, &user_id)) {
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Authentication required\"}");
        return 0;
    }
    
    int requested_todo_id = parse_todo_id_from_uri(uri);
    if (requested_todo_id <= 0) {
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Todo not found\"}");
        return 0;
    }
    
    int todo_idx = find_todo_by_id_and_user(requested_todo_id, user_id);
    if (todo_idx == -1) {
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Todo not found\"}");
        return 0;
    }
    
    // Mark as inactive instead of truly deleting to maintain array integrity
    todos[todo_idx].active = 0;
    
    dprintf(client_fd, "HTTP/1.1 204 No Content\r\n\r\n");
    
    return 0;
}

// Main request handler
void handle_request(int client_fd, const char *method, const char *uri, const char *headers, const char *body) {
    if (strcmp(method, "POST") == 0 && strcmp(uri, "/register") == 0) {
        handle_register(client_fd, body, headers);
    } 
    else if (strcmp(method, "POST") == 0 && strcmp(uri, "/login") == 0) {
        handle_login(client_fd, body, headers);
    }
    else if (strcmp(method, "POST") == 0 && strcmp(uri, "/logout") == 0) {
        handle_logout(client_fd, body, headers);
    }
    else if (strcmp(method, "GET") == 0 && strcmp(uri, "/me") == 0) {
        handle_me(client_fd, body, headers);
    }
    else if (strcmp(method, "PUT") == 0 && strcmp(uri, "/password") == 0) {
        handle_change_password(client_fd, body, headers);
    }
    else if (strcmp(method, "GET") == 0 && strcmp(uri, "/todos") == 0) {
        handle_get_todos(client_fd, body, headers);
    }
    else if (strcmp(method, "POST") == 0 && strcmp(uri, "/todos") == 0) {
        handle_create_todo(client_fd, body, headers);
    }
    else if (strcmp(method, "GET") == 0 && strncmp(uri, "/todos/", 7) == 0) {
        handle_get_todo(client_fd, uri, body, headers);
    }
    else if (strcmp(method, "PUT") == 0 && strncmp(uri, "/todos/", 7) == 0) {
        handle_update_todo(client_fd, uri, body, headers);
    }
    else if (strcmp(method, "DELETE") == 0 && strncmp(uri, "/todos/", 7) == 0) {
        handle_delete_todo(client_fd, uri, body, headers);
    }
    else {
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Endpoint not found\"}");
    }
}

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
            i++;
        }
    }
    
    // Initialize data structures
    for (int i = 0; i < MAX_USERS; i++) {
        users[i].active = 0;
    }
    for (int i = 0; i < MAX_USERS * MAX_TODOS_PER_USER; i++) {
        todos[i].active = 0;
    }
    for (int i = 0; i < MAX_SESSIONS; i++) {
        sessions[i].active = 0;
    }
    
    struct sockaddr_in server_addr, client_addr;
    socklen_t client_len = sizeof(client_addr);
    char buffer[BUFFER_SIZE];
    int server_fd, client_fd;
    
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }
    
    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        exit(EXIT_FAILURE);
    }
    
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(port);
    
    if (bind(server_fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }
    
    if (listen(server_fd, 10) < 0) {
        perror("listen failed");
        exit(EXIT_FAILURE);
    }
    
    printf("Server running on port %d\n", port);
    
    while (1) {
        client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_fd < 0) {
            perror("accept failed");
            continue;
        }
        
        int bytes_read = recv(client_fd, buffer, BUFFER_SIZE - 1, 0);
        if (bytes_read <= 0) {
            close(client_fd);
            continue;
        }
        buffer[bytes_read] = '\0';
        
        // Parse HTTP request: Method URI HTTP-Version followed by optional headers and body
        char method[16], uri[512], http_version[16];
        if (sscanf(buffer, "%15s %511s %15s", method, uri, http_version) != 3) {
            dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid HTTP request\"}");
            close(client_fd);
            continue;
        }
        
        // Find start of headers - right after the first \r\n
        char *headers_start = strstr(buffer, "\r\n");
        if (!headers_start) {
            dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\": \"Invalid HTTP headers\"}");
            close(client_fd);
            continue;
        }
        headers_start += 2;  // Skip \r\n to point to header content
        
        // Check if we can find the end of headers (\r\n\r\n) to determine the request body
        char *end_of_headers = strstr(headers_start, "\r\n\r\n");
        if (end_of_headers) {
            *end_of_headers = '\0';  // Temporarily null-terminate headers
            char *req_body = end_of_headers + 4; // Point to actual body
            handle_request(client_fd, method, uri, headers_start, req_body);
        } else {
            // No body found - all content after request line are headers
            handle_request(client_fd, method, uri, headers_start, "");
        }
        
        close(client_fd);
    }
    
    close(server_fd);
    return 0;
}
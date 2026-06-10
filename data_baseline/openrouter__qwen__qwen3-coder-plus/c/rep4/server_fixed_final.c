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
#include <regex.h>
#include <uuid/uuid.h>
#include <json-c/json.h>

#define MAX_USERS 1000
#define MAX_TODOS 10000
#define MAX_SESSIONS 1000
#define MIN_PASSWORD_LENGTH 8
#define USERNAME_MIN_LENGTH 3
#define USERNAME_MAX_LENGTH 50

// Forward declarations
typedef struct TodoItem TodoItem;
typedef struct User User;
typedef struct Session Session;

struct TodoItem {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed;
    char created_at[21];  // YYYY-MM-DDTHH:MM:SSZ
    char updated_at[21];  // YYYY-MM-DDTHH:MM:SSZ
};

struct User {
    int id;
    char *username;
    char *password_hash;  // For practical purposes we'll store plaintext
};

struct Session {
    char session_token[37];  // UUID string length
    int user_id;
    int valid;
};

// Global storage
User users[MAX_USERS];
int user_count = 0;
int next_user_id = 1;

TodoItem todos[MAX_TODOS];
int todo_count = 0;
int next_todo_id = 1;

Session sessions[MAX_SESSIONS];
int session_count = 0;

// Helper functions
char* get_timestamp() {
    static char buffer[21];
    time_t now = time(0);
    struct tm *gmt_time = gmtime(&now);
    strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", gmt_time);
    return buffer;
}

int validate_username(const char *username) {
    if (!username) return 0;
    
    size_t len = strlen(username);
    if (len < USERNAME_MIN_LENGTH || len > USERNAME_MAX_LENGTH) return 0;
    
    for (size_t i = 0; i < len; i++) {
        char c = username[i];
        if (!((c >= 'a' && c <= 'z') || 
              (c >= 'A' && c <= 'Z') || 
              (c >= '0' && c <= '9') || 
              c == '_')) {
            return 0;
        }
    }
    return 1;
}

int find_user_by_username(const char *username) {
    for (int i = 0; i < user_count; i++) {
        if (users[i].username && strcmp(users[i].username, username) == 0) {
            return i;
        }
    }
    return -1;
}

int find_session_by_token(const char *token) {
    if (!token) return -1;
    for (int i = 0; i < session_count; i++) {
        if (sessions[i].valid == 1 && strcmp(sessions[i].session_token, token) == 0) {
            return i;
        }
    }
    return -1;
}

char* extract_cookie_value(const char *header, const char *cookie_name) {
    if (!header || !cookie_name) return NULL;
    
    char search_str[100];
    snprintf(search_str, sizeof(search_str), "%s=", cookie_name);
    
    char *pos = strstr((char*)header, search_str);
    if (!pos) {
        return NULL;
    }
    
    pos += strlen(search_str); // Move past cookie name and =
    
    // Find end of value
    char *end = pos;
    while (*end && *end != ';' && *end != '\r' && *end != '\n') {
        end++;
    }
    
    int len = end - pos;
    if (len <= 0) return NULL;
    
    char *result = malloc(len + 1);
    if (result) {
        strncpy(result, pos, len);
        result[len] = '\0';
    }
    return result;
}

char* create_json_error_response(const char *error_msg) {
    json_object *jobj = json_object_new_object();
    json_object_object_add(jobj, "error", json_object_new_string(error_msg));
    const char *json_str = json_object_to_json_string(jobj);
    
    char *result = strdup(json_str);
    json_object_put(jobj);
    return result;
}

// Handler functions
void handle_register(int client_fd, const char *request_body) {
    if (!request_body) {
        char *error = create_json_error_response("Missing request body");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *jobj = json_tokener_parse(request_body);
    if (!jobj) {
        char *error = create_json_error_response("Invalid JSON");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *username_obj, *password_obj;
    
    if (!json_object_object_get_ex(jobj, "username", &username_obj) || !json_object_is_type(username_obj, json_type_string)) {
        json_object_put(jobj);
        char *error = create_json_error_response("Invalid username");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    if (!json_object_object_get_ex(jobj, "password", &password_obj) || !json_object_is_type(password_obj, json_type_string)) {
        json_object_put(jobj);
        char *error = create_json_error_response("Password too short");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    const char *username = json_object_get_string(username_obj);
    const char *password = json_object_get_string(password_obj);
    
    if (!validate_username(username)) {
        json_object_put(jobj);
        char *error = create_json_error_response("Invalid username");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    if (strlen(password) < MIN_PASSWORD_LENGTH) {
        json_object_put(jobj);
        char *error = create_json_error_response("Password too short");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    // Check if username already exists
    if (find_user_by_username(username) != -1) {
        json_object_put(jobj);
        char *error = create_json_error_response("Username already exists");
        dprintf(client_fd, "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    // Create new user
    if (user_count >= MAX_USERS) {
        json_object_put(jobj);
        char *error = create_json_error_response("Too many users");
        dprintf(client_fd, "HTTP/1.1 507 Insufficient Storage\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    User *user = &users[user_count];
    user->id = next_user_id++;
    user->username = strdup(username);
    user->password_hash = strdup(password);  // In real app this would be hashed
    
    user_count++;
    json_object_put(jobj);
    
    // Create response
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(user->id));
    json_object_object_add(response, "username", json_object_new_string(user->username));
    const char *response_str = json_object_to_json_string(response);
    
    dprintf(client_fd, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
            strlen(response_str), response_str);
    json_object_put(response);
}

void handle_login(int client_fd, const char *request_body) {
    if (!request_body) {
        char *error = create_json_error_response("Missing request body");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *jobj = json_tokener_parse(request_body);
    if (!jobj) {
        char *error = create_json_error_response("Invalid JSON");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *username_obj, *password_obj;
    
    if (!json_object_object_get_ex(jobj, "username", &username_obj) ||
        !json_object_object_get_ex(jobj, "password", &password_obj) ||
        !json_object_is_type(username_obj, json_type_string) ||
        !json_object_is_type(password_obj, json_type_string)) {
        json_object_put(jobj);
        char *error = create_json_error_response("Missing credentials");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    const char *username = json_object_get_string(username_obj);
    const char *password = json_object_get_string(password_obj);
    
    int user_idx = find_user_by_username(username);
    if (user_idx == -1 || strcmp(users[user_idx].password_hash, password) != 0) {
        json_object_put(jobj);
        char *error = create_json_error_response("Invalid credentials");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    // Generate session token
    uuid_t session_uuid;
    uuid_generate(session_uuid);
    char session_token[37];
    uuid_unparse_lower(session_uuid, session_token);
    
    if (session_count >= MAX_SESSIONS) {
        json_object_put(jobj);
        char *error = create_json_error_response("Too many sessions");
        dprintf(client_fd, "HTTP/1.1 507 Insufficient Storage\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    Session *session = &sessions[session_count];
    strcpy(session->session_token, session_token);
    session->user_id = users[user_idx].id;
    session->valid = 1;
    session_count++;
    
    json_object_put(jobj);
    
    // Create response
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(users[user_idx].id));
    json_object_object_add(response, "username", json_object_new_string(users[user_idx].username));
    const char *response_str = json_object_to_json_string(response);
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nSet-Cookie: session_id=%s; Path=/; HttpOnly\r\n\r\n%s", 
            strlen(response_str), session_token, response_str);
    json_object_put(response);
}

void invalidate_session(const char *session_token) {
    if (!session_token) return;
    for (int i = 0; i < session_count; i++) {
        if (sessions[i].valid == 1 && strcmp(sessions[i].session_token, session_token) == 0) {
            sessions[i].valid = 0;
            return;
        }
    }
}

void handle_logout(int client_fd, const char *session_token) {
    if (!session_token) {
        char *error = create_json_error_response("Authentication required");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    invalidate_session(session_token);
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
}

int get_user_from_session(const char *session_token) {
    int session_idx = find_session_by_token(session_token);
    if (session_idx != -1) {
        int user_id = sessions[session_idx].user_id;
        for (int i = 0; i < user_count; i++) {
            if (users[i].id == user_id) {
                return i;  // Return user index
            }
        }
    }
    return -1;
}

void handle_me(int client_fd, const char *session_token) {
    int user_idx = get_user_from_session(session_token);
    if (user_idx == -1) {
        char *error = create_json_error_response("Authentication required");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(users[user_idx].id));
    json_object_object_add(response, "username", json_object_new_string(users[user_idx].username));
    const char *response_str = json_object_to_json_string(response);
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
            strlen(response_str), response_str);
    json_object_put(response);
}

void handle_change_password(int client_fd, const char *session_token, const char *request_body) {
    int user_idx = get_user_from_session(session_token);
    if (user_idx == -1) {
        char *error = create_json_error_response("Authentication required");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *jobj = json_tokener_parse(request_body);
    if (!jobj) {
        char *error = create_json_error_response("Invalid JSON");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *old_password_obj, *new_password_obj;
    
    if (!json_object_object_get_ex(jobj, "old_password", &old_password_obj) ||
        !json_object_object_get_ex(jobj, "new_password", &new_password_obj) ||
        !json_object_is_type(old_password_obj, json_type_string) ||
        !json_object_is_type(new_password_obj, json_type_string)) {
        json_object_put(jobj);
        char *error = create_json_error_response("Missing password parameters");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    const char *old_password = json_object_get_string(old_password_obj);
    const char *new_password = json_object_get_string(new_password_obj);
    
    if (strcmp(users[user_idx].password_hash, old_password) != 0) {
        json_object_put(jobj);
        char *error = create_json_error_response("Invalid credentials");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    if (strlen(new_password) < MIN_PASSWORD_LENGTH) {
        json_object_put(jobj);
        char *error = create_json_error_response("Password too short");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    free(users[user_idx].password_hash);
    users[user_idx].password_hash = strdup(new_password);
    json_object_put(jobj);
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
}

TodoItem* get_todo_by_id(int todo_id) {
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id) {
            return &todos[i];
        }
    }
    return NULL;
}

int find_todo_index(int todo_id) {
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == todo_id) {
            return i;
        }
    }
    return -1;
}

void handle_get_todos(int client_fd, const char *session_token) {
    int user_idx = get_user_from_session(session_token);
    if (user_idx == -1) {
        char *error = create_json_error_response("Authentication required");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *response = json_object_new_array();
    
    // Only include todos belonging to the current user
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].user_id == users[user_idx].id) {
            json_object *todo_obj = json_object_new_object();
            json_object_object_add(todo_obj, "id", json_object_new_int(todos[i].id));
            json_object_object_add(todo_obj, "title", json_object_new_string(todos[i].title));
            json_object_object_add(todo_obj, "description", json_object_new_string(todos[i].description ? todos[i].description : ""));
            json_object_object_add(todo_obj, "completed", json_object_new_boolean(todos[i].completed));
            json_object_object_add(todo_obj, "created_at", json_object_new_string(todos[i].created_at));
            json_object_object_add(todo_obj, "updated_at", json_object_new_string(todos[i].updated_at));
            
            json_object_array_add(response, todo_obj);
        }
    }
    
    const char *response_str = json_object_to_json_string(response);
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
            strlen(response_str), response_str);
    json_object_put(response);
}

void handle_create_todo(int client_fd, const char *session_token, const char *request_body) {
    int user_idx = get_user_from_session(session_token);
    if (user_idx == -1) {
        char *error = create_json_error_response("Authentication required");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *jobj = json_tokener_parse(request_body);
    if (!jobj) {
        char *error = create_json_error_response("Invalid JSON");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *title_obj, *desc_obj;
    
    if (!json_object_object_get_ex(jobj, "title", &title_obj) || 
        !json_object_is_type(title_obj, json_type_string) || 
        strlen(json_object_get_string(title_obj)) == 0) {
        json_object_put(jobj);
        char *error = create_json_error_response("Title is required");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    const char *title = json_object_get_string(title_obj);
    const char *description = "";
    
    if (json_object_object_get_ex(jobj, "description", &desc_obj) && 
        json_object_is_type(desc_obj, json_type_string)) {
        description = json_object_get_string(desc_obj);
    }
    
    // Create new todo
    if (todo_count >= MAX_TODOS) {
        json_object_put(jobj);
        char *error = create_json_error_response("Too many todos");
        dprintf(client_fd, "HTTP/1.1 507 Insufficient Storage\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    TodoItem *new_todo = &todos[todo_count];
    new_todo->id = next_todo_id++;
    new_todo->user_id = users[user_idx].id;
    new_todo->title = strdup(title);
    new_todo->description = strdup(description ? description : "");
    new_todo->completed = 0;  // defaults to false
    
    char *timestamp = get_timestamp();
    strcpy(new_todo->created_at, timestamp);
    strcpy(new_todo->updated_at, timestamp);
    
    todo_count++;
    json_object_put(jobj);
    
    // Create response
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(new_todo->id));
    json_object_object_add(response, "title", json_object_new_string(new_todo->title));
    json_object_object_add(response, "description", json_object_new_string(new_todo->description));
    json_object_object_add(response, "completed", json_object_new_boolean(new_todo->completed));
    json_object_object_add(response, "created_at", json_object_new_string(new_todo->created_at));
    json_object_object_add(response, "updated_at", json_object_new_string(new_todo->updated_at));
    const char *response_str = json_object_to_json_string(response);
    
    dprintf(client_fd, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
            strlen(response_str), response_str);
    json_object_put(response);
}

void handle_get_todo(int client_fd, const char *session_token, int requested_todo_id) {
    int user_idx = get_user_from_session(session_token);
    if (user_idx == -1) {
        char *error = create_json_error_response("Authentication required");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    // Check if todo exists and belongs to user
    TodoItem *target_todo = NULL;
    for (int i = 0; i < todo_count; i++) {
        if (todos[i].id == requested_todo_id && todos[i].user_id == users[user_idx].id) {
            target_todo = &todos[i];
            break;
        }
    }
    
    if (!target_todo) {
        char *error = create_json_error_response("Todo not found");
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    // Create response
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(target_todo->id));
    json_object_object_add(response, "title", json_object_new_string(target_todo->title));
    json_object_object_add(response, "description", json_object_new_string(target_todo->description ? target_todo->description : ""));
    json_object_object_add(response, "completed", json_object_new_boolean(target_todo->completed));
    json_object_object_add(response, "created_at", json_object_new_string(target_todo->created_at));
    json_object_object_add(response, "updated_at", json_object_new_string(target_todo->updated_at));
    const char *response_str = json_object_to_json_string(response);
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
            strlen(response_str), response_str);
    json_object_put(response);
}

void handle_update_todo(int client_fd, const char *session_token, int requested_todo_id, const char *request_body) {
    int user_idx = get_user_from_session(session_token);
    if (user_idx == -1) {
        char *error = create_json_error_response("Authentication required");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    int todo_idx = find_todo_index(requested_todo_id);
    if (todo_idx == -1 || todos[todo_idx].user_id != users[user_idx].id) {
        char *error = create_json_error_response("Todo not found");
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    json_object *jobj = json_tokener_parse(request_body);
    if (!jobj) {
        char *error = create_json_error_response("Invalid JSON");
        dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    TodoItem *target_todo = &todos[todo_idx];
    
    json_object *title_obj, *desc_obj, *comp_obj;
    
    // Handle title update if provided
    if (json_object_object_get_ex(jobj, "title", &title_obj) && json_object_is_type(title_obj, json_type_string)) {
        const char *new_title = json_object_get_string(title_obj);
        if (strlen(new_title) == 0) {
            json_object_put(jobj);
            char *error = create_json_error_response("Title is required");
            dprintf(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                    strlen(error), error);
            free(error);
            return;
        }
        free(target_todo->title);
        target_todo->title = strdup(new_title);
    }
    
    // Handle description update if provided
    if (json_object_object_get_ex(jobj, "description", &desc_obj) && json_object_is_type(desc_obj, json_type_string)) {
        free(target_todo->description);
        target_todo->description = strdup(json_object_get_string(desc_obj));
    }
    
    // Handle completed update if provided
    if (json_object_object_get_ex(jobj, "completed", &comp_obj) && json_object_is_type(comp_obj, json_type_boolean)) {
        target_todo->completed = json_object_get_boolean(comp_obj);
    }
    
    // Update the updated_at timestamp
    char *timestamp = get_timestamp();
    strcpy(target_todo->updated_at, timestamp);
    
    json_object_put(jobj);
    
    // Create response
    json_object *response = json_object_new_object();
    json_object_object_add(response, "id", json_object_new_int(target_todo->id));
    json_object_object_add(response, "title", json_object_new_string(target_todo->title));
    json_object_object_add(response, "description", json_object_new_string(target_todo->description ? target_todo->description : ""));
    json_object_object_add(response, "completed", json_object_new_boolean(target_todo->completed));
    json_object_object_add(response, "created_at", json_object_new_string(target_todo->created_at));
    json_object_object_add(response, "updated_at", json_object_new_string(target_todo->updated_at));
    const char *response_str = json_object_to_json_string(response);
    
    dprintf(client_fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
            strlen(response_str), response_str);
    json_object_put(response);
}

void handle_delete_todo(int client_fd, const char *session_token, int requested_todo_id) {
    int user_idx = get_user_from_session(session_token);
    if (user_idx == -1) {
        char *error = create_json_error_response("Authentication required");
        dprintf(client_fd, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    int todo_idx = find_todo_index(requested_todo_id);
    if (todo_idx == -1 || todos[todo_idx].user_id != users[user_idx].id) {
        char *error = create_json_error_response("Todo not found");
        dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
        return;
    }
    
    // Free memory associated with this todo
    free(todos[todo_idx].title);
    free(todos[todo_idx].description);
    
    // Remove the item by shifting remaining items
    for (int i = todo_idx; i < todo_count - 1; i++) {
        todos[i] = todos[i + 1];
    }
    
    todo_count--;
    
    dprintf(client_fd, "HTTP/1.1 204 No Content\r\n\r\n");
}

void process_request(int client_fd, char *request_buffer) {
    // Safety check: don't process empty buffer or malformed input
    if (!request_buffer || strlen(request_buffer) < 10) {
        return;
    }
    
    char *original_request = strdup(request_buffer);
    if (!original_request) {
        return;
    }
    
    char *method_line = strtok(original_request, "\r\n");
    if (!method_line) {
        free(original_request);
        return;
    }
    
    char method[16] = {0}, path[512] = {0}, protocol[16] = {0};
    if (sscanf(method_line, "%15s %511s %15s", method, path, protocol) != 3) {
        free(original_request);
        return;
    }
    
    // Find the boundary between headers and body
    char *headers_and_body = strdup(request_buffer);
    if (!headers_and_body) {
        free(original_request);
        return;        
    }
    
    char *boundary = strstr(headers_and_body, "\r\n\r\n");
    char *request_body = (boundary) ? boundary + 4 : "";

    // Parse headers to get cookies
    char header_section_buf[4096];
    int headers_len = boundary ? (boundary - headers_and_body) : strlen(headers_and_body);
    if (headers_len >= sizeof(header_section_buf)) {
        headers_len = sizeof(header_section_buf) - 1;
    }
    strncpy(header_section_buf, headers_and_body, headers_len);
    header_section_buf[headers_len] = '\0';
    
    char *session_token = NULL;
    char *saveptr;
    char *header_line = strtok_r(header_section_buf, "\r\n", &saveptr);
    
    // Process first line - if it contains protocol, skip it (it's the request line)
    if (strstr(header_line, "HTTP/") != NULL) { 
        header_line = strtok_r(NULL, "\r\n", &saveptr);
    }
    
    while (header_line) {
        if (strncasecmp(header_line, "Cookie:", 7) == 0) {
            char *value_start = header_line + 7;
            while (*value_start == ' ') value_start++;
            session_token = extract_cookie_value(value_start, "session_id");
            break;
        }
        header_line = strtok_r(NULL, "\r\n", &saveptr);
    }
    
    // Route the request based on method and path
    char full_path[512];
    strcpy(full_path, path);
    
    if (strcmp(method, "POST") == 0 && strcmp(full_path, "/register") == 0) {
        handle_register(client_fd, request_body);
    } else if (strcmp(method, "POST") == 0 && strcmp(full_path, "/login") == 0) {
        handle_login(client_fd, request_body);
    } else if (strcmp(method, "POST") == 0 && strcmp(full_path, "/logout") == 0) {
        handle_logout(client_fd, session_token);
    } else if (strcmp(method, "GET") == 0 && strcmp(full_path, "/me") == 0) {
        handle_me(client_fd, session_token);
    } else if (strcmp(method, "PUT") == 0 && strcmp(full_path, "/password") == 0) {
        handle_change_password(client_fd, session_token, request_body);
    } else if (strcmp(method, "GET") == 0 && strcmp(full_path, "/todos") == 0) {
        handle_get_todos(client_fd, session_token);
    } else if (strcmp(method, "POST") == 0 && strcmp(full_path, "/todos") == 0) {
        handle_create_todo(client_fd, session_token, request_body);
    } else if (strcmp(method, "GET") == 0) {
        // Handle /todos/id paths
        if (strncmp(full_path, "/todos/", 7) == 0 && strlen(full_path) > 7) {
            int requested_todo_id;
            int n = 0;
            if (sscanf(full_path + 7, "%d%n", &requested_todo_id, &n) == 1 && full_path[7+n] == '\0') {
                handle_get_todo(client_fd, session_token, requested_todo_id);
            } else {
                char *error = create_json_error_response("Not found");
                dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                        strlen(error), error);
                free(error);
            }
        } else {
            char *error = create_json_error_response("Not found");
            dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                    strlen(error), error);
            free(error);
        }
    } else if (strcmp(method, "PUT") == 0) {
        // Handle /todos/id paths for updates
        if (strncmp(full_path, "/todos/", 7) == 0 && strlen(full_path) > 7) {
            int requested_todo_id;
            int n = 0;
            if (sscanf(full_path + 7, "%d%n", &requested_todo_id, &n) == 1 && full_path[7+n] == '\0') {
                handle_update_todo(client_fd, session_token, requested_todo_id, request_body);
            } else {
                char *error = create_json_error_response("Not found");
                dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                        strlen(error), error);
                free(error);
            }
        } else {
            char *error = create_json_error_response("Not found");
            dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                    strlen(error), error);
            free(error);
        }
    } else if (strcmp(method, "DELETE") == 0) {
        // Handle /todos/id paths for deletion
        if (strncmp(full_path, "/todos/", 7) == 0 && strlen(full_path) > 7) {
            int requested_todo_id;
            int n = 0;
            if (sscanf(full_path + 7, "%d%n", &requested_todo_id, &n) == 1 && full_path[7+n] == '\0') {
                handle_delete_todo(client_fd, session_token, requested_todo_id);
            } else {
                char *error = create_json_error_response("Not found");
                dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                        strlen(error), error);
                free(error);
            }
        } else {
            char *error = create_json_error_response("Not found");
            dprintf(client_fd, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                    strlen(error), error);
            free(error);
        }
    } else {
        char *error = create_json_error_response("Method not allowed");
        dprintf(client_fd, "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, POST, PUT, DELETE\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", 
                strlen(error), error);
        free(error);
    }
    
    // Cleanup
    if (session_token) free(session_token);
    free(original_request);
    free(headers_and_body);
}

void setup_server(int port) {
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
        perror("setsockopt failed");
        exit(EXIT_FAILURE);
    }
    
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);
    
    // Bind the socket to the port
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }
    
    // Listen for incoming connections
    if (listen(server_fd, 10) < 0) {
        perror("listen failed");
        exit(EXIT_FAILURE);
    }
    
    printf("Server listening on port %d\n", port);
    printf("API endpoints available:\n");
    printf("- POST /register (register new user)\n");
    printf("- POST /login (login and get session cookie)\n");
    printf("- POST /logout (end current session)\n");
    printf("- GET /me (get current user info)\n");
    printf("- PUT /password (change password)\n");
    printf("- GET /todos (get todos for logged in user)\n");
    printf("- POST /todos (create new todo)\n");
    printf("- GET /todos/:id (get specific todo)\n");
    printf("- PUT /todos/:id (update todo)\n");
    printf("- DELETE /todos/:id (delete todo)\n");
    
    while (1) {
        int client_fd = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen);
        if (client_fd < 0) {
            perror("accept failed");
            continue;
        }
        
        // Read the request 
        char request_buffer[8192] = {0};
        int bytes_read = read(client_fd, request_buffer, sizeof(request_buffer) - 1); 
        
        if (bytes_read > 0) {
            request_buffer[bytes_read] = '\0';
            process_request(client_fd, request_buffer);
        } else if (bytes_read < 0) {
            perror("read failed");
        }
        
        close(client_fd);
    }
    
    close(server_fd);
}

int main(int argc, char *argv[]) {
    int port = 8080;  // Default port
    
    // Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
            i++;  // Skip the port value
        }
    }
    
    setup_server(port);
    
    return 0;
}
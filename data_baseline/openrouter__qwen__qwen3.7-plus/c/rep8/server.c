#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <ctype.h>
#include <errno.h>

#define MAX_USERS 1000
#define MAX_TODOS 10000
#define MAX_SESSIONS 1000
#define MAX_CONN 100
#define BUF_SIZE 65536

typedef struct {
    int id;
    char username[64];
    char password[256];
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
    char token[64];
    int user_id;
    int active;
} Session;

User users[MAX_USERS];
int user_count = 0;
int next_user_id = 1;

Todo todos[MAX_TODOS];
int todo_count = 0;
int next_todo_id = 1;

Session sessions[MAX_SESSIONS];

typedef struct {
    int fd;
    char buf[BUF_SIZE];
    size_t len;
    size_t head;
} Client;

Client clients[MAX_CONN];

void get_current_time(char *buf, size_t size) {
    time_t t = time(NULL);
    struct tm *tm = gmtime(&t);
    strftime(buf, size, "%Y-%m-%dT%H:%M:%SZ", tm);
}

void generate_token(char *buf, size_t size) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        unsigned char bytes[32];
        if (read(fd, bytes, sizeof(bytes)) == sizeof(bytes)) {
            for (size_t i = 0; i < 32 && (i * 2 + 2) < size; i++) {
                snprintf(buf + (i * 2), 3, "%02x", bytes[i]);
            }
            close(fd);
            return;
        }
        close(fd);
    }
    srand(time(NULL) ^ getpid());
    for (size_t i = 0; i < 32 && (i * 2 + 2) < size; i++) {
        snprintf(buf + (i * 2), 3, "%02x", rand() % 256);
    }
}

int is_valid_username(const char *username) {
    int len = strlen(username);
    if (len < 3 || len > 50) return 0;
    for (int i = 0; i < len; i++) {
        char ch = username[i];
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_')) {
            return 0;
        }
    }
    return 1;
}

void escape_json_string(const char *src, char *dst, size_t dst_size) {
    size_t j = 0;
    for (size_t i = 0; src[i] != '\0' && j < dst_size - 1; i++) {
        if (src[i] == '"' || src[i] == '\\') {
            if (j + 2 >= dst_size) break;
            dst[j++] = '\\';
            dst[j++] = src[i];
        } else if (src[i] == '\n') {
            if (j + 2 >= dst_size) break;
            dst[j++] = '\\';
            dst[j++] = 'n';
        } else if (src[i] == '\r') {
            if (j + 2 >= dst_size) break;
            dst[j++] = '\\';
            dst[j++] = 'r';
        } else if (src[i] == '\t') {
            if (j + 2 >= dst_size) break;
            dst[j++] = '\\';
            dst[j++] = 't';
        } else {
            dst[j++] = src[i];
        }
    }
    dst[j] = '\0';
}

// Simple JSON string extractor
// Expects "key":"value" or "key": "value"
int get_json_str(const char *json, const char *key, char *out, size_t out_size) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return 0;
    p += strlen(search);
    while (*p == ' ' || *p == ':' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (*p != '"') return 0;
    p++;
    size_t i = 0;
    while (*p != '\0' && *p != '"') {
        if (*p == '\\' && *(p+1) != '\0') {
            p++;
            if (*p == 'n') out[i++] = '\n';
            else if (*p == 'r') out[i++] = '\r';
            else if (*p == 't') out[i++] = '\t';
            else out[i++] = *p;
        } else {
            if (i < out_size - 1) out[i++] = *p;
        }
        p++;
    }
    out[i] = '\0';
    return 1;
}

int get_json_bool(const char *json, const char *key, int *out) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return 0;
    p += strlen(search);
    while (*p == ' ' || *p == ':' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (strncmp(p, "true", 4) == 0) {
        *out = 1;
        return 1;
    }
    if (strncmp(p, "false", 5) == 0) {
        *out = 0;
        return 1;
    }
    return 0;
}

int has_json_key(const char *json, const char *key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    return strstr(json, search) != NULL;
}

int get_session_user(const char *cookie_hdr) {
    if (!cookie_hdr) return -1;
    const char *p = strstr(cookie_hdr, "session_id=");
    if (!p) return -1;
    p += 11;
    char token[64] = {0};
    int i = 0;
    while (*p && *p != ';' && *p != ' ' && *p != '\r' && *p != '\n' && i < 63) {
        token[i++] = *p++;
    }
    token[i] = '\0';
    
    for (int j = 0; j < MAX_SESSIONS; j++) {
        if (sessions[j].active && strcmp(sessions[j].token, token) == 0) {
            return sessions[j].user_id;
        }
    }
    return -1;
}

void send_response(int fd, int status, const char *status_text, const char *extra_headers, const char *body) {
    char headers[1024];
    int hlen = snprintf(headers, sizeof(headers), 
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n", status, status_text, body ? strlen(body) : 0);
    
    if (extra_headers) {
        hlen += snprintf(headers + hlen, sizeof(headers) - hlen, "%s", extra_headers);
    }
    
    if (hlen >= (int)sizeof(headers)) hlen = sizeof(headers) - 1;
    strcpy(headers + hlen, "\r\n");
    
    write(fd, headers, strlen(headers));
    if (body && strlen(body) > 0) {
        write(fd, body, strlen(body));
    }
}

void send_no_body(int fd, int status, const char *status_text, const char *extra_headers) {
    char headers[1024];
    int hlen = snprintf(headers, sizeof(headers), 
        "HTTP/1.1 %d %s\r\n"
        "Content-Length: 0\r\n", status, status_text);
    
    if (extra_headers) {
        hlen += snprintf(headers + hlen, sizeof(headers) - hlen, "%s", extra_headers);
    }
    
    if (hlen >= (int)sizeof(headers)) hlen = sizeof(headers) - 1;
    strcpy(headers + hlen, "\r\n");
    write(fd, headers, strlen(headers));
}

// Case-insensitive substring search
char* my_strcasestr(const char *haystack, const char *needle) {
    if (!*needle) return (char*)haystack;
    for (; *haystack; ++haystack) {
        if (tolower((unsigned char)*haystack) == tolower((unsigned char)*needle)) {
            const char *h = haystack, *n = needle;
            while (*h && *n && tolower((unsigned char)*h) == tolower((unsigned char)*n)) {
                ++h; ++n;
            }
            if (!*n) return (char*)haystack;
        }
    }
    return NULL;
}

void handle_client(int fd, const char *request, size_t req_len) {
    (void)req_len;
    char method[16], uri[512];
    int parsed = sscanf(request, "%15s %511s", method, uri);
    if (parsed < 2) {
        send_response(fd, 400, "Bad Request", NULL, "{\"error\":\"Bad Request\"}");
        return;
    }
    
    const char *body_start = strstr(request, "\r\n\r\n");
    const char *body = body_start ? body_start + 4 : "";
    
    const char *cookie_hdr = NULL;
    const char *cl_start = my_strcasestr(request, "\r\nCookie:");
    if (cl_start) {
        cl_start += 9;
        static char cookie_buf[1024];
        size_t i = 0;
        int j = 0;
        while (cl_start[i] && cl_start[i] != '\r' && cl_start[i] != '\n' && i < sizeof(cookie_buf) - 1) {
            if (cl_start[i] != ' ' && cl_start[i] != '\t') {
                cookie_buf[j++] = cl_start[i];
            }
            i++;
        }
        cookie_buf[j] = '\0';
        cookie_hdr = cookie_buf;
    }
    
    if (strcmp(method, "POST") == 0 && strcmp(uri, "/register") == 0) {
        char username[64] = {0};
        char password[256] = {0};
        
        if (!get_json_str(body, "username", username, sizeof(username)) || !get_json_str(body, "password", password, sizeof(password))) {
            send_response(fd, 400, "Bad Request", NULL, "{\"error\":\"Invalid username\"}");
            return;
        }
        
        if (!is_valid_username(username)) {
            send_response(fd, 400, "Bad Request", NULL, "{\"error\":\"Invalid username\"}");
            return;
        }
        
        if (strlen(password) < 8) {
            send_response(fd, 400, "Bad Request", NULL, "{\"error\":\"Password too short\"}");
            return;
        }
        
        for (int i = 0; i < user_count; i++) {
            if (strcmp(users[i].username, username) == 0) {
                send_response(fd, 409, "Conflict", NULL, "{\"error\":\"Username already exists\"}");
                return;
            }
        }
        
        if (user_count >= MAX_USERS) {
            send_response(fd, 500, "Internal Server Error", NULL, "{\"error\":\"Server error\"}");
            return;
        }
        
        users[user_count].id = next_user_id++;
        strncpy(users[user_count].username, username, sizeof(users[user_count].username) - 1);
        strncpy(users[user_count].password, password, sizeof(users[user_count].password) - 1);
        user_count++;
        
        char resp[256];
        snprintf(resp, sizeof(resp), "{\"id\":%d,\"username\":\"%s\"}", users[user_count-1].id, users[user_count-1].username);
        send_response(fd, 201, "Created", NULL, resp);
        return;
    }
    
    if (strcmp(method, "POST") == 0 && strcmp(uri, "/login") == 0) {
        char username[64] = {0};
        char password[256] = {0};
        get_json_str(body, "username", username, sizeof(username));
        get_json_str(body, "password", password, sizeof(password));
        
        int user_id = -1;
        char uname[64] = {0};
        for (int i = 0; i < user_count; i++) {
            if (strcmp(users[i].username, username) == 0 && strcmp(users[i].password, password) == 0) {
                user_id = users[i].id;
                strncpy(uname, users[i].username, sizeof(uname) - 1);
                break;
            }
        }
        
        if (user_id == -1) {
            send_response(fd, 401, "Unauthorized", NULL, "{\"error\":\"Invalid credentials\"}");
            return;
        }
        
        char token[64] = {0};
        generate_token(token, sizeof(token));
        
        int slot = -1;
        for (int i = 0; i < MAX_SESSIONS; i++) {
            if (!sessions[i].active) {
                slot = i;
                break;
            }
        }
        if (slot == -1) {
            send_response(fd, 500, "Internal Server Error", NULL, "{\"error\":\"Server error\"}");
            return;
        }
        
        strcpy(sessions[slot].token, token);
        sessions[slot].user_id = user_id;
        sessions[slot].active = 1;
        
        char extra[256];
        snprintf(extra, sizeof(extra), "Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", token);
        char resp[256];
        snprintf(resp, sizeof(resp), "{\"id\":%d,\"username\":\"%s\"}", user_id, uname);
        send_response(fd, 200, "OK", extra, resp);
        return;
    }
    
    if (strcmp(method, "POST") == 0 && strcmp(uri, "/logout") == 0) {
        int user_id = get_session_user(cookie_hdr);
        if (user_id == -1) {
            send_response(fd, 401, "Unauthorized", NULL, "{\"error\":\"Authentication required\"}");
            return;
        }
        
        const char *p = strstr(cookie_hdr, "session_id=");
        if (p) {
            p += 11;
            char token[64] = {0};
            int i = 0;
            while (*p && *p != ';' && *p != ' ' && *p != '\r' && *p != '\n' && i < 63) {
                token[i++] = *p++;
            }
            token[i] = '\0';
            for (int j = 0; j < MAX_SESSIONS; j++) {
                if (sessions[j].active && strcmp(sessions[j].token, token) == 0) {
                    sessions[j].active = 0;
                    break;
                }
            }
        }
        send_response(fd, 200, "OK", NULL, "{}");
        return;
    }
    
    if (strcmp(method, "GET") == 0 && strcmp(uri, "/me") == 0) {
        int user_id = get_session_user(cookie_hdr);
        if (user_id == -1) {
            send_response(fd, 401, "Unauthorized", NULL, "{\"error\":\"Authentication required\"}");
            return;
        }
        for (int i = 0; i < user_count; i++) {
            if (users[i].id == user_id) {
                char resp[256];
                snprintf(resp, sizeof(resp), "{\"id\":%d,\"username\":\"%s\"}", users[i].id, users[i].username);
                send_response(fd, 200, "OK", NULL, resp);
                return;
            }
        }
        send_response(fd, 500, "Internal Server Error", NULL, "{\"error\":\"Server error\"}");
        return;
    }
    
    if (strcmp(method, "PUT") == 0 && strcmp(uri, "/password") == 0) {
        int user_id = get_session_user(cookie_hdr);
        if (user_id == -1) {
            send_response(fd, 401, "Unauthorized", NULL, "{\"error\":\"Authentication required\"}");
            return;
        }
        
        char old_pw[256] = {0};
        char new_pw[256] = {0};
        get_json_str(body, "old_password", old_pw, sizeof(old_pw));
        get_json_str(body, "new_password", new_pw, sizeof(new_pw));
        
        int user_idx = -1;
        for (int i = 0; i < user_count; i++) {
            if (users[i].id == user_id) {
                user_idx = i;
                break;
            }
        }
        
        if (user_idx == -1 || strcmp(users[user_idx].password, old_pw) != 0) {
            send_response(fd, 401, "Unauthorized", NULL, "{\"error\":\"Invalid credentials\"}");
            return;
        }
        
        if (strlen(new_pw) < 8) {
            send_response(fd, 400, "Bad Request", NULL, "{\"error\":\"Password too short\"}");
            return;
        }
        
        strncpy(users[user_idx].password, new_pw, sizeof(users[user_idx].password) - 1);
        send_response(fd, 200, "OK", NULL, "{}");
        return;
    }
    
    if (strcmp(method, "GET") == 0 && strcmp(uri, "/todos") == 0) {
        int user_id = get_session_user(cookie_hdr);
        if (user_id == -1) {
            send_response(fd, 401, "Unauthorized", NULL, "{\"error\":\"Authentication required\"}");
            return;
        }
        
        char *body_out = malloc(32768);
        body_out[0] = '[';
        size_t pos = 1;
        int first = 1;
        for (int i = 0; i < todo_count; i++) {
            if (todos[i].user_id == user_id) {
                if (!first) body_out[pos++] = ',';
                first = 0;
                char esc_title[512], esc_desc[2048];
                escape_json_string(todos[i].title, esc_title, sizeof(esc_title));
                escape_json_string(todos[i].description, esc_desc, sizeof(esc_desc));
                
                char item[2048];
                int len = snprintf(item, sizeof(item), 
                    "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
                    todos[i].id, esc_title, esc_desc, todos[i].completed ? "true" : "false", todos[i].created_at, todos[i].updated_at);
                
                if (pos + (size_t)len < 32760) {
                    memcpy(body_out + pos, item, (size_t)len);
                    pos += (size_t)len;
                }
            }
        }
        body_out[pos++] = ']';
        body_out[pos] = '\0';
        
        send_response(fd, 200, "OK", NULL, body_out);
        free(body_out);
        return;
    }
    
    if (strcmp(method, "POST") == 0 && strcmp(uri, "/todos") == 0) {
        int user_id = get_session_user(cookie_hdr);
        if (user_id == -1) {
            send_response(fd, 401, "Unauthorized", NULL, "{\"error\":\"Authentication required\"}");
            return;
        }
        
        char title[256] = {0};
        char desc[1024] = {0};
        
        if (!get_json_str(body, "title", title, sizeof(title))) {
            send_response(fd, 400, "Bad Request", NULL, "{\"error\":\"Title is required\"}");
            return;
        }
        
        if (strlen(title) == 0) {
            send_response(fd, 400, "Bad Request", NULL, "{\"error\":\"Title is required\"}");
            return;
        }
        
        get_json_str(body, "description", desc, sizeof(desc));
        
        if (todo_count >= MAX_TODOS) {
            send_response(fd, 500, "Internal Server Error", NULL, "{\"error\":\"Server error\"}");
            return;
        }
        
        int idx = todo_count++;
        todos[idx].id = next_todo_id++;
        todos[idx].user_id = user_id;
        strncpy(todos[idx].title, title, sizeof(todos[idx].title) - 1);
        strncpy(todos[idx].description, desc, sizeof(todos[idx].description) - 1);
        todos[idx].completed = 0;
        get_current_time(todos[idx].created_at, sizeof(todos[idx].created_at));
        get_current_time(todos[idx].updated_at, sizeof(todos[idx].updated_at));
        
        char esc_title[512], esc_desc[2048];
        escape_json_string(todos[idx].title, esc_title, sizeof(esc_title));
        escape_json_string(todos[idx].description, esc_desc, sizeof(esc_desc));
        
        char resp[2048];
        snprintf(resp, sizeof(resp), 
            "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
            todos[idx].id, esc_title, esc_desc, "false", todos[idx].created_at, todos[idx].updated_at);
        
        send_response(fd, 201, "Created", NULL, resp);
        return;
    }
    
    if ((strcmp(uri, "/todos") == 0 || strncmp(uri, "/todos/", 7) == 0) && 
        (strcmp(method, "GET") == 0 || strcmp(method, "PUT") == 0 || strcmp(method, "DELETE") == 0)) {
        
        int user_id = get_session_user(cookie_hdr);
        if (user_id == -1) {
            send_response(fd, 401, "Unauthorized", NULL, "{\"error\":\"Authentication required\"}");
            return;
        }
        
        int todo_id = 0;
        if (sscanf(uri, "/todos/%d", &todo_id) != 1) {
            send_response(fd, 404, "Not Found", NULL, "{\"error\":\"Not found\"}");
            return;
        }
        
        int todo_idx = -1;
        for (int i = 0; i < todo_count; i++) {
            if (todos[i].id == todo_id && todos[i].user_id == user_id) {
                todo_idx = i;
                break;
            }
        }
        
        if (todo_idx == -1) {
            send_response(fd, 404, "Not Found", NULL, "{\"error\":\"Todo not found\"}");
            return;
        }
        
        if (strcmp(method, "GET") == 0) {
            char esc_title[512], esc_desc[2048];
            escape_json_string(todos[todo_idx].title, esc_title, sizeof(esc_title));
            escape_json_string(todos[todo_idx].description, esc_desc, sizeof(esc_desc));
            char resp[2048];
            snprintf(resp, sizeof(resp),
                "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
                todos[todo_idx].id, esc_title, esc_desc, todos[todo_idx].completed ? "true" : "false", todos[todo_idx].created_at, todos[todo_idx].updated_at);
            send_response(fd, 200, "OK", NULL, resp);
            return;
        }
        
        if (strcmp(method, "PUT") == 0) {
            char title[256] = {0};
            char desc[1024] = {0};
            int completed = -1;
            
            if (has_json_key(body, "title")) {
                if (!get_json_str(body, "title", title, sizeof(title))) {
                    send_response(fd, 400, "Bad Request", NULL, "{\"error\":\"Title is required\"}");
                    return;
                }
                if (strlen(title) == 0) {
                    send_response(fd, 400, "Bad Request", NULL, "{\"error\":\"Title is required\"}");
                    return;
                }
                strncpy(todos[todo_idx].title, title, sizeof(todos[todo_idx].title) - 1);
            }
            
            if (has_json_key(body, "description")) {
                get_json_str(body, "description", desc, sizeof(desc));
                strncpy(todos[todo_idx].description, desc, sizeof(todos[todo_idx].description) - 1);
            }
            
            if (has_json_key(body, "completed")) {
                get_json_bool(body, "completed", &completed);
                if (completed != -1) {
                    todos[todo_idx].completed = completed;
                }
            }
            
            get_current_time(todos[todo_idx].updated_at, sizeof(todos[todo_idx].updated_at));
            
            char esc_title[512], esc_desc[2048];
            escape_json_string(todos[todo_idx].title, esc_title, sizeof(esc_title));
            escape_json_string(todos[todo_idx].description, esc_desc, sizeof(esc_desc));
            char resp[2048];
            snprintf(resp, sizeof(resp),
                "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
                todos[todo_idx].id, esc_title, esc_desc, todos[todo_idx].completed ? "true" : "false", todos[todo_idx].created_at, todos[todo_idx].updated_at);
            send_response(fd, 200, "OK", NULL, resp);
            return;
        }
        
        if (strcmp(method, "DELETE") == 0) {
            for (int i = todo_idx; i < todo_count - 1; i++) {
                todos[i] = todos[i+1];
            }
            todo_count--;
            send_no_body(fd, 204, "No Content", NULL);
            return;
        }
    }
    
    send_response(fd, 404, "Not Found", NULL, "{\"error\":\"Not found\"}");
}

void set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i+1]);
        } else if (strncmp(argv[i], "--port=", 7) == 0) {
            port = atoi(argv[i] + 7);
        }
    }
    
    for (int i = 0; i < MAX_CONN; i++) {
        clients[i].fd = -1;
    }
    
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }
    
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    
    if (listen(server_fd, 10) < 0) {
        perror("listen");
        return 1;
    }
    
    set_nonblock(server_fd);
    printf("Server listening on 0.0.0.0:%d\n", port);
    
    fd_set read_fds;
    struct timeval tv;
    
    while (1) {
        FD_ZERO(&read_fds);
        FD_SET(server_fd, &read_fds);
        int max_fd = server_fd;
        
        for (int i = 0; i < MAX_CONN; i++) {
            if (clients[i].fd >= 0) {
                FD_SET(clients[i].fd, &read_fds);
                if (clients[i].fd > max_fd) max_fd = clients[i].fd;
            }
        }
        
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        
        int activity = select(max_fd + 1, &read_fds, NULL, NULL, &tv);
        if (activity < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }
        
        if (FD_ISSET(server_fd, &read_fds)) {
            struct sockaddr_in client_addr;
            socklen_t client_len = sizeof(client_addr);
            int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
            if (client_fd >= 0) {
                set_nonblock(client_fd);
                int slot = -1;
                for (int i = 0; i < MAX_CONN; i++) {
                    if (clients[i].fd < 0) {
                        slot = i;
                        break;
                    }
                }
                if (slot != -1) {
                    clients[slot].fd = client_fd;
                    clients[slot].len = 0;
                    clients[slot].head = 0;
                } else {
                    close(client_fd);
                }
            }
        }
        
        for (int i = 0; i < MAX_CONN; i++) {
            if (clients[i].fd >= 0 && FD_ISSET(clients[i].fd, &read_fds)) {
                size_t avail = BUF_SIZE - clients[i].len - 1;
                if (avail > 0) {
                    ssize_t r = read(clients[i].fd, clients[i].buf + clients[i].len, avail);
                    if (r <= 0) {
                        close(clients[i].fd);
                        clients[i].fd = -1;
                    } else {
                        clients[i].len += r;
                        clients[i].buf[clients[i].len] = '\0';
                        
                        // Check if we have a full request (ends with \r\n\r\n or content length matches)
                        char *body_start = strstr(clients[i].buf, "\r\n\r\n");
                        int ready = 0;
                        if (body_start) {
                            char *cl_ptr = my_strcasestr(clients[i].buf, "Content-Length:");
                            if (cl_ptr) {
                                int cl = atoi(cl_ptr + 15);
                                size_t body_len = clients[i].len - (size_t)(body_start - clients[i].buf + 4);
                                if (body_len >= (size_t)cl) ready = 1;
                            } else {
                                ready = 1; // No content length, assume body is complete
                            }
                        }
                        
                        if (ready) {
                            handle_client(clients[i].fd, clients[i].buf, clients[i].len);
                            close(clients[i].fd);
                            clients[i].fd = -1;
                        }
                    }
                } else {
                    close(clients[i].fd);
                    clients[i].fd = -1;
                }
            }
        }
    }
    
    close(server_fd);
    return 0;
}

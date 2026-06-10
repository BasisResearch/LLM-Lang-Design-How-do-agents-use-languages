#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <pthread.h>
#include <stdbool.h>
#include <ctype.h>
#include <uuid/uuid.h>

#define MAX_USERS 50
#define MAX_TODOS_PER_USER 100
#define MAX_SESSIONS 50
#define BUFFER_SIZE 8192
#define MIN_PASSWORD_LENGTH 8

// Minimal structure to just test registration and login end-to-end
char registered_users[50][51];
int registered_user_ids[50];
int num_registered_users = 0;
pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

int find_json_field_value(const char *json, const char *field, char *target, size_t target_size) {
    char pattern[200];
    snprintf(pattern, sizeof(pattern), "\"%s\"", field);

    const char *field_pos = strstr(json, pattern);
    if (field_pos) {
        field_pos = strchr(field_pos, ':');
        if (field_pos) {
            field_pos++; // Skip colon
            while (*field_pos == ' ' || *field_pos == '\t') field_pos++;
            if (*field_pos == '"') {
                field_pos++; // Skip opening quote
                const char *end_quote = strchr(field_pos, '"');
                if (end_quote) {
                    size_t len = end_quote - field_pos;
                    if (len < target_size-1) {  // Account for null terminator
                        strncpy(target, field_pos, len);
                        target[len] = '\0';
                        return 1;
                    }
                }
            }
        }
    }
    return 0;
}


void process_register_request(int client_socket, const char *json_body) {
    char username[51];
    char password[129];
    
    if (!find_json_field_value(json_body, "username", username, sizeof(username))) {
        const char *response = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 53\r\nConnection: close\r\n\r\n{\"error\":\"Missing username\"}";
        send(client_socket, response, strlen(response), 0);
        return;
    }
    
    if (!find_json_field_value(json_body, "password", password, sizeof(password))) {
        const char *response = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 53\r\nConnection: close\r\n\r\n{\"error\":\"Missing password\"}";
        send(client_socket, response, strlen(response), 0);
        return;
    }
    
    // Check if user already exists
    pthread_mutex_lock(&mu);
    for (int i = 0; i < num_registered_users; i++) {
        if (strcmp(registered_users[i], username) == 0) {
            pthread_mutex_unlock(&mu);
            const char *response = "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 70\r\nConnection: close\r\n\r\n{\"error\":\"Username already exists\"}";
            send(client_socket, response, strlen(response), 0);
            return;
        }
    }
    
    // Add user
    strcpy(registered_users[num_registered_users], username);
    registered_user_ids[num_registered_users] = num_registered_users + 1;
    num_registered_users++;
    pthread_mutex_unlock(&mu);
    
    
    // Success: 201 Created with user data
    char response_body[200];
    int json_len = snprintf(response_body, sizeof(response_body), "{\"id\":%d,\"username\":\"%s\"}", num_registered_users, username);
    
    char response[1024];
    int total_len = snprintf(response, sizeof(response), 
        "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        json_len, response_body);
    
    send(client_socket, response, total_len, 0);
}

void process_request(int client_socket) {
    char buffer[BUFFER_SIZE];
    memset(buffer, 0, sizeof(buffer));
    
    ssize_t received = recv(client_socket, buffer, sizeof(buffer) - 1, 0);
    if (received <= 0) {
        close(client_socket);
        return;
    }
    buffer[received] = '\0';
    
    // Parse first line
    char method[16], path[256];
    if (sscanf(buffer, "%15s %255s HTTP/", method, path) != 2) {
        close(client_socket);
        return;
    }

    // Find body
    char *body_start = strstr(buffer, "\r\n\r\n");
    if (body_start) {
        body_start += 4;
    } else {
        body_start = "";
    }
    
    if (strcmp(method, "POST") == 0 && strcmp(path, "/register") == 0) {
        process_register_request(client_socket, body_start);
    } else {
        const char *notfound = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 18\r\nConnection: close\r\n\r\n{\"error\":\"Not found\"}";
        send(client_socket, notfound, strlen(notfound), 0);
    }
    
    close(client_socket);
}

int main(int argc, char *argv[]) {
    int port = 8080;
    if (argc > 2 && strcmp(argv[1], "--port") == 0) {
        port = atoi(argv[2]);
    }

    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    bind(sockfd, (struct sockaddr*)&addr, sizeof(addr));
    listen(sockfd, 10);
    printf("Test server listening on port %d\n", port);

    while (1) {
        int client_sock = accept(sockfd, NULL, NULL);
        process_request(client_sock);
    }
}

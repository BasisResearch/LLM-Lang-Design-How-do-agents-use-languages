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

#define BUFFER_SIZE 8192

void process_request(int client_socket) {
    char buffer[BUFFER_SIZE];
    memset(buffer, 0, sizeof(buffer));
    
    // Receive all data in one go with small timeout
    ssize_t bytes_received = recv(client_socket, buffer, sizeof(buffer) - 1, 0);
    if (bytes_received <= 0) {
        close(client_socket);
        return;
    }
    
    buffer[bytes_received] = '\0';
    printf("DEBUG: Received request:\n%s\n", buffer);
    
    // Parse first line of request to get method, URL path and version
    char method[16] = {0}, url_path[256] = {0}, http_version[64] = {0};
    int parsed_items = sscanf(buffer, "%15s %255s %63s", method, url_path, http_version);
    if (parsed_items != 3) {
        printf("DEBUG: Could not parse request line properly, got %d items\n", parsed_items);
        close(client_socket);
        return;
    }
    
    printf("Parsed method: %s, path: %s, version: %s\n", method, url_path, http_version);
    
    // Find the body location - it follows after "\r\n\r\n" or "\n\n"
    char *body_start = strstr(buffer, "\r\n\r\n");
    char *header_end = body_start;
    if (body_start) {
        body_start += 4;  // Skip over the delimiter
    } else {
        body_start = strstr(buffer, "\n\n");
        header_end = body_start;
        if (body_start) {
            body_start += 2;  // Skip over the delimiter
        }
    }
    
    char request_body[1024] = {0};
    if (body_start) {
        strcpy(request_body, body_start);
    }

    // Example for /register
    if (strcmp(method, "POST") == 0 && strcmp(url_path, "/register") == 0) {
        printf("Processing register request, body is: %s\n", request_body);
        
        // Simple parse for username and password
        char username[51] = {0};
        char password[129] = {0};
        
        char *uname_pos = strstr(request_body, "\"username\"");
        if (uname_pos) {
            uname_pos = strchr(uname_pos, ':');
            if (uname_pos) {
                uname_pos++; // Skip colon
                while (*uname_pos == ' ' || *uname_pos == '\t') uname_pos++;
                if (*uname_pos == '"') {
                    uname_pos++; // Skip opening quote
                    char *end_quote = strchr(uname_pos, '"');
                    if (end_quote) {
                        size_t len = end_quote - uname_pos;
                        if (len < sizeof(username)) {
                            strncpy(username, uname_pos, len);
                            username[len] = '\0';
                        }
                    }
                }
            }
        }

        char *pwd_pos = strstr(request_body, "\"password\"");
        if (pwd_pos) {
            pwd_pos = strchr(pwd_pos, ':');
            if (pwd_pos) {
                pwd_pos++; // Skip colon
                while (*pwd_pos == ' ' || *pwd_pos == '\t') pwd_pos++;
                if (*pwd_pos == '"') {
                    pwd_pos++; // Skip opening quote
                    char *end_quote = strchr(pwd_pos, '"');
                    if (end_quote) {
                        size_t len = end_quote - pwd_pos;
                        if (len < sizeof(password)) {
                            strncpy(password, pwd_pos, len);
                            password[len] = '\0';
                        }
                    }
                }
            }
        }
        
        printf("Detected username: '%s', password: '%s'\n", username, password);
        
        // Respond
        const char *response = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 24\r\nConnection: close\r\n\r\n{\"id\":1,\"username\":\"test\"}";
        send(client_socket, response, strlen(response), 0);
        close(client_socket);
        return;
    }
    
    // Default response for not implemented routes
    const char *response = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 22\r\nConnection: close\r\n\r\n{\"error\":\"Not found\"}";
    send(client_socket, response, strlen(response), 0);
    close(client_socket);
}

int main(int argc, char *argv[]) {
    int port = 8080;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
            i++;
        }
    }

    printf("Starting server on port %d\n", port);

    int server_fd;
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }

    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        exit(EXIT_FAILURE);
    }

    struct sockaddr_in address;
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

    printf("Server listening on port %d\n", port);

    while(1) {
        int client_socket = accept(server_fd, NULL, NULL);
        if (client_socket < 0) {
            perror("accept failed");
            continue;
        }
        
        process_request(client_socket);
    }

    close(server_fd);
    return 0;
}
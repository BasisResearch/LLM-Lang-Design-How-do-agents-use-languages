// This is a temporary implementation in C to understand the socket programming better
// Then I'll translate to a proper NASM assembly approach 
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <ctype.h>

#define MAX_CLIENTS 10
#define BUFFER_SIZE 4096

typedef struct {
    int user_id;
    char username[64];
    char password_hash[64];  // For real impl, would be hashed
} User;

typedef struct {
    int id;
    int user_id;
    char title[128];
    char description[256];
    int completed;
    char created_at[21];   // YYYY-MM-DDTHH:MM:SSZ
    char updated_at[21];   // YYYY-MM-DDTHH:MM:SSZ
} Todo;

typedef struct {
    char session_id[32];
    int user_id;
    int active;
} Session;

User users[256];
Todo todos[512];
Session sessions[64];

int user_count = 0;
int todo_count = 0;
int session_count = 0;

int main(int argc, char *argv[]) {
    int port = 8080;
    if (argc >= 3 && strcmp(argv[1], "--port") == 0) {
        port = atoi(argv[2]);
    }

    int server_fd, client_fd;
    struct sockaddr_in server_addr, client_addr;
    socklen_t addr_len = sizeof(client_addr);

    // Create socket
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }

    // Allow reuse
    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        exit(EXIT_FAILURE);
    }

    // Configure server address
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(port);

    // Bind socket
    if (bind(server_fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }

    // Listen for connections
    if (listen(server_fd, MAX_CLIENTS) < 0) {
        perror("listen failed");
        exit(EXIT_FAILURE);
    }
    
    printf("Server running on port %d\n", port);

    // Main event loop (for the exercise)
    while(1) {
        // Accept new client
        if ((client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &addr_len)) < 0) {
            perror("accept failed");
            continue;  // Keep server alive
        }

        // Read request
        char buffer[BUFFER_SIZE];
        int read_size = read(client_fd, buffer, BUFFER_SIZE-1);
        if(read_size <= 0) {
            close(client_fd);
            continue;
        }
        buffer[read_size] = '\0';
        
        // For demo purposes, just respond with a basic status
        const char *response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nOK";
        write(client_fd, response, strlen(response));
        
        close(client_fd);
    }

    return 0;
}
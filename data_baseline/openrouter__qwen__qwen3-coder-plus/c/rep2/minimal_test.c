#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>

int main() {
    // Simple test to ensure the approach works
    char *request = "POST /register HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 57\r\n\r\n{\"username\": \"test\", \"password\": \"password123\"}\r\n";
    
    char *headers_end = strstr(request, "\r\n\r\n");
    if (headers_end) {
        headers_end += 4; 
        printf("Headers end at: %s", headers_end);
    }
    
    char method[10], path[256], version[20];
    sscanf(request, "%s %s %s", method, path, version);
    printf("Parsed method: %s, path: %s, version: %s\n", method, path, version);
    
    return 0;
}
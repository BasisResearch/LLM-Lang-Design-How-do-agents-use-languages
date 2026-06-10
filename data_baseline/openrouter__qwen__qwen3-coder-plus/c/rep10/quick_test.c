#include <stdio.h>
#include <string.h>
#include <regex.h>

int validate_username(const char *username) {
    if (!username || strlen(username) < 3 || strlen(username) > 50) {
        printf("Length check failed: %s, len=%lu, min=3, max=50\n", username ? username : "NULL", 
               username ? strlen(username) : 0);
        return 0;
    }
    
    regex_t regex;
    int reti = regcomp(&regex, "^[a-zA-Z0-9_]+$", REG_EXTENDED);
    if (reti) {
        printf("Could not compile regex\n");
        return 0;
    }
    
    reti = regexec(&regex, username, 0, NULL, 0);
    printf("Regex execution result for '%s': %d (where 0=match)\n", username, reti);
    regfree(&regex);
    
    // regexec returns 0 on match
    return !reti;
}

int main() {
    // Simulate the string extraction from our server code
    const char* request_body = "{\"username\": \"testuser\", \"password\": \"testpass123\"}";
    
    printf("Input: %s\n", request_body);
    
    const char *username_pos = strstr(request_body, "\"username\":\"");
    printf("Found username position: %s\n", username_pos ? username_pos : "NULL");
    
    if (username_pos) {
        username_pos += 12; // Skip '"username":"' 
        const char *end_quote = strchr(username_pos, '"');
        if (end_quote && end_quote > username_pos) {
            int len = end_quote - username_pos;
            char extracted_username[100];
            strncpy(extracted_username, username_pos, len);
            extracted_username[len] = '\0';
            printf("Extracted username: '%s', length: %d\n", extracted_username, len);
            
            if (validate_username(extracted_username)) {
                printf("Extracted username is valid: %s\n", extracted_username);
            } else {
                printf("Extracted username is invalid: %s\n", extracted_username);
            }
        } else {
            printf("End quote not found\n");
        }
    }
    
    // Check if sscanf would work
    char username_sscanf[100];
    char password_sscanf[100];
    int result = sscanf(request_body, "{\"username\":\"%99[^\",]\", \"password\":\"%99[^\",]\"}", 
                      username_sscanf, password_sscanf);
    printf("\nsscanf result: %d\n", result);
    if (result >= 2) {
        printf("sscanf username: '%s'\n", username_sscanf);
        printf("sscanf password: '%s'\n", password_sscanf);
        printf("Is sscanf username valid? %d\n", validate_username(username_sscanf));
    }
    
    return 0;
}
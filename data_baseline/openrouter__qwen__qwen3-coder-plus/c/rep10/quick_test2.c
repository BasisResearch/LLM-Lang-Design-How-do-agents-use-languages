#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main() {
    const char *request_body = "{\"username\": \"johndoe\", \"password\": \"securepassword\"}";
    printf("Original request_body: %s\n", request_body);
    
    // Extract manually
    const char *uname_start = strstr(request_body, "\"username\"");
    const char *pass_start = strstr(request_body, "\"password\""); 

    printf("Username pos: %s\n", uname_start ? "found" : "not found");
    printf("Password pos: %s\n", pass_start ? "found" : "not found");

    if (uname_start && pass_start) {
        uname_start = strchr(uname_start, ':');
        pass_start = strchr(pass_start, ':');

        if (uname_start && pass_start) {
            printf("Username after comma: %s\n", uname_start);
            printf("Password after comma: %s\n", pass_start);

            uname_start++; // Skip colon
            pass_start++; // Skip colon

            // Skip spaces
            while (*uname_start == ' ') uname_start++;
            while (*pass_start == ' ') pass_start++;

            // Both should now point to a quote
            if (*uname_start == '"' && *pass_start == '"') {
                uname_start++; // Skip quote 
                pass_start++; // Skip quote
            }

            const char *uname_end = strchr(uname_start, '"');
            const char *pass_end = strchr(pass_start, '"');

            if (uname_end && pass_end) {
                char extracted_username[100];
                char extracted_password[100];

                int uname_len = uname_end - uname_start;
                int pass_len = pass_end - pass_start;

                strncpy(extracted_username, uname_start, uname_len);
                strncpy(extracted_password, pass_start, pass_len);

                extracted_username[uname_len] = '\0';
                extracted_password[pass_len] = '\0';

                printf("Extracted username: '%s'\n", extracted_username);
                printf("Extracted password: '%s'\n", extracted_password);
            }
        }
    }

    // Try with sscanf
    char username[100];
    char password[100];
    int result = sscanf(request_body, "{\"username\": \"%99[^\"]\", \"password\": \"%99[^\"]\"}", username, password);
    printf("sscanf result: %d\n", result);
    if (result == 2) {
        printf("sscanf username: '%s'\n", username);
        printf("sscanf password: '%s'\n", password);
    }

    return 0;
}

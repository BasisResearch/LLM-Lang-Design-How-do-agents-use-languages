#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

char* extract_json_field(const char *json, const char *field_name) {
    // Build search pattern: "field_name":"..."
    char search_pattern[256];
    snprintf(search_pattern, sizeof(search_pattern), "\"%s\"", field_name);
    
    const char *start = strstr(json, search_pattern);
    if (!start) return NULL;

    printf("Found field '%s' at: '%.50s'\n", field_name, start);
    
    start = strstr(start + strlen(field_name) + 2, ":"); // Find colon after field name
    if (!start) return NULL;
    
    start++; // Move past colon
    while (*start && isspace((unsigned char)*start)) start++; // Skip whitespace after colon
    printf("After colon skipping: '%.20s'\n", start);
    
    if (*start != '"') return NULL; // Expect quoted value
    printf("Expecting quote char, found: '%c'\n", *start);
    start++; // Skip opening quote
    printf("Skipping quote, next: '%.20s'\n", start);
    
    const char *end = strchr(start, '"');
    if (!end) return NULL;
    
    int length = end - start;
    char *result = malloc(length + 1);
    if (result) {
        strncpy(result, start, length);
        result[length] = '\0';
    }
    
    printf("Extracted value: '%s'\n", result);
    return result;
}

int validate_username(const char *username) {
    if (!username || strlen(username) < 3 || strlen(username) > 50) {
        printf("Validate failed: null=%d, len=%ld, 3=%d, 50=%d\n", 
               username==NULL, username ? strlen(username) : -1, 
               username ? strlen(username) < 3 : 0,
               username ? strlen(username) > 50 : 0);
        return 0;
    }
    
    for(int i = 0; username[i] != '\0'; i++) {
        if(!isalnum(username[i]) && username[i] != '_') {
            return 0;
        }
    }
    return 1;
}

int main() {
    const char *json = "{\"username\": \"testuser\", \"password\": \"password123\"}";
    printf("JSON: %s\n", json);
    
    char *username = extract_json_field(json, "username");
    if (username) {
        printf("Final username: '%s', valid=%d\n", username, validate_username(username));
        free(username);
    } else {
        printf("Username not found!\n");
    }
    
    return 0;
}

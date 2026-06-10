#include <stdio.h>
#include <string.h>
#include <regex.h>

int validate_username(const char *username) {
    if (!username || strlen(username) < 3 || strlen(username) > 50) {
        return 0;
    }
    
    regex_t regex;
    int reti = regcomp(&regex, "^[a-zA-Z0-9_]+$", REG_EXTENDED);
    if (reti) {
        printf("Could not compile regex\n");
        return 0;
    }
    
    reti = regexec(&regex, username, 0, NULL, 0);
    regfree(&regex);
    
    // regexec returns 0 on match
    return !reti;
}

int main() {
    const char *test_username = "testuser";
    
    if (validate_username(test_username)) {
        printf("Valid: %s\n", test_username);
    } else {
        printf("Invalid: %s\nlength: %lu, min: %d, max: %d\n", 
               test_username, strlen(test_username), 3, 50);
    }
    return 0;
}

#include <stdio.h>
#include <stdlib.h>
#include <curl/curl.h>
#include <string.h>

#define MAX_COOKIE_LENGTH 512
char session_cookie[MAX_COOKIE_LENGTH];

// Callback to capture the Set-Cookie header
static size_t WriteCallback(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t realsize = size * nmemb;
    // Check for Set-Cookie header in response
    char *header = (char *)contents;
    if (strncasecmp(header, "Set-Cookie:", 11) == 0) {
        char *cookie_start = strstr(header, "session_id=");
        if (cookie_start) {
            cookie_start += 11; // Skip "session_id="
            char *semicolon = strchr(cookie_start, ';');
            if (semicolon) {
                int len = semicolon - cookie_start;
                strncpy(session_cookie, cookie_start, len);
                session_cookie[len] = '\0';
                // printf("Extracted session cookie: %s\n", session_cookie);
            }
        }
    }
    return realsize;
}

int main() {
    CURL *curl;
    CURLcode res;
    
    // Initialize curl
    curl_global_init(CURL_GLOBAL_DEFAULT);
    curl = curl_easy_init();
    
    if (curl) {
        // Test 1: Register
        printf("Test 1: Register user\n");
        curl_easy_setopt(curl, CURLOPT_URL, "http://localhost:8080/register");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, "{\"username\":\"testuser\", \"password\":\"password123\"}");
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, NULL);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        res = curl_easy_perform(curl);
        if (res != CURLE_OK)
            fprintf(stderr, "curl_easy_perform() failed: %s\n", curl_easy_strerror(res));
        printf("Registration done.\n");

        // Test 2: Login and get cookie
        printf("\nTest 2: Login to obtain session\n");
        curl_easy_setopt(curl, CURLOPT_URL, "http://localhost:8080/login");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, "{\"username\":\"testuser\", \"password\":\"password123\"}");
        res = curl_easy_perform(curl);
        if (res != CURLE_OK)
            fprintf(stderr, "curl_easy_perform() failed: %s\n", curl_easy_strerror(res));
        printf("Session cookie obtained: %s\n", session_cookie);
        
        // Test 3: Use the cookie for /me
        printf("\nTest 3: Access /me with cookie\n");
        char cookie_header[1024];
        sprintf(cookie_header, "Cookie: session_id=%s", session_cookie);
        struct curl_slist *headers = NULL;
        headers = curl_slist_append(headers, cookie_header);
        curl_easy_setopt(curl, CURLOPT_URL, "http://localhost:8080/me");
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        curl_easy_setopt(curl, CURLOPT_POST, 0L);  // No post
        res = curl_easy_perform(curl);
        if (res != CURLE_OK)
            fprintf(stderr, "curl_easy_perform() failed: %s\n", curl_easy_strerror(res));
        
        // Cleanup headers
        curl_slist_free_all(headers);
        
        curl_easy_cleanup(curl);
    }
    
    curl_global_cleanup();
    return 0;
}
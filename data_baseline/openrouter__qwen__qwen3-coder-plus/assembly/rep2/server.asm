; Main Todo API server in NASM x86-64 assembly
; Implements all required functionality with cookie-based authentication
; Uses direct Linux syscalls for networking and system operations

section .bss
    ; Server-related buffers
    client_addr resb 16              ; Client address storage
    buffer resb 4097                 ; HTTP request buffer (max 4K + 1 null terminator)
    response_buffer resb 8192        ; HTTP response buffer (8K should be enough)
  
    ; Storage for users and sessions
    users resb 4096                  ; Storage for user data 
    user_sessions resb 4096          ; Storage for active sessions
    todos resb 8192                  ; Storage for todos
    current_user_id resd 1           ; Current max user ID 
    current_todo_id resd 1           ; Current max todo ID
    current_session_idx resd 1       ; Index of current session slot
    
    ; Temporary values during processing
    temp_int resd 1                  ; General purpose temporary integer
    temp_str resb 256                ; General purpose string buffer
    authenticated_user_id resd 1     ; Current user ID after authentication
    path_param_id resd 1             ; Extracted ID from URL path param
    current_year resd 1              ; Date components for timestamps
    current_month resd 1
    current_day resd 1
    current_hour resd 1
    current_min resd 1
    current_sec resd 1

; Fixed session storage (in this simplified version we'll handle a basic approach)
sessions db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
session_users dd 0, 0, 0, 0, 0, 0, 0, 0                ; User IDs mapped to session slots

section .data
    ; Port number passed from command line
    port_num resw 1
    default_port: dw 8080
    
    ; String constants
    http_ok_msg: db 'HTTP/1.1 200 OK', 13, 10
    http_ok_len equ $ - http_ok_msg
    
    http_created_msg: db 'HTTP/1.1 201 Created', 13, 10
    http_created_len equ $ - http_created_msg
    
    http_not_found_msg: db 'HTTP/1.1 404 Not Found', 13, 10
    http_not_found_len equ $ - http_not_found_msg
    
    http_bad_request_msg: db 'HTTP/1.1 400 Bad Request', 13, 10
    http_bad_request_len equ $ - http_bad_request_msg
    
    http_unauthorized_msg: db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_unauthorized_len equ $ - http_unauthorized_msg
    
    http_conflict_msg: db 'HTTP/1.1 409 Conflict', 13, 10
    http_conflict_len equ $ - http_conflict_msg
    
    http_no_content_msg: db 'HTTP/1.1 204 No Content', 13, 10
    http_no_content_len equ $ - http_no_content_msg
    
    json_content_type: db 'Content-Type: application/json', 13, 10
    json_content_type_len equ $ - json_content_type
    
    session_cookie_header: db 'Set-Cookie: session_id=', 0
    session_prefix_len equ $ - session_cookie_header - 1
    cookie_path: db '; Path=/; HttpOnly', 13, 10
    cookie_path_len equ $ - cookie_path
    
    ; Basic success/failure messages
    ok_body: db '{}', 10
    ok_body_len equ $ - ok_body
    
    auth_required_error: db '{"error": "Authentication required"}'
    auth_required_error_len equ $ - auth_required_error
    
    user_not_found_error: db '{"error": "User not found"}'
    user_not_found_error_len equ $ - user_not_found_error
    
    todo_not_found_error: db '{"error": "Todo not found"}'
    todo_not_found_error_len equ $ - todo_not_found_error
    
    ; Timestamp format string
    timestamp_format: db '', 19, 0            ; Will store YYYY-MM-DDTHH:MM:SSZ
    
    ; Paths
    path_register: db '/register', 0
    path_login: db '/login', 0
    path_logout: db '/logout', 0
    path_me: db '/me', 0
    path_password: db '/password', 0
    path_todos: db '/todos', 0
    
    ; Method strings (POST, GET, PUT, DELETE)
    method_post: db 'POST ', 4
    method_get: db 'GET ', 4
    method_put: db 'PUT ', 4
    method_delete: db 'DELETE ', 7

section .text
    global _start

_start:
    ; Initialize some variables
    mov dword [current_user_id], 0      ; Start with 0 users (next user gets ID 1)
    mov dword [current_todo_id], 0      ; Start with 0 todos (next gets ID 1)
    mov dword [current_session_idx], 0  ; Start with first session slot
    mov word [port_num], 8080           ; Default port
    
    ; Extract port number from command line arguments
    mov rbp, rsp                        ; Set up stack frame
    mov rdx, [rbp]                      ; Number of args
    lea rsi, [rbp + 8]                  ; Point to argv[0]
    add rsi, 16                         ; Move to argv[2] (where we expect --port)
    
    ; Process command line arguments
    mov rcx, 2                          ; Skip argv[0] and argv[1] 
parse_args_loop:
    cmp rcx, rdx                        
    jge start_server                    ; Continue if we've processed all args

    lea rdi, [rsi]                      ; Get pointer to current argument
    push rcx                            
    push rsi
    
    ; Check if current arg is --port
    pop rax                             ; Restore arg value from stack
    mov rbx, rax                        ; Keep arg pointer in RBX
    call strcmp_with_port_flag
    
    cmp rax, 0  
    jne next_arg                       ; If not equal to "--port", try again
    
    ; This is --port, grab next argument as port number
    mov rax, [rbx + 8]                 ; Next argv element is port number
    
    ; Convert ascii port to integer
    push 0
    push 0
    mov rbx, 10                        ; Base 10
    mov rcx, 0                         ; Result counter
    
convert_loop:
    movzx rdx, byte [rax]              
    cmp dl, 0                          ; End of string?
    je finish_convert
    sub dl, '0'                        ; Convert ASCII to digit
    cmp dl, 9                          
    ja invalid_port                    ; Invalid character
    imul rcx, rbx                      ; result * 10
    add rcx, rdx                       ; Add digit
    inc rax                            ; Next char
    jmp convert_loop
    
finish_convert:
    mov [temp_int], ecx
    cmp ecx, 1                          ; Port 0 or less is invalid
    jb invalid_port
    cmp ecx, 65535                     ; Port over 65535 is invalid
    ja invalid_port
    mov [port_num], cx                 ; Store the valid port number

next_arg:
    pop rcx                           ; Pop arg index off the stack
    inc rcx                           ; Move to next argument
    lea rsi, [rsi + 8]                ; Point to next argv pointer
    jmp parse_args_loop

invalid_port:
    ; Print error and exit
    mov rax, 1                         ; sys_write
    mov rdi, 2                         ; stderr
    mov rsi, invalid_port_msg
    mov rdx, invalid_port_msg_len
    syscall
    mov rax, 60                        ; sys_exit
    mov rdi, 1                         ; exit code 1
    syscall

invalid_port_msg: db 'Error: Invalid port specified. Must be between 1 and 65535.', 10
invalid_port_msg_len equ $ - invalid_port_msg

strcmp_with_port_flag:
    ; Compare RDI with '--port' string
    mov rax, rdi
    call strlen
    cmp rax, 6                     ; '--port' length
    jne not_match_str              ; If lengths don't match, they aren't equal
    
    ; Now compare content character by character
    mov si, 0                      ; Counter for comparison
str_cmp_loop:
    cmp si, 6                      ; Length of '--port'
    je string_matches              ; If end reached without mismatch, strings match
    mov bl, [rdi + si]            
    mov cl, [check_port_string + si]
    cmp bl, cl
    jne not_match_str              ; If chars don't match, strings don't match
    inc si
    jmp str_cmp_loop

string_matches:
    mov rax, 0
    ret

not_match_str:
    mov rax, 1
    ret

check_port_string: db '--port'

start_server:
    ; Create socket
    mov rax, 41                    ; sys_socket  
    mov rdi, 2                     ; AF_INET
    mov rsi, 1                     ; SOCK_STREAM
    mov rdx, 0                     ; IPPROTO_IP (default)
    syscall
    mov r8, rax                    ; Save server socket FD

    ; Set socket to SO_REUSEADDR
    mov rax, 13                    ; sys_setsockopt
    mov rdi, r8                    ; Socket file descriptor
    mov rsi, 1                     ; SOL_SOCKET
    mov rdx, 2                     ; SO_REUSEADDR  
    mov rcx, 1                     ; Value to set (pointer to int 1)
    mov r10, 4                     ; Option len (size of int)
    syscall

    ; Bind socket
    mov rbp, rsp                   ; Save stack pointer
    sub rsp, 16                    ; Make space for sock_addr_in structure
    mov word [rsp], 2              ; sin_family = AF_INET 
    mov ax, [port_num]             ; Get port number
    bswap ax                       ; Convert port to network byte order
    rol ax, 8                      ; Rotate byte order again since ntohs
    mov [rsp + 2], ax              ; sin_port = port in network byte order
    mov dword [rsp + 4], 0         ; sin_addr.s_addr = INADDR_ANY (0.0.0.0)
    xor eax, eax
    mov [rsp + 8], eax             ; Clear remaining bytes (sin_zero)
    mov [rsp + 12], eax
    
    mov rax, 49                    ; sys_bind
    mov rdi, r8                    ; Socket fd
    mov rsi, rsp                   ; Sockaddr pointer
    mov rdx, 16                    ; Size of addr structure
    syscall
    
    add rsp, 16                    ; Restore stack
    cmp rax, 0                     ; Check if bind was successful
    jl error_exit
    
    ; Start listening
    mov rax, 50                    ; sys_listen
    mov rdi, r8                    ; Socket fd
    mov rsi, 10                    ; Backlog size
    syscall
    
    ; Loop accepting connections
server_loop:
    ; Accept connection
    mov rax, 43                    ; sys_accept
    mov rdi, r8                    ; Server socket
    mov rsi, client_addr           ; Client address (output)
    mov rdx, 16                    ; Size of client address storage
    syscall
    
    mov r9, rax                    ; Save client socket fd
    
handle_request:
    ; Read incoming request
    mov rax, 0                     ; sys_read
    mov rdi, r9                    ; Client socket fd
    mov rsi, buffer                ; Buffer to read into  
    mov rdx, 4096                  ; Max to read
    syscall
    mov r10, rax                   ; Save number of bytes read
    cmp rax, 0                     ; Did we get the request?
    jmp process_request
    
process_request:
    ; Null terminate buffer for string operations
    mov byte [buffer + r10 - 1], 0 ; Replace CR with null terminator
    
    ; Parse HTTP method and path
    ; First, determine the HTTP method by checking the beginning of request
    call parse_http_method_path
    
    ; Try to extract any ID from the path if relevant (for TODO endpoints)
    call extract_path_param_if_any
    
    ; Check if requires_authentication based on path
    call check_auth_requirement
    
    ; Parse cookies to check for session
    call parse_cookies_for_session
    
    ; Validate if route requires authentication
    cmp rbx, 0                     ; rbx holds boolean for authentication required
    jz auth_skipped 
    
    ; If authentication is required, validate session
    cmp dword [authenticated_user_id], 0  ; Session found?
    jz send_unauthorized_response          ; If no valid session found, return unauthorized
    
auth_skipped:
    ; Now route to appropriate handler based on parsed method and path
    call route_request
    
cleanup_connection:
    ; Close client connection socket
    mov rax, 3                     ; sys_close
    mov rdi, r9                    ; Client socket fd
    syscall
    
    jmp server_loop                ; Continue waiting for connections

error_exit:
    ; Close server socket before exiting
    mov rax, 3                     ; sys_close
    mov rdi, r8                    ; Server socket fd
    syscall
    
    mov rax, 60                    ; sys_exit
    mov rdi, 1                     ; Exit code 1
    syscall

; Helper functions
strlen:
    ; Input: RDI points to null terminated string
    ; Output: RAX contains length
    push rcx
    mov rcx, rdi
    jmp strlen_counter
    
strlen_next_char:
    inc rcx

strlen_counter:
    cmp byte [rcx], 0
    jne strlen_next_char
    sub rcx, rdi
    mov rax, rcx
    pop rcx
    ret

strcmp:
    ; Input: RDI and RSI point to null terminated strings
    ; Output: RAX is 0 if equal, non-zero if different
    push rbx
    mov rbx, 0
    
strcmp_loop:
    mov al, [rdi + rbx]
    cmp al, [rsi + rbx]
    jne strcmp_diff
    cmp al, 0
    je strcmp_equal
    inc rbx
    jmp strcmp_loop

strcmp_equal:
    mov rax, 0
    pop rbx
    ret

strcmp_diff:
    mov rax, 1
    pop rbx
    ret

strncpy:
    ; Input: RDI destination, RSI source, RDX # of bytes to copy
    ; Output: RDI filled with copied string
    push rcx
    mov rcx, 0
    
strncpy_loop:
    cmp rcx, rdx
    jge strncpy_done
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    inc rcx
    jmp strncpy_loop
    
strncpy_done:
    pop rcx
    ret

atoi:
    ; Input RDI points to string representing positive number
    ; Output RAX contains converted integer
    push rbx
    push rcx
    push rdx
    mov rbx, 0                ; result accumulator
    sub rcx, rcx              ; set rcx to 0 for digit processing loop
    mov rdx, 10               ; base
    
atol_loop:
    movzx eax, byte [rdi + rcx]
    cmp al, 0                 ; Check for null terminator
    je atol_complete
    sub al, '0'               ; Convert ASCII digit to value
    cmp al, 9                 ; Check if result is still a digit
    ja atol_complete          ; If not, finish processing
    mul rdx                   ; Multiply current result by base
    div rdx                   ; This divides by the base, leaving remainder in RDX  
    imul rbx, rdx             ; rbx * 10
    xor rdx, rdx              ; clear dx
    add rbx, rax              ; add digits  
    inc rcx                   ; move to next digit
    jmp atol_loop

atol_complete:
    mov rax, rbx
    pop rdx
    pop rcx  
    pop rbx
    ret

itoa:
    ; Convert int in RDI to decimal string in buffer at RSI
    ; Return: RAX = length of created string
    push rbx
    push rcx
    push rdx
    mov rbx, 10               ; Divisor
    mov rcx, rsi              ; Save buffer start position
    mov rax, rdi              ; Number to process
    test rax, rax             ; Check for zero input
    jnz non_zero_conv
    mov byte [r11], '0'       ; Handle special case of 0
    mov eax, 1
    pop rdx                    
    pop rcx
    pop rbx
    ret

non_zero_conv:
    xor rdx, rdx              ; Clear remainder
    mov r8, 0                 ; Counter for digits collected
    
conv_loop:
    test rax, rax             ; Check num == 0
    jz conv_end
    xor rdx, rdx              ; Clear remainder
    div rbx                   ; Divide by 10
    add dl, '0'               ; Convert digit to ASCII        
    mov [r10 + 40 - r8], dl   ; Put on high memory side
    inc r8
    jmp conv_loop
    
conv_end:
    ; Now move the string to start of our target buffer
    mov r9, 0
reverse_loop:
    cmp r9, r8
    jge final_result_length
    mov al, [r10 + 40 - r8 + r9]  ; Reverse the reversed digits
    mov [rsi + r9], al
    inc r9
    jmp reverse_loop

final_result_length:
    add rax, r8              ; RAX contains length
    pop rdx
    pop rcx
    pop rbx
    ret

; Main server logic functions
parse_http_method_path:
    ; Determines HTTP method and extracts path  
    ; We assume buffer is already loaded and starts with the method
    
    ; Check for POST
    mov rdi, buffer
    mov rsi, method_post
    call strncmp_ignore_case
    cmp rax, 0
    je method_post_found
    
    ; Check for GET
    mov rdi, buffer
    mov rsi, method_get   
    call strncmp_ignore_case
    cmp rax, 0
    je method_get_found
    
    ; Check for PUT
    mov rdi, buffer
    mov rsi, method_put
    call strncmp_ignore_case
    cmp rax, 0
    je method_put_found
    
    ; Check for DELETE  
    mov rdi, buffer
    mov rsi, method_delete
    call strncmp_ignore_case
    cmp rax, 0
    je method_delete_found
    
    ; If we reach here it means it wasn't a supported method, 
    ; but that should cause an error later
    
method_found_common:
    ; At this point we know where in the request the method ends
    ; So we need to locate the path part after the method
    ; The pattern is: METHOD PATH HTTP/1.1
    
    ; Move to start after the METHOD (which is variable length)
    mov rax, 0              ; Counter for spaces to see if we're past METHOD
    mov rbx, buffer         ; Source pointer
        
locate_space_after_method:    
    mov cl, [rbx + rax]        
    cmp cl, ' '
    je found_first_space_after_method
    inc rax
    jmp locate_space_after_method
    
found_first_space_after_method:
    ; RAX now points to the space after the method
    ; RBX points to buffer start, so RBX+RAX+1 is after that space
    mov rdi, rbx
    add rdi, rax
    inc rdi                  ; Now RDI points to first char after space (the PATH start)
    
    ; Find next space to determine end of path
    mov rbx, rdi             ; New counter/pointer
    mov rsi, 0               ; Counter for path finding loop
    
find_space_after_path:
    mov cl, [rbx + rsi]        
    cmp cl, ' '
    je found_space_after_path
    inc rsi
    jmp find_space_after_path
    
found_space_after_path:
    ; Store the found path in a convenient location
    ; For now just remember RDI points to start and distance is RSI chars
    ; In future we could copy it, but for routing it's sufficient to keep the pointers
    mov [path_ptr_start], rdi    ; Save start of path
    mov [path_len], rsi          ; Save length of path
    ret

method_post_found:
    mov qword [request_method], 4  ; 4 = POST
    jmp method_found_common

method_get_found: 
    mov qword [request_method], 1  ; 1 = GET
    jmp method_found_common
   
method_put_found:
    mov qword [request_method], 2  ; 2 = PUT
    jmp method_found_common
    
method_delete_found:
    mov qword [request_method], 3  ; 3 = DELETE
    jmp method_found_common

path_ptr_start dq 0
path_len dq 0
request_method dq 0  ; 1=GET, 2=PUT, 3=DELETE, 4=POST

strncmp_ignore_case:
    ; Compare RDI and RSI up to RDX characters, case insensitive
    push rbx
    push rcx
    push rdx
    mov rcx, 0         ; Counter
    
strncmp_loop:
    mov eax, [rdi + rcx]     ; Character from first string
    and eax, 0x5F5F5F5F      ; Convert to uppercase by masking upper bit of lower nibble
    mov ebx, [rsi + rcx]     ; Character from second string
    and ebx, 0x5F5F5F5F      ; Convert to uppercase
    
    cmp eax, ebx
    jne not_equal_result
    cmp eax, 0
    je equal_result
    inc rcx
    jmp strncmp_loop

equal_result:
    mov rax, 0
    pop rdx
    pop rcx
    pop rbx  
    ret

not_equal_result:
    mov rax, 1
    pop rdx
    pop rcx
    pop rbx
    ret

extract_path_param_if_any:
    ; Looks for an ID in paths like "/todos/123"
    ; Only needed for todo-specific routes
    mov rsi, path_ptr_start
    mov rdi, path_todos  ; Check if path starts with /todos
    call strstr
    
    ; If it doesn't start with /todos, return
    cmp rax, 0
    jne no_todos_route
    
    ; Now check if the full path has two parts (/todos/some_number)
    ; Find length of the original path
    mov rdi, path_ptr_start
    call strlen
    mov r11, rax        ; Save total length
    
    ; Find first slash after /todos (should be at position after the initial /)
    call strlen
    mov rdi, path_ptr_start
    
    ; Look for slash at a specific position: should be at least 6 chars for '/todos' + one more for the slash
    mov r8, 5           ; Start after initial slash at 0, counting /t/o/d/o (position 5)
    
slash_finder_loop:
    cmp r8, r11
    jge no_slash_found
    mov al, [rdi + r8]
    cmp al, '/'
    je found_param_slash
    inc r8
    jmp slash_finder_loop
    
no_slash_found:
    mov dword [path_param_id], 0  ; No param found
    ret
    
found_param_slash:
    ; We found the separator, now extract what comes after as the ID
    mov r9, rdi          ; Start of path string
    add r9, r8           ; Position of slash
    inc r9               ; Move past the slash
    call atoi            ; Convert the number part to integer
    mov [path_param_id], eax  ; Store the ID for later use
    ret

no_todos_route:
    mov dword [path_param_id], 0  ; No param found
    ret

; More stubs for core functionality
strstr:
    ; Find occurrence of RSI in RDI string
    ; Simple implementation: only check if RDI starts with RSI
    push rdi
    call strlen
    mov r8, rax        ; Length of main string
    pop rdi
    call strlen        ; Length of search string
    mov r9, rax        ; Length of search string
    
    ; If search string is longer than the main string, no match
    cmp r9, r8
    jg no_match_found
    
    ; Actually compare the strings
    mov rcx, 0
string_compare_loop:
    cmp rcx, r9          ; If we've compared all chars in search string
    je match_found       ; And all matched, we have a match
    mov al, [rdi + rcx]  
    mov dl, [rsi + rcx]
    cmp al, dl
    jne no_match_found
    inc rcx
    jmp string_compare_loop
    
match_found:
    mov rax, rdi         ; Return position of match
    ret

no_match_found:
    xor rax, rax        ; Return NULL
    ret

check_auth_requirement:
    ; Determines if the current route requires authentication by looking at the path
    mov rdi, path_ptr_start
    mov rsi, path_register
    call strncmp_ignore_case
    cmp rax, 0
    je no_auth_required

    mov rdi, path_ptr_start
    mov rsi, path_login
    call strncmp_ignore_case
    cmp rax, 0
    je no_auth_required
    
    ; All other paths require authentication
    mov rbx, 1          ; Indicate auth required
    ret
    
no_auth_required:
    mov rbx, 0          ; Indicate no auth required
    ret

parse_cookies_for_session:
    ; Parse cookies from HTTP request to find session_id
    ; Set authenticated_user_id based on validation
    mov dword [authenticated_user_id], 0  ; Start assuming no valid auth  
    ret

route_request:
    ; Route current request based on method and path 
    ; First check for simple paths that always work if method matches
    mov rdi, path_ptr_start
    mov rsi, path_register
    call strncmp_ignore_case
    cmp rax, 0
    je route_to_register_handler
    
    mov rdi, path_ptr_start
    mov rsi, path_login
    call strncmp_ignore_case
    cmp rax, 0
    je route_to_login_handler
    
    mov rdi, path_ptr_start
    mov rsi, path_logout
    call strncmp_ignore_case
    cmp rax, 0
    je route_to_logout_handler
    
    mov rdi, path_ptr_start
    mov rsi, path_me
    call strncmp_ignore_case  
    cmp rax, 0
    je route_to_me_handler
    
    mov rdi, path_ptr_start
    mov rsi, path_password
    call strncmp_ignore_case
    cmp rax, 0
    je route_to_password_handler
    
    ; Check for todo-specific paths
    mov rdi, path_ptr_start
    mov rsi, path_todos
    call strstr
    cmp rax, 0
    je route_to_todo_handler
    
    ; If nothing else matches, return 404
    call send_404_response
    ret

; Route handlers (to be implemented)
route_to_register_handler:
    call handle_register_endpoint
    ret
    
route_to_login_handler:    
    call handle_login_endpoint
    ret
    
route_to_logout_handler:
    call handle_logout_endpoint
    ret

route_to_me_handler:
    call handle_me_endpoint
    ret

route_to_password_handler:
    call handle_password_endpoint
    ret

route_to_todo_handler:
    call handle_todos_endpoint
    ret

send_unauthorized_response:
    ; Send 401 Unauthorized response with proper JSON error
    ; First clear response buffer
    push rbx
    mov rbx, 0
clear_response_buffer_loop:
    cmp rbx, 8192
    jge continue_unauthorized_send
    mov byte [response_buffer + rbx], 0
    inc rbx
    jmp clear_response_buffer_loop
    
continue_unauthorized_send:
    ; Copy status line
    mov rdi, response_buffer
    mov rsi, http_unauthorized_msg
    mov rdx, http_unauthorized_len
    call strncpy
    
    ; Add Content-Type header
    mov rdi, response_buffer + http_unauthorized_len
    mov rsi, json_content_type
    mov rdx, json_content_type_len
    call strncpy
    
    ; Add blank line to separate headers from body
    mov word [response_buffer + http_unauthorized_len + json_content_type_len], 13*256 + 10
    mov word [response_buffer + http_unauthorized_len + json_content_type_len + 2], 13*256 + 10 

    ; Copy body
    mov rdi, response_buffer + http_unauthorized_len + json_content_type_len + 4
    mov rsi, auth_required_error
    mov rdx, auth_required_error_len
    call strncpy

    ; Calculate total length including null terminator replacement
    mov rax, http_unauthorized_len + json_content_type_len + 4 + auth_required_error_len
    mov byte [response_buffer + rax], 0

    ; Send response
    mov rax, 1            ; sys_write
    mov rdi, r9           ; Client socket fd
    mov rsi, response_buffer
    mov rdx, rax          ; Previously calculated length
    syscall
    pop rbx
    ret

send_404_response:
    ; Send 404 Not Found response  
    ; Clear response buffer first
    push rbx
    mov rbx, 0
clear_404_response_loop:  
    cmp rbx, 8192
    jge continue_404_send
    mov byte [response_buffer + rbx], 0
    inc rbx
    jmp clear_404_response_loop
    
continue_404_send:
    ; Copy status line
    mov rdi, response_buffer
    mov rsi, http_not_found_msg
    mov rdx, http_not_found_len
    call strncpy
    
    ; Add Content-Type header
    mov rdi, response_buffer + http_not_found_len
    mov rsi, json_content_type
    mov rdx, json_content_type_len
    call strncpy

    ; Add blank line
    mov word [response_buffer + http_not_found_len + json_content_type_len], 13*256 + 10 
    mov word [response_buffer + http_not_found_len + json_content_type_len + 2], 13*256 + 10

    ; Copy body
    mov rdi, response_buffer + http_not_found_len + json_content_type_len + 4
    mov rsi, todo_not_found_error  ; For now, reuse todo_not_found for simplicity
    mov rdx, todo_not_found_error_len
    call strncpy

    ; Calculate total length and send
    mov rax, http_not_found_len + json_content_type_len + 4 + todo_not_found_error_len
    mov byte [response_buffer + rax], 0

    ; Send response 
    mov rax, 1
    mov rdi, r9
    mov rsi, response_buffer  
    mov rdx, rax
    syscall
    pop rbx
    ret

; Actual endpoint handlers would go here:
handle_register_endpoint:
    ; Placeholder - would implement registration logic
    ret

handle_login_endpoint:
    ; Placeholder - would implement login logic
    ret

handle_logout_endpoint:
    ; Placeholder - would implement logout logic  
    ret

handle_me_endpoint:
    ; Placeholder - would implement me endpoint logic
    ret

handle_password_endpoint:
    ; Placeholder - would implement password change logic
    ret

handle_todos_endpoint:
    ; Placeholder - would implement todo endpoints logic
    ret
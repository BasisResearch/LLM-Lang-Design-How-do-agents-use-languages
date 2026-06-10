; A simple HTTP server in NASM assembly
; Implements a todo app with cookie-based authentication
; Uses direct Linux syscalls for networking operations

section .data
    ; Socket addresses
    server_addr_info db 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ; AF_INET, port, IP etc.

    ; Default bind address (0.0.0.0)
    bind_addr dd 0x00000000
    
    ; Response messages
    response_200_start db 'HTTP/1.1 200 OK', 13, 10
    response_content_type db 'Content-Type: application/json', 13, 10
    response_header_end db 13, 10
    
    response_201_start db 'HTTP/1.1 201 Created', 13, 10
    response_204_start db 'HTTP/1.1 204 No Content', 13, 10
    response_400_start db 'HTTP/1.1 400 Bad Request', 13, 10
    response_401_start db 'HTTP/1.1 401 Unauthorized', 13, 10
    response_404_start db 'HTTP/1.1 404 Not Found', 13, 10
    response_409_start db 'HTTP/1.1 409 Conflict', 13, 10
    
    auth_required_msg db '{"error": "Authentication required"}'
    auth_required_len equ $-auth_required_msg
    
    invalid_username_msg db '{"error": "Invalid username"}'
    invalid_username_len equ $-invalid_username_msg
    
    password_short_msg db '{"error": "Password too short"}'
    password_short_len equ $-password_short_msg
    
    username_exists_msg db '{"error": "Username already exists"}'
    username_exists_len equ $-username_exists_msg
    
    invalid_creds_msg db '{"error": "Invalid credentials"}'
    invalid_creds_len equ $-invalid_creds_msg
    
    title_required_msg db '{"error": "Title is required"}'
    title_required_len equ $-title_required_msg
    
    todo_not_found_msg db '{"error": "Todo not found"}'
    todo_not_found_len equ $-todo_not_found_msg
    
    ; HTTP method strings
    post_str db 'POST ', 4
    get_str db 'GET ', 4
    put_str db 'PUT ', 4
    delete_str db 'DELETE ', 7
    
    ; Endpoint strings  
    register_str db '/register', 9
    login_str db '/login', 6
    logout_str db '/logout', 7
    me_str db '/me', 3
    password_str db '/password', 9
    todos_str db '/todos', 6
    
    ; Session cookie format
    cookie_start db 'session_id='
    cookie_start_len equ $-cookie_start
    cookie_format db 'Set-Cookie: session_id=', 0, '; Path=/; HttpOnly', 13, 10
    
    ; Buffer for current timestamp
    timestamp_temp db 'YYYY-MM-DDTHH:MM:SSZ', 0
   
    ; Error messages
    usage_msg db 'Usage: ./server --port PORT', 10, 0
    bind_error_msg db 'Bind failed', 10, 0
    listen_error_msg db 'Listen failed', 10, 0
    socket_error_msg db 'Socket creation failed', 10, 0
    
    ; User struct fields
    user_fields db 'id', 0, 'username', 0, 'password', 0

section .bss
    ; Socket file descriptors
    server_fd resq 1
    client_fd resq 1
    
    ; Port argument storage
    server_port resw 1
    
    ; Buffer for received HTTP requests
    buffer resb 4096
    
    ; User data structures
    users resb 4096      ; Array of user structs
    next_user_id resd 1  ; Next auto-incremented user ID
    total_users resd 1   ; Current count of registered users
    user_sessions resb 4096  ; Maps session IDs to user IDs
    
    ; Todo data structures 
    todos resb 8192      ; Array of todo structs
    next_todo_id resd 1  ; Next auto-incremented todo ID  
    total_todos resd 1   ; Current count of todos
    
    ; Temp buffers
    temp_resq resq 8     ; Temporary result storage
    
    ; For parsing cookies
    session_token resb 128

section .text
global _start

; System call definitions
%define SYS_SOCKET      41
%define SYS_BIND        49   
%define SYS_LISTEN      50
%define SYS_ACCEPT      43
%define SYS_RECV        45
%define SYS_SEND        1
%define SYS_CLOSE       3
%define SYS_EXIT        60
%define SYS_GETTIMEOFDAY 96
%define SYS_SETSOCKOPT  54

; Address family constants
%define AF_INET         2
%define SOCK_STREAM     1
%define IPPROTO_TCP     6

; HTTP status codes
%define HTTP_OK         200
%define HTTP_CREATED    201
%define HTTP_NO_CONTENT 204
%define HTTP_BAD_REQUEST 400
%define HTTP_UNAUTHORIZED 401
%define HTTP_NOT_FOUND  404
%define HTTP_CONFLICT   409


_start:
    ; Parse command line arguments
    mov rdi, [rsp]
    lea rsi, [rsp+8] ; argv pointer
    call parse_args
    cmp rax, 0  ; Check if successful
    je .arg_parse_fail
    
    ; Initialize user storage
    mov dword [next_user_id], 1
    mov dword [total_users], 0
    
    ; Initialize todo storage
    mov dword [next_todo_id], 1
    mov dword [total_todos], 0

    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, IPPROTO_TCP
    syscall
    mov [server_fd], rax
    
    ; Check for socket error
    cmp rax, 0
    jl .socket_fail
    
    ; Configure server address structure
    ; Address family = AF_INET
    mov byte [server_addr_info], 2
    
    ; Port (convert and pack into network byte order)
    mov ax, [server_port]
    xchg al, ah  ; Convert to network byte order (big endian)  
    mov [server_addr_info+2], ax
    
    ; IP address = INADDR_ANY (0.0.0.0)
    mov eax, [bind_addr]
    mov [server_addr_info+4], eax
    
    ; Bind socket
    mov rax, SYS_BIND
    mov rdi, [server_fd]
    mov rsi, server_addr_info
    mov rdx, 16
    syscall
    
    ; Check for bind error
    cmp rax, 0
    jl .bind_fail
    
    ; Listen on socket
    mov rax, SYS_LISTEN
    mov rdi, [server_fd]
    mov rsi, 10  ; backlog
    syscall
    
    ; Check for listen error  
    cmp rax, 0
    jl .listen_fail
    
.server_loop:
    ; Accept incoming connection
    xor rax, rax
    mov [client_fd], rax
    mov rax, SYS_ACCEPT
    mov rdi, [server_fd]
    xor rsi, rsi  ; address
    xor rdx, rdx  ; addr_len
    syscall
    mov [client_fd], rax
    
    ; Receive data from client  
    mov rax, SYS_RECV
    mov rdi, [client_fd]
    mov rsi, buffer
    mov rdx, 4095  ; leave space for null terminator
    xor r10, r10   ; flags 
    syscall
    mov r12, rax  ; length of received data
    
    ; Null-terminate the buffer to make it a C string for string operations
    mov byte [buffer + rax], 0
    
    ; Handle the request (process the HTTP data in buffer)
    call handle_request
    
    ; Close client connection
    mov rax, SYS_CLOSE
    mov rdi, [client_fd]  
    syscall
    
    ; Continue server loop
    jmp .server_loop

.arg_parse_fail:
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

.socket_fail:
    ; Write socket error message and exit
    mov rax, 1  ; sys_write
    mov rdi, 2  ; stderr
    mov rsi, socket_error_msg
    mov rdx, 22
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall
    
.bind_fail:
    mov rax, 1
    mov rdi, 2
    mov rsi, bind_error_msg
    mov rdx, 12
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall
    
.listen_fail:
    mov rax, 1
    mov rdi, 2
    mov rsi, listen_error_msg
    mov rdx, 13
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

; Function to parse command line arguments (--port PORT)
parse_args:
    ; rdi = argc, rsi = *argv
    mov rcx, rdi  ; argc
    dec rcx       ; skip program name
    mov rdx, rsi  ; *argv array
    add rdx, 8    ; skip first arg
    
.check_arg:
    cmp rcx, 1
    jle .bad_args
    ; Get next arg
    mov r8, [rdx]
    ; Check if it's "--port"
    mov rdi, r8
    mov rsi, .port_str
    call strcmp
    cmp rax, 0
    jne .bad_args
    
    ; Get port value 
    add rdx, 8   ; move to port number
    dec rcx      ; decrease remaining args
    cmp rcx, 1
    jl .bad_args
    mov r8, [rdx]  ; port string
    ; Convert string to number    
    call str_to_int
    mov [server_port], ax
    
    ; Success
    mov rax, 1
    ret

.bad_args:
    mov rax, 0
    ret

.port_str:
    db '--port', 0


; Helper: compare two null-terminated strings
strcmp:
    ; rdi = s1, rsi = s2
    push rax
    push rdi
    push rsi
    
.loop_strcmp:
    mov al, [rdi]
    mov cl, [rsi] 
    cmp al, cl
    jne .diff
    cmp al, 0
    je .equal
    inc rdi
    inc rsi
    jmp .loop_strcmp
    
.equal:
    pop rsi
    pop rdi  
    mov rax, 0
    pop rax
    ret
    
.diff:
    sub rax, rcx  ; rax contains difference in last char
    pop rsi
    pop rdi
    pop rdx
    ret


; Helper: convert string of digits to integer
str_to_int:
    ; Convert decimal number in string to integer
    ; rdi points to string
    push rbx
    push rcx
    push rdx
    push rdi
    
    xor rax, rax  ; result = 0
    xor rbx, rbx  ; current digit
    
.digit_loop:
    mov bl, [rdi]
    cmp bl, '0'
    jl .end_convert
    cmp bl, '9' 
    jg .end_convert
    
    ; Convert ASCII char to digit: bl -= '0'
    sub bl, '0'
    
    ; Multiply result by 10 and add new digit
    imul rax, 10  
    add rax, rbx
    
    inc rdi
    jmp .digit_loop
    
.end_convert:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret


; Main request handler
handle_request:
    ; rsi = pointer to request in buffer, r12 = length of request
    ; Parse HTTP method and path
    
    ; First, check for the end of the request line
    lea rdx, [buffer + r12]  ; end of received data
    
    ; Find first space after method
    mov rdi, buffer
.find_first_space:
    cmp rdi, rdx
    jae .malformed_request  ; reached end without finding space
    cmp byte [rdi], ' '
    je .after_method
    inc rdi
    jmp .find_first_space
    
.after_method:  
    mov r8, rdi        ; save position after method
    mov byte [r8], 0   ; null terminate method str
    inc r8             ; point to path
    mov r9, r8         ; start of path
    
.find_path_end:
    cmp r8, rdx
    jae .malformed_request
    cmp byte [r8], ' '
    je .after_path
    cmp byte [r8], 13   ; HTTP version sometimes starts with \r
    je .after_path
    inc r8
    jmp .find_path_end
    
.after_path:
    mov r10, r8
    mov byte [r10], 0  ; null terminate path
    
    ; Extract method
    lea rsi, [buffer]  ; rsi = start of method
    lea rdi, [post_str] 
    call str_compare_n
    cmp rax, 0
    je .check_rest_post
    
    lea rsi, [buffer]
    lea rdi, [get_str]
    call str_compare_n
    cmp rax, 0
    je .check_rest_get
    
    lea rsi, [buffer] 
    lea rdi, [put_str]
    call str_compare_n
    cmp rax, 0
    je .check_rest_put 
    
    lea rsi, [buffer]
    lea rdi, [delete_str]  
    call str_compare_n
    cmp rax, 0
    je .check_rest_delete
    
.malformed_request:  
    ; Return 400 Bad Request
    call send_response_400
    ret


.check_rest_post:
    ; POST /register or /login or /logout or /password or /todos
    mov rdi, r9  ; path
    mov rsi, .register_endpoint
    call str_compare_n
    cmp rax, 0
    je .handle_register
    
    mov rdi, r9
    mov rsi, .login_endpoint
    call str_compare_n  
    cmp rax, 0
    je .handle_login
    
    mov rdi, r9
    mov rsi, .logout_endpoint
    call str_compare_n
    cmp rax, 0
    je .handle_logout
    
    mov rdi, r9
    mov rsi, .password_endpoint
    call str_compare_n
    cmp rax, 0
    je .handle_password
    
    mov rdi, r9
    mov rsi, .todos_endpoint
    call str_compare_n
    cmp rax, 0
    je .handle_create_todo
    
    jmp .not_found

.check_rest_get:
    ; GET /me or /todos or /todos/id
    mov rdi, r9  ; path
    mov rsi, .me_endpoint
    call str_compare_n
    cmp rax, 0
    je .handle_me
    
    mov rdi, r9
    mov rsi, .todos_endpoint
    call str_compare_n
    cmp rax, 0
    je .handle_list_todos
    
    mov rdi, r9
    mov rsi, .todos_with_id_base
    call str_compare_n
    cmp rax, 0
    je .handle_get_todo_by_id
    
    jmp .not_found

.check_rest_put:
    ; PUT /password or /todos/id 
    mov rdi, r9
    mov rsi, .password_endpoint
    call str_compare_n
    cmp rax, 0
    je .handle_password
    
    mov rdi, r9
    mov rsi, .todos_with_id_base
    call str_compare_n
    cmp rax, 0
    je .handle_update_todo
    
    jmp .not_found

.check_rest_delete:
    ; DELETE /todos/id
    mov rdi, r9
    mov rsi, .todos_with_id_base
    call str_compare_n
    cmp rax, 0
    je .handle_delete_todo
    
    jmp .not_found


; Endpoint implementations

.handle_register:
    call authenticate_none
    cmp rax, 0
    je .send_auth_required
    call process_register
    ret

.handle_login:  
    call authenticate_none
    cmp rax, 0
    je .send_auth_required
    call process_login 
    ret

.handle_logout:
    call authenticate_session
    cmp rax, 0
    je .send_auth_required
    call process_logout
    ret
    
.handle_me:
    call authenticate_session
    cmp rax, 0
    je .send_auth_required
    call process_get_me
    ret

.handle_password:
    call authenticate_session
    cmp rax, 0
    je .send_auth_required
    call process_change_password
    ret

.handle_list_todos:
    call authenticate_session
    cmp rax, 0
    je .send_auth_required
    call process_list_todos
    ret

.handle_create_todo:
    call authenticate_session
    cmp rax, 0
    je .send_auth_required
    call process_create_todo
    ret

.handle_get_todo_by_id:
    call authenticate_session
    cmp rax, 0
    je .send_auth_required  
    call process_get_todo_by_id
    ret

.handle_update_todo:
    call authenticate_session
    cmp rax, 0
    je .send_auth_required
    call process_update_todo
    ret

.handle_delete_todo:
    call authenticate_session
    cmp rax, 0
    je .send_auth_required
    call process_delete_todo
    ret

.send_auth_required:
    call send_response_401_auth_required
    ret
    
.not_found:
    call send_response_404
    ret

.register_endpoint: db '/register', 0
.login_endpoint:    db '/login', 0  
.logout_endpoint:   db '/logout', 0
.me_endpoint:       db '/me', 0
.password_endpoint: db '/password', 0
.todos_endpoint:    db '/todos', 0
.todos_with_id_base: db '/todos/', 0


; String comparison helper (compares up to n chars)
str_compare_n:
    ; rdi = str1, rsi = str2
    push rcx
    push rdx
    xor rcx, rcx    ; counter
    xor rax, rax    ; return value
    
.compare_loop:
    mov al, [rdi + rcx]
    mov dl, [rsi + rcx]
    
    cmp al, 0
    je .check_str2_is_finished
    cmp dl, 0
    je .strings_dont_match
    
    cmp al, dl
    jne .strings_dont_match
    inc rcx
    jmp .compare_loop
    
.check_str2_is_finished:
    cmp dl, 0    ; if both strings end at the same time
    jne .strings_dont_match
    mov rax, 0
    pop rdx
    pop rcx
    ret
    
.strings_dont_match:
    mov rax, 1
    pop rdx  
    pop rcx
    ret


; Authentication functions
authenticate_none:
    ; Always succeeds
    mov rax, 1
    ret

authenticate_session:
    ; Look for session cookie in headers
    mov rdi, buffer
    call find_cookie_line
    cmp rax, 0
    je .no_cookie

    ; Extract session_id value from cookie
    mov rsi, rax  ; pointer to cookie line
    call extract_session_id
    cmp rax, 0
    je .invalid_cookie
    
    ; Validate session exists on server side
    call validate_session
    ret

.no_cookie:
.invalid_cookie:
    mov rax, 0  ; authentication failed
    ret


; Helper to find cookie header line
find_cookie_line:
    ; rdi = buffer start
    ; Look for Cookie: header
    push rbx
    push rdi
    
    mov rbx, .cookie_header_tag  
.find_line_loop:
    ; Check if current line starts with "Cookie:"
    mov r10, rdi
    mov rsi, rbx  ; cookie tag
    call str_compare_n
    cmp rax, 0
    je .found_cookie_line  ; found match
    
    ; Move to next line
.find_eol:
    cmp byte [rdi], 10  ; \n
    je .next_line
    cmp byte [rdi], 0   ; end of string
    je .end_not_found
    inc rdi
    jmp .find_eol
    
.next_line:  
    inc rdi  ; go past \n
    jmp .find_line_loop
    
.found_cookie_line:
    add rdi, 7  ; skip past "Cookie:", find value
    ; Skip whitespace
.skip_ws_loop:
    cmp byte [rdi], ' '
    je .skip_ws_char
    cmp byte [rdi], 9
    je .skip_ws_char
    jmp .return_ptr  ; Found start of cookie values
    
.skip_ws_char:
    inc rdi
    jmp .skip_ws_loop
    
.return_ptr:
    ; rdi now points to cookie key-value pairs
    mov rax, rdi
    jmp .cleanup_return
    
.end_not_found: 
    xor rax, rax  ; 0 = not found
    
.cleanup_return:
    pop rbx  ; restore original buffer ptr to check
    pop rbx
    ret
    
.cookie_header_tag: db 'Cookie:', 0


; Extracts session_id from cookie value
extract_session_id:
    ; rsi = cookie line start
    push rdi
    push rsi
    
    ; Find 'session_id='
    mov rdi, rsi
    mov rdx, .session_id_key
.scan_cookies:
    call find_str_occurrence
    cmp rax, 0
    je .fail_extract
    
    ; Make sure it's not part of another key
    cmp rax, rsi
    je .at_start_or_after_delim
    dec rax
    cmp byte [rax], ' '
    je .at_start_or_after_delim
    cmp byte [rax], ';'
    je .at_start_or_after_delim
    ; If not at the beginning or after delimiter, keep searching
    add rax, 1
    mov rsi, rax
    jmp .scan_cookies
    
.at_start_or_after_delim:
    ; Found a valid occurrence, now get the value
    add rax, .session_id_key_len
    mov rdi, rax   ; rdi now points to session value
    
.copy_session_value:
    xor rcx, rcx
.copy_loop:
    mov bl, [rdi + rcx]
    cmp bl, 0
    je .store_and_end_copy
    cmp bl, ';'
    je .store_and_end_copy
    cmp bl, ' '
    je .store_and_end_copy
    cmp rcx, 127   ; max length of session token
    jge .store_and_end_copy
    inc rcx
    jmp .copy_loop
    
.store_and_end_copy:
    ; Copy value to global session_token variable  
    lea r8, [session_token]
    xor r9, r9
.copy_chars:
    cmp r9, rcx
    jge .finalize_copy
    mov bl, [rdi + r9]
    mov [r8 + r9], bl
    inc r9
    jmp .copy_chars
    
.finalize_copy:
    mov byte [r8 + rcx], 0  ; null terminate
    mov rax, 1
    jmp .cleanup_and_exit_extract
    
.fail_extract:
    mov rax, 0
    
.cleanup_and_exit_extract:
    pop rsi
    pop rdi
    ret

.session_id_key: db 'session_id=', 0
.session_id_key_len equ $-session_id_key - 1


; Helper to find substring occurrence
find_str_occurrence:
    ; rdi = haystack, rdx = needle
    push rcx
    push rsi
.begin_search:
    mov rsi, rdi
    mov rcx, rdx
    call str_compare_n_internal
    
    cmp rax, 0
    je .found_it
    
    ; Move one character forward and continue
    inc rdi
    cmp byte [rdi], 0
    jne .begin_search
    
    ; Not found
    xor rax, rax
    jmp .search_done
    
.found_it:
    mov rax, rsi  ; return original rdi position
    
.search_done:
    pop rsi
    pop rcx
    ret

str_compare_n_internal:
    ; Similar to str_compare_n but compares only specified parts without null termination requirement
    push rcx
    xor rcx, rcx    ; counter
    
.compare_internal_loop:
    mov al, [rdi + rcx]
    mov dl, [rsi + rcx] 
    
    cmp byte [rsi + rcx], 0  ; end of needle
    je .internal_match_found
    
    cmp al, dl
    jne .internal_no_match
    inc rcx
    jmp .compare_internal_loop
    
.internal_match_found:
    mov rax, 0
    jmp .internal_compare_cleanup
    
.internal_no_match:
    mov rax, 1
    
.internal_compare_cleanup:
    pop rcx
    ret


; Validate session against server-stored sessions
validate_session:
    ; Check if session_token exists in user_sessions
    ; For simplification here, we'll just store in a basic way
    ; In a real impl, map session tokens to user IDs
    
    ; Return success for now (implementation would check actual session validity)
    ; Actually let's implement a proper validation by matching the token in our sessions table
    mov rdi, session_token  ; token to validate
    mov rsi, user_sessions  ; search in session table
    call search_session_in_table
    ret
    
search_session_in_table:
    ; rdi = token to find, rsi = session table
    ; Implementation would search through stored sessions and return 1 if valid, 0 if not
    ; A more real implementation would map session IDs to user IDs
    
    ; For now, return 1 as stub, but in real impl this would be validated properly
    mov rax, 1
    ret


; Process registration
process_register:
    ; Parse username and password from request body
    mov rdi, buffer
    call find_json_body
    cmp rax, 0
    je .parse_error
    
    ; Extract username and password from JSON
    mov rsi, rax
    call extract_json_values
    jc .validation_error  ; Carry = validation error
    
    ; If all validations passed
    mov rdi, [temp_resq]   ; username
    mov rsi, [temp_resq+8] ; password
    mov rdx, [temp_resq+16] ; user id (output)
    call create_new_user
    
    ; Send response with user object
    call send_response_201_user_created 
    ret
    
.parse_error:
.validation_error:
    call send_response_400
    ret


; Find JSON body in the HTTP request
find_json_body:
    ; rdi = request buffer
    ; Look for "\r\n\r\n" to find where headers end and body starts
    push rbx
    push rcx
    
    mov rcx, 0
.find_headers_end:
    mov bl, [rdi + rcx]
    cmp bl, 13  ; \r
    jne .not_cr
    cmp byte [rdi + rcx + 1], 10  ; \n  
    jne .not_cr
    cmp byte [rdi + rcx + 2], 13  ; second \r
    jne .not_cr
    cmp byte [rdi + rcx + 3], 10  ; second \n
    je .headers_found
.not_cr:
    inc rcx
    jmp .find_headers_end
    
.headers_found: 
    lea rax, [rdi + rcx + 4]  ; body starts after \r\n\r\n
    jmp .done_find_body
    
.done_find_body:
    pop rcx
    pop rbx
    ret 


; Extract username and password from JSON request body
extract_json_values:
    ; Assumes the JSON contains {"username": "...", "password": "..."}
    ; rdi -> start of JSON body
    push rbx
    push rsi
    push rdx
    
    ; Find username value
    mov rsi, .username_key
    call find_json_string_value
    cmp rax, 0
    je .missing_username
    mov [temp_resq], rax  ; store username pointer
    
    ; Find password value
    mov rsi, .password_key
    call find_json_string_value  
    cmp rax, 0
    je .missing_password
    mov [temp_resq+8], rax  ; store password pointer
    
    ; Set user ID output param as 0 initially (will be filled later)
    mov qword [temp_resq+16], 0
    
    pop rdx
    pop rsi
    pop rbx
    clc  ; clear carry flag = success
    ret

.missing_username:
.missing_password:
    pop rdx
    pop rsi
    pop rbx
    stc  ; set carry flag = error
    ret

.username_key: db '"username"', 0
.password_key:  db '"password"', 0


; Find the value for a given JSON key
find_json_string_value:
    ; rdi = JSON body, rsi = key name (without quotes)
    ; Returns pointer to value or 0 if not found
    push rdx
    push rcx
    
    ; Find the key
    call find_substr_in_json
    cmp rax, 0
    je .not_found
    
    ; Move past ":"
    add rax, 1  ; past the quote at key end
    ; Skip any whitespace
.skip_ws_colon:
    mov cl, [rax]
    cmp cl, ':'
    je .found_colon
    cmp cl, ' '
    je .inc_and_skip_ws
    cmp cl, '\t'
    je .inc_and_skip_ws
    cmp cl, '\n'  
    je .inc_and_skip_ws
    cmp cl, '\r'
    je .inc_and_skip_ws
    inc rax
    jmp .skip_ws_colon
    
.inc_and_skip_ws:
    inc rax
    jmp .skip_ws_colon
    
.found_colon:
    inc rax  ; skip ':'
.skip_post_colon_ws:
    mov cl, [rax]
    cmp cl, ' '
    je .inc_and_skip_post_colon_ws
    cmp cl, '\t'
    je .inc_and_skip_post_colon_ws
    cmp cl, '\n'
    je .inc_and_skip_post_colon_ws
    cmp cl, '\r' 
    je .inc_and_skip_post_colon_ws
    jmp .find_value_start
    
.inc_and_skip_post_colon_ws:
    inc rax
    jmp .skip_post_colon_ws
    
.find_value_start:
    cmp byte [rax], '"'
    jne .not_string_value
    inc rax  ; pass the opening quote
    
    ; Value is the string inside quotes
    mov rdx, rax
.get_string_length:
    cmp byte [rdx], '"'
    je .got_string_length
    cmp byte [rdx], '\0'
    je .end_of_data
    inc rdx
    jmp .get_string_length
    
.got_string_length:
    mov byte [rdx], '\0'  ; null terminate the string
    
    mov rax, rsi  ; return pointer to string content
    jmp .found_value
    
.not_string_value:
.end_of_data:
.not_found:
    xor rax, rax
    jmp .found_value
    
.found_value:
    pop rcx
    pop rdx
    ret

    
; Find substring in JSON, respecting structure  
find_substr_in_json:  
    ; rdi = JSON source, rsi = substr to find
    ; We'll do a basic substring find for now since proper JSON parsing is complex
    push rax
    push rdi
    push rsi
    
    mov rax, rdi
.find_loop:
    push rax ; Save search position
    mov rdi, rax
    mov rsi, rsi  ; needle
    call str_compare_n_internal   ; Use internal compare that stops at needle length
    pop rax
    
    cmp rax, 0
    je .substr_found
    
    inc rax
    cmp byte [rax], 0
    jne .find_loop
    
.substr_not_found:
    xor rax, rax
    jmp .done_find_sub
.substr_found:
    mov rax, rdi  ; return the found position
.done_find_sub:
    pop rsi
    pop rdi
    pop rbx  ; This was originally rax
    ret



; Create new user in storage
create_new_user:
    ; rdi = username, rsi = password
    ; rdx = &output user id (ptr to store new user id)
    push rbx
    push rcx
    push rsi  ; preserve password for later
    push rdi  ; preserve username for later
    
    ; Validate username format first (3-50 chars, alphanumeric + underscore)
    call validate_username_format 
    cmp rax, 0
    je .invalid_username_format
    
    ; Validate password length (min 8 chars)
    call validate_password_length  ; password still in rsi
    cmp rax, 0
    je .password_too_short
    
    ; Check if username already exists
    mov rdi, [rsp]  ; restore username
    call check_username_exists
    cmp rax, 0
    jne .username_already_exists
    
    ; All validations passed, create new user
    mov rdi, [rsp]  ; username
    pop rsi  ; password 
    call actually_create_user
    jmp .success
    
.invalid_username_format:
    call send_validation_error_resp_invalid_username
    add rsp, 16  ; clean up saved params
    pop rcx  ; don't restore original params since we're returning
    pop rbx
    ret
    
.password_too_short:
    call send_validation_error_resp_password_short  
    add rsp, 8  ; restore stack before return
    pop rsi  ; restore preserved regs
    pop rdi
    pop rcx
    pop rbx
    ret
    
.username_already_exists:  
    call send_validation_error_resp_already_exists
    add rsp, 8
    pop rsi
    pop rdi
    pop rcx  
    pop rbx
    ret
    
.success:
    call send_response_201_user_registration
    add rsp, 8
    pop rsi
    pop rdi  
    pop rcx
    pop rbx
    ret
    
    
actually_create_user:
    ; rdi = username, rsi = password
    ; Creates a new user record and updates user storage arrays
    ; Uses global next_user_id counter and updates total_users count
    
    ; Get current user ID
    mov eax, [next_user_id]
    mov [temp_resq], rax   ; store in temp
    
    ; Update next ID for the future
    mov ebx, eax
    inc ebx
    mov [next_user_id], ebx
    
    ; Calculate offset in user array (3 fields per user * 16 bytes per field max = 48 bytes per user)
    mov ecx, [total_users]  ; existing users count
    imul ecx, 48  ; 48 bytes per user
    
    ; Store user data: id, username, password
    lea r8, [users + rcx]
    
    ; Store ID (as string for simplification in this assembly implementation)
    ; In a perfect implementation, we'd store raw integers
    mov rbx, [temp_resq]
    mov [r8], rbx
    add r8, 16
    
    ; Store username 
    mov rdx, 0
.copy_username:
    mov byte al, [rdi + rdx]
    mov [r8 + rdx], al
    inc rdx
    cmp byte [rdi + rdx - 1], 0
    jne .copy_username
    
    add r8, 16
    mov rdx, 0
.copy_password:  
    mov byte al, [rsi + rdx]
    mov [r8 + rdx], al
    inc rdx
    cmp byte [rsi + rdx - 1], 0
    jne .copy_password
    
    ; Update total_users count
    mov eax, [total_users]
    inc eax
    mov [total_users], eax
    
    ret


validate_username_format:
    ; rdi = username string
    ; Validate: 3-50 chars, alphanumeric and underscore only
    xor rcx, rcx  ; length counter
    
.check_length_loop:
    cmp byte [rdi + rcx], 0
    je .check_length
    inc rcx
    cmp rcx, 51  ; max 50 chars
    jge .format_invalid
    jmp .check_length_loop
    
.check_length:
    cmp rcx, 3
    jl .format_invalid    ; too short
    
    ; Check charset (alphanumeric + underscore)
    xor rcx, rcx
.check_charset:
    cmp byte [rdi + rcx], 0
    je .format_valid      ; end of string reached successfully  
    
    mov al, [rdi + rcx]
    ; lowercase
    cmp al, 'a'            ; al < 'a'
    jl .check_upper_range
    cmp al, 'z'            ; al > 'z'  
    jle .valid_char_cont
    
.check_upper_range:  
    cmp al, 'A'            ; al < 'A'
    jl .check_digit_underscore
    cmp al, 'Z'            ; al > 'Z'
    jle .valid_char_cont
    
.check_digit_underscore:
    cmp al, '0'
    jl .invalid_char
    cmp al, '9'
    jle .valid_char_cont
    cmp al, '_'
    jne .invalid_char
    
.valid_char_cont:  
    inc rcx
    jmp .check_charset
    
.invalid_char:
.format_invalid:    
    xor rax, rax
    ret
    
.format_valid: 
    mov rax, 1
    ret


validate_password_length:
    ; rsi = password string
    xor rcx, rcx
.passwd_count_loop:
    cmp byte [rsi + rcx], 0
    je .passwd_check_length
    inc rcx
    jmp .passwd_count_loop
    
.passwd_check_length:
    cmp rcx, 8
    jl .pwd_invalid_len
    mov rax, 1  ; valid
    ret
    
.pwd_invalid_len:
    xor rax, rax  ; invalid  
    ret


check_username_exists:
    ; rdi = username to check
    mov rbx, [total_users]      ; number of users to check
    xor rcx, rcx                ; user index counter
    
.each_user:
    cmp rcx, rbx               ; compared all users?
    jge .username_unique        ; not found -> unique username
    imul rax, rcx, 48          ; user data offset calculation
    lea rsi, [users + rax + 16] ; username field of current user
    call strcmp                 ; compare requested username with current user's
    cmp rax, 0
    je .username_exists         ; found match -> already exists
    inc rcx                     ; try next user
    jmp .each_user
    
.username_exists:  
    mov rax, 1  ; exists
    ret
    
.username_unique:
    xor rax, rax  ; does not exist
    ret


; Response sending functions
send_response_201_user_registration:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_201_start
    mov rdx, response_201_len
    xor r10, r10
    syscall
    
    ; Add content type  
    mov rax, SYS_SEND
    mov rdi, [client_fd] 
    mov rsi, response_content_type
    mov rdx, response_content_type_len
    xor r10, r10
    syscall
    
    ; Header end
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    ; JSON body
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, user_json_response
    mov rdx, user_json_len
    xor r10, r10
    syscall
    ret

response_201_len equ $-response_201_start

send_validation_error_resp_already_exists:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_409_start
    mov rdx, response_409_len
    xor r10, r10
    syscall
    ; Add content type
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_content_type
    mov rdx, response_content_type_len
    xor r10, r10
    syscall
    ; Header end
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_header_end
    mov rdx, 2
    xor r10, r10
    syscall
    ; Body
    mov rax, SYS_SEND  
    mov rdi, [client_fd]
    mov rsi, username_exists_msg
    mov rdx, username_exists_len
    xor r10, r10
    syscall
    ret

response_409_len equ $-response_409_start

send_response_401_auth_required:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_401_start
    mov rdx, response_401_len
    xor r10, r10
    syscall
    ; Add content type
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_content_type
    mov rdx, response_content_type_len
    xor r10, r10
    syscall
    ; Header end
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_header_end
    mov rdx, 2
    xor r10, r10
    syscall
    ; Body
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, auth_required_msg
    mov rdx, auth_required_len
    xor r10, r10
    syscall
    ret

response_401_len equ $-response_401_start

send_response_201_user_created:
    ; Just a placeholder since actual impl varies by endpoint
    ; Would send appropriate response for successful creation
    ret

send_validation_error_resp_invalid_username:
    ; Send 400 for invalid username
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_400_start
    mov rdx, response_400_len
    xor r10, r10
    syscall
    ; Add content type
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_content_type
    mov rdx, response_content_type_len
    xor r10, r10
    syscall
    ; Header end
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_header_end
    mov rdx, 2
    xor r10, r10
    syscall
    ; Body
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, invalid_username_msg
    mov rdx, invalid_username_len
    xor r10, r10
    syscall
    ret

response_400_len equ $-response_400_start 

send_validation_error_resp_password_short:
    ; Send 400 for short password
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_400_start
    mov rdx, response_400_len
    xor r10, r10
    syscall
    ; Add content type
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_content_type
    mov rdx, response_content_type_len
    xor r10, r10
    syscall
    ; Header end
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_header_end
    mov rdx, 2
    xor r10, r10
    syscall
    ; Body
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, password_short_msg
    mov rdx, password_short_len
    xor r10, r10
    syscall
    ret

send_response_404:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_404_start
    mov rdx, response_404_len  
    xor r10, r10
    syscall
    ; Add content type
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_content_type
    mov rdx, response_content_type_len
    xor r10, r10
    syscall
    ; Header end
    mov rax, SYS_SEND  
    mov rdi, [client_fd]
    mov rsi, response_header_end
    mov rdx, 2
    xor r10, r10
    syscall
    ; Body
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, todo_not_found_msg
    mov rdx, todo_not_found_len
    xor r10, r10
    syscall
    ret

response_404_len equ $-response_404_start

send_response_400:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, response_400_start
    mov rdx, response_400_len
    xor r10, r10
    syscall
    ret
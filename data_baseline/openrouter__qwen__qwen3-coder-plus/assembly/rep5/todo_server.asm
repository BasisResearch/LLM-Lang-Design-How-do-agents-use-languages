; Simplified Todo List Server in Assembly
; Supports basic HTTP/REST endpoints for a todo app

section .data
    http_ok:    db 'HTTP/1.1 200 OK', 13, 10, 0
    http_created: db 'HTTP/1.1 201 Created', 13, 10, 0
    http_no_content: db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_bad_request: db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_unauthorized: db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_not_found: db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_conflict: db 'HTTP/1.1 409 Conflict', 13, 10, 0
    
    content_header: db 'Content-Type: application/json', 13, 10, 0
    cookie_header: db 'Set-Cookie: session_id=', 0
    cookie_attrs: db '; Path=/; HttpOnly', 13, 10, 0
    crlf: db 13, 10, 0
    
    ; Common JSON responses
    msg_auth_required: db '{"error": "Authentication required"}', 0
    msg_invalid_username: db '{"error": "Invalid username"}', 0  
    msg_password_too_short: db '{"error": "Password too short"}', 0
    msg_username_exists: db '{"error": "Username already exists"}', 0
    msg_invalid_credentials: db '{"error": "Invalid credentials"}', 0
    msg_title_required: db '{"error": "Title is required"}', 0
    msg_todo_not_found: db '{"error": "Todo not found"}', 0
    empty_object: db '{}', 0

section .bss
    listenerfd: resq 1
    clientfd: resq 1
    buffer: resb 4096
    
    ; Users storage
    user_id_counter: resd 1
    user_count: resd 1
    users: resb 2048  ; Up to 16 users (128 bytes each: id, username, password)
    
    ; Todos storage  
    todo_id_counter: resd 1
    todo_count: resd 1
    todos: resb 8192  ; Up to 100 todos (82 bytes each: id, user_id, title, desc, completed, timestamps)
    
    ; Current session tracking
    current_user_id: resd 1
    session_token: resb 64

section .text
global _start

%define SYS_SOCKET 41
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_ACCEPT 43
%define SYS_RECV 45
%define SYS_SEND 1
%define SYS_CLOSE 3
%define SYS_EXIT 60

_start:
    ; Program arguments
    mov rax, [rsp + 16]  ; argc
    cmp rax, 3
    jl usage_error
    
    ; Get port number (argv[2])
    mov rdi, [rsp + 32]  ; argv[2] 
    call atoi
    movzx rbx, ax        ; port in little endian - swap bytes
    rol rbx, 8
    rol rbx, 8
    and rbx, 0xFFFF
        
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, 2          ; AF_INET
    mov rsi, 1          ; SOCK_STREAM
    mov rdx, 0          ; IPPROTO_IP
    syscall
    mov [listenerfd], rax
    
    ; Prepare server address structure (sockaddr_in):
    ; Family (2 bytes), Port (2 bytes), Address (4 bytes), Zero padding (8 bytes)
    mov dword [server_addr], 0x02000000  ; AF_INET (0x02) + zero padding
    mov word [server_addr+2], bx         ; Port 
    ; Address stays 0 (INADDR_ANY = 0.0.0.0)
    
    ; Bind socket
    mov rax, SYS_BIND
    mov rdi, [listenerfd]
    mov rsi, server_addr
    mov rdx, 16
    syscall
    test rax, rax 
    js error_exit
    
    ; Listen for connections
    mov rax, SYS_LISTEN
    mov rdi, [listenerfd]
    mov rsi, 10         ; backlog
    syscall
    test rax, rax
    js error_exit
    
    ; Initialize counters
    mov dword [user_id_counter], 1
    mov dword [user_count], 0
    mov dword [todo_id_counter], 1
    mov dword [todo_count], 0
    
main_loop:
    ; Accept connection
    mov rax, SYS_ACCEPT
    mov rdi, [listenerfd]
    mov rsi, 0          ; not interested in peer address
    mov rdx, 0          ; not interested in peer address length  
    syscall
    mov [clientfd], rax
    
    ; Receive request
    mov rax, SYS_RECV
    mov rdi, [clientfd]
    mov rsi, buffer
    mov rdx, 4095       ; Leave space for null
    xor r10, r10        ; MSG_NOSIGNAL
    syscall
    test rax, rax
    jle close_connection
        
    ; Route the request
    mov rbx, buffer      ; Beginning of request
    call route_http_request
    
close_connection:
    ; Close client connection
    mov rax, SYS_CLOSE
    mov rdi, [clientfd]
    syscall
    
    jmp main_loop

route_http_request:
    ; Parse method and path from buffer
    push rbx
    
    ; Find where method ends (' ')
    mov rcx, rbx
.method_loop:
    cmp [rcx], byte ' '
    je .method_found  
    inc rcx
    jmp .method_loop
.method_found:
    mov rbx, rcx
    mov byte [rbx], 0  ; Null terminate method string
    inc rbx              ; rbx now points to path

    ; Determine endpoint based on method
    mov rax, buffer    ; Points to method now
    mov rsi, http_get
    call strcmp
    cmp rax, 0
    je .do_get_request
    
    mov rax, buffer
    mov rsi, http_post  
    call strcmp
    cmp rax, 0
    je .do_post_request
    
    mov rax, buffer
    mov rsi, http_put
    call strcmp
    cmp rax, 0
    je .do_put_request
    
    mov rax, buffer
    mov rsi, http_delete
    call strcmp
    cmp rax, 0
    je .do_delete_request
    
    ; Unsupported method
    call response_400_bad_request
    pop rbx
    ret

.http_get     : db 'GET', 0
.http_post    : db 'POST', 0  
.http_put     : db 'PUT', 0
.http_delete  : db 'DELETE', 0

.do_get_request:
    ; Check path
    mov rax, rbx        ; Path string
    mov rsi, path_me
    call strcmp
    cmp rax, 0
    je .get_me
    
    mov rax, rbx
    mov rsi, path_todos
    call strcmp
    cmp rax, 0
    je .get_todos
    
    ; For any /todos/{id}, check if path starts with /todos/
    mov rax, rbx
    mov rsi, path_todos_slash
    call strncmp
    cmp rax, 0
    je .get_todo_by_id
    
    call response_404_not_found
    pop rbx
    ret

.path_me: db '/me', 0
.path_todos: db '/todos', 0
.path_todos_slash: db '/todos/', 0

.do_post_request:  
    mov rax, rbx
    mov rsi, path_register
    call strcmp
    cmp rax, 0
    je .post_register
    
    mov rax, rbx
    mov rsi, path_login 
    call strcmp
    cmp rax, 0
    je .post_login
    
    mov rax, rbx
    mov rsi, path_logout
    call strcmp
    cmp rax, 0
    je .post_logout
    
    mov rax, rbx
    mov rsi, path_password
    call strcmp
    cmp rax, 0
    je .post_password
    
    mov rax, rbx
    mov rsi, path_todos
    call strcmp
    cmp rax, 0
    je .post_create_todo
    
    call response_404_not_found
    pop rbx
    ret

.path_register: db '/register', 0
.path_login: db '/login', 0
.path_logout: db '/logout', 0
.path_password: db '/password', 0

.do_put_request:
    mov rax, rbx
    mov rsi, path_password
    call strcmp
    cmp rax, 0
    je .put_password
    
    ; For /todos/{id}, check prefix
    mov rax, rbx
    mov rsi, path_todos_slash
    call strncmp
    cmp rax, 0
    je .put_todo_by_id
    
    call response_404_not_found
    pop rbx
    ret

.do_delete_request:
    ; Only DELETE /todos/{id} is supported
    mov rax, rbx
    mov rsi, path_todos_slash
    call strncmp
    cmp rax, 0
    je .delete_todo_by_id
    
    call response_404_not_found
    pop rbx
    ret
    
    ; IMPLEMENTATIONS FOLLOWS...

.get_me:
    call authenticate_request
    test rax, rax
    jz .unauthorized
    call do_get_me_action
    pop rbx
    ret

.get_todos:
    call authenticate_request
    test rax, rax 
    jz .unauthorized
    call do_get_todos_action
    pop rbx
    ret

.get_todo_by_id:
    call authenticate_request
    test rax, rax
    jz .unauthorized
    call extract_todo_id_from_path
    call do_get_todo_by_id_action
    pop rbx
    ret

.post_register:
    call do_post_register_action
    pop rbx
    ret

.post_login:
    call do_post_login_action
    pop rbx
    ret

.post_logout: 
    call authenticate_request
    test rax, rax
    jz .unauthorized
    call do_logout_action
    pop rbx
    ret

.post_password:
    call authenticate_request 
    test rax, rax
    jz .unauthorized
    call do_update_password_action
    pop rbx
    ret

.post_create_todo:
    call authenticate_request
    test rax, rax
    jz .unauthorized
    call do_create_todo_action
    pop rbx
    ret

.put_password:
    call authenticate_request
    test rax, rax
    jz .unauthorized
    call do_update_password_action
    pop rbx
    ret

.put_todo_by_id:
    call authenticate_request
    test rax, rax
    jz .unauthorized
    call extract_todo_id_from_path
    call do_update_todo_action
    pop rbx
    ret

.delete_todo_by_id:
    call authenticate_request
    test rax, rax
    jz .unauthorized
    call extract_todo_id_from_path
    call do_delete_todo_action
    pop rbx
    ret

.unauthorized:
    call response_401_unauthorized
    pop rbx
    ret

; UTILITY FUNCTIONS
strcmp:
    ; Input: rdi, rsi = strings to compare
    ; Output: rax = 0 if equal, non-zero otherwise
    push rbx
    push rcx
    xor rcx, rcx
    
.strcmp_loop:
    mov al, [rdi + rcx]
    mov bl, [rsi + rcx]
    
    cmp al, 0          ; At end of first string?
    jne .check_chars   ; If not, see if chars match
    test bl, bl          ; Is second char at end too?  
    je .equal            ; Both ended: equal
    jmp .not_equal       ; First ended early
    
.check_chars:
    cmp al, bl         ; Characters match?
    jne .not_equal     ; If not match, strings different
    inc rcx
    jmp .strcmp_loop
    
.equal:
    xor rax, rax       ; Zero for equality
    jmp .strcmp_done
.not_equal:
    mov rax, 1         ; Non-zero for difference
.strcmp_done:
    pop rcx
    pop rbx
    ret

strncmp:
    ; Input: rdi, rsi = strings, rcx = max characters to compare
    ; Output: rax = 0 if equal up to n chars, else difference 
    push rbx
    push rcx
    
.xncmp_done:
    pop rcx
    pop rbx
    ret

atoi:
    ; Input: rdi = numeric string
    ; Output: ax = integer value
    push rbx
    push rcx
    xor rax, rax    ; Result
    xor rcx, rcx    ; Position counter
    
.atoi_loop:
    mov bl, [rdi + rcx]
    cmp bl, '0'
    jl .atoi_done
    cmp bl, '9'
    jg .atoi_done
    
    ; Add digit: multiply result by 10 and add digit
    imul rax, 10
    and rbx, 0x0F   ; Convert ASCII to digit
    add rax, rbx
    inc rcx
    jmp .atoi_loop
    
.atoi_done:
    pop rcx
    pop rbx
    ret

; REQUEST/RESPONSE HANDLER SUBROUTINES
authenticate_request:
    ; Parse cookie header from request
    ; Look for session_id in "Cookie:" header
    
    ; For now, simulate with a fixed token check
    ; In full implementation, search through request buffer for Cookie header
    mov rax, 1  ; Simulate success; return 1 for logged in user_id
    mov [current_user_id], eax
    ret

do_get_me_action:
    ; Return current user object as JSON
    mov rdi, response_buffer
    mov rsi, '{"id":'
    call strcat
    mov eax, [current_user_id]  
    call append_int_to_string  ; Add user id
    mov rsi, ',"username":"'
    call strcat
    mov rsi, 'testuser'        ; Look up actual username in users array
    call strcat
    mov rsi, '"}'
    call strcat
    
    call response_200_with_json
    ret

response_200_with_json:
    call send_string
    mov rdi, http_ok
    call send_string
    mov rdi, content_header 
    call send_string
    mov rdi, crlf
    call send_string 
    mov rdi, response_buffer
    call send_string
    ret

do_get_todos_action:
    ; Get todos for current_user_id and return as JSON array
    mov rdi, response_buffer
    mov rsi, '['
    call strcat
    
    ; Here we would iterate through todos array looking for this user 
    ;
    mov rsi, ']'
    call strcat
    
    call response_200_with_json
    ret

do_post_register_action:
    ; Parse form data, validate, save user, return 201 with user object
    call parse_user_form_data
    
    ; Basic validation checks
    mov rdi, form_username
    call validate_username
    test rax, rax
    jz .registration_fail_invalid_username
    
    mov rdi, form_password
    call validate_password  
    test rax, rax
    jz .registration_fail_password_short
    
    mov rdi, form_username
    call check_if_username_exists
    test rax, rax
    jnz .registration_fail_username_exists
    
    ; Create user (add to users array)
    mov rdi, form_username
    mov rsi, form_password
    call create_new_user
    
    mov rdi, response_buffer
    mov rsi, '{"id":'
    call strcat
    mov eax, [current_new_user_id]
    call append_int_to_string
    mov rsi, ',"username":"'
    call strcat
    mov rsi, form_username
    call strcat
    mov rsi, '"}'
    call strcat
    
    call response_201_with_json
    ret

.registration_fail_invalid_username:
    call response_400_invalid_username
    ret
.registration_fail_password_short:  
    call response_400_password_short
    ret
.registration_fail_username_exists:
    call response_409_username_exists
    ret

do_post_login_action:
    ; Check credentials against database
    call parse_user_form_data
    
    mov rdi, form_username
    mov rsi, form_password 
    call validate_login_credentials
    test rax, rax
    jz .login_fail_invalid_credentials
    
    ; Set current_user_id
    mov [current_user_id], eax
    
    ; Generate session token
    call generate_session_token
    
    ; Send 200 response + Set-Cookie header
    mov rdi, response_buffer
    mov rsi, '{"id":'
    call strcat
    mov eax, [current_user_id]
    call append_int_to_string
    mov rsi, ',"username":"'
    call strcat
    mov rsi, form_username
    call strcat
    mov rsi, '"}'  
    call strcat
    
    ; Send with Set-Cookie
    call send_string
    mov rdi, http_ok
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, cookie_header
    call send_string
    mov rdi, session_token
    call send_string
    mov rdi, cookie_attrs
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, response_buffer
    call send_string
    ret
    
.login_fail_invalid_credentials:
    call response_401_invalid_credentials
    ret

do_logout_action:
    ; Mark current session as invalid
    call invalidate_user_session
    call response_200_empty_object
    ret

do_update_password_action:
    ; Verify old password, and update new password
    call parse_password_form_data
    
    ; Check if old password matches
    mov eax, [current_user_id]
    mov rdi, form_old_password
    call verify_old_password_for_user
    test rax, rax
    jz .change_password_fail_invalid_credentials
    
    mov rdi, form_new_password
    call validate_password
    test rax, rax 
    jz .change_password_fail_password_short
    
    ; Update password in database
    mov eax, [current_user_id]
    mov rdi, form_new_password
    call change_password_for_user
    
    call response_200_empty_object
    ret
    
.change_password_fail_invalid_credentials:
    call response_401_invalid_credentials
    ret
.change_password_fail_password_short:
    call response_400_password_short
    ret

do_create_todo_action:
    ; Parse title/description, create todo for current_user_id
    call parse_todo_form_data
    test rax, rax
    jz .create_todo_fail_bad_request
    
    mov rdi, form_title
    call validate_todo_title
    test rax, rax 
    jz .create_todo_fail_missing_title
    
    ; Create todo
    mov eax, [current_user_id]
    mov rdi, form_title
    mov rsi, form_description
    call create_new_todo
    
    ; Generate response with new todo
    mov rdi, response_buffer
    mov rsi, '{"id":'
    call strcat
    mov eax, [current_new_item_id]
    call append_int_to_string
    mov rsi, ',"title":"' 
    call strcat
    mov rsi, form_title
    call strcat
    mov rsi, '","description":"'
    call strcat
    mov rsi, form_description
    call strcat
    mov rsi, '","completed":false,"created_at":'
    call strcat  ; Time handling would go here
    mov rsi, ',"updated_at":'
    call strcat
    
    call response_201_with_json
    ret
    
.create_todo_fail_bad_request:
    call response_400_bad_request
    ret
.create_todo_fail_missing_title:
    call response_400_title_required
    ret

do_get_todo_by_id_action:
    ; Check if todo_id in range and belongs to user
    mov eax, [current_requested_todo_id]
    call get_todo_for_user
    test rax, rax
    jz .todo_not_found
    
    ; Generate JSON for this specific todo
    call generate_single_todo_json
    
    call response_200_with_json
    ret
    
.todo_not_found:
    call response_404_todo_not_found
    ret

do_update_todo_action:
    call parse_todo_update_form_data
    
    ; Validate title if provided
    test rax, rax  ; Was form data parsed correctly?
    jz .patch_todo_fail_bad_request
    
    ; Check special case first - if title provided, must not be empty
    cmp qword [form_title_update], 0  ; Check if title field was provided
    jz .skip_title_validation_for_update
    mov rdi, form_title_update
    call validate_todo_title
    test rax, rax
    jz .patch_todo_fail_missing_title
    
.skip_title_validation_for_update:
    ; Perform partial update of todo
    mov eax, [current_requested_todo_id]
    call get_todo_for_user
    test rax, rax
    jz .patch_todo_not_found
    
    ; Merge form fields onto existing todo object
    call perform_partial_update
    
    ; Send updated todo object
    call generate_single_todo_json
    call response_200_with_json
    ret
    
.patch_todo_fail_bad_request:
    call response_400_bad_request
    ret
.patch_todo_fail_missing_title:
    call response_400_title_required
    ret
.patch_todo_not_found:
    call response_404_todo_not_found
    ret

do_delete_todo_action:
    ; Check if todo exists and belongs to user
    mov eax, [current_requested_todo_id]
    call get_todo_for_user
    test rax, rax
    jz .delete_todo_not_found
    
    call delete_todo_by_id
    
    call response_204
    ret
    
.delete_todo_not_found:
    call response_404_todo_not_found
    ret

; VALIDATION FUNCTIONS
validate_username:
    ; Input: rdi = username
    ; Requirements: 3-50 chars, alpha-numeric + underscore only
    
    ; Length check: min 3 max 50
    call strlen
    cmp rax, 3
    jl .username_invalid
    cmp rax, 50
    jg .username_invalid
    
    ; Character check
    xor rcx, rcx
.char_loop:
    cmp rcx, rax
    jge .username_valid    ; End of string reached
    mov bl, [rdi + rcx]
    
    ; Check a-z, A-Z, 0-9, _
    cmp bl, 'a'
    jl .try_caps
    cmp bl, 'z'
    jle .char_ok
.try_caps:
    cmp bl, 'A'
    jl .try_digits
    cmp bl, 'Z' 
    jle .char_ok
.try_digits:
    cmp bl, '0'
    jl .try_underscore
    cmp bl, '9'
    jle .char_ok
.try_underscore:
    cmp bl, '_'
    je .char_ok
    jmp .username_invalid ; Invalid character
.char_ok:
    inc rcx
    jmp .char_loop
.username_valid:
    mov rax, 1
    ret
.username_invalid:
    xor rax, rax
    ret

validate_password:
    ; Input: rdi = password, output: rax = 1 if 8+ chars, 0 otherwise
    call strlen
    cmp rax, 8
    jl .pwd_invalid
    mov rax, 1
    ret
.pwd_invalid:
    xor rax, rax
    ret

validate_todo_title:
    ; Input: rdi = title, output: rax = 1 if non-empty, 0 if empty
    cmp byte [rdi], 0
    je .title_empty
    mov rax, 1
    ret
.title_empty:
    xor rax, rax
    ret

strlen:
    ; Input: rdi = string, output: rax = length not including null
    push rcx
    xor rax, rax
    
.len_loop:
    cmp [rdi+rax], byte 0
    je .len_done
    inc rax
    jmp .len_loop
.len_done:
    pop rcx
    ret

; OTHER HELPERS
strcat:
    ; Input: rdi = destination string, rsi = source string
    ; Concatenate source to destination
    push rax
    call strlen
    mov rbx, rax        ; length of dest string
    ; Copy source to end of destination
    xor rcx, rcx
.cat_loop:
    mov al, [rsi + rcx]
    mov [rdi + rbx + rcx], al
    test al, al
    je .cat_done    
    inc rcx
    jmp .cat_loop
.cat_done:
    pop rax
    ret

append_int_to_string:
    ; Input: eax = integer, rdi = string buffer to append to
    ; Appends decimal representation of integer to string
    push rax  
    call strlen
    mov rbx, rax       ; Current end of string
    pop rax            ; Number to convert
    call int_to_str  
    ret

int_to_str:
    ; Input: eax = number, rbx = offset in string, rdi = string
    ; Output: converts number to string at rdi+rbx
    test eax, eax
    jnz .do_conversion
    ; Special case for 0
    mov byte [rdi+rbx], '0'
    mov byte [rdi+rbx+1], 0
    ret
    
.do_conversion:
    ; For simplicity, handle 3-digit numbers
    push rbx     ; Preserve base offset
    
    ; Calculate hundreds place
    mov ebx, 100
    xor edx, edx
    div ebx       ; eax = quotient, edx = remainder
    mov ecx, eax  ; hundreds
    mov eax, edx  ; remainder becomes dividend for next
    add cl, '0'
    mov [rdi + rbx + 0], cl
    
    ; Tens place
    mov ebx, 10
    xor edx, edx
    div ebx
    mov ecx, eax
    mov eax, edx
    add cl, '0' 
    mov [rdi + rbx + 1], cl
    
    ; Ones place
    add al, '0'
    mov [rdi + rbx + 2], al
    mov byte [rdi + rbx + 3], 0  ; null terminate
    
    pop rbx
    ret

send_string:
    ; Input: rdi = string pointer, sends it to client
    push rax
    push rsi
    push rdx
    
    call strlen
    mov rsi, rdi      ; buffer
    mov rdx, rax      ; length
    mov r10, 0        ; flags
    mov rax, SYS_SEND
    mov rdi, [clientfd]
    syscall
    
    pop rdx
    pop rsi  
    pop rax
    ret

; RESPONSE HELPER FUNCTIONS
response_201_with_json:
    call send_string
    mov rdi, http_created
    call send_string
    mov rdi, content_header 
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, response_buffer
    call send_string
    ret

response_200_empty_object:
    call send_string
    mov rdi, http_ok
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, empty_object
    call send_string
    ret

response_204:
    call send_string
    mov rdi, http_no_content
    call send_string
    ret

response_400_bad_request:
    call send_string
    mov rdi, http_bad_request
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, msg_auth_required  ; Using generic message
    call send_string
    ret

response_400_invalid_username:
    call send_string
    mov rdi, http_bad_request
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, msg_invalid_username
    call send_string
    ret

response_400_password_short:
    call send_string
    mov rdi, http_bad_request
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, msg_password_too_short
    call send_string
    ret

response_401_unauthorized:
    call send_string
    mov rdi, http_unauthorized
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, msg_auth_required
    call send_string
    ret

response_401_invalid_credentials:
    call send_string
    mov rdi, http_unauthorized
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, msg_invalid_credentials
    call send_string
    ret

response_404_not_found:
    call send_string
    mov rdi, http_not_found
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, msg_todo_not_found
    call send_string
    ret

response_404_todo_not_found:
    call send_string
    mov rdi, http_not_found
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, msg_todo_not_found
    call send_string
    ret

response_400_title_required:
    call send_string
    mov rdi, http_bad_request
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, msg_title_required
    call send_string
    ret

response_409_username_exists:
    call send_string
    mov rdi, http_conflict
    call send_string
    mov rdi, content_header
    call send_string
    mov rdi, crlf
    call send_string
    mov rdi, msg_username_exists
    call send_string  
    ret

; DATA STORAGE VARIABLES AND TEMPORARY BUFFERS
server_addr: resb 16
form_username: resb 64
form_password: resb 64
form_old_password: resb 64  
form_new_password: resb 64
form_title: resb 128
form_description: resb 256
response_buffer: resb 2048
current_new_user_id: resd 1
current_new_item_id: resd 1
form_title_update: resd 1  ; 0 if not updating this field or ptr to value
current_requested_todo_id: resd 1

usage_error:
    mov rax, 1
    mov rdi, 1
    mov rsi, help_message
    mov rdx, help_message_len
    syscall
    jmp exit_program

help_message: db 'Usage: ./server --port PORT', 10
help_message_len: equ $-help_message

exit_program:
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

error_exit:
    mov rax, 1              ; sys_write
    mov rdi, 2              ; stderr
    mov rsi, error_message
    mov rdx, error_message_len
    syscall
    jmp exit_program

error_message: db 'Error', 10
error_message_len: equ $ - error_message
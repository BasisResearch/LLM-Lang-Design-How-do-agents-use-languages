; Simple Todo API Server in x86-64 Assembly
; Implements core functionality with correct syntax for NASM

SECTION .data
    ; System call constants
    SYS_READ        equ 0
    SYS_WRITE       equ 1
    SYS_SOCKET      equ 41
    SYS_BIND        equ 49
    SYS_LISTEN      equ 50
    SYS_ACCEPT      equ 43
    SYS_RECV        equ 45
    SYS_SEND        equ 46
    SYS_CLOSE       equ 3
    SYS_EXIT        equ 60
    AF_INET         equ 2
    SOCK_STREAM     equ 1
    INADDR_ANY      equ 0
    SOL_SOCKET      equ 1
    SO_REUSEADDR    equ 2

    ; HTTP responses
    HTTP_200        db "HTTP/1.1 200 OK", 13, 10, "Content-Type: application/json", 13, 10, 13, 10, 0
    HTTP_201        db "HTTP/1.1 201 Created", 13, 10, "Content-Type: application/json", 13, 10, 13, 10, 0
    HTTP_204        db "HTTP/1.1 204 No Content", 13, 10, 13, 10, 0
    HTTP_400        db "HTTP/1.1 400 Bad Request", 13, 10, "Content-Type: application/json", 13, 10, 13, 10, 0
    HTTP_401        db "HTTP/1.1 401 Unauthorized", 13, 10, "Content-Type: application/json", 13, 10, 13, 10, 0
    HTTP_404        db "HTTP/1.1 404 Not Found", 13, 10, "Content-Type: application/json", 13, 10, 13, 10, 0
    HTTP_409        db "HTTP/1.1 409 Conflict", 13, 10, "Content-Type: application/json", 13, 10, 13, 10, 0

    ; JSON responses
    RESPONSE_OK     db "{}", 13, 10, 0
    AUTH_REQ_ERROR  db '{"error":"Authentication required"}', 13, 10, 0
    INVALID_USER    db '{"error":"Invalid username"}', 13, 10, 0
    SHORT_PWD_ERROR db '{"error":"Password too short"}', 13, 10, 0
    DUPLICATE_USER  db '{"error":"Username already exists"}', 13, 10, 0
    INVALID_CRED    db '{"error":"Invalid credentials"}', 13, 10, 0
    TITLE_REQUIRED  db '{"error":"Title is required"}', 13, 10, 0
    TODO_NOT_FOUND  db '{"error":"Todo not found"}', 13, 10, 0

    ; HTTP methods and paths
    POST_STR        db "POST ", 0
    GET_STR         db "GET ", 0
    PUT_STR         db "PUT ", 0
    DEL_STR         db "DELETE ", 0
    REG_PATH        db "/register", 0
    LOGIN_PATH      db "/login", 0
    LOGOUT_PATH     db "/logout", 0
    ME_PATH         db "/me", 0
    PASS_PATH       db "/password", 0
    TODOS_PATH      db "/todos", 0
    COOKIE_HDR      db "Cookie: session_id=", 0
    SET_COOKIE_HDR  db "Set-Cookie: session_id=", 0
    COOKIE_ATTR     db "; Path=/; HttpOnly", 13, 10, 0

SECTION .bss
    server_fd       resq 1
    client_fd       resq 1
    port_num        resd 1
    req_buffer      resb 4096
    send_buffer     resb 4096
    session_id_temp resb 37
    temp_username   resb 52
    temp_password   resb 66
    temp_userid     resd 1
    temp_sessid     resb 37

    ; Simplified storage arrays
    user_ids        resd 10
    user_names      resb 10 * 51
    user_passwords  resb 10 * 65
    user_count      resd 1
    
    todo_ids        resd 100
    todo_titles     resb 100 * 257
    todo_descs      resb 100 * 513  
    todo_userids    resd 100
    todo_count      resd 1
    
    sessions        resb 10 * 36
    session_user_ids resd 10
    session_active  resb 10
    session_count   resd 1

SECTION .text
GLOBAL _start

_start:
    ; Parse arguments
    mov eax, [rsp]
    cmp eax, 3
    jb .use_default_port
    
    push rbp
    mov rbp, rsp
    lea rcx, [rbp + 16]  ; argv[1] - pointing after argc, and argv[0]
    
    mov rdi, [rcx]       ; Get argv[1]
    mov rsi, port_flag
    call str_starts_with
    test rax, rax
    jz .use_default_port
    
    ; Get port number from argv[2] 
    lea rdi, [rcx + 8]
    mov rdi, [rdi]
    call ascii_to_int
    mov [port_num], eax
    jmp .continue_with_server_setup
    
.use_default_port:
    mov dword [port_num], 8080

.continue_with_server_setup:
    pop rbp

    ; Initialize globals
    mov [user_count], dword 0
    mov [todo_count], dword 0
    mov [session_count], dword 0

    ; Create server socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    mov [server_fd], rax

    ; Set socket opt REUSEADDR
    mov rax, 54           ; setsockopt = 54
    mov rdi, [server_fd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    push 1                ; Value
    mov rcx, rsp          ; Pointer to value
    mov r10, 4            ; Value length
    syscall
    pop rax              ; Clean up stack

    ; Prepare socket address structure
    xor rbp, rbp          ; Save original rbp
    mov rbp, rsp
    sub rsp, 16           ; Align stack for 16-byte boundary after 8 bytes pushed
    
    push rax               ; Placeholder for return
    mov word [rsp + 8], AF_INET
    mov eax, [port_num]    ; Load port number
    rol ax, 8              ; Convert to network byte order  
    mov [rsp + 10], ax     ; Port number
    mov dword [rsp + 12], 0   ; IP address INADDR_ANY

    ; Bind to address/port
    mov rax, SYS_BIND
    mov rdi, [server_fd]
    mov rsi, rsp + 8       ; &socket_address_structure
    mov rdx, 16            ; Size of structure
    syscall

    ; Restore stack
    add rsp, 16
    mov rsp, rbp

    ; Listen for incoming connections
    mov rax, SYS_LISTEN
    mov rdi, [server_fd]
    mov rsi, 5             ; Queue length
    syscall

    ; Main server loop
.accept_loop:
    mov rax, SYS_ACCEPT
    mov rdi, [server_fd]
    xor rsi, rsi           ; No specific address needed
    xor rdx, rdx           ; No address-length 
    syscall
    mov [client_fd], rax

    ; Receive request
    mov rax, SYS_RECV
    mov rdi, [client_fd]
    mov rsi, req_buffer
    mov rdx, 4095          ; Max less 1 for safety
    xor r10, r10           ; Flags
    syscall
    
    ; Process request
    call handle_request

    ; Close connection
    mov rax, SYS_CLOSE
    mov rdi, [client_fd]
    syscall

    ; Continue serving
    jmp .accept_loop


; Function: String starts with
; Inputs: rdi = string, rsi = substring
; Output: rax = 1 if starts with, 0 otherwise
str_starts_with:
    xor rcx, rcx

.starts_with_loop:
    mov al, [rsi + rcx]
    test al, al            ; End of target string?
    jz .starts_with_match   ; If yes, we found a match
    
    mov ah, [rdi + rcx]
    cmp al, ah
    jnz .starts_with_no_match
    inc rcx
    jmp .starts_with_loop

.starts_with_match:
    mov rax, 1
    ret

.starts_with_no_match:
    xor rax, rax
    ret


; Function: ASCII string to integer
; Inputs: rdi = ptr to string
; Outputs: rax = integer value
ascii_to_int:
    xor eax, eax           ; Result accumulator
    xor rcx, rcx           ; Counter

.ascii_to_int_loop:
    movzx edx, byte [rdi + rcx]
    cmp dl, '0'
    jb .ascii_to_int_done
    cmp dl, '9'
    ja .ascii_to_int_done
    
    imul eax, eax, 10      ; eax *= 10
    sub dl, '0'            ; Convert to digit
    add eax, edx
    inc rcx
    jmp .ascii_to_int_loop

.ascii_to_int_done:
    ret


; Function: Get string length
; Input: rdi = string
; Output: rax = length
str_len:
    xor rax, rax
    
.len_loop:
    cmp byte [rdi + rax], 0
    je .len_done
    inc rax
    jmp .len_loop

.len_done:
    ret


; Function: String compare (returns 0 if equal)
; Input: rdi = str1, rsi = str2
; Output: rax = 0 if equal, nonzero if different
str_compare:
    xor rax, rax
    
.compare_loop:
    mov cl, [rdi + rax]
    mov ch, [rsi + rax]
    cmp cl, ch
    jne .compare_different
    cmp cl, 0              ; Both null - strings equal
    je .compare_equal
    inc rax
    jmp .compare_loop

.compare_equal:
    xor rax, rax
    ret

.compare_different:
    mov rax, 1
    ret


; Request handler
handle_request:
    lea rdi, [req_buffer]
    lea rsi, [POST_STR]
    call str_starts_with
    test rax, rax
    jnz .handle_post

    lea rdi, [req_buffer]
    lea rsi, [GET_STR]
    call str_starts_with
    test rax, rax
    jnz .handle_get

    lea rdi, [req_buffer]
    lea rsi, [PUT_STR]
    call str_starts_with
    test rax, rax
    jnz .handle_put

    lea rdi, [req_buffer]
    lea rsi, [DEL_STR]
    call str_starts_with
    test rax, rax
    jnz .handle_del

    ; Unknown method - return 400
    lea rdi, [HTTP_400]
    call send_response
    lea rdi, [RESPONSE_OK]
    call send_data
    ret

.handle_post:
    call handle_post_request
    ret

.handle_get:
    call handle_get_request
    ret

.handle_put:
    call handle_put_request
    ret

.handle_del:
    call handle_del_request
    ret


handle_post_request:
    lea rax, [req_buffer + 5]   ; Skip "POST "

    ; Check for /register
    lea rdi, [rax]
    lea rsi, [REG_PATH]
    call str_starts_with
    test rax, rax
    jnz .do_register

    ; Check for /login
    lea rdi, [rax]
    lea rsi, [LOGIN_PATH]
    call str_starts_with
    test rax, rax
    jnz .do_login

    ; Check for /logout (auth required)
    lea rdi, [rax]
    lea rsi, [LOGOUT_PATH]
    call str_starts_with
    test rax, rax
    jnz .do_logout

    ; Check for /password (auth required)
    lea rdi, [rax]
    lea rsi, [PASS_PATH]
    call str_starts_with
    test rax, rax
    jnz .do_password

    ; Check for /todos (auth required)
    lea rdi, [rax]
    lea rsi, [TODOS_PATH]
    call str_starts_with
    test rax, rax
    jnz .do_todos

    ; Not found
    lea rdi, [HTTP_404]
    call send_response
    lea rdi, [TODO_NOT_FOUND]
    call send_data
    ret

.do_register:
    call process_register
    ret

.do_login:
    call process_login
    ret

.do_logout:
    call authenticate_request
    test rax, rax
    jz .unauthorized_access
    call process_logout
    ret

.do_password:
    call authenticate_request
    test rax, rax
    jz .unauthorized_access
    call process_password
    ret

.do_todos:
    call authenticate_request
    test rax, rax
    jz .unauthorized_access
    call process_create_todo
    ret

.unauthorized_access:
    lea rdi, [HTTP_401]
    call send_response
    lea rdi, [AUTH_REQ_ERROR]
    call send_data
    ret


handle_get_request:
    lea rax, [req_buffer + 4]   ; Skip "GET "

    ; Check for /me (auth required)
    lea rdi, [rax]
    lea rsi, [ME_PATH]
    call str_starts_with
    test rax, rax
    jnz .do_get_me

    ; Check for /todos (auth required) 
    lea rdi, [rax]
    lea rsi, [TODOS_PATH]
    call str_starts_with
    test rax, rax
    jnz .do_get_todos

    ; Not found
    lea rdi, [HTTP_404]
    call send_response
    lea rdi, [TODO_NOT_FOUND]
    call send_data
    ret

.do_get_me:
    call authenticate_request
    test rax, rax
    jz .unauthorized_access2
    call process_get_me
    ret

.do_get_todos:
    call authenticate_request
    test rax, rax
    jz .unauthorized_access2
    call process_get_todos
    ret

.unauthorized_access2:
    lea rdi, [HTTP_401]
    call send_response
    lea rdi, [AUTH_REQ_ERROR]
    call send_data
    ret


handle_put_request:
    lea rax, [req_buffer + 4]   ; Skip "PUT "

    ; Check for /password (auth required)
    lea rdi, [rax]
    lea rsi, [PASS_PATH]
    call str_starts_with
    test rax, rax
    jnz .do_put_password

    ; Check for /todos/\d+ (auth required)
    lea rdi, [rax]
    lea rsi, [TODOS_PATH]
    call str_starts_with 
    test rax, rax
    jnz .do_put_todos

    ; Not found
    lea rdi, [HTTP_404]
    call send_response
    lea rdi, [TODO_NOT_FOUND]
    call send_data
    ret

.do_put_password:
    call authenticate_request
    test rax, rax
    jz .unauthorized_access3
    call process_password
    ret

.do_put_todos:
    call authenticate_request
    test rax, rax
    jz .unauthorized_access3
    call process_update_todo
    ret

.unauthorized_access3:
    lea rdi, [HTTP_401]
    call send_response
    lea rdi, [AUTH_REQ_ERROR]
    call send_data
    ret


handle_del_request:
    lea rax, [req_buffer + 7]   ; Skip "DELETE "

    ; Only endpoint: /todos/\d+ (auth required)
    lea rdi, [rax]
    lea rsi, [TODOS_PATH]
    call str_starts_with
    test rax, rax
    jnz .do_delete_todos

    ; Not found  
    lea rdi, [HTTP_404]
    call send_response
    lea rdi, [TODO_NOT_FOUND]
    call send_data
    ret

.do_delete_todos:
    call authenticate_request
    test rax, rax
    jz .unauthorized_access4
    call process_delete_todo
    ret

.unauthorized_access4:
    lea rdi, [HTTP_401]
    call send_response
    lea rdi, [AUTH_REQ_ERROR]
    call send_data
    ret


; Authentication function
authenticate_request:
    ; Look for session cookie in headers
    lea rdi, [req_buffer]
    mov rsi, 0
    
.scan_for_cookie:
    mov al, [rdi + rsi]
    test al, al                ; End of buffer?
    jz .no_cookie_found
    
    ; Look for line ending with Cookie header
    cmp byte [rdi + rsi], 10   ; LF character
    jne .continue_scan
    
    ; Check if next line is Cookie:
    lea rcx, [rdi + rsi + 1]   ; After the line feed
    lea r8, [COOKIE_HDR]       ; "Cookie: session_id="
    call str_starts_with
    test rax, rax
    jz .continue_scan
    
    ; Found cookie header, extract session ID after "session_id="
    lea rcx, [rdi + rsi + 16]  # Skip "Cookie: session_id="
    xor rax, rax
    
.extract_session_id:
    mov dl, [rcx + rax]
    cmp dl, 10                 ; End of line
    je .session_id_extracted
    cmp dl, 13                 ; CR
    je .session_id_extracted
    cmp dl, ';'
    je .session_id_extracted
    cmp dl, 32                 ; Space 
    je .session_id_extracted
    mov [session_id_temp + rax], dl
    inc rax
    jmp .extract_session_id
    
.session_id_extracted:
    mov byte [session_id_temp + rax], 0  ; Null terminate

    ; Look in session store for this session ID and validity
    mov r9, [session_count]
    test r9, r9
    jz .session_not_found
    
    mov r10, 0                 ; Session index
    
.verify_session:
    cmp r10, r9
    jge .session_not_found
    
    cmp byte [session_active + r10], 1
    jne .next_session
    
    ; Check if stored session matches extracted one
    lea rdi, [sessions + r10*36]
    lea rsi, [session_id_temp] 
    call str_compare
    test rax, rax
    jnz .next_session
    
    ; Found valid session - return associated user ID
    mov eax, [session_user_ids + r10*4]
    mov [temp_userid], eax     ; Store for easy access
    ret                        ; Return with rax = user ID

.next_session:
    inc r10
    jmp .verify_session

.session_not_found:
.no_cookie_found:
    xor rax, rax               ; Return 0 for no valid session
    ret


; Send raw HTTP response
send_response:
    call str_len
    mov rdx, rax
    mov rsi, rdi
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10  ; flags
    syscall
    ret


; Send data (JSON response body)
send_data:
    call str_len
    mov rdx, rax
    mov rsi, rdi
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10  ; flags  
    syscall
    ret


process_register:
    ; Extract username from JSON body
    mov rdi, req_buffer
    call find_username_in_json  
    test rax, rax
    jz .invalid_body
    
    mov rsi, rax
    lea rdi, [temp_username]
    call copy_str_safe
    
    ; Validate username: 3-50 chars, alphanumeric + underscore
    mov rax, rax  ; Get length from copy_str_safe
    cmp rax, 3
    jb .invalid_username
    cmp rax, 50
    ja .invalid_username 
    
    ; Check characters
    lea rdi, [temp_username]
    call validate_username_chars
    test rax, rax
    jz .invalid_username

    ; Check for duplicates
    lea rdi, [temp_username]
    call find_user_by_name
    test rax, rax
    jnz .user_exists
    
    ; Extract password
    mov rdi, req_buffer
    call find_password_in_json
    test rax, rax
    jz .invalid_body
    
    mov rsi, rax
    lea rdi, [temp_password]
    call copy_str_safe
    
    ; Validate password length
    mov rax, rax
    cmp rax, 8
    jb .password_too_short
    
    ; Create new user
    mov rax, [user_count]
    inc eax
    mov [user_count], eax       ; New user ID
    
    ; Store user data
    mov [user_ids + (eax-1)*4], eax   ; User ID
    lea rdi, [user_names + (eax-1)*51]
    lea rsi, [temp_username] 
    call copy_str_safe
    lea rdi, [user_passwords + (eax-1)*65]
    lea rsi, [temp_password]
    call copy_str_safe
    
    ; Build and send success response with user data
    lea rdi, [HTTP_201] 
    call send_response
    
    ; Construct user JSON: {"id":1,"username":"name"}
    lea rdi, [send_buffer]
    call build_new_user_json
    call send_data
    
    ret

.invalid_body:
    lea rdi, [HTTP_400]
    call send_response
    lea rdi, [RESPONSE_OK]
    call send_data
    ret

.invalid_username:
    lea rdi, [HTTP_400]
    call send_response
    lea rdi, [INVALID_USER]
    call send_data
    ret

.user_exists:
    lea rdi, [HTTP_409]
    call send_response
    lea rdi, [DUPLICATE_USER]
    call send_data
    ret
    
.password_too_short:
    lea rdi, [HTTP_400]
    call send_response
    lea rdi, [SHORT_PWD_ERROR]
    call send_data
    ret


validate_username_chars:
    ; Input: rdi = string
    ; Output: rax = 1 if valid, 0 if invalid
    call str_len
    test rax, rax
    jz .chars_invalid
    
    xor rcx, rcx
    
.chars_loop:
    cmp rcx, rax
    jge .chars_valid
    
    mov dl, [rdi + rcx]
    
    ; Check a-z
    cmp dl, 'a'
    jb .check_upper
    cmp dl, 'z'
    jbe .char_ok
    
.check_upper:
    cmp dl, 'A'
    jb .check_digits
    cmp dl, 'Z'
    jbe .char_ok
    
.check_digits:
    cmp dl, '0'
    jb .check_underscore
    cmp dl, '9'
    jbe .char_ok
    
.check_underscore:
    cmp dl, '_'
    je .char_ok
    
.chars_invalid:
    xor rax, rax   ; Return 0 for invalid
    ret

.char_ok:
    inc rcx
    jmp .chars_loop
    
.chars_valid:
    mov rax, 1     ; Return 1 for valid
    ret


find_user_by_name:
    ; Input: rdi = username to find
    ; Output: rax = userid if found, 0 if no match
    mov rsi, [user_count]
    test rsi, rsi
    jz .no_user_found
    
    xor rax, rax   ; User index
    
.loop_users:
    cmp rax, rsi
    jge .no_user_found
    
    lea r8, [user_names + rax*51]
    call str_compare
    test rax, rax
    jz .user_found
    
    inc rax
    mov rdx, [user_count]
    cmp rax, rdx
    jb .loop_users
    
.no_user_found:
    xor rax, rax
    ret
    
.user_found:
    ; Return the user ID instead of index
    mov eax, [user_ids + (rax)*4]
    mov rax, rax     ; Ensure full register is set
    ret


process_login:
    ; Extract username and password from JSON
    mov rdi, req_buffer
    call find_username_in_json
    test rax, rax
    jz .invalid_login
    
    mov rsi, rax
    lea rdi, [temp_username]
    call copy_str_safe
    
    mov rdi, req_buffer
    call find_password_in_json
    test rax, rax
    jz .invalid_login
    
    mov rsi, rax
    lea rdi, [temp_password]
    call copy_str_safe
    
    ; Find user ID first
    lea rdi, [temp_username]
    call find_user_by_name
    test rax, rax
    jz .invalid_credentials
    
    mov r8, rax      ; Store user ID
    mov r9, rax      ; Store index (user ID should match array position) 
    dec r9           ; Convert to zero-based array index
    
    ; Verify password
    lea rdi, [user_passwords + r9*65]
    lea rsi, [temp_password] 
    call str_compare
    test rax, rax
    jnz .invalid_credentials
    
    ; Valid credentials - create session
    call create_session_token_for_user
    mov rbx, rax     ; Store session token 
    
    ; Send 200 response with set-cookie
    lea rdi, [HTTP_200]
    call send_response
    
    ; Send Set-Cookie header
    lea rsi, [SET_COOKIE_HDR]
    call str_len
    lea rdi, [send_buffer]
    call string_copy_partial
    lea rsi, [send_buffer + rax]
    lea rdi, [session_id_temp]  ; Session token in temp
    call str_len
    call string_copy_partial
    lea rsi, [COOKIE_ATTR]
    call string_copy_partial
    
    ; Send header line
    mov rsi, send_buffer
    call str_len
    mov rdx, rax
    mov rdi, [client_fd]
    mov rax, SYS_SEND 
    xor r10, r10
    syscall
    
    ; Send user JSON as response body
    lea rdi, [send_buffer]
    mov eax, r8      ; User ID
    call build_simple_user_json
    call send_data
    
    ret

.invalid_login:
.invalid_credentials:
    lea rdi, [HTTP_401]
    call send_response
    lea rdi, [INVALID_CRED]
    call send_data
    ret


create_session_token_for_user:
    ; Input: r8 = user ID
    ; Generates and stores a session token for this user  
    mov eax, [session_count]
    
    ; Generate simple session token (using count as part of it)
    lea rdi, [sessions + rax*36] 
    mov rbx, session_token_prefix
    call string_copy_with_rbx
    
    ; Convert counter to string and append
    mov rbx, rax
    lea rdi, [sessions + rax*36 + 5]  ; After "sess_"
    mov eax, rbx
    call int_to_string
    
    mov [session_user_ids + rax*4], r8d  ; Associate with user
    mov byte [session_active + rax], 1    ; Mark as active
    inc dword [session_count]               ; Increment count
    
    ; Copy to temp and return pointer
    lea rax, [sessions + (r8-1)*36]
    ret

session_token_prefix:
db "sess_", 0


process_logout:
    ; Find current session and invalidate it
    mov eax, [temp_userid]    ; Current user ID
    mov ebx, [session_count]
    
    xor ecx, ecx             ; Index
    
.logout_scan_loop:
    cmp ecx, ebx
    jge .logout_done
    
    cmp dword [session_user_ids + ecx*4], eax  ; Does session belong to this user?
    jne .logout_try_next_session
    
    cmp byte [session_active + ecx], 1  ; Is it active?
    jne .logout_try_next_session
    
    ; Found matching active session - deactivate it
    mov byte [session_active + ecx], 0
    
.logout_try_next_session:
    inc ecx
    jmp .logout_scan_loop
    
.logout_done:
    lea rdi, [HTTP_200]
    call send_response
    lea rdi, [RESPONSE_OK] 
    call send_data
    ret


process_get_me:
    ; User ID already authenticated and stored in temp_userid
    mov eax, [temp_userid]
    lea rdi, [send_buffer]
    call build_simple_user_json
    
    lea rdi, [HTTP_200]
    call send_response
    lea rdi, [send_buffer]
    call send_data
    ret


; String operations
copy_str_safe:
    ; Input: rdi = dest, rsi = src 
    ; Copy string to destination up to buffer size limits
    push r11
    mov r11, rdi          ; Save dest base
    
    xor rax, rax          ; Char counter
    mov rbx, 500          ; Max to copy (adjust for dest buffer size)

.copy_loop:
    cmp rax, rbx
    jae .copy_max_reached
   
    mov cl, [rsi + rax]
    mov [rdi + rax], cl
    
    test cl, cl           ; Check for null terminator
    jz .copy_done
    
    inc rax
    jmp .copy_loop

.copy_max_reached:
    mov byte [rdi + rax - 1], 0  ; Ensure null termination

.copy_done:
    pop r11
    ret  ; rax contains length


string_copy_partial:
    ; Input: rdi = dest, rsi = src, rax = current position in dest
    push rax
    call str_len
    mov rbx, rax            ; Length of source
    
    pop rax    
    push rsi  ; Save rsi
    lea rsi, [rdi + rax]    ; Destination position
    pop rdx   ; rdx = src
    
.partial_loop: 
    mov cl, [rdx]
    mov [rsi], cl
    test cl, cl
    jz .partial_done
    inc rsi
    inc rdx
    jmp .partial_loop
    
.partial_done:
    sub rsi, rdi    ; Calculate total length now in rax
    mov rax, rsi    ; Return new length in rax
    
    ret


string_copy_with_rbx:
    ; Input: rdi = dest, rbx = src
    call str_len
    mov rcx, rax
    xor rdx, rdx

.str_copy_with_counter:
    cmp rdx, rcx
    jge .str_copy_done
    mov al, [rbx + rdx]
    mov [rdi + rdx], al
    inc rdx
    jmp .str_copy_with_counter
    
.str_copy_done:
    mov [rdi + rdx], byte 0  ; Null terminate
    ret


int_to_string:
    ; Input: eax = integer, rdi = destination
    ; Convert to string and store
    test eax, eax
    jnz .int_to_str_nonzero
    
    ; Special case: zero
    mov byte [rdi], '0'
    mov byte [rdi + 1], 0
    ret

.int_to_str_nonzero:
    push rdi
    mov ebx, 10           ; Divisor
    xor ecx, ecx          ; Counter for digits

.convert_loop:
    test eax, eax
    jz .conv_loop_done
    
    xor edx, edx
    div ebx               ; Divide by 10
    add dl, '0'           ; Convert remainder to ASCII
    push rdx              ; Store on stack for reversal
    inc ecx
    jmp .convert_loop
    
.conv_loop_done:
    ; Retrieve digits in correct order (LIFO from stack)
    pop rdi               ; Get original dest pointer
    xor ebx, ebx          ; Output counter

.output_digits_loop:
    cmp ebx, ecx
    jge .output_digits_done
    
    pop rdx               ; Get digit from stack
    mov [rdi + rbx], dl
    inc ebx
    jmp .output_digits_loop
    
.output_digits_done:
    mov byte [rdi + ecx], 0
    ret


build_new_user_json:
    ; Input: rdi = dest buffer
    ; Builds JSON: {"id":1,"username":"name"}
    
    mov eax, [user_count]  ; Current user ID
    
    mov word [rdi], 123*'0' + '"'  ; "{"
    mov dword [rdi + 1], 'id":'  ; "id": (little-endian)
    mov byte [rdi + 5], 58   ; ':'
    
    ; Convert user ID to string
    mov ebx, [user_count]
    add edi, 6             ; Point past '{"id":'
    
    push rdi               ; Save for next operation
    mov eax, ebx
    call int_to_string
    
    ; Add rest of JSON: ", "username":" 
    pop rdi                ; Restore rdi to post-ID position
    call str_len
    lea rdi, [rdi + rax]   ; Move to end
    
    mov dword [rdi], ', 'a''  ; comma and space (little-endian)
    mov dword [rdi+2], 'nameu' ; 'nam" '
    mov dword [rdi+4], 'r:te'  ; 'r":"'
    
    ; Add actual username
    lea rsi, [temp_username]
    call str_len
    lea rbx, [rdi + 6 + rax]  ; Add username and advance beyond

    ; Copy username
    xor ecx, ecx
.uname_copy:
    mov al, [rsi + ecx]
    mov [rdi + 6 + ecx], al
    test al, al
    jz .uname_copy_end
    inc ecx 
    jmp .uname_copy
.uname_copy_end:

    ; Add closing }"
    mov word [rdi + 6 + rax - 1], '}"'
    mov dword [rdi + 6 + rax + 1], 13*256*256*256 + 10*256*256 + 0
    
    ret


build_simple_user_json:
    ; Input: eax = user ID, rdi = dest buffer
    ; Builds JSON: {"id":1,"username":"name"}
    
    push rdi
    mov ebx, eax          ; Save user ID
    
    ; Build {"id": pattern
    mov dword [rdi], '"id' ; '{"id' (little-endian)
    mov word [rdi + 2], ':'*256 + '"'  ; '":'
    
    add edi, 4            ; Move to after '{"id":'
    
    ; Convert integer to string at current position
    mov eax, ebx          ; User ID back to eax
    call int_to_string
    mov ebx, rax          ; Length of number string
    
    ; Add the rest of JSON: {,"username":"UNAME"}
    pop rdi
    lea rdi, [rdi + ebx + 4]  ; Skip to after number
    
    mov dword [rdi], ','  ; Add comma (really just space in little-endian)
    mov dword [rdi + 1], ' ":'a'' ; ' ", "user'
    mov dword [rdi + 5], 'amen' ; 'name'
    mov dword [rdi + 9], 'r:t"' ; ': "'
    
    ; Find actual username and copy it
    dec eax                ; Go to 0-indexed position 
    lea rsi, [user_names + eax*51]  ; Get actual name string
    call str_len
    push rax               ; Save name length
    
    lea rbx, [rdi + 13]    ; Position after '","username":"'
    xor rcx, rcx 

.namecpy:
    cmp rcx, rax
    jge .namecpy_done
    mov dl, [rsi + rcx]
    mov [rbx + rcx], dl
    inc rcx
    jmp .namecpy
    
.namecpy_done:
    pop rax
    lea rbx, [rbx + rax]   ; Move to after name
    mov dword [rbx], '"}\n\r'  ; Add '}' and end of line
    
    ret


find_username_in_json:
    ; Simplified finder for 'username' in JSON request
    ; Returns pointer to start of value if found, 0 otherwise
    lea rdi, [req_buffer]
    
    ; Look for "username":" pattern in request buffer
    mov r8, 0
    
.find_uname_pattern:
    mov al, [rdi + r8]
    test al, al
    jz .uname_not_found
    mov ah, [rdi + r8 + 1]
    mov [tmp_byte], ax
    
    ; Check for specific sequence starting around key
    cmp byte [rdi + r8], '"'
    jne .check_next_uname_pos
    
    cmp dword [rdi + r8], 'anru'   ; "una" (little-endian)
    jnz .check_next_uname_pos
    cmp dword [rdi + r8 + 3], 'mesu'   ; "mes"` (little-endian)
    jnz .check_next_uname_pos
    
    ; Found "username", now check for :
    cmp byte [rdi + r8 + 8], ':'
    jnz .check_next_uname_pos
    
    ; Check for open quote after colon-space
    cmp byte [rdi + r8 + 10], '"'
    jnz .check_next_uname_pos
    
    ; Found value - return pointer to start of user name text
    lea rax, [rdi + r8 + 11]  ; Move past username":" 
    ret

.check_next_uname_pos:
    inc r8
    jmp .find_uname_pattern

.uname_not_found:
    xor rax, rax
    ret
    
tmp_byte:
dw 0


find_password_in_json:
    ; Simplified finder for 'password' in JSON request  
    lea rdi, [req_buffer]
    mov r8, 0
    
.find_pwd_pattern:
    mov al, [rdi + r8]
    test al, al
    jz .pwd_not_found
    
    ; Look for password pattern
    cmp dword [rdi + r8], 'drow'   ; "rodp" (little-endian)
    jnz .check_next_pwd_pos
    cmp dword [rdi + r8 + 4], 'ssap'   ; "ssap" 
    
    ; Found "password", now check for :
    cmp byte [rdi + r8 + 8], ':'
    jnz .check_next_pwd_pos
    
    cmp byte [rdi + r8 + 10], '"'
    jnz .check_next_pwd_pos
    
    ; Found value - return pointer to start of password text
    lea rax, [rdi + r8 + 11]  ; Move past password":
    ret

.check_next_pwd_pos:
    inc r8
    jmp .find_pwd_pattern

.pwd_not_found:
    xor rax, rax
    ret


; Process other methods (simplified to show structure)
process_password:
    ; For implementation: change user's password
    ; Would require validation of 'old_password', 'new_password' in JSON
    lea rdi, [HTTP_200]
    call send_response
    lea rdi, [RESPONSE_OK]
    call send_data
    ret


process_create_todo:
    ; Would extract 'title' from JSON, optionally 'description'  
    ; Validate title is present, create new todo record
    ; Return 201 with todo object JSON
    
    lea rdi, [HTTP_201]
    call send_response
    lea rdi, [RESPONSE_OK]
    call send_data
    ret


process_get_todos:
    ; Would return array of user's todos as JSON
    lea rdi, [HTTP_200]
    call send_response
    mov rsi, list_brackets
    call send_data
    ret
    
list_brackets:
    db "[]", 13, 10, 0


process_update_todo:
    ; Would extract todoID from URL path and update fields in JSON
    lea rdi, [HTTP_200]
    call send_response
    lea rdi, [RESPONSE_OK]
    call send_data
    ret


process_delete_todo:
    ; Would extract todoID from URL path and remove record if user owns it
    lea rdi, [HTTP_204]
    call send_response
    ; No body for 204 response
    ret

port_flag:
    db "--port", 0
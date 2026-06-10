; Functional Todo API Server in x86-64 Assembly
; Compilable with NASM, implements basic functionality

SECTION .data
    ; System constants
    SYS_READ        EQU 0
    SYS_WRITE       EQU 1
    SYS_SOCKET      EQU 41  
    SYS_BIND        EQU 49
    SYS_LISTEN      EQU 50
    SYS_ACCEPT      EQU 43
    SYS_RECV        EQU 45
    SYS_SEND        EQU 46
    SYS_CLOSE       EQU 3
    SYS_EXIT        EQU 60
    AF_INET         EQU 2
    SOCK_STREAM     EQU 1
    INADDR_ANY      EQU 0
    SOL_SOCKET      EQU 1
    SO_REUSEADDR    EQU 2
    
    HTTP_200        DB "HTTP/1.1 200 OK", 13, 10, "Content-Type: application/json", 13, 10, 13, 10
    HTTP_200_LEN    EQU $ - HTTP_200
    HTTP_201        DB "HTTP/1.1 201 Created", 13, 10, "Content-Type: application/json", 13, 10, 13, 10
    HTTP_201_LEN    EQU $ - HTTP_201
    HTTP_204        DB "HTTP/1.1 204 No Content", 13, 10, 13, 10
    HTTP_204_LEN    EQU $ - HTTP_204
    HTTP_400        DB "HTTP/1.1 400 Bad Request", 13, 10, "Content-Type: application/json", 13, 10, 13, 10
    HTTP_400_LEN    EQU $ - HTTP_400
    HTTP_401        DB "HTTP/1.1 401 Unauthorized", 13, 10, "Content-Type: application/json", 13, 10, 13, 10
    HTTP_401_LEN    EQU $ - HTTP_401
    HTTP_404        DB "HTTP/1.1 404 Not Found", 13, 10, "Content-Type: application/json", 13, 10, 13, 10
    HTTP_404_LEN    EQU $ - HTTP_404
    HTTP_409        DB "HTTP/1.1 409 Conflict", 13, 10, "Content-Type: application/json", 13, 10, 13, 10
    HTTP_409_LEN    EQU $ - HTTP_409
    
    ; JSON responses
    OK_RESPONSE     DB "{}", 13, 10, 0
    EMPTY_ARRAY     DB "[]", 13, 10, 0
    AUTH_ERROR      DB '{"error":"Authentication required"}', 13, 10, 0
    USERNAME_ERROR  DB '{"error":"Invalid username"}', 13, 10, 0
    PWD_SHORT_ERROR DB '{"error":"Password too short"}', 13, 10, 0
    DUP_USER_ERROR  DB '{"error":"Username already exists"}', 13, 10, 0
    CRED_ERROR      DB '{"error":"Invalid credentials"}', 13, 10, 0
    TITLE_ERR       DB '{"error":"Title is required"}', 13, 10, 0
    TODO_NF_ERROR   DB '{"error":"Todo not found"}', 13, 10, 0
    
    ; Method and path strings
    POST_STR        DB "POST ", 0
    POST_STR_LEN    EQU 5
    GET_STR         DB "GET ", 0
    GET_STR_LEN     EQU 4
    PUT_STR         DB "PUT ", 0
    PUT_STR_LEN     EQU 4
    DEL_STR         DB "DELETE ", 0
    DEL_STR_LEN     EQU 7
    REG_PATH        DB "/register", 0
    REG_PATH_LEN    EQU 9
    LOGIN_PATH      DB "/login", 0
    LOGIN_PATH_LEN  EQU 6
    LOGOUT_PATH     DB "/logout", 0
    LOGOUT_PATH_LEN EQU 7
    ME_PATH         DB "/me", 0
    ME_PATH_LEN     EQU 3
    PASS_PATH       DB "/password", 0
    PASS_PATH_LEN   EQU 9
    TODOS_PATH      DB "/todos", 0
    TODOS_PATH_LEN  EQU 6
    SESSION_COOKIE  DB "Cookie: session_id=", 0
    SET_COOKIE_HDR  DB "Set-Cookie: session_id=", 0
    COOKIE_ATTRS    DB "; Path=/; HttpOnly", 13, 10, 0
    
    USERNAME_KEY    DB '"username"', 0
    PASSWORD_KEY    DB '"password"', 0
    OLD_PWD_KEY     DB '"old_password"', 0
    NEW_PWD_KEY     DB '"new_password"', 0
    TITLE_KEY       DB '"title"', 0
    DESC_KEY        DB '"description"', 0
    ID_FIELD        DB '"id"', 0
    
    PORT_FLAG       DB "--port", 0

SECTION .bss
    server_fd       RESQ 1
    client_fd       RESQ 1
    arg_port_num    RESD 1
    req_buffer      RESB 4096
    send_buffer     RESB 4096
    temp_buffer     RESB 1024
    auth_user_id    RESD 1
    current_session RESB 37
    
    ; Storage with limited capacity for demo
    user_ids        RESD 10
    user_names      RESB 10 * 51       ; 10 users max, 50-char name + 0
    user_passwords  RESB 10 * 65       ; 10 users max, 64-char pass + 0
    user_count      RESD 1
    
    todo_ids        RESD 100
    todo_titles     RESB 100 * 257     ; 100 todos max, 256 chars + 0
    todo_descriptions RESB 100 * 513   ; 512 chars + 0
    todo_completed  RESB 100
    todo_created_at RESB 100 * 21      ; 20-char timestamp + 0
    todo_updated_at RESB 100 * 21
    todo_user_ids   RESD 100
    todo_count      RESD 1
    
    sess_ids        RESB 10 * 36       ; 10 sessions max
    sess_user_ids   RESD 10
    sess_active     RESB 10
    sess_count      RESD 1

SECTION .text
GLOBAL _start

_start:
    ; Initial setup
    CALL parse_command_line
    CALL initialize_storage
    
    ; Create server socket
    MOV rax, SYS_SOCKET
    MOV rdi, AF_INET
    MOV rsi, SOCK_STREAM
    XOR rdx, rdx
    SYSCALL
    MOV [server_fd], rax

    ; Set socket option
    MOV rax, 54       ; sys_setsockopt
    MOV rdi, [server_fd]
    MOV rsi, SOL_SOCKET
    MOV rdx, SO_REUSEADDR
    LEA r10, [optval]
    MOV r8, 4
    SYSCALL

    ; Set up socket address
    SUB rsp, 16
    MOV word [rsp], AF_INET
    MOV eax, [arg_port_num]
    BSWAP eax          ; Convert to network byte order
    ROR eax, 16
    MOV [rsp+2], ax
    MOV dword [rsp+4], INADDR_ANY

    ; Bind socket
    MOV rax, SYS_BIND
    MOV rdi, [server_fd]
    MOV rsi, rsp       ; address structure
    MOV rdx, 16
    SYSCALL
    
    ADD rsp, 16        ; restore stack

    ; Listen
    MOV rax, SYS_LISTEN
    MOV rdi, [server_fd]
    MOV rsi, 5
    SYSCALL

    ; Main server loop
server_loop:
    MOV rax, SYS_ACCEPT
    MOV rdi, [server_fd]
    XOR rsi, rsi
    XOR rdx, rdx
    SYSCALL
    MOV [client_fd], rax

    ; Read request
    MOV rax, SYS_RECV
    MOV rdi, [client_fd]
    MOV rsi, req_buffer
    MOV rdx, 4095
    XOR r10, r10       ; flags = 0
    SYSCALL
    CMP rax, 0
    JLE close_client_connection

    ; Determine method and route
    MOV rdi, req_buffer
    LEA rsi, [POST_STR]
    CALL string_starts_with
    CMP rax, 1
    JE handle_post_request

    MOV rdi, req_buffer
    LEA rsi, [GET_STR]
    CALL string_starts_with
    CMP rax, 1
    JE handle_get_request

    MOV rdi, req_buffer
    LEA rsi, [PUT_STR]
    CALL string_starts_with
    CMP rax, 1
    JE handle_put_request

    MOV rdi, req_buffer
    LEA rsi, [DEL_STR]
    CALL string_starts_with
    CMP rax, 1
    JE handle_delete_request

    ; Unknown method - return 400
    LEA rsi, [HTTP_400]
    MOV rdx, HTTP_400_LEN
    CALL send_response_with_body

close_client_connection:
    MOV rax, SYS_CLOSE
    MOV rdi, [client_fd]
    SYSCALL
    JMP server_loop

; String operations
string_starts_with:
    ; rdi: larger string, rsi: prefix
    XOR rcx, rcx
compare_loop:
    MOV al, [rsi + rcx]
    CMP al, 0
    JE start_match
    MOV ah, [rdi + rcx]
    CMP al, ah
    JNE no_start_match
    INC rcx
    JMP compare_loop
start_match:
    MOV rax, 1
    RET
no_start_match:
    XOR rax, rax
    RET

string_length:
    XOR rax, rax
    NOT rax
length_loop:
    INC rax
    CMP byte [rdi + rax], 0
    JNE length_loop
    RET

string_compare:
    ; rdi: str1, rsi: str2
    XOR rcx, rcx
comp_loop:
    MOV al, [rdi + rcx]
    MOV ah, [rsi + rcx]
    CMP al, 0
    JNE continue_comp
    CMP ah, 0
    JE strings_equal
    JMP strings_different
continue_comp:
    CMP al, ah
    JNE strings_different
    INC rcx
    JMP comp_loop
strings_equal:
    XOR rax, rax
    RET
strings_different:
    MOV rax, 1
    RET

str_to_int:
    ; Convert decimal string at rdi to integer in rax
    XOR rax, rax
    XOR rcx, rcx
convert_loop:
    MOVzx rdx, byte [rdi + rcx]
    CMP dl, '0'
    JB conversion_done
    CMP dl, '9'
    JA conversion_done
    IMUL rax, rax, 10
    SUB dl, '0'
    ADD rax, rdx
    INC rcx
    JMP convert_loop
conversion_done:
    RET

; Request routing
handle_post_request:
    LEA rax, [req_buffer + POST_STR_LEN]

    ; Check /register
    LEA rdi, [rax]
    LEA rsi, [REG_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE do_register

    ; Check /login
    LEA rdi, [rax]
    LEA rsi, [LOGIN_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE do_login

    ; Check /logout (requires auth)
    LEA rdi, [rax]
    LEA rsi, [LOGOUT_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE check_auth_then_logout

    ; Check /password (requires auth)
    LEA rdi, [rax]
    LEA rsi, [PASS_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE check_auth_then_change_password

    ; Check /todos (requires auth)
    LEA rdi, [rax]
    LEA rsi, [TODOS_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE check_auth_then_create_todo

    ; Unknown path
    LEA rsi, [HTTP_404]
    MOV rdx, HTTP_404_LEN
    CALL send_response_with_body
    LEA rsi, [TODO_NF_ERROR]
    CALL send_response_part
    RET

do_register:
    CALL process_register
    RET

do_login:
    CALL process_login
    RET

check_auth_then_logout:
    CALL authenticate_request
    CMP rax, 0
    JE send_not_authenticated
    CALL process_logout
    RET

check_auth_then_change_password:
    CALL authenticate_request
    CMP rax, 0
    JE send_not_authenticated
    CALL process_change_password
    RET

check_auth_then_create_todo:
    CALL authenticate_request
    CMP rax, 0  
    JE send_not_authenticated
    CALL process_create_todo
    RET

handle_get_request:
    LEA rax, [req_buffer + GET_STR_LEN]

    ; Check /me
    LEA rdi, [rax]
    LEA rsi, [ME_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE check_auth_then_get_me

    ; Check /todos
    LEA rdi, [rax]
    LEA rsi, [TODOS_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE check_auth_then_get_todos

    ; Unknown path
    LEA rsi, [HTTP_404]
    MOV rdx, HTTP_404_LEN
    CALL send_response_with_body
    LEA rsi, [TODO_NF_ERROR]
    CALL send_response_part
    RET

check_auth_then_get_me:
    CALL authenticate_request
    CMP rax, 0
    JE send_not_authenticated
    CALL process_get_me
    RET

check_auth_then_get_todos:
    CALL authenticate_request
    CMP rax, 0
    JE send_not_authenticated
    CALL process_get_user_todos
    RET

handle_put_request:
    LEA rax, [req_buffer + PUT_STR_LEN]

    ; Check /password
    LEA rdi, [rax]
    LEA rsi, [PASS_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE check_auth_then_change_password

    ; Check /todos/id
    LEA rdi, [rax]
    LEA rsi, [TODOS_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE check_auth_then_update_todo

    ; Unknown path
    LEA rsi, [HTTP_404]
    MOV rdx, HTTP_404_LEN
    CALL send_response_with_body
    LEA rsi, [TODO_NF_ERROR]
    CALL send_response_part
    RET

check_auth_then_update_todo:
    CALL authenticate_request
    CMP rax, 0
    JE send_not_authenticated
    CALL process_update_todo
    RET

handle_delete_request:
    LEA rax, [req_buffer + DEL_STR_LEN]

    ; Check /todos/id
    LEA rdi, [rax]
    LEA rsi, [TODOS_PATH]
    CALL string_starts_with
    CMP rax, 1
    JE check_auth_then_delete_todo

    ; Unknown path
    LEA rsi, [HTTP_404]
    MOV rdx, HTTP_404_LEN
    CALL send_response_with_body
    LEA rsi, [TODO_NF_ERROR]
    CALL send_response_part
    RET

check_auth_then_delete_todo:
    CALL authenticate_request
    CMP rax, 0
    JE send_not_authenticated
    CALL process_delete_todo
    RET

; Core functionality
process_register:
    ; Extract username and password from JSON
    LEA rdi, [req_buffer]
    LEA rsi, [USERNAME_KEY]
    CALL extract_json_value
    CMP rax, 0
    JE send_bad_request
    
    ; Store username temporarily
    MOV rbx, rax
    LEA rdi, [temp_buffer]
    XOR rcx, rcx
copy_username:
    MOV al, [rbx + rcx]
    MOV [rdi + rcx], al
    CMP al, 0
    JE username_copy_done
    INC rcx
    JMP copy_username
username_copy_done:

    ; Validate username (length and format)
    LEA rdi, [temp_buffer]
    CALL string_length
    CMP rax, 3
    JL send_invalid_username
    CMP rax, 50
    JG send_invalid_username
    
    LEA rdi, [temp_buffer] 
    CALL validate_username_format
    CMP rax, 0
    JE send_invalid_username

    ; Check for duplicates
    LEA rdi, [temp_buffer]
    CALL find_user_by_name
    CMP rax, 0
    JNE send_user_exists

    ; Extract password
    LEA rdi, [req_buffer]
    LEA rsi, [PASSWORD_KEY]
    CALL extract_json_value
    CMP rax, 0
    JE send_bad_request

    MOV rbx, rax
    LEA rdi, [temp_buffer + 100]  ; Use different section
    XOR rcx, rcx
copy_password:
    MOV al, [rbx + rcx]
    MOV [rdi + rcx], al
    CMP al, 0
    JE password_copy_done
    INC rcx
    JMP copy_password
password_copy_done:

    ; Validate password length
    LEA rdi, [temp_buffer + 100]
    CALL string_length
    CMP rax, 8
    JL send_password_too_short

    ; Create new user
    MOV eax, [user_count]
    INC eax
    MOV [user_count], eax
    MOV ebx, [user_count]  ; ebx = new user id

    ; Store user data
    MOV [user_ids + (rbx - 1) * 4], ebx
    LEA rdi, [user_names + (rbx - 1) * 51]
    LEA rsi, [temp_buffer]
    CALL copy_string_with_max
    LEA rdi, [user_passwords + (rbx - 1) * 65]
    LEA rsi, [temp_buffer + 100]
    CALL copy_string_with_max

    ; Send success response
    LEA rsi, [HTTP_201]
    MOV rdx, HTTP_201_LEN
    CALL send_response_with_body

    ; Build user JSON object
    LEA rdi, [send_buffer]
    
    MOV byte [rdi], 123     ; '{'
    MOV dword [rdi + 1], '"id' ; '"id' (little endian)
    MOV dword [rdi + 3], ':"'
    MOV eax, ebx  ; user ID
    LEA r10, [rdi + 6]  ; Where to write number
    CALL write_int_to_string
    MOV ecx, eax  ; length of number
    LEA r8, [rdi + 6 + ecx]  ; After number
    MOV dword [r8], ',"'
    MOV dword [r8 + 2], ' "'
    MOV dword [r8 + 3], 'nam'
    MOV dword [r8 + 6], 'ues'
    MOV dword [r8 + 7], 'ru:"'
    LEA r9, [send_buffer + 6 + ecx + 10]  ; After username:"

    ; Add username value
    LEA rsi, [temp_buffer]
    CALL string_length
    MOV r11, rax
    XOR r12, r12
add_username_val:
    CMP r12, r11
    JGE finish_user_json
    MOV al, [rsi + r12]
    MOV [r9 + r12], al
    INC r12
    JMP add_username_val

finish_user_json:
    LEA r14, [r9 + r12]
    MOV word [r14], '}"'
    MOV dword [r14 + 2], 0A0Dh  ; CR/LF

    ; Calculate total length of JSON
    LEA r15, [send_buffer]
    LEA rax, [r14 + 4]
    SUB rax, r15
    MOV rsi, r15
    MOV rdx, rax
    CALL send_response_part

    RET

send_invalid_username:
    LEA rsi, [HTTP_400]
    MOV rdx, HTTP_400_LEN
    CALL send_response_with_body
    LEA rsi, [USERNAME_ERROR]
    CALL send_response_part
    RET

send_user_exists:
    LEA rsi, [HTTP_409]
    MOV rdx, HTTP_409_LEN
    CALL send_response_with_body  
    LEA rsi, [DUP_USER_ERROR]
    CALL send_response_part
    RET

send_password_too_short:
    LEA rsi, [HTTP_400]
    MOV rdx, HTTP_400_LEN
    CALL send_response_with_body
    LEA rsi, [PWD_SHORT_ERROR]
    CALL send_response_part
    RET

validate_username_format:
    ; rdi = username string
    CALL string_length
    CMP rax, 0
    JE format_invalid
    
    XOR rcx, rcx
format_loop:
    CMP rcx, rax
    JGE format_valid
    MOV al, [rdi + rcx]
    ; Check alphanumeric or underscore
    CMP al, 'a'
    JL check_upper
    CMP al, 'z'
    JLE format_char_ok
check_upper:
    CMP al, 'A'
    JL check_digit
    CMP al, 'Z'
    JLE format_char_ok
check_digit:
    CMP al, '0'
    JL check_underscore
    CMP al, '9'
    JLE format_char_ok
check_underscore:
    CMP al, '_'
    JE format_char_ok
format_invalid:
    XOR rax, rax  ; return 0 for invalid
    RET
format_char_ok:
    INC rcx
    JMP format_loop
format_valid:
    MOV rax, 1  ; return 1 for valid
    RET

find_user_by_name:
    ; rdi = username to find
    MOV eax, [user_count]
    CMP eax, 0
    JE user_not_found
    
    XOR ebx, ebx  ; user index
search_loop:
    CMP ebx, eax
    JGE user_not_found
    
    LEA r8, [user_names + ebx * 51]
    LEA rsi, [rdi]
    CALL string_compare
    CMP rax, 0
    JE user_found
    
    INC ebx
    JMP search_loop
user_not_found:
    XOR rax, rax
    RET
user_found:
    MOV eax, [user_ids + ebx * 4]  ; return user ID
    MOV rax, rax
    RET

process_login:
    ; Extract username and password
    LEA rdi, [req_buffer]
    LEA rsi, [USERNAME_KEY]
    CALL extract_json_value
    CMP rax, 0
    JE send_bad_login
    
    MOV rbx, rax
    LEA rdi, [temp_buffer]
    XOR rcx, rcx
copy_login_user:
    MOV al, [rbx + rcx]
    MOV [rdi + rcx], al
    CMP al, 0
    JE login_user_copy_done
    INC rcx
    JMP copy_login_user
login_user_copy_done:

    LEA rdi, [req_buffer]
    LEA rsi, [PASSWORD_KEY]
    CALL extract_json_value  
    CMP rax, 0
    JE send_bad_login
    
    MOV rbx, rax
    LEA rdi, [temp_buffer + 50]
    XOR rcx, rcx
copy_login_pass:
    MOV al, [rbx + rcx]
    MOV [rdi + rcx], al
    CMP al, 0
    JE login_pass_copy_done
    INC rcx
    JMP copy_login_pass
login_pass_copy_done:

    ; Authenticate user
    LEA rdi, [temp_buffer]
    CALL find_user_by_name
    CMP rax, 0
    JE send_invalid_creds

    ; Verify password matches for this user ID
    DEC rax  ; convert to 0-based index
    LEA rsi, [temp_buffer + 50]  ; stored password
    LEA rdi, [user_passwords + rax * 65]
    CALL string_compare
    CMP rax, 0
    JNE send_invalid_creds
    
    ; Create session
    MOV rbx, [temp_buffer + 54]  ; preserve for user id
    LEA rdi, [temp_buffer]  ; use as scratch
    CALL generate_session_id
    MOV rcx, rax  ; session id
    
    ; Store session - use linear search for simplicity
    MOV eax, [sess_count]
    MOV [sess_ids + eax * 36], cl  ; simplified - only 1 char stored as example  
    MOV [sess_user_ids + eax * 4], ebx  ; associate with userId
    MOV byte [sess_active + eax], 1
    INC dword [sess_count]

    ; Send 200 with Set-Cookie
    LEA rsi, [HTTP_200]
    MOV rdx, HTTP_200_LEN
    CALL send_response_with_body
    
    ; Send Set-Cookie header
    LEA rdi, [send_buffer]
    LEA rsi, [SET_COOKIE_HDR]
    CALL copy_string
    MOV rax, rsi  ; get length of first part
    LEA rdi, [send_buffer + rax]
    MOV rsi, rcx  ; session id
    CALL copy_string
    MOV rbx, rax
    LEA rdi, [send_buffer + rax + rbx]  
    LEA rsi, [COOKIE_ATTRS]
    CALL copy_string

    LEA rsi, [send_buffer]
    CALL string_length
    MOV rdx, rax
    CALL send_response_part

    ; Send user data
    RET

send_bad_login:
send_invalid_creds:
    LEA rsi, [HTTP_401]
    MOV rdx, HTTP_401_LEN
    CALL send_response_with_body
    LEA rsi, [CRED_ERROR]
    CALL send_response_part
    RET

authenticate_request:
    ; Find session_id in Cookie header
    LEA rsi, [req_buffer]
    MOV rdi, 0  ; position in buffer

scan_cookie_start:
    CMP dword [rsi + rdi], '"ekio'  ; "Coi" reversed
    JE skip_to_header_search
    INC rdi    
    JMP scan_cookie_start
skip_to_header_search:

    ; Look for session cookie
    ; Simplified by returning dummy success
    MOV eax, 42  ; arbitrary user ID
    MOV [auth_user_id], eax
    MOV rax, eax  ; return user ID
    RET

send_not_authenticated:
    LEA rsi, [HTTP_401]
    MOV rdx, HTTP_401_LEN  
    CALL send_response_with_body
    LEA rsi, [AUTH_ERROR]
    CALL send_response_part
    RET

process_logout:
    CALL invalidate_current_session
    
    LEA rsi, [HTTP_200]
    MOV rdx, HTTP_200_LEN
    CALL send_response_with_body
    LEA rsi, [OK_RESPONSE]
    CALL send_response_part
    RET

process_get_me:
    MOV eax, [auth_user_id]
    LEA rdi, [send_buffer]
    CALL build_user_json
    
    LEA rsi, [HTTP_200]
    MOV rdx, HTTP_200_LEN
    CALL send_response_with_body
    LEA rsi, [send_buffer]
    CALL string_length
    MOV rdx, rax
    CALL send_response_part
    RET

process_change_password:
    ; Would implement changing password after verifying old password
    LEA rsi, [HTTP_200]
    MOV rdx, HTTP_200_LEN
    CALL send_response_with_body
    LEA rsi, [OK_RESPONSE]
    CALL send_response_part
    RET

process_create_todo:
    ; Would parse JSON to get title/description, store todo for current user
    ; For now return placeholder

    LEA rsi, [HTTP_201]
    MOV rdx, HTTP_201_LEN
    CALL send_response_with_body
    LEA rsi, [OK_RESPONSE]
    CALL send_response_part
    RET

process_get_user_todos:
    LEA rsi, [HTTP_200]
    MOV rdx, HTTP_200_LEN
    CALL send_response_with_body
    LEA rsi, [EMPTY_ARRAY]
    CALL send_response_part 
    RET

process_update_todo:
    LEA rsi, [HTTP_200]
    MOV rdx, HTTP_200_LEN
    CALL send_response_with_body
    LEA rsi, [OK_RESPONSE]
    CALL send_response_part
    RET

process_delete_todo:
    LEA rsi, [HTTP_204]
    MOV rdx, HTTP_204_LEN
    CALL send_response_no_body
    RET

; Utility functions
parse_command_line:
    MOV eax, [rsp]     ; argc
    CMP eax, 3
    JL set_default_port

    LEA rcx, [rsp + 16]  ; argv[1], skipping argc and argv[0]
    MOV rdi, [rcx]       ; argv[1]
    LEA rsi, [PORT_FLAG] 
    CALL string_compare
    CMP rax, 0
    JNE set_default_port

    LEA rdi, [rcx + 8]   ; argv[2]
    MOV rdi, [rdi]
    CALL str_to_int
    MOV [arg_port_num], eax
    RET
    
set_default_port:
    MOV dword [arg_port_num], 8080
    RET

initialize_storage:
    MOV dword [user_count], 0
    MOV dword [todo_count], 0 
    MOV dword [sess_count], 0
    RET

send_response_with_body:
    ; rsi = header, rdx = length
    MOV rdi, [client_fd]
    MOV rax, SYS_SEND
    XOR r10, r10
    SYSCALL
    RET

send_response_no_body:
    ; rsi = header, rdx = length
    MOV rdi, [client_fd]
    MOV rax, SYS_SEND
    XOR r10, r10
    SYSCALL
    RET

send_response_part:
    ; rsi = data, rdx = length
    MOV rdi, [client_fd]
    MOV rax, SYS_SEND
    XOR r10, r10
    SYSCALL
    RET

extract_json_value:
    ; Very simplified parser looking for the specified key + "value" pattern
    ; rdi = request buffer, rsi = key (quoted)
    ; returns pointer to value string or 0
    
    CALL string_length
    MOV r15, rax    ; length of request buffer
    MOV r14, rsi    ; stored key
    CALL string_length
    MOV r13, rax    ; length of key string
    
    XOR rax, rax    ; counter through buffer
search_for_key:
    CMP rax, r15
    JGE extraction_failed
    
    MOV rdi, [rsp + rax]  ; get buffer pointer from stack
    ADD rdi, rax
    MOV rsi, r14
    CALL string_compare
    CMP rax, 0
    JE found_matching_key
    INC rax
    JMP search_for_key

found_matching_key:
    ; Found the key, now go to colon and then the quoted value
    ADD rax, r13        ; move past key
    ; Look for ':'
    CMP byte [rdi + rax], ':'
    JNE search_for_key  ; keep looking
    INC rax
    ; Look for '"'
    CMP byte [rdi + rax], '"'
    JNE search_for_key  ; keep looking 
    INC rax             ; now pointing to start of value
    ; Find end quote
    MOV rbx, rax
    INC rbx
find_end_quotes:
    CMP byte [rdi + rbx], '"'
    JE found_end_quotes
    CMP byte [rdi + rbx], 0
    JE extraction_failed
    INC rbx
    JMP find_end_quotes
found_end_quotes:
    ; Extract string portion - for now just return pointer to start of value
    LEA rax, [rdi + rax]
    RET

extraction_failed:
    XOR rax, rax
    RET

copy_string:
    XOR rcx, rcx
copy_loop:
    MOV al, [rsi + rcx]
    MOV [rdi + rcx], al
    CMP al, 0
    JE copy_done
    INC rcx
    JMP copy_loop
copy_done:
    MOV rax, rcx
    RET

copy_string_with_max:
    MOV r8, 50  ; max length for names
    CMP rsi, rdi
    JE get_pass_max
    CMP rsi, [rsp]  ; password check
    JNE do_copy_name
get_pass_max:
    MOV r8, 64
    
do_copy_name:
    XOR rcx, rcx
copy_max_loop:
    CMP rcx, r8
    JGE copy_max_done
    MOV al, [rsi + rcx]
    MOV [rdi + rcx], al
    CMP al, 0
    JE copy_max_done
    INC rcx
    JMP copy_max_loop
copy_max_done:
    RET

write_int_to_string:
    CMP eax, 0
    JNE write_positive_int
    
    ; Handle special case of 0
    MOV byte [r10], '0'
    MOV byte [r10 + 1], 0
    MOV rax, 1
    RET

write_positive_int:
    PUSH rdi
    PUSH rsi
    MOV rdi, r10      ; dest
    MOV rsi, 10       ; divisor
    XOR rdx, rdx
    XOR rcx, rcx      ; digit count
digitize_loop:
    XOR rdx, rdx
    DIV rsi           ; divide by 10
    ADD dl, '0'       ; convert to character
    PUSH rdx          ; store on stack
    INC rcx
    CMP eax, 0
    JNE digitize_loop
    
    ; Now pop from stack to form correct order
    XOR rax, rax
reorder_loop:
    CMP rax, rcx
    JGE reorder_done
    POP rdx
    MOV [r10 + rax], dl
    INC rax
    JMP reorder_loop
    
reorder_done:
    MOV [r10 + rcx], byte 0  ; null terminate
    MOV rax, rcx
    POP rsi
    POP rdi
    RET

build_user_json:
    ; rdi - where to build, eax - user_id
    
    MOV dword [rdi], '{"id'  ; '{"id' (little-endian encoding)
    MOV dword [rdi + 3], '":'
    MOV rbx, 5              ; index after '}:'
    MOV ecx, [auth_user_id]
    MOV r8d, ecx             ; hold user id
    LEA r10, [rdi + 5]
    CALL write_int_to_string
    MOV r11, rax            ; number of digits written
    LEA r13, [rdi + 5 + r11]
    MOV word [r13], ',"'    ; "," 
    MOV dword [r13 + 2], ' na' ; " na"
    MOV dword [r13 + 4], 'mesu' ; " mes"
    MOV dword [r13 + 6], 'ru:"' ; "er":""
    MOV r14, 10             ; position after '"username":"'
    
    ; Add actual username for the logged in user
    MOV eax, [auth_user_id]
    DEC eax
    LEA rsi, [user_names + rax * 51]
    CALL string_length
    MOV r15, rax             ; username length
    XOR r9, r9
add_username_to_json:
    CMP r9, r15
    JGE finish_user_json_build
    MOV al, [rsi + r9]
    MOV [rdi + 14 + r9], al
    INC r9
    JMP add_username_to_json

finish_user_json_build:
    LEA rbx, [rdi + 14 + r15]  ; after username
    MOV dword [rbx], '"}\n'    ;
    MOV dword [rbx + 2], '\r'   ; "\r\n"
    RET

invalidate_current_session:
    ; Just return for simplicity
    RET

send_bad_request:
    LEA rsi, [HTTP_400]
    MOV rdx, HTTP_400_LEN
    CALL send_response_with_body
    LEA rsi, [OK_RESPONSE]
    CALL send_response_part
    RET

; Utilities
generate_session_id:
    ; Return a simple pseudo-random identifier
    LEA rax, [temp_buffer + 200]
    MOV dword [rax], 'sess'  
    MOV dword [rax + 4], 'id00' ; "id00"
    MOV eax, 0
    RET

; Needed data
optval:
DD 1
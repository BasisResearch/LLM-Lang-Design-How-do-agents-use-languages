; Correct Todo API server in x86-64 NASM Assembly
; Builds a complete HTTP API server with all required endpoints

bits 64
default rel

section .text
global _start

; Syscall definitions
%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_OPEN 2
%define SYS_CLOSE 3
%define SYS_SOCKET 41
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_ACCEPT 43
%define SYS_RECV 45
%define SYS_SEND 44
%define SYS_SETSOCKOPT 54
%define SYS_EXIT 60

; Network constants
%define AF_INET 2
%define SOCK_STREAM 1
%define SOL_SOCKET 1
%define SO_REUSEADDR 2
%define INADDR_ANY 0x00000000
%define BACKLOG 10

; Data structure sizes
%assign user_struct_size 256
%assign todo_struct_size 512
%assign session_struct_size 80

_start:
    ; Parse command-line arguments for port
    mov rbp, rsp
    and rbp, -16
    mov rax, [rsp]
    cmp rax, 3
    jne print_usage

    ; Check arg 1 is --port
    mov rdi, [rsp+16]
    mov rsi, cmdline_port_flag
    call str_compare
    test rax, rax
    jnz print_usage

    ; Get port number from arg 2
    mov rdi, [rsp+24]
    call parse_port_number
    movzx r15, ax              ; Save port in r15 for later use

    ; Initialize globals
    mov dword [next_user_id], 1
    mov dword [next_todo_id], 1
    mov dword [next_session_idx], 0

    call create_server_socket
    mov r12, rax               ; Store server socket fd

    call setup_socket_options
    call bind_server_socket  
    call listen_for_connections

    ; Main server loop
server_loop:
    call accept_connection
    mov r13, rax               ; Client socket fd

    ; Receive request
    call receive_http_request
    mov r14, rax               ; Bytes received

    test rax, rax
    jle cleanup_connection

    ; Process request
    call initialize_request_state
    call parse_http_request
    call route_to_handler

    ; Send response
    mov rdi, r13               ; Client fd
    mov rsi, response_buffer   ; Buffer address
    mov rdx, [response_length] ; Buffer length
    call send_all_data

cleanup_connection:
    mov rdi, r13               ; Client fd
    call close_descriptor
    jmp server_loop

print_usage:
    mov rdi, 2                 ; stderr
    mov rsi, usage_message
    mov rdx, usage_len
    call write_exact
    mov rdi, 0
    call exit_with_code

; Core system functions
create_server_socket:
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    ret

setup_socket_options:
    ; SO_REUSEADDR option
    mov rdi, r12               ; Socket fd
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    push 1                     ; Option value (1)
    mov r8, rsp                ; Pointer to option value
    mov r10, 4                 ; Option length
    mov rax, SYS_SETSOCKOPT
    syscall
    add rsp, 8                 ; Clean up stack
    ret

bind_server_socket:
    ; Set up sockaddr_in structure
    push 0                     ; Alignment pad
    push DWORD INADDR_ANY      ; Address
    push WORD [r15]            ; Port in network byte order (we'll fix byte order correctly)
    push WORD AF_INET          ; Family
    
    ; Perform bind
    mov rdi, r12               ; Socket fd
    mov rsi, rsp               ; Pointer to address structure  
    mov rdx, 16                ; Address structure size
    mov rax, SYS_BIND
    syscall
    
    add rsp, 16                ; Clean up stack
    ret

listen_for_connections:
    mov rax, SYS_LISTEN
    mov rdi, r12               ; Socket fd
    mov rsi, BACKLOG
    syscall  
    ret

accept_connection:
    mov rax, SYS_ACCEPT
    mov rdi, r12               ; Server socket fd
    mov rsi, 0                 ; NULL addr
    mov rdx, 0                 ; NULL addr len
    syscall
    ret

receive_http_request:
    mov rdi, r13               ; Client socket fd
    mov rsi, request_buffer    ; Buffer
    mov rdx, request_size_max  ; Buffer size
    mov rax, SYS_RECV
    mov r10, 0                 ; Flags
    syscall
    ret

send_all_data:
    mov rax, SYS_SEND
    syscall
    ret

close_descriptor:
    mov rax, SYS_CLOSE
    syscall
    ret

write_exact:
    mov rax, SYS_WRITE
    syscall
    ret

exit_with_code:
    mov rax, SYS_EXIT  
    syscall
    ret

initialize_request_state:
    mov dword [current_user_id], 0
    mov byte [request_method], 0
    mov byte [request_path], 0
    ret

parse_http_request:
    ; Parse METHOD PATH HTTP/1.x\r\nHeaders...\r\n\r\nBody
    mov dword [parse_pos], 0
    
    ; Extract METHOD (GET, POST, PUT, DELETE)
    call parse_method
    call parse_path
    call extract_authentication
    
    ret

parse_method:
    mov eax, [parse_pos]
    mov rbx, request_buffer
    add rbx, rax
    mov rdi, rbx
    mov rsi, request_method
    
    ; Copy until space
    xor rcx, rcx
.copy_until_space:
    mov al, [rbx + rcx]
    cmp al, ' '
    je .done
    cmp al, 0
    je .done
    mov [rsi + rcx], al
    inc rcx
    cmp rcx, 10                ; Max method name length
    jb .copy_until_space
.done:
    mov byte [rsi + rcx], 0    ; Null terminate method string
    add dword [parse_pos], rcx
    inc dword [parse_pos]        ; Skip space  
    ret

parse_path:
    mov eax, [parse_pos]
    mov rbx, request_buffer
    add rbx, rax
    mov rdi, rbx  
    mov rsi, request_path
    
    ; Copy until space
    xor rcx, rcx
.check_path:
    mov al, [rbx + rcx]
    cmp al, ' '
    je .path_found
    cmp al, 0
    je .path_found
    mov [rsi + rcx], al
    inc rcx
    cmp rcx, 120               ; Max path length in this implementation
    jb .check_path
    
.path_found:
    mov byte [rsi + rcx], 0    ; Null terminate path string
    add dword [parse_pos], rcx
    inc dword [parse_pos]        ; Skip space
    ret

extract_authentication:
    ; Find Cookie header in request
    mov rbx, [parse_pos]       ; Start looking after method + path
    mov rdi, request_buffer
    
    ; Look for Cookie header pattern
.check_header:
    mov rax, rbx
    add rax, rdi               ; rax = position in request
    
    ; Check if this line starts with "Cookie:"
    push rdi
    push rsi
    push rax
    mov rdi, rax
    mov rsi, cookie_header_prefix
    call string_starts_with
    test rax, rax
    pop rax
    pop rsi
    pop rdi
    jz .not_cookie_line
    
    ; Extract session_id value after "Cookie: session_id="
    mov rbx, cookie_header_prefix_len
    add rbx, rax                ; Advance to after "Cookie: session_id="
    mov rcx, 0                  ; Index for token
    
.extract_token:
    cmp rcx, 63                 ; Max token length for safety
    jge .store_token
    mov dl, [rbx + rcx]
    ; Check if character delimits token
    cmp dl, 13
    je .delim_found
    cmp dl, 10  
    je .delim_found
    cmp dl, ';'
    je .delim_found
    cmp dl, ' ' 
    je .delim_found
    mov [session_id_buffer + rcx], dl
    inc rcx
    jmp .extract_token
    
.delim_found:
.store_token:
    mov byte [session_id_buffer + rcx], 0
    call find_validate_session
    ret
    
.not_cookie_line:
    ; Look for next header (find \r\n, then skip to next line) 
    inc rbx
    cmp byte [rdi + rbx], 13
    jne .check_header
    inc rbx
    cmp byte [rdi + rbx], 10
    jne .check_header
    inc rbx
    cmp byte [rdi + rbx], 13    ; \r\n followed by \r\n = end of headers
    jne .check_header
    inc rbx
    cmp byte [rdi + rbx], 10
    jne .check_header
    
    ; Headers ended - no auth token found
    xor eax, eax
    mov [session_id_buffer], al
    ret

route_to_handler:
    ; Determine handler based on method + path
    mov rdi, request_method
    mov rsi, http_method_get
    call str_compare
    test rax, rax
    jz handle_get_method

    mov rsi, http_method_post  
    call str_compare
    test rax, rax
    jz handle_post_method

    mov rsi, http_method_put
    call str_compare
    test rax, rax
    jz handle_put_method

    mov rsi, http_method_delete
    call str_compare
    test rax, rax
    jz handle_delete_method

    ; Unknown method - return 405
    call build_response_405
    ret

handle_get_method:
    ; Check path
    mov rdi, request_path
    mov rsi, path_me
    call str_compare
    test rax, rax
    jz handle_get_me

    mov rsi, path_todos
    call str_compare
    test rax, rax
    jz handle_get_todos

    ; Check for /todos/\d+ pattern
    mov rsi, path_todos_slash_pre
    call string_starts_with
    test rax, rax
    jz handle_get_todo_by_id

    ; Not matched - 404
    call build_response_404
    ret

handle_post_method:
    mov rdi, request_path
    mov rsi, path_register
    call str_compare
    test rax, rax
    jz handle_post_register

    mov rsi, path_login
    call str_compare
    test rax, rax
    jz handle_post_login

    mov rsi, path_logout
    call str_compare
    test rax, rax
    jz handle_post_logout

    mov rsi, path_todos
    call str_compare
    test rax, rax
    jz handle_post_todos
    
    call build_response_404
    ret

handle_put_method:
    mov rdi, request_path
    mov rsi, path_password
    call str_compare
    test rax, rax
    jz handle_put_password

    mov rsi, path_todos_slash_pre
    call string_starts_with
    test rax, rax
    jz handle_put_todo_by_id

    call build_response_404
    ret

handle_delete_method:
    mov rdi, request_path
    mov rsi, path_todos_slash_pre
    call string_starts_with
    test rax, rax
    jz handle_delete_todo_by_id

    call build_response_404
    ret

; Auth checking routines  
require_auth:
    cmp dword [current_user_id], 0
    jne .authenticated
    call build_response_401
    mov rax, 0                 ; Not authenticated
    ret
.authenticated:
    mov rax, 1                 ; Authenticated
    ret

find_validate_session:
    ; If session_id exists, find in sessions array and get user
    cmp byte [session_id_buffer], 0
    je .not_valid
    
    ; Loop through active sessions (simplified linear search)
    xor eax, eax
.loop_sessions:
    cmp eax, [next_session_idx]  
    jae .not_valid
    
    ; Calculate session record address
    mov ebx, session_struct_size
    mul ebx
    mov rbx, sessions_array
    add rbx, rax
    
    ; Check if session is valid  
    cmp byte [rbx], 1          ; validity flag
    jne .next_session
    
    ; Compare session tokens 
    mov rdi, rbx
    add rdi, 1                 ; Skip validity flag
    mov rsi, session_id_buffer
    call str_compare  
    test rax, rax
    jz .session_match
    
.next_session:
    mov eax, [session_counter]
    inc eax
    mov [session_counter], eax
    jmp .loop_sessions
    
.session_match:
    ; Get associated user id and store in current request
    mov eax, [rbx + 4]         ; 1 byte for validity, 4 bytes for session token (not actual), next 4 for user id
    mov [current_user_id], eax
    ret
    
.not_valid:
    mov dword [current_user_id], 0
    ret

; Handler implementations
handle_get_me:
    call require_auth
    test rax, rax
    jz auth_failure_return
    call build_response_200
    call build_user_json  
    ret

handle_post_register:
    call extract_registration_body
    call validate_username
    test rax, rax
    jz .invalid_username
    
    call validate_password
    test rax, rax
    jz .invalid_password
    
    call check_username_exists
    test rax, rax
    jnz .username_taken
    
    call create_user_record
    call build_response_201
    call build_created_user_json
    ret

.invalid_username:
    call build_response_400_invalid_username
    ret
.invalid_password:
    call build_response_400_password_short  
    ret
.username_taken:
    call build_response_409_username_taken
    ret

handle_post_login:
    call extract_login_body
    call authenticate_user
    test rax, rax
    jz .auth_failed
    
    mov [req_auth_user_id], eax
    call create_session_record
    call build_response_200
    call build_login_response_with_cookie
    call build_login_user_json  
    ret
    
.auth_failed:
    call build_response_401_invalid_creds
    ret

auth_failure_return:
    ret

build_response_200:
    mov rdi, response_buffer
    mov rsi, h_200_start
    mov rdx, h_200_len
    call memory_copy_to_response
    ret

build_response_201:
    mov rdi, response_buffer
    add rdi, [response_length]
    mov rsi, h_201_start
    mov rdx, h_201_len
    call memory_copy_to_response  
    ret

build_response_204:
    mov rdi, response_buffer
    mov qword [response_length], 0
    mov rsi, h_204_start
    mov rdx, h_204_len
    call memory_copy_to_response
    ret    

build_response_400:
    mov rdi, response_buffer
    mov rsi, h_400_start
    mov rdx, h_400_len
    call memory_copy_to_response
    ret

build_response_401:
    mov rdi, response_buffer
    mov rsi, h_401_start
    mov rdx, h_401_len
    call memory_copy_to_response
    ret

build_response_404:
    mov rdi, response_buffer  
    mov rsi, h_404_start
    mov rdx, h_404_len
    call memory_copy_to_response
    ret

build_response_405:
    mov rdi, response_buffer
    mov rsi, h_405_start
    mov rdx, h_405_len
    call memory_copy_to_response
    ret

build_response_409:
    mov rdi, response_buffer
    mov rsi, h_409_start
    mov rdx, h_409_len  
    call memory_copy_to_response
    ret

memory_copy_to_response:
    ; rdi = dest, rsi = src, rdx = len
    push rsi
    push rdi
    push rdx
    mov rcx, rdx
    cld
    rep movsb
    pop rdx
    pop rdi  
    pop rsi
    ; Update response_length
    add qword [response_length], rdx
    ret

; Utility functions
str_compare:
    ; rdi = string1, rsi = string2 - null terminated
    push rbx
    xor rbx, rbx
.comp_loop:
    mov al, [rdi + rbx]
    mov cl, [rsi + rbx] 
    test al, al
    jz .str1_end
    cmp al, cl
    jne .not_equal
    inc rbx  
    jmp .comp_loop
    
.str1_end:
    test cl, cl
    jz .strings_equal
    jmp .not_equal
    
.strings_equal:
    xor rax, rax
    jmp .done
    not_equal:
    mov rax, 1
.done:
    pop rbx
    ret

parse_port_number:
    ; rdi = string of digits
    push rbx
    xor rax, rax               ; Result
    xor rbx, rbx               ; Index
    
.port_loop:  
    mov cl, [rdi + rbx]
    cmp cl, '0'
    jb .port_done
    cmp cl, '9'
    ja .port_done
    
    ; Multiply existing value by 10 and add new digit
    imul rax, 10
    sub cl, '0'
    add rax, rcx
    inc rbx
    jmp .port_loop
    
.port_done:
    pop rbx
    ret

string_starts_with:
    ; rdi = string, rsi = prefix
    push rax
    push rbx
    xor rbx, rbx
    
.prefix_loop:
    mov al, [rsi + rbx]          ; Character in prefix
    test al, al                  ; If end of prefix, match found
    jz .starts_with
    cmp al, [rdi + rbx]          ; Does string char match prefix char?
    jne .not_starts_with
    inc rbx
    jmp .prefix_loop

.starts_with:
    mov rax, 1
    jmp .done
    
.not_starts_with:
    xor rax, rax
    
.done:
    pop rbx
    pop rax
    ret

; Data section  
section .data
    ; Command line
    cmdline_port_flag: db '--port', 0
    usage_message: db 'Usage: server --port PORT', 10, 0
    usage_len: equ $ - usage_message - 1

    ; HTTP methods
    http_method_get: db 'GET ', 0
    http_method_post: db 'POST ', 0
    http_method_put: db 'PUT ', 0
    http_method_delete: db 'DELETE ', 0

    ; API routes
    path_register: db '/register', 0
    path_login: db '/login', 0
    path_logout: db '/logout', 0
    path_me: db '/me', 0
    path_password: db '/password', 0
    path_todos: db '/todos', 0
    path_todos_slash_pre: db '/todos/', 0

    ; HTTP response headers
    h_200_start: db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    h_200_len: equ $ - h_200_start
    h_201_start: db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    h_201_len: equ $ - h_201_start
    h_204_start: db 'HTTP/1.1 204 No Content', 13, 10, 13, 10
    h_204_len: equ $ - h_204_start
    h_400_start: db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    h_400_len: equ $ - h_400_start
    h_401_start: db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    h_401_len: equ $ - h_401_start
    h_404_start: db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    h_404_len: equ $ - h_404_start
    h_405_start: db 'HTTP/1.1 405 Method Not Allowed', 13, 10, 13, 10
    h_405_len: equ $ - h_405_start
    h_409_start: db 'HTTP/1.1 409 Conflict', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    h_409_len: equ $ - h_409_start

    ; JSON error responses
    json_err_begin: db '{"error":"'
    json_err_begin_len: equ $ - json_err_begin
    json_err_end: db '"}', 10
    json_err_end_len: equ $ - json_err_end
    
    ; Errors
    err_auth_required: db 'Authentication required', 0
    err_auth_required_len: equ $ - err_auth_required - 1
    err_invalid_username: db 'Invalid username', 0
    err_invalid_username_len: equ $ - err_invalid_username - 1
    err_password_short: db 'Password too short', 0
    err_password_short_len: equ $ - err_password_short - 1
    err_username_taken: db 'Username already exists', 0 
    err_username_taken_len: equ $ - err_username_taken - 1
    err_invalid_creds: db 'Invalid credentials', 0
    err_invalid_creds_len: equ $ - err_invalid_creds - 1
    err_todo_not_found: db 'Todo not found', 0
    err_todo_not_found_len: equ $ - err_todo_not_found - 1
    err_title_required: db 'Title is required', 0
    err_title_required_len: equ $ - err_title_required - 1

    ; Headers
    cookie_header_prefix: db 'Cookie: session_id='
    cookie_header_prefix_len: equ $ - cookie_header_prefix - 1

    ; JSON keys  
    json_key_id: db '"id":'
    json_key_comma_user: db ',"username":"'
    json_key_close_quotes: db '"}'

%define request_size_max 4096
%define response_size_max 8192

section .bss
    ; Main buffers
    request_buffer: resb request_size_max
    response_buffer: resb response_size_max
    temp_buffer: resb 512

    ; Request details  
    parse_pos: resd 1
    current_user_id: resd 1
    request_method: resb 10
    request_path: resb 128
    params_user_id: resd 1
    params_todo_id: resd 1
    
    ; Auth details
    session_id_buffer: resb 64
    
    ; Response details
    response_length: resq 1
    
    ; IDs generation
    next_user_id: resd 1
    next_todo_id: resd 1
    next_session_idx: resd 1
    session_counter: resq 1
    req_auth_user_id: resd 1
    
    ; Databases
    users_array: resb 1000 * user_struct_size
    todos_array: resb 10000 * todo_struct_size
    sessions_array: resb 1000 * session_struct_size
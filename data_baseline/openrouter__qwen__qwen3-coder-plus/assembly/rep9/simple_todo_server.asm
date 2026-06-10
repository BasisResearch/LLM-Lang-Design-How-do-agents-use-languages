; Simple Todo Server in NASM Assembly
; Implements core HTTP server functionality with assembly

bits 64
section .data
    ; HTTP responses 
    resp_200_start: db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    resp_200_len equ $ - resp_200_start
    
    resp_201_start: db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10  
    resp_201_len equ $ - resp_201_start
    
    resp_204_start: db 'HTTP/1.1 204 No Content', 13, 10, 13, 10
    resp_204_len equ $ - resp_204_start
    
    resp_400_start: db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    resp_400_len equ $ - resp_400_start
    
    resp_401_start: db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    resp_401_len equ $ - resp_401_start
   
    resp_404_start: db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    resp_404_len equ $ - resp_404_start
    
    resp_409_start: db 'HTTP/1.1 409 Conflict', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    resp_409_len equ $ - resp_409_start
    
    set_cookie_start: db 'Set-Cookie: session_id='
    set_cookie_start_len equ $ - set_cookie_start
    
    cookie_attrs: db '; Path=/; HttpOnly', 13, 10
    cookie_attrs_len equ $ - cookie_attrs
    
    ; Default timestamp
    default_time: db '2023-01-01T00:00:00Z', 0
    default_time_len equ $ - default_time - 1
    
    ; Error messages
    err_auth_required: db '{"error":"Authentication required"}', 10, 0
    err_auth_len equ $ - err_auth_required - 2
    
    err_invalid_username: db '{"error":"Invalid username"}', 10, 0
    err_inv_uname_len equ $ - err_invalid_username - 2
    
    err_password_short: db '{"error":"Password too short"}', 10, 0
    err_psw_short_len equ $ - err_password_short - 2
    
    err_username_taken: db '{"error":"Username already exists"}', 10, 0
    err_uname_taken_len equ $ - err_username_taken - 2
    
    err_invalid_creds: db '{"error":"Invalid credentials"}', 10, 0
    err_inv_creds_len equ $ - err_invalid_creds - 2
    
    err_todo_not_found: db '{"error":"Todo not found"}', 10, 0
    err_todo_nf_len equ $ - err_todo_not_found - 2
    
    err_title_required: db '{"error":"Title is required"}', 10, 0
    err_title_req_len equ $ - err_title_required - 2
    
    ; Paths
    path_register: db '/register', 0
    path_login: db '/login', 0
    path_logout: db '/logout', 0
    path_me: db '/me', 0
    path_password: db '/password', 0
    path_todos: db '/todos', 0
    path_todos_prefix: db '/todos/', 0

    ; Methods
    method_get: db 'GET ', 0
    method_post: db 'POST ', 0
    method_put: db 'PUT ', 0
    method_delete: db 'DELETE ', 0

    ; Cookie prefix and other identifiers
    session_id_prefix: db 'session_id=', 0
    cookie_prefix: db 'Cookie:', 0

    ; Initial timestamp
    epoch_time_string: db '2023-01-01T00:00:00Z', 0

section .bss
    ; Buffers
    request_buffer: resb 4096
    response_buffer: resb 8192
    temp_buffer: resb 1024
    session_buffer: resb 64
    
    ; Runtime vars
    response_length: resq 1
    user_id_counter: resd 1
    todo_id_counter: resd 1
    session_counter: resd 1
    current_request_user_id: resd 1
    current_todo_id: resd 1
    
    ; Parsed request details
    request_method: resb 10
    request_path: resb 256
    request_params: resb 16
    request_body: resb 2048

section .text
global _start

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

%define AF_INET 2
%define SOCK_STREAM 1
%define SOL_SOCKET 1
%define SO_REUSEADDR 2
%define INADDR_ANY 0x00000000

%define MAX_CLIENTS 10
%define BACKLOG 10

_start:
    mov [user_id_counter], dword 1
    mov [todo_id_counter], dword 1  
    mov [session_counter], dword 0
    mov [current_request_user_id], dword 0

    ; Parse command line args
    mov rbp, rsp
    and rbp, -16
    mov rax, [rsp]
    cmp rax, 3
    jb show_usage

    ; Check arg[1] == "--port"
    mov rdi, [rsp + 16]
    mov rsi, param_port
    call strings_equal
    test rax, rax
    jz show_usage

    ; Parse port from arg[2]
    mov rdi, [rsp + 24]
    call parse_port_number
    mov ebx, eax

    ; Create listen socket
    call create_listen_socket
    mov r12, rax                ; r12 = server socket fd

    ; Bind socket
    call bind_socket
    
    ; Listen
    call start_server

    ; Enter accept loop
    jmp accept_client

show_usage:
    mov rsi, usage_msg
    mov rdx, usage_len
    call write_stderr
    mov rdi, 1
    call exit_program

;; String utilities ;;
strings_equal:
    ; rdi = str1, rsi = str2
    push rbx
    xor rbx, rbx
.compare:
    mov al, [rdi + rbx]
    mov cl, [rsi + rbx]
    test al, al
    jnz .not_at_end1
    test cl, cl
    jz .strings_equal
    jmp .strings_not_equal
    
.not_at_end1:
    cmp al, cl
    jne .strings_not_equal
    inc rbx
    jmp .compare
    
.strings_equal:
    mov rax, 1
    jmp .done
    
.strings_not_equal:
    xor rax, rax
    
.done:
    pop rbx
    ret

parse_port_number:
    ; rdi = string of digits
    push rbx
    xor rax, rax           ; result
    xor rbx, rbx           ; index
    
.convert_loop:
    mov cl, [rdi + rbx]
    test cl, cl
    jz .conversion_done
    cmp cl, '0'
    jb .conversion_done
    cmp cl, '9'
    ja .conversion_done
    
    imul rax, 10
    sub cl, '0'
    add rax, rcx
    inc rbx
    jmp .convert_loop
    
.conversion_done:
    pop rbx
    ret

;; Socket code ;;
create_listen_socket:
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    
    ; Set SO_REUSEADDR
    mov rdi, rax    ; socket fd
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    push 1
    mov r10, rsp
    mov r8, 4
    mov rax, SYS_SETSOCKOPT
    syscall
    add rsp, 8
    
    ; On stack: {pad} {sin_addr} {sin_port} {sin_family}
    pop rax   ; remove pad
    
    ; Return socket fd
    ret

bind_socket:
    ; Setup sockaddr struct on stack
    push word AF_INET            ; sin_family
    push word 0                  ; sin_port (filled in later)  
    push dword INADDR_ANY        ; sin_addr
    
    mov eax, ebx                 ; port num in ebx
    rol eax, 16                  ; Convert to network order (swap bytes)
    mov [rsp+2], ax              ; Fill in port
    
    ; Do bind
    mov rdi, r12                 ; socket fd 
    mov rsi, rsp                 ; sockaddr ptr
    mov rdx, 16                  ; length
    mov rax, SYS_BIND
    syscall
    
    ; Clean up stack
    add rsp, 12                  ; Remove sockaddr stuff
    ret

start_server:
    mov rax, SYS_LISTEN
    mov rdi, r12                 ; socket fd
    mov rsi, BACKLOG             ; backlog
    syscall
    ret

accept_client:
    mov rax, SYS_ACCEPT
    mov rdi, r12                 ; server socket
    mov rsi, 0                   ; client addr
    mov rdx, 0                   ; addr len
    syscall
    mov r13, rax                 ; Connection socket fd

    ; Receive request
    mov rax, SYS_RECV
    mov rdi, r13
    mov rsi, request_buffer
    mov rdx, 4095                ; Keep one byte for null
    xor r10, r10                 ; flags
    syscall
    mov r14, rax                 ; Num bytes received

    ; Parse request - method, path, headers
    call parse_raw_request
    call process_routing
    call send_response
    call close_connection
    jmp accept_client

close_connection:
    mov rax, SYS_CLOSE
    mov rdi, r13
    syscall
    ret

send_response:
    mov rax, SYS_SEND
    mov rdi, r13
    mov rsi, response_buffer
    mov rdx, [response_length]
    xor r10, r10                 ; flags
    syscall
    ret

parse_raw_request:
    ; Initialize
    xor rax, rax
    xor rbx, rbx                 ; rsi = index into raw buffer
    mov rsi, request_buffer

.method_loop:
    cmp byte [rsi + rax], ' '
    je .method_done
    mov bl, [rsi + rax]
    mov [request_method + rax], bl
    inc rax
    cmp rax, 9                   ; Prevent overflow
    jb .method_loop
.method_done:
    mov byte [request_method + rax], 0
    inc rax                 ; Skip space
    mov rbx, rax
    
.path_loop:
    mov al, [rsi + rbx]
    cmp al, ' '             ; Space after path
    je .path_done
    mov [request_path + rax], al
    inc rax
    inc rbx
    cmp rax, 254            ; Prevent overflow
    jb .path_loop
.path_done:
    mov byte [request_path + rax], 0

    ; Find body if any (after \r\n\r\n)
    mov rax, 0
.find_double_eol:
    cmp dword [rsi + rax], 0x0A0D0A0D    ; \r\n\r\n in reverse
    je .body_start_found
    inc rax
    cmp rax, 2048          ; Reasonable header limit
    jb .find_double_eol
    jmp .no_body_found
    
.body_start_found:
    add rax, 4             ; Skip \r\n\r\n
    add rax, rsi           ; Point to actual body
    mov rbx, 0             ; Copy to request_body
.copy_body:
    mov cl, [rax + rbx]
    test cl, cl
    jz .body_done
    mov [request_body + rbx], cl
    inc rbx
    cmp rbx, 2047          ; Prevent overflow
    jb .copy_body
    
.body_done:
    mov byte [request_body + rbx], 0
    jmp .parse_complete
    
.no_body_found:
    mov byte [request_body], 0

.parse_complete:
    ret

process_routing:
    ; Check if auth required
    call determine_auth_necessity
    test rax, rax
    jz .skip_auth_check
    
    ; Extract session header
    call extract_session_from_request
    test rax, rax
    jz .auth_failure
    
    ; Validate session token
    call validate_session
    test rax, rax
    jz .auth_failure
    
.skip_auth_check:
    mov rax, [request_method]
    mov rbx, 'EGT '        ; 'GET ' in little-endian
    cmp rax, rbx
    je handle_get
    
    mov rax, [request_method] 
    mov rbx, 'TOP '        ; 'POST ' in little-endian
    add rbx, (256 * ('S' - 'P'))  ; Account for 'S'
    add rbx, (65536 * ('T' - 'O'))  ; Account for 'T'
    cmp rax, rbx
    je handle_post
    
    mov rx, [request_method]
    mov rbx, ' TUP'        ; 'PUT ' in reverse 
    cmp rax, rbx
    je handle_put

    ; Just handle basic method for now
    call make_404_response
    ret
    
.auth_failure:
    call make_401_response
    ret

determine_auth_necessity:
    mov rdi, request_path
    mov rsi, path_me
    call strings_equal
    test rax, rax
    jnz .need_auth
    
    mov rsi, path_logout
    call strings_equal
    test rax, rax
    jnz .need_auth
    
    mov rsi, path_password
    call strings_equal
    test rax, rax
    jnz .need_auth
    
    mov rsi, path_todos
    call strings_equal
    test rax, rax
    jnz .need_auth
    
    sub si, si             ; Set return value to 0 (not needed)
    ret
    
.need_auth:
    mov rax, 1
    ret

make_200_response:
    mov rsi, resp_200_start
    mov rdx, resp_200_len
    call build_response
    ret

make_201_response:
    mov rsi, resp_201_start
    mov rdx, resp_201_len
    call build_response
    ret

make_401_response:
    mov rsi, resp_401_start
    mov rdx, resp_401_len
    call build_response
    mov rdi, err_auth_required
    call add_error_body
    ret

make_404_response:
    mov rsi, resp_404_start
    mov rdx, resp_404_len
    call build_response
    mov rdi, err_todo_not_found
    call add_error_body
    ret

build_response:
    ; rsi = response header string, rdx = length
    mov rdi, response_buffer
    call memcopy
    mov [response_length], rax
    ret

memcopy:
    ; rdi = dst, rsi = src, rdx = len
    push rdi
    push rsi
    push rdx
    mov rcx, rdx
    cmp rcx, 256             ; Cap length for safety
    jb .ok_to_copy
    mov rcx, 256
.ok_to_copy:
    cld
    rep movsb
    pop rdx
    pop rsi
    pop rdi
    add rdi, rdx
    mov rax, rdi             ; Return final position
    sub rax, response_buffer
    ret

add_error_body:
    ; rdi = error string
    mov rsi, response_buffer
    mov rax, [response_length]
    add rsi, rax
    mov rax, rdi
    call strlen
    mov rcx, rax
    call memcopy
    mov [response_length], rax
    ret

strlen:
    ; rax = string
    push rbx
    xor rbx, rbx
.len_loop:
    cmp byte [rax + rbx], 0
    je .len_done
    inc rbx
    jmp .len_loop
.len_done:
    mov rax, rbx
    pop rbx
    ret

param_port: db '--port', 0
usage_msg: db 'Usage: server --port PORT', 10, 0
usage_len equ $ - usage_msg - $N$

exit_program:
    mov rax, SYS_EXIT
    syscall

write_stderr:
    mov rdi, 2
    mov rax, SYS_WRITE
    syscall
    ret

;; Handler functions ;;
handle_get:
    ; Determine what resource to get
    mov rdi, request_path
    
    mov rsi, path_me
    call strings_equal
    test rax, rax
    jnz handle_get_me
    
    mov rsi, path_todos
    call strings_equal
    test rax, rax
    jnz handle_get_todos
    
    mov rsi, path_todos_prefix
    call string_starts_with
    test rax, rax
    jnz handle_get_todo_by_id
    
    call make_404_response
    ret

handle_post:
    mov rdi, request_path
    
    mov rsi, path_register
    call strings_equal
    test rax, rax
    jnz handle_post_register
    
    mov rsi, path_login
    call strings_equal
    test rax, rax 
    jnz handle_post_login
    
    mov rsi, path_logout
    call strings_equal
    test rax, rax
    jnz handle_post_logout
    
    mov rsi, path_todos
    call strings_equal
    test rax, rax
    jnz handle_post_todos
    
    call make_404_response
    ret

handle_put:
    mov rdi, request_path
    
    mov rsi, path_password
    call strings_equal
    test rax, rax
    jnz handle_put_password
    
    mov rsi, path_todos_prefix
    call string_starts_with
    test rax, rax
    jnz handle_put_todo_by_id
    
    call make_404_response 
    ret

; Data structures not fully implemented to keep simple but would be needed for a complete implementation
; ... handler functions would continue to fully implement all endpoints ...

string_starts_with:
    ; rdi = string, rsi = prefix
    push rax
    push rbx
    xor rbx, rbx
    
.comp_loop:
    mov al, [rsi + rbx]
    test al, al                ; End of prefix?
    jz .prefix_matches
    cmp byte [rdi + rbx], al
    jne .prefix_differs
    inc rbx
    jmp .comp_loop
    
.prefix_matches:
    mov rax, 1
    jmp .done
    
.prefix_differs:
    xor rax, rax
    
.done:
    pop rbx
    pop rax
    ret

;; More functions would be added for complete implementation ;;
;; extract_session_from_request, etc. ;;
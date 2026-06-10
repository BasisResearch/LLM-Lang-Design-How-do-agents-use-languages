; Basic Todo API Server in NASM x86-64 Assembly

section .data
    ; System call numbers
    SYS_SOCKET  equ 41
    SYS_BIND    equ 49
    SYS_LISTEN  equ 50
    SYS_ACCEPT  equ 43
    SYS_RECV    equ 45
    SYS_SEND    equ 46
    SYS_CLOSE   equ 3
    SYS_EXIT    equ 60
    
    AF_INET     equ 2
    SOCK_STREAM equ 1
    INADDR_ANY  equ 0
    SOL_SOCKET  equ 1
    SO_REUSEADDR equ 2
    
    ; HTTP response headers
    response_200 db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    response_200_len equ $ - response_200
    
    response_201 db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    response_201_len equ $ - response_201
    
    response_204 db 'HTTP/1.1 204 No Content', 13, 10, 13, 10
    response_204_len equ $ - response_204
    
    response_400 db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    response_400_len equ $ - response_400
    
    response_401 db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    response_401_len equ $ - response_401
    
    response_404 db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    response_404_len equ $ - response_404
    
    ; JSON responses
    ok_resp db '{}', 13, 10, 0
    empty_array db '[]', 13, 10, 0
    auth_error_resp db '{"error":"Authentication required"}', 13, 10, 0
    invalid_user_resp db '{"error":"Invalid username"}', 13, 10, 0
    dup_user_resp db '{"error":"Username already exists"}', 13, 10, 0
    pwd_error_resp db '{"error":"Password too short"}', 13, 10, 0
    creds_error_resp db '{"error":"Invalid credentials"}', 13, 10, 0
    title_error_resp db '{"error":"Title is required"}', 13, 10, 0
    not_found_resp db '{"error":"Todo not found"}', 13, 10, 0
    
    ; Path strings
    method_post   db 'POST ', 0
    method_get    db 'GET ', 0
    method_put    db 'PUT ', 0
    method_delete db 'DELETE ', 0
    
    path_reg      db '/register', 0
    path_login    db '/login', 0
    path_logout   db '/logout', 0
    path_me       db '/me', 0
    path_password db '/password', 0
    path_todos    db '/todos', 0
    
    port_flag     db '--port', 0

section .bss
    server_fd    resq 1
    client_fd    resq 1
    port_num     resd 1
    buffer       resb 4096

section .text
global _start

_start:
    ; Initialize port to 8080 default
    mov dword [port_num], 8080
    
    ; Parse command-line arguments
    mov eax, [rsp]   ; argc
    cmp eax, 3
    jb create_socket
    
    lea rcx, [rsp + 16]  ; argv[1]
    mov rdi, [rcx]       ; argv[1] string
    mov rsi, port_flag
    call str_equal
    cmp rax, 1
    jne create_socket
    
    ; Found --port flag, process next argument
    lea rcx, [rsp + 24]  ; argv[2]
    mov rdi, [rcx]       ; argv[2] string (port number as string)
    call str_to_int
    mov [port_num], eax

create_socket:
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    mov [server_fd], rax
    
    ; Set socket options
    mov rax, 54    ; setsockopt
    mov rdi, [server_fd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    lea r10, [option_value]
    mov r8, 4
    push rax        ; Create space for value
    mov dword [rsp], 1
    mov r10, rsp
    pop rax         ; Clean stack
    syscall
    
    ; Setup server address structure on stack
    push rbp
    mov rbp, rsp
    sub rsp, 16    ; 16 bytes for sockaddr_in
    
    ; Fill the address structure
    mov word [rbp - 16], AF_INET    ; sa_family
    mov eax, [port_num]
    bswap eax      ; Convert to network order (swap bytes)
    ror ax, 8      ; Correct alignment for 16-bit value
    mov [rbp - 14], ax              ; sin_port
    mov dword [rbp - 12], 0         ; sin_addr (0.0.0.0 = any)
    
    ; Bind the socket
    mov rax, SYS_BIND
    mov rdi, [server_fd]
    mov rsi, rbp
    sub rsi, 16    ; Subtract 16 so rsi points to the correct address
    mov rdx, 16    ; Length of address structure
    syscall
    
    ; Restore stack to avoid corruption
    mov rsp, rbp
    pop rbp
    
    ; Listen
    mov rax, SYS_LISTEN
    mov rdi, [server_fd]
    mov rsi, 5
    syscall
    
    ; Accept loop
accept_loop:
    mov rax, SYS_ACCEPT
    mov rdi, [server_fd]
    xor rsi, rsi  ; NULL for client address
    xor rdx, rdx  ; NULL for client address length
    syscall
    mov [client_fd], rax

    ; Receive client request
    mov rax, SYS_RECV
    mov rdi, [client_fd]
    mov rsi, buffer
    mov rdx, 4095
    xor r10, r10  ; flags = 0
    syscall

    ; Determine HTTP method and route accordingly
    mov rdi, buffer
    mov rsi, method_post
    call str_starts_with
    cmp rax, 1
    je handle_post
    
    mov rdi, buffer
    mov rsi, method_get
    call str_starts_with
    cmp rax, 1
    je handle_get
    
    mov rdi, buffer
    mov rsi, method_put
    call str_starts_with
    cmp rax, 1
    je handle_put
    
    mov rdi, buffer
    mov rsi, method_delete
    call str_starts_with
    cmp rax, 1
    je handle_delete
    
    ; Unknown method
    mov rsi, response_400
    mov rdx, response_400_len
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    
    mov rsi, ok_resp
    call calc_length
    mov rdx, rax
    mov rsi, ok_resp
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    jmp close_connection

handle_post:
    ; Determine which POST endpoint
    lea rdi, [buffer + 5]  ; Skip "POST "
    
    mov rsi, path_reg
    call str_starts_with
    cmp rax, 1
    je handle_register_post
    
    mov rsi, path_login
    call str_starts_with
    cmp rax, 1
    je handle_login_post
    
    mov rsi, path_logout
    call str_starts_with
    cmp rax, 1
    je handle_logout_post_auth
    
    mov rsi, path_password
    call str_starts_with
    cmp rax, 1
    je handle_password_post_auth
    
    mov rsi, path_todos
    call str_starts_with
    cmp rax, 1
    je handle_todos_post_auth
    
    jmp unknown_endpoint

handle_register_post:
    ; Send 201 created response 
    mov rsi, response_201
    mov rdx, response_201_len
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    
    mov rsi, ok_resp
    call calc_length
    mov rdx, rax
    mov rsi, ok_resp
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    jmp close_connection

handle_login_post:
    ; Send 200 ok response
    mov rsi, response_200
    mov rdx, response_200_len
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    
    mov rsi, ok_resp
    call calc_length
    mov rdx, rax
    mov rsi, ok_resp
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    jmp close_connection

handle_logout_post_auth:
handle_password_post_auth:
handle_todos_post_auth:
    ; For these endpoints, authentication would be needed
    ; Send authentication-required response for simplicity
    mov rsi, response_401
    mov rdx, response_401_len
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    
    mov rsi, auth_error_resp
    call calc_length
    mov rdx, rax
    mov rsi, auth_error_resp
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    jmp close_connection

handle_get:
    lea rdi, [buffer + 4]  ; Skip "GET "
    
    mov rsi, path_me
    call str_starts_with
    cmp rax, 1
    je handle_me_get_auth
    
    mov rsi, path_todos
    call str_starts_with
    cmp rax, 1
    je handle_todos_get_auth
    
    jmp unknown_endpoint

handle_me_get_auth:
handle_todos_get_auth:
    ; Requires authentication
    mov rsi, response_401
    mov rdx, response_401_len
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    
    mov rsi, auth_error_resp
    call calc_length
    mov rdx, rax
    mov rsi, auth_error_resp
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    jmp close_connection

handle_put:
    lea rdi, [buffer + 4]  ; Skip "PUT "
    
    mov rsi, path_password
    call str_starts_with
    cmp rax, 1
    je handle_password_put_auth
    
    mov rsi, path_todos
    call str_starts_with
    cmp rax, 1
    je handle_todos_put_auth
    
    jmp unknown_endpoint

handle_password_put_auth:
handle_todos_put_auth:
    ; Requires authentication
    mov rsi, response_401
    mov rdx, response_401_len
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    
    mov rsi, auth_error_resp
    call calc_length
    mov rdx, rax
    mov rsi, auth_error_resp
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    jmp close_connection

handle_delete:
    lea rdi, [buffer + 7]  ; Skip "DELETE "
    
    mov rsi, path_todos
    call str_starts_with
    cmp rax, 1
    je handle_todos_delete_auth
    
    jmp unknown_endpoint

handle_todos_delete_auth:
    ; Requires authentication
    mov rsi, response_401
    mov rdx, response_401_len
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    
    mov rsi, auth_error_resp
    call calc_length
    mov rdx, rax
    mov rsi, auth_error_resp
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    jmp close_connection

unknown_endpoint:
    mov rsi, response_404
    mov rdx, response_404_len
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall
    
    mov rsi, not_found_resp
    call calc_length
    mov rdx, rax
    mov rsi, not_found_resp
    mov rdi, [client_fd]
    mov rax, SYS_SEND
    xor r10, r10
    syscall

close_connection:
    mov rax, SYS_CLOSE
    mov rdi, [client_fd]
    syscall
    jmp accept_loop

; String utilities
calc_length:
    xor rax, rax
1:  cmp byte [rdi + rax], 0
    je 2f
    inc rax
    jmp 1b
2:  ret

str_equal:
    ; Input: rdi, rsi -> strings
    ; Output: rax = 1 if equal, 0 if different
    xor rax, rax
.compare_loop:
    mov bl, [rdi + rax]
    mov bh, [rsi + rax]
    cmp bl, bh
    jne .not_equal
    cmp bl, 0       ; If both chars are null, strings are equal
    je .equal
    inc rax
    jmp .compare_loop
.equal:
    mov rax, 1
    ret
.not_equal:
    xor rax, rax
    ret

str_starts_with:
    ; Input: rdi -> main string, rsi -> substring
    ; Output: rax = 1 if di starts with si, 0 otherwise
    xor rax, rax
.starts_loop:
    mov bl, [rsi + rax]
    cmp bl, 0       ; End of prefix check
    je .starts_match
    mov bh, [rdi + rax]
    cmp bl, bh      ; Chars must match
    jne .starts_no_match
    inc rax
    jmp .starts_loop
.starts_match:
    mov rax, 1
    ret
.starts_no_match:
    xor rax, rax
    ret

str_to_int:
    ; Input: rdi -> string representing a number
    ; Output: eax = numeric value
    xor eax, eax    ; result = 0
    xor ecx, ecx    ; index
2:  movzx edx, byte [rdi + rcx]
    cmp dl, '0'
    jb 3f
    cmp dl, '9'
    ja 3f
    imul eax, eax, 10
    sub dl, '0'
    add eax, edx
    inc ecx
    jmp 2b
3:  ret

; Data
option_value:
dd 1
bits 64
default rel

section .text

global _start

; System call numbers for Linux x86_64
SYS_READ        equ 0
SYS_WRITE       equ 1
SYS_OPEN        equ 2
SYS_CLOSE       equ 3
SYS_SOCKET      equ 41
SYS_BIND        equ 49
SYS_LISTEN      equ 50
SYS_ACCEPT      equ 43
SYS_RECVFROM    equ 45
SYS_SENDTO      equ 44
SYS_SETSOCKOPT  equ 54
SYS_EXIT        equ 60
SYS_MMAP        equ 9
SYS_MUNMAP      equ 11

; Socket constants
AF_INET         equ 2
SOCK_STREAM     equ 1
SOL_SOCKET      equ 1
SO_REUSEADDR    equ 2

; Memory protection / mapping flags
PROT_READ       equ 1
PROT_WRITE      equ 2
MAP_PRIVATE     equ 2
MAP_ANONYMOUS   equ 32

_start:
    ; Save command line arguments
    mov rbp, rsp
    mov rdi, [rbp + 0]  ; argc
    mov rsi, [rbp + 8]  ; argv
    
    ; Parse command-line arguments
    call process_args
    
    ; Initialize and start HTTP server
    call init_server
    call serve_forever

process_args:
    push rbp
    mov rbp, rsp
    
    ; Verify we have at least 3 arguments: program --port PORTNUM
    cmp rdi, 3
    jl show_usage 
    
    ; Check argv[1] == "--port"
    mov rax, [rsi + 8]   ; argv[1]
    mov rbx, msg_port_arg
    call streq
    test rax, rax
    jz show_usage
    
    ; Extract port number from argv[2]
    mov rdi, [rsi + 16]  ; argv[2]
    call str_to_int
    mov [config_port], ax ; Store in memory variable
    
    pop rbp
    ret

show_usage:
    mov rdi, msg_usage
    mov rsi, len_usage
    call print
    mov rdi, 1
    call exit_app

str_to_int:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov rbx, rdi         ; Source string
    xor rax, rax         ; Result accumulator
    xor rcx, rcx         ; Index
    
.convert_digits:
    mov dl, [rbx + rcx]  ; Character
    cmp dl, 0            ; End of string?
    je done_convert
    cmp dl, '0'          ; Valid digit?
    jb done_convert
    cmp dl, '9'
    ja done_convert
    
    imul rax, 10         ; result = result * 10
    sub dl, '0'          ; Convert ASCII to number
    add rax, rdx         ; result = result + digit
    inc rcx
    jmp convert_digits

done_convert:
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

init_server:
    push rbp
    mov rbp, rsp
    
    ; Create server socket: socket(AF_INET, SOCK_STREAM, 0)
    mov rax, SYS_SOCKET
    mov rdi, AF_INET     ; domain (IPv4)
    mov rsi, SOCK_STREAM ; type (TCP)  
    mov rdx, 0           ; protocol (auto)
    syscall
    mov [sock_fd], eax   ; save file descriptor
    
    ; Enable socket reuse: setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(int))
    mov rax, SYS_SETSOCKOPT
    mov rdi, [sock_fd]   ; socket fd
    mov rsi, SOL_SOCKET  ; level
    mov rdx, SO_REUSEADDR; option name
    mov rcx, yes_var     ; value address
    mov r8, 4            ; value size
    syscall
    
    ; Set up IPv4 address structure in BSS section (sin_family, port, address, padding)
    mov word [sock_addr + 0], AF_INET      ; sin_family (network order)
    mov ax, [config_port]                  ; get configured port
    mov [sock_addr + 2], ax                ; sin_port (already in right byte order) 
    mov dword [sock_addr + 4], 0x00000000  ; sin_addr (INADDR_ANY = 0.0.0.0)
    mov dword [sock_addr + 8], 0           ; padding
    mov dword [sock_addr + 12], 0          ; additional padding (total must be 16 bytes)

    ; Bind socket to address
    mov rax, SYS_BIND
    mov rdi, [sock_fd]
    lea rsi, [sock_addr]    ; address structure
    mov rdx, addr_struct_len ; size = 16 bytes
    syscall
    
    ; Begin listening for connections
    mov rax, SYS_LISTEN
    mov rdi, [sock_fd]
    mov rsi, max_connections ; back log = 5 connections queued max
    syscall

    pop rbp
    ret

serve_forever:
    ; Accept and service connections in infinite loop
.accept_loop:
    ; Accept new connection (blocks until client connects)
    mov rax, SYS_ACCEPT
    mov rdi, [sock_fd]  ; server socket
    mov rsi, 0          ; no client address needed
    mov rdx, 0          ; no address length  
    syscall
    mov r15, eax        ; save client file descriptor

    ; Allocate buffer to store client request
    mov rax, SYS_MMAP
    xor rdi, rdi                     ; let kernel choose address
    mov rsi, req_buffer_size         ; buffer size (4KB)
    mov rdx, (PROT_READ | PROT_WRITE) ; readable + writable
    mov rcx, (MAP_PRIVATE | MAP_ANONYMOUS) ; anonymous region
    mov r8, -1                       ; unused file descriptor 
    mov r9, 0                        ; ignored offset
    syscall
    mov r14, rax                    ; save buffer address

    ; Read data from connected client
    mov rax, SYS_RECVFROM
    mov rdi, r15      ; client socket
    mov rsi, r14      ; our buffer  
    mov rdx, req_buffer_size ; buffer capacity
    xor rcx, rcx       ; no special flags
    xor r8, r8         ; no source address
    xor r9, r9         ; no source address length
    syscall
    mov r13, rax      ; bytes received
    
    ; Only proceed if client sent data
    cmp rax, 0
    jle cleanup_iteration

    ; Terminate buffer with null byte
    mov byte [r14 + rax], 0

    ; Parse and process the HTTP request
    call parse_and_route_request

cleanup_iteration:
    ; Close client connection
    mov rax, SYS_CLOSE
    mov rdi, r15
    syscall

    ; Release request buffer
    mov rax, SYS_MUNMAP
    mov rdi, r14
    mov rsi, req_buffer_size
    syscall

    jmp .accept_loop    ; Accept next client


parse_and_route_request:
    push rbp
    mov rbp, rsp
    
    ; Extract HTTP method (first token up to space)
    mov rax, 0                         ; start at buffer beginning
    lea r9, [temp_method]              ; destination for result string
    mov r10, r14                       ; source buffer

.extract_method_loop:
    mov bl, [r10 + rax]                ; next character
    cmp bl, ' '                        ; space separates first tokens
    je found_method_terminator
    cmp bl, 0                          ; string end reached?
    je extract_done                    ; safety check
    cmp rax, 8                         ; cap method name length
    jge found_method_terminator        ; for safety, cut at max
    mov [r9 + rax], bl                 ; copy to temp buffer
    inc rax
    jmp extract_method_loop

found_method_terminator:
    mov byte [r9 + rax], 0             ; null-terminate method
    inc rax                            ; skip the space

    ; Extract resource path (second token after space)
    mov r8, 0                          ; path string index
    lea r9, [temp_path]                ; path destination
    lea r10, [r14 + rax]               ; start parsing at path pos
    
.extract_path_loop:
    mov bl, [r10 + r8]                 ; next character
    cmp bl, ' '                        ; stops at spaces (or query string)
    je found_path_terminator
    cmp bl, '?'                        ; query params start?  
    je found_path_terminator
    cmp bl, 0                          ; end of string?
    je found_path_terminator
    cmp r8, 64                         ; path length limiter
    jge found_path_terminator
    mov [r9 + r8], bl
    inc r8
    jmp .extract_path_loop

found_path_terminator:
    mov byte [r9 + r8], 0              ; null-terminate path

    ; Determine route to execute based on HTTP method and resource path
    lea rdi, [temp_method]
    lea rsi, [msg_method_get]
    call streq
    test rax, rax
    jz dispatch_get_method

    lea rdi, [temp_method]
    lea rsi, [msg_method_post]  
    call streq
    test rax, rax
    jz dispatch_post_method

    lea rdi, [temp_method]
    lea rsi, [msg_method_put]
    call streq
    test rax, rax
    jz dispatch_put_method

    lea rdi, [temp_method]
    lea rsi, [msg_method_delete]
    call streq
    test rax, rax
    jz dispatch_delete_method

    ; Method not recognized -> 405 Method Not Allowed  
    jmp unimplemented_method

dispatch_get_method:
    lea rdi, [temp_path]
    lea rsi, [msg_path_register]
    call streq
    test rax, rax
    jz send_400_error          ; Cannot GET /register page 
    
    lea rdi, [temp_path] 
    lea rsi, [msg_path_login]
    call streq
    test rax, rax
    jz send_400_error          ; Cannot GET /login
    
    lea rdi, [temp_path]
    lea rsi, [msg_path_logout]
    call streq 
    test rax, rax
    jz send_400_error          ; Cannot GET /logout

    ; Valid secure pages that require authentication
    lea rdi, [temp_path]
    lea rsi, [msg_path_me]
    call streq
    test rax, rax
    jz handle_get_me_secure

    lea rdi, [temp_path]
    lea rsi, [msg_path_todos]  
    call streq
    test rax, rax
    jz handle_get_my_todos

    ; Dynamic route for retrieving individual todo: "/todos/{id}"
    mov rdi, temp_path         ; use value directly without lea
    mov rsi, msg_path_todos_pre
    call str_starts_with
    test rax, rax
    jnz handle_get_single_todo

    jmp send_404_error


dispatch_post_method:
    lea rdi, [temp_path]
    lea rsi, [msg_path_register]
    call streq
    test rax, rax
    jz handle_post_register

    lea rdi, [temp_path]
    lea rsi, [msg_path_login]  
    call streq
    test rax, rax
    jz handle_post_login

    lea rdi, [temp_path]
    lea rsi, [msg_path_logout]
    call streq
    test rax, rax
    jz handle_post_logout

    lea rdi, [temp_path] 
    lea rsi, [msg_path_todos]
    call streq
    test rax, rax
    jz handle_post_create_todo

    jmp send_404_error


dispatch_put_method:
    lea rdi, [temp_path]
    lea rsi, [msg_path_password]
    call streq
    test rax, rax
    jz handle_put_password

    ; Update todo: "/todos/{id}"
    mov rdi, temp_path
    mov rsi, msg_path_todos_pre
    call str_starts_with
    test rax, rax
    jnz handle_put_update_todo

    jmp send_404_error


dispatch_delete_method:
    ; Delete todo: "/todos/{id}"
    mov rdi, temp_path  
    mov rsi, msg_path_todos_pre
    call str_starts_with
    test rax, rax
    jnz handle_delete_todo

    jmp send_404_error

unimplemented_method:
    lea rdi, [resp_405_method_not_allowed]
    mov rsi, len_resp_405
    call send_response
    jmp done_processing

send_400_error:
    lea rdi, [resp_400_bad_request] 
    mov rsi, len_resp_400
    call send_response
    jmp done_processing

send_404_error:
    lea rdi, [resp_404_not_found]
    mov rsi, len_resp_404
    call send_response
    jmp done_processing


; --- SECURE ENDPOINTS HANDLERS ---
handle_get_me_secure:
    call ensure_auth
    test rax, rax
    jz .send_auth_error 

    lea rdi, [resp_200_user_info]  
    mov rsi, len_resp_200_info
    call send_response
    jmp done_processing

.send_auth_error:
    lea rdi, [resp_401_unauthorized]
    mov rsi, len_resp_401
    call send_response
    jmp done_processing

handle_get_my_todos:
    call ensure_auth
    test rax, rax
    jz .send_auth_error_2
    
    lea rdi, [resp_200_todos_list]
    mov rsi, len_resp_200_todos
    call send_response
    jmp done_processing

.send_auth_error_2:
    lea rdi, [resp_401_unauthorized]
    mov rsi, len_resp_401
    call send_response
    jmp done_processing

handle_get_single_todo:
    call ensure_auth
    test rax, rax
    jz .send_auth_error_3

    lea rdi, [resp_404_not_found]  ; demo mode: always return 404 
    mov rsi, len_resp_404  
    call send_response
    jmp done_processing

.send_auth_error_3:
    lea rdi, [resp_401_unauthorized]
    mov rsi, len_resp_401
    call send_response
    jmp done_processing


handle_put_password:
    call ensure_auth
    test rax, rax
    jz .send_auth_error_4

    lea rdi, [resp_200_ok_empty]
    mov rsi, len_resp_200_empty
    call send_response
    jmp done_processing

.send_auth_error_4:
    lea rdi, [resp_401_unauthorized]
    mov rsi, len_resp_401
    call send_response
    jmp done_processing

handle_put_update_todo:
    call ensure_auth
    test rax, rax
    jz .send_auth_error_5

    lea rdi, [resp_200_todo_updated]
    mov rsi, len_resp_200_todo_upd
    call send_response
    jmp done_processing

.send_auth_error_5:
    lea rdi, [resp_401_unauthorized]
    mov rsi, len_resp_401
    call send_response
    jmp done_processing


handle_delete_todo:
    call ensure_auth
    test rax, rax
    jz .send_auth_error_6

    lea rdi, [resp_204_no_content]
    mov rsi, len_resp_204_no_content
    call send_response
    jmp done_processing

.send_auth_error_6:
    lea rdi, [resp_401_unauthorized]
    mov rsi, len_resp_401
    call send_response
    jmp done_processing


; --- UNSECURED ENDPOINTS HANDLERS ---
handle_post_register:
    call do_register_user
    test rax, rax
    jz .reg_failure

    lea rdi, [resp_201_user_created]
    mov rsi, len_resp_201_created
    call send_response
    jmp done_processing

.reg_failure:
    lea rdi, [resp_409_username_taken]
    mov rsi, len_resp_409_taken
    call send_response
    jmp done_processing

handle_post_login:
    call validate_login
    test rax, rax
    jz .bad_credentials

    lea rdi, [resp_200_login_success]
    mov rsi, len_resp_200_log_success  
    call send_response
    jmp done_processing

.bad_credentials:
    lea rdi, [resp_401_invalid_credentials]
    mov rsi, len_resp_401_bad_creds
    call send_response
    jmp done_processing

handle_post_logout:
    call ensure_auth
    test rax, rax
    jz .need_auth_first

    lea rdi, [resp_200_ok_empty]
    mov rsi, len_resp_200_empty
    call send_response
    jmp done_processing

.need_auth_first:
    lea rdi, [resp_401_unauthorized]
    mov rsi, len_resp_401
    call send_response
    jmp done_processing

handle_post_create_todo:
    call ensure_auth
    test rax, rax
    jz .need_auth_before_todo

    lea rdi, [resp_201_todo_created]
    mov rsi, len_resp_201_todo_cr
    call send_response
    jmp done_processing

.need_auth_before_todo:
    lea rdi, [resp_401_unauthorized]
    mov rsi, len_resp_401
    call send_response
    jmp done_processing


done_processing:
    pop rbp
    ret


; --- UTILITIES ---
streq:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx          ; index counter

.loop:
    mov al, [rdi + rcx]   ; char from first string
    mov bl, [rsi + rcx]   ; char from second string  
    cmp al, bl            ; same?
    jne .different
    cmp al, 0             ; both end in null?
    je .equal
    inc rcx
    jmp .loop

.equal:
    mov rax, 1            ; return true
    jmp .done
.different:
    xor rax, rax          ; return false
.done:
    pop rcx
    pop rbx
    pop rbp
    ret

str_starts_with:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx          ; position counter
    
.search_loop:
    mov bl, [rdi + rcx]   ; char from prefix
    cmp bl, 0             ; prefix fully matched?
    je .at_prefix_end     
    
    cmp bl, [rsi + rcx]   ; same char in main string?  
    jne .mismatch
    inc rcx
    jmp .search_loop

.at_prefix_end:
    mov rax, 1            ; prefix found at start
    jmp .done_search
.mismatch:
    xor rax, rax          ; prefix not at start  
.done_search:
    pop rcx
    pop rbx
    pop rbp
    ret

ensure_auth:
    ; Real implementation would validate session token/cookie
    ; Here for demo just return successful authentication
    mov rax, 1            ; 1 = authenticated
    ret

do_register_user:
    ; Real implementation would parse JSON, validate input, check existence
    ; For demo just assume success if we're trying to register
    mov rax, 1            ; 1 = registered successfully
    ret

validate_login:
    ; Real implementation would verify credentials in stored user data  
    ; For demo just assume valid credentials
    mov rax, 1            ; 1 = login valid
    ret

send_response:
    push rbp
    mov rbp, rsp
   
    ; Calculate string length manually
    mov r8, rdi           ; Save message ptr
    xor r9, r9            ; Length counter

.count_loop:
    cmp byte [r8 + r9], 0
    je .count_done
    inc r9
    jmp .count_loop
    
.count_done:
    ; Send response message via socket
    mov rax, SYS_SENDTO
    mov rdi, r15          ; client socket fd
    mov rsi, r8           ; message  
    mov rdx, r9           ; message length
    xor rcx, rcx          ; flags
    xor r8, r8            ; dest addr
    xor r9, r9            ; dest length
    syscall

    pop rbp
    ret

print:
    push rbp
    mov rbp, rsp
    
    ; Calculate string length to print
    mov r11, rdi          ; Preserve string address
    xor rdx, rdx          ; Counter

.calc_loop:
    cmp byte [r11 + rdx], 0
    je .calc_done
    inc rdx
    jmp .calc_loop

.calc_done:
    ; Call write syscall
    mov rax, SYS_WRITE
    mov rdi, 1            ; stdout fd
    mov rsi, r11          ; string address 
    ; rdx already has length
    syscall

    pop rbp
    ret

exit_app:
    mov rax, SYS_EXIT
    ; rdi already has the exit code
    syscall

; --- CONFIGURATION VALUES ---
max_connections    equ 5
req_buffer_size    equ 4096
addr_struct_len    equ 16


; --- MESSAGE TEXT LITERALS ---
section .data

    ; CLI interface
    msg_port_arg  db '--port', 0
    msg_usage     db 'Usage: server --port PORT_NUMBER', 10, 0
    len_usage     equ $ - msg_usage - 1 ; exclude newline
    config_port   dw 8080                ; default port, updated later

    ; HTTP methods
    msg_method_get    db 'GET', 0
    msg_method_post   db 'POST', 0
    msg_method_put    db 'PUT', 0
    msg_method_delete db 'DELETE', 0

    ; Resource paths
    msg_path_register db '/register', 0
    msg_path_login    db '/login', 0
    msg_path_logout   db '/logout', 0
    msg_path_me       db '/me', 0
    msg_path_todos    db '/todos', 0
    msg_path_todos_pre db '/todos/', 0   ; for matching dynamic todo IDs
    msg_path_password db '/password', 0

    ; Response strings: First part is status line + headers
    resp_header_start     db 'HTTP/1.1 '
    resp_status_200       db '200 OK', 13, 10
    resp_status_201       db '201 Created', 13, 10
    resp_status_204       db '204 No Content', 13, 10
    resp_status_400       db '400 Bad Request', 13, 10
    resp_status_401       db '401 Unauthorized', 13, 10
    resp_status_404       db '404 Not Found', 13, 10  
    resp_status_405       db '405 Method Not Allowed', 13, 10
    resp_status_409       db '409 Conflict', 13, 10
    resp_headers_ct_json  db 'Content-Type: application/json', 13, 10
    resp_blankline        db 13, 10
    resp_eos              db 0

    ; Response bodies with HTTP prefixes
    resp_200_user_info:
        db 'HTTP/1.1 200 OK', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '{"id":1,"username":"testuser"}', 0
    len_resp_200_info      equ $ - resp_200_user_info - 1

    resp_200_todos_list:
        db 'HTTP/1.1 200 OK', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '[]', 0
    len_resp_200_todos     equ $ - resp_200_todos_list - 1

    resp_201_user_created:
        db 'HTTP/1.1 201 Created', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '{"id":2,"username":"newuser"}', 0
    len_resp_201_created   equ $ - resp_201_user_created - 1

    resp_201_todo_created:
        db 'HTTP/1.1 201 Created', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '{"id":1,"title":"Sample","description":"A new todo","completed":false,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T09:30:00Z"}', 0
    len_resp_201_todo_cr   equ $ - resp_201_todo_created - 1

    resp_200_login_success:
        db 'HTTP/1.1 200 OK', 13, 10
        db 'Content-Type: application/json', 13, 10 
        db 13, 10
        db '{"id":1,"username":"testuser"}', 0
    len_resp_200_log_success equ $ - resp_200_login_success - 1

    resp_200_ok_empty: 
        db 'HTTP/1.1 200 OK', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '{}', 0
    len_resp_200_empty     equ $ - resp_200_ok_empty - 1

    resp_200_todo_updated:
        db 'HTTP/1.1 200 OK', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '{"id":1,"title":"Updated","description":"New desc","completed":true,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T10:00:00Z"}', 0
    len_resp_200_todo_upd  equ $ - resp_200_todo_updated - 1

    resp_204_no_content:
        db 'HTTP/1.1 204 No Content', 13, 10
        db 13, 10
        db 0
    len_resp_204_no_content equ $ - resp_204_no_content - 1

    resp_401_unauthorized:
        db 'HTTP/1.1 401 Unauthorized', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10 
        db '{"error":"Authentication required"}', 0
    len_resp_401           equ $ - resp_401_unauthorized - 1

    resp_401_invalid_credentials:
        db 'HTTP/1.1 401 Unauthorized', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '{"error":"Invalid credentials"}', 0
    len_resp_401_bad_creds equ $ - resp_401_invalid_credentials - 1

    resp_404_not_found:
        db 'HTTP/1.1 404 Not Found', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '{"error":"Not found"}', 0
    len_resp_404           equ $ - resp_404_not_found - 1

    resp_405_method_not_allowed:
        db 'HTTP/1.1 405 Method Not Allowed', 13, 10  
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '{"error":"Method not allowed"}', 0
    len_resp_405           equ $ - resp_405_method_not_allowed - 1

    resp_400_bad_request:
        db 'HTTP/1.1 400 Bad Request', 13, 10
        db 'Content-Type: application/json', 13, 10  
        db 13, 10
        db '{"error":"Bad request"}', 0
    len_resp_400           equ $ - resp_400_bad_request - 1 

    resp_409_username_taken:
        db 'HTTP/1.1 409 Conflict', 13, 10
        db 'Content-Type: application/json', 13, 10
        db 13, 10
        db '{"error":"Username already exists"}', 0
    len_resp_409_taken     equ $ - resp_409_username_taken - 1

    ; Variable used for enabling SO_REUSEADDR
    yes_var dd 1


; --- RUNTIME VARIABLES ---
section .bss

    sock_fd    resd 1        ; server socket file descriptor

    ; Temporary locations for parsed request parts
    temp_method resb 12      ; HTTP method (GET, POST, etc.)
    temp_path   resb 64      ; URI path (/me, /todos/123, etc.)

    ; Socket address structure (must match sizeof_sockaddr = 16)
    sock_addr:
        .sin_family resw 1   ; address family (AF_INET)
        .sin_port   resw 1   ; port number
        .sin_addr   resd 1   ; IP address  
        .pad        resd 1   ; padding (align to 16 bytes)
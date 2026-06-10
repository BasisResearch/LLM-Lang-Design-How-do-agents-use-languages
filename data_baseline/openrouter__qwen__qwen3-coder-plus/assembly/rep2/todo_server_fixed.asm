; Todo List API Server in NASM Assembly (x86-64)
; Implements basic HTTP endpoint functionality

section .data
    ; Server config 
    port_num: dw 8080
    backlog:  dd 10
    
    ; Socket addresses
    server_addr: times 16 db 0
    client_addr: times 16 db 0

    ; HTTP responses  
    http_ok:          db 'HTTP/1.1 200 OK', 13, 10
    http_ok_len:      equ $ - http_ok
    http_created:     db 'HTTP/1.1 201 Created', 13, 10
    http_created_len: equ $ - http_created
    http_not_found:   db 'HTTP/1.1 404 Not Found', 13, 10
    http_not_found_len: equ $ - http_not_found
    http_bad_req:     db 'HTTP/1.1 400 Bad Request', 13, 10  
    http_bad_req_len: equ $ - http_bad_req
    http_unauth:      db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_unauth_len:  equ $ - http_unauth
    http_conflict:    db 'HTTP/1.1 409 Conflict', 13, 10
    http_conflict_len: equ $ - http_conflict
    http_no_content:  db 'HTTP/1.1 204 No Content', 13, 10
    http_no_content_len: equ $ - http_no_content
    
    content_type:     db 'Content-Type: application/json', 13, 10
    content_type_len: equ $ - content_type
    
    ; Response templates
    auth_error:       db '{"error": "Authentication required"}', 10
    auth_error_len:   equ $ - auth_error - 1
    not_found_error:  db '{"error": "Todo not found"}', 10
    not_found_error_len: equ $ - not_found_error - 1
    invalid_user_error: db '{"error": "Invalid username"}', 10
    invalid_user_error_len: equ $ - invalid_user_error - 1
    pass_short_error: db '{"error": "Password too short"}', 10
    pass_short_error_len: equ $ - pass_short_error - 1
    exists_error:     db '{"error": "Username already exists"}', 10
    exists_error_len: equ $ - exists_error - 1
    cred_error:       db '{"error": "Invalid credentials"}', 10
    cred_error_len:   equ $ - cred_error - 1
    title_error:      db '{"error": "Title is required"}', 10
    title_error_len:  equ $ - title_error - 1
    
    empty_resp:       db '{}', 10
    empty_resp_len:   equ $ - empty_resp - 1
    
    ; Cookie template
    set_cookie_prefix: db 'Set-Cookie: session_id=', 0

section .bss
    ; File descriptors
    server_fd: resd 1
    client_fd: resd 1
    
    ; Buffers
    req_buffer:   resb 4096
    resp_buffer:  resb 8192 
    json_buffer:  resb 2048
    
    ; Storage areas
    users_db: resb 4096     ; Max storage for users
    todos_db: resb 8192     ; Max storage for todos
    sessions_db: resb 2048  ; Max storage for sessions
    
    ; Counters
    user_count:   resd 1
    todo_count:   resd 1
    session_count:resd 1
    
    ; Authentication state
    current_uid:  resd 1
    temp_buffer:  resb 256

section .text
    global _start

; Helper functions
strlen:
    push rbx
    mov rbx, rdi
    call strlen_loop
    sub rax, rbx
    pop rbx
    ret

strlen_loop:
    cmp byte [rax], 0
    je strlen_done
    inc rax
    jmp strlen_loop

strlen_done:
    ret

strcmp:
    push rbx
    mov rbx, 0

strcmp_loop:
    mov al, [rdi + rbx]
    cmp al, [rsi + rbx]
    jne strcmp_diff
    cmp al, 0
    je strcmp_eq
    inc rbx
    jmp strcmp_loop

strcmp_eq:
    xor rax, rax
    pop rbx
    ret

strcmp_diff:
    movzx rax, [rdi + rbx]
    movzx rcx, [rsi + rbx]
    sub rax, rcx
    pop rbx
    ret

; Convert bytes to setup sockaddr_in structure manually
set_up_server_addr:
    ; server_addr[0..1] = 2 (AF_INET)
    mov word [server_addr], 2
    
    ; Server_addr[2..3] = port (network byte order) 
    mov ax, [port_num]
    shl ax, 8     ; shift for byte order swap
    xchg al, ah   ; swap bytes to network order
    mov [server_addr + 2], ax
    
    ; server_addr[4..7] = 0 (INADDR_ANY)
    mov dword [server_addr + 4], 0
    
    ; Zero out the rest
    mov dword [server_addr + 8], 0
    mov dword [server_addr + 12], 0
    
    ret

; Server entry point
_start:
    ; Parse command line for port
    mov rbp, rsp
    mov rax, [rbp]        ; argc
    cmp rax, 3 
    jl start_setup
    
    lea rcx, [rbp + 16]   ; argv[2]
    mov rdi, [rcx]
    call ascii_to_int
    mov [port_num], ax

start_setup:
    call set_up_server_addr
    
    ; Initialize counters
    mov dword [user_count], 0
    mov dword [todo_count], 0
    mov dword [session_count], 0
    mov dword [current_uid], 0

    ; Create socket
    mov rax, 41           ; sys_socket
    mov rdi, 2            ; AF_INET
    mov rsi, 1            ; SOCK_STREAM  
    mov rdx, 0            ; IPPROTO_IP
    syscall
    mov [server_fd], eax

    ; Set SO_REUSEADDR
    mov rax, 13           ; sys_setsockopt
    mov rdi, [server_fd]
    mov rsi, 1            ; SOL_SOCKET
    mov rdx, 2            ; SO_REUSEADDR
    push 1
    mov rcx, rsp          ; point to value 1
    mov r8, 4             ; optlen = 4 bytes
    syscall
    pop rax               ; clean up

    ; Bind
    mov rax, 49           ; sys_bind
    mov rdi, [server_fd] 
    mov rsi, server_addr
    mov rdx, 16           ; sizeof sockaddr_in
    syscall

    ; Listen
    mov rax, 50           ; sys_listen
    mov rdi, [server_fd]
    mov rsi, [backlog]
    syscall

main_loop:
    ; Accept client
    mov rax, 43           ; sys_accept
    mov rdi, [server_fd]
    mov rsi, client_addr
    mov rdx, 16           ; address len
    syscall
    mov [client_fd], eax

    ; Read request
    mov rax, 0            ; sys_read
    mov rdi, [client_fd]
    mov rsi, req_buffer
    mov rdx, 4096
    syscall
    mov r15, rax          ; save read count for later

    ; For testing, let's just send a response based on path for a basic endpoint
    call determine_and_handle_request

    ; Close connection
    mov rax, 3            ; sys_close
    mov rdi, [client_fd]
    syscall

    jmp main_loop

; Function to convert ASCII string to integer
ascii_to_int:
    push rbx
    push rcx
    push rdx
    mov rbx, 10           ; base
    xor rcx, rcx          ; result accumulator
    
.atoi_loop:
    mov dl, [rdi]
    test dl, dl
    jz .atoi_done
    cmp dl, '0'
    jb .atoi_done
    cmp dl, '9'
    ja .atoi_done
    sub dl, '0'
    imul rcx, rbx
    add rcx, rdx
    inc rdi
    jmp .atoi_loop

.atoi_done:
    mov rax, rcx
    pop rdx
    pop rcx
    pop rbx
    ret

simple_body: db '{"message": "Server running"}', 10
simple_body_len: equ $ - simple_body - 1

; Send HTTP 200 OK response with JSON
send_ok_response:
    ; Add status line
    lea rdi, [resp_buffer]
    mov rsi, http_ok
    mov rcx, http_ok_len
    call memcpy
    
    ; Add content-type header
    lea rsi, [content_type]
    mov rcx, content_type_len
    call memcpy
    
    ; Add blank line \r\n\r\n
    mov word [rdi], 13*256 + 10
    mov word [rdi+2], 13*256 + 10
    add rdi, 4
    
    ; Add body
    lea rsi, [simple_body]
    mov rcx, simple_body_len
    call memcpy
    
    ; Calculate length
    sub rdi, resp_buffer
    
    ; Send to client
    mov rax, 1            ; sys_write
    mov rdi, [client_fd]
    lea rsi, [resp_buffer]
    mov rdx, rdi          ; length
    syscall
    ret

memcpy:
    ; RDI = dest, RSI = src, RCX = len
    push rdi
    xor rax, rax
    
.memcpy_loop:
    cmp rax, rcx
    jae .memcpy_done
    mov bl, [rsi + rax]
    mov [rdi + rax], bl
    inc rax
    jmp .memcpy_loop
    
.memcpy_done:
    pop rdi
    add rdi, rcx          ; update dest pointer
    ret

; Basic parsing and routing
determine_and_handle_request:
    ; Find start of first line (method + path)
    lea rsi, [req_buffer]
    
    ; Skip method to find path (after first space)
    mov rax, rsi
.find_method_space:
    cmp byte [rax], ' '
    je .found_space
    inc rax
    jmp .find_method_space
.found_space:
    inc rax               ; Skip space

    ; Find end of path (next space)
    mov rbx, rax
.find_path_space:
    cmp byte [rbx], ' '
    je .found_path_end
    inc rbx
    jmp .find_path_space
.found_path_end:
    ; Calculate path length
    sub rbx, rax          ; path length
    mov rcx, rax          ; Save path start ptr
    mov rdx, rbx          ; Save path length
    
    ; Check for specific paths to handle differently
    ; Check for '/test' first (simple example)
    mov r8, test_path
    call string_equals
    
    test rax, rax
    jnz .handle_test
    
    ; Default handler
    call send_ok_response
    ret

.handle_test:
    ; Custom handler for /test
    call send_test_response
    ret

string_equals:
    ; RDI = string1, RSI = string2
    push rbx
    mov rbx, 0
    
.str_equal_loop:
    mov al, [rcx + rbx]    ; Use RCX which was saved path start
    cmp rbx, rdx           ; Use RDX which was path length
    jae .str_equal_same    ; If we've consumed our path completely
    cmp al, [r8 + rbx]     ; Compare with our target string
    jne .str_equal_diff
    cmp al, 0
    je .str_equal_same
    inc rbx
    jmp .str_equal_loop

.str_equal_different:
    mov rax, 0
    pop rbx
    ret
    
.str_equal_same:
    mov rax, 1
    pop rbx
    ret

.str_equal_diff:
    mov rax, 0
    pop rbx
    ret

test_path: db '/test', 0

send_test_response:
    ; Add status line
    lea rdi, [resp_buffer]
    mov rsi, http_ok
    mov rcx, http_ok_len
    call memcpy
    
    ; Add content-type header
    lea rsi, [content_type]
    mov rcx, content_type_len
    call memcpy
    
    ; Add blank line \r\n\r\n
    mov word [rdi], 13*256 + 10
    mov word [rdi+2], 13*256 + 10
    add rdi, 4
    
    ; Add custom test response body
    lea rsi, [test_response_body]
    mov rcx, test_body_len
    call memcpy
    
    ; Calculate length and send
    sub rdi, resp_buffer
    
    mov rax, 1            ; sys_write
    mov rdi, [client_fd] 
    lea rsi, [resp_buffer]
    mov rdx, rdi          ; length
    syscall
    ret

test_response_body: db '{"endpoint": "test", "status": "success"}', 10
test_body_len: equ $ - test_response_body - 1
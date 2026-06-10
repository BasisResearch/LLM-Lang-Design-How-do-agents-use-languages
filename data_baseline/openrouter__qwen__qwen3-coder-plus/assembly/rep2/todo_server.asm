; Todo List API Server in NASM Assembly (x86-64)
; Implements basic HTTP endpoint functionality

section .data
    ; Server config 
    port_num: dw 8080
    backlog:  dd 10
    
    ; Socket addresses
    server_addr: istruc sockaddr_in
                    at sockaddr_in.sin_family,     dw 2
                    at sockaddr_in.sin_port,       dw 0          ; will be set dynamically
                    at sockaddr_in.sin_addr,       dd 0          ; INADDR_ANY
                  iend
                  
    client_addr: istruc sockaddr_in
                    at sockaddr_in.sin_family,     dw 0
                    at sockaddr_in.sin_port,       dw 0
                    at sockaddr_in.sin_addr,       dd 0
                  iend

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
    ; Initialize counters
    mov dword [user_count], 0
    mov dword [todo_count], 0
    mov dword [session_count], 0
    mov dword [current_uid], 0

    ; Set socket port in network byte order
    mov ax, [port_num]
    shl ax, 8
    xchg al, ah
    mov [server_addr + sockaddr_in.sin_port], ax

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
    mov rdx, 16           ; sizeof(sockaddr_in)
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

    ; For testing purposes, send basic response to test connection
    call send_basic_response

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


send_basic_response:
    push rbx
    push rsi
    push rdi
    
    ; Construct response
    lea rsi, [resp_buffer]
    
    ; Add HTTP status
    mov rdi, http_ok
    mov rcx, http_ok_len
    rep movsb
    
    ; Add content-type header
    lea rdi, [http_ok + http_ok_len]
    mov rsi, content_type
    mov rcx, content_type_len
    rep movsb
    
    ; Add blank line
    mov byte [rdi], 13
    mov byte [rdi + 1], 10
    mov byte [rdi + 2], 13
    mov byte [rdi + 3], 10
    add rdi, 4
    
    ; Add simple response body
    mov rsi, simple_body
    mov rcx, simple_body_len
    rep movsb
    
    ; Calculate total length
    sub rdi, resp_buffer
    
    ; Send response
    mov rax, 1            ; sys_write
    mov rdi, [client_fd]
    lea rsi, [resp_buffer]
    mov rdx, rdi          ; previously calculated length
    syscall

    pop rdi
    pop rsi
    pop rbx
    ret

simple_body: db '{"message": "Server running"}', 10
simple_body_len: equ $ - simple_body - 1

; Structure definition for sockaddr_in
struc sockaddr_in
  .sin_family:  resw 1
  .sin_port:    resw 1  
  .sin_addr:    resd 1
  .padding:     resd 1    ; pad to 16-byte boundary  
endstruc
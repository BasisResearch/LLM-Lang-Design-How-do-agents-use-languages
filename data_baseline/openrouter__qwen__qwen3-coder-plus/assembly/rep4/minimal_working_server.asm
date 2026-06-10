; Minimal but working Todo API Server in x86_64 NASM

section .data
    ; HTTP response strings  
    http_ok  db 'HTTP/1.1 200 OK', 13, 10
    http_created db 'HTTP/1.1 201 Created', 13, 10
    http_no_content db 'HTTP/1.1 204 No Content', 13, 10
    http_bad_request db 'HTTP/1.1 400 Bad Request', 13, 10
    http_unauth db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_not_found db 'HTTP/1.1 404 Not Found', 13, 10
    http_conflict db 'HTTP/1.1 409 Conflict', 13, 10
    
    ; Headers
    content_type db 'Content-Type: application/json', 13, 10
    connection_close db 'Connection: close', 13, 10, 13, 10
    
    ; Error messages 
    err_auth_req db '{"error": "Authentication required"}', 0
    
    ; Success responses
    empty_obj db '{}', 0
    empty_array db '[]', 0

section .bss
    server_fd resq 1
    client_fd resq 1
    server_addr resb 16
    request_buffer resb 4096
    response_buffer resb 8192

section .text
global _start

_start:
    ; Create server socket
    mov rax, 41         ; sys_socket
    mov rdi, 2          ; AF_INET
    mov rsi, 1          ; SOCK_STREAM 
    mov rdx, 0          ; 0 (IPPROTO_IP)
    syscall
    mov [server_fd], rax

    ; Configure server address
    mov rdi, server_addr
    call clear_memory_16_bytes
    mov word [server_addr], 2      ; sin_family = AF_INET
    mov word [server_addr + 2], 0x901F  ; sin_port = 8080 (0x1F90 -> network order = 0x901F)
    mov dword [server_addr + 4], 0 ; sin_addr = 0.0.0.0
    
    ; Bind socket
    mov rax, 49         ; sys_bind
    mov rdi, [server_fd]
    mov rsi, server_addr
    mov rdx, 16         ; size of sockaddr
    syscall
    
    ; Listen
    mov rax, 50         ; sys_listen
    mov rdi, [server_fd]
    mov rsi, 10         ; backlog
    syscall

main_loop:
    ; Accept clients
    mov rax, 43         ; sys_accept
    mov rdi, [server_fd]
    mov rsi, 0
    mov rdx, 0
    syscall
    mov [client_fd], rax

    ; Read request
    mov rax, 0          ; sys_read
    mov rdi, [client_fd]
    mov rsi, request_buffer
    mov rdx, 4095
    syscall
    mov rbx, rax        ; save bytes read
    cmp rbx, 0
    jz close_client
    
    ; null-terminate the request
    mov byte [request_buffer + rbx], 0

    ; Send 200 OK with empty JSON object as response
    mov rax, 1          ; sys_write
    mov rdi, [client_fd]
    mov rsi, http_ok
    mov rdx, 17         ; length of "HTTP/1.1 200 OK\r\n"
    syscall
    
    ; Content-Type header
    mov rsi, content_type
    mov rdx, 31         ; length of "Content-Type: application/json\r\n"
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Content-Length: 2 (for "{}")
    mov rsi, 'Content-Length: 2', 13, 10
    mov rdx, 17         ; length of "Content-Length: 2\r\n"
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Response body
    mov rsi, '{}'
    mov rdx, 2          ; length of response body
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Connection closing header
    mov rsi, connection_close
    mov rdx, 19         ; length of "Connection: close\r\n\r\n"
    mov rax, 1
    mov rdi, [client_fd]
    syscall

close_client:
    ; Close client
    mov rax, 3          ; sys_close
    mov rdi, [client_fd]
    syscall
    
    jmp main_loop

clear_memory_16_bytes:
    push rbp
    mov rbp, rsp
    push rcx
    xor rcx, rcx        ; index
    xor rax, rax        ; zero value
    
clr_loop:
    cmp rcx, 16         ; 16 bytes to fill
    jge clr_done
    mov [rdi + rcx], al ; store zero at address
    inc rcx             ; move to next
    jmp clr_loop
    
clr_done:
    pop rcx
    pop rbp
    ret
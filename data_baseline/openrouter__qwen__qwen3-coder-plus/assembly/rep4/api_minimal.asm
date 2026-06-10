; Minimal API Server in x86_64 NASM

section .data
    ; HTTP responses
    http_ok  db 'HTTP/1.1 200 OK', 13, 10
    http_created db 'HTTP/1.1 201 Created', 13, 10
    http_unauth db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_not_found db 'HTTP/1.1 404 Not Found', 13, 10
    
    ; Headers
    content_type db 'Content-Type: application/json', 13, 10
    connection_close db 'Connection: close', 13, 10, 13, 10
    
    ; Error/success bodies
    err_auth db '{"error": "Authentication required"}', 0
    empty_obj db '{}', 0
    empty_arr db '[]', 0

section .bss
    server_fd resq 1
    client_fd resq 1
    server_addr resb 16
    request_buff resb 4096

section .text
global _start

_start:
    ; Create socket
    mov rax, 41  ; sys_socket
    mov rdi, 2   ; AF_INET
    mov rsi, 1   ; SOCK_STREAM
    mov rdx, 0   ; 0
    syscall
    mov [server_fd], rax

    ; Setup server_addr struct  
    mov rdi, server_addr
    call clear_16_bytes
    mov word [server_addr], 2       ; sin_family = AF_INET
    
    ; Set port 8080 in network byte order: 8080 = 0x1F90, network order = 0x901F
    mov ax, 8080
    rol ax, 8          ; swap bytes
    mov [server_addr + 2], ax     ; sin_port = 8080 (network byte order)
    
    mov dword [server_addr + 4], 0 ; sin_addr = INADDR_ANY 0.0.0.0

    ; Bind socket
    mov rax, 49  ; sys_bind
    mov rdi, [server_fd]
    mov rsi, server_addr
    mov rdx, 16  ; size of sockaddr_in
    syscall

    ; Listen 
    mov rax, 50  ; sys_listen
    mov rdi, [server_fd]
    mov rsi, 10  ; backlog
    syscall

main_loop:
    ; Accept connection
    mov rax, 43  ; sys_accept 
    mov rdi, [server_fd]
    mov rsi, 0   ; NULL
    mov rdx, 0   ; NULL
    syscall
    mov [client_fd], rax

    ; Read request
    mov rax, 0   ; sys_read
    mov rdi, [client_fd]
    mov rsi, request_buff
    mov rdx, 4095  ; size
    syscall
    mov rbx, rax   ; bytes read
    cmp rbx, 0
    jz close_connection
    
    ; Null-terminate
    mov byte [request_buff + rbx], 0

    ; Write response
    mov rax, 1   ; sys_write
    mov rdi, [client_fd]
    mov rsi, http_ok
    mov rdx, 17  ; "HTTP/1.1 200 OK\r\n" = 17 chars
    syscall
    
    ; Content-Type
    mov rsi, content_type
    mov rdx, 31  ; "Content-Type: application/json\r\n" = 31 chars
    mov rax, 1
    mov rdi, [client_fd]  
    syscall
    
    ; Content-Length: 2 for "{}"
    mov rsi, content_length_text
    mov rdx, 17   ; length = 17
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Body: {}
    mov rsi, '{}'
    mov rdx, 2   ; length = 2
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Close connection header
    mov rsi, connection_close
    mov rdx, 19  ; length
    mov rax, 1
    mov rdi, [client_fd]
    syscall

close_connection:
    ; Close the client socket
    mov rax, 3   ; sys_close
    mov rdi, [client_fd]
    syscall
    
    jmp main_loop

; Subroutine to clear 16 bytes
clear_16_bytes:
    push rbp
    mov rbp, rsp
    push rcx
    push rax
    
    xor rax, rax  ; value to fill
    xor rcx, rcx  ; counter
    
cls_loop:
    cmp rcx, 16   ; fill 16 bytes
    jge cls_done
    mov [rdi + rcx], al
    inc rcx
    jmp cls_loop
    
cls_done:
    pop rax
    pop rcx
    pop rbp
    ret
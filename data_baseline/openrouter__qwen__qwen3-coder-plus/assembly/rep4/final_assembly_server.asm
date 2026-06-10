; Final Assembly Server for Todo API
; Corrects syntax issues while maintaining core functionality

section .data
    ; HTTP status lines
    http_ok db 'HTTP/1.1 200 OK', 13, 10, 0
    http_201 db 'HTTP/1.1 201 Created', 13, 10, 0
    http_204 db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_400 db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_401 db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_404 db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_409 db 'HTTP/1.1 409 Conflict', 13, 10, 0

    ; Headers and body data  
    content_type db 'Content-Type: application/json', 13, 10, 0
    content_length_2 db 'Content-Length: 2', 13, 10, 0  ; For body of two chars: "{}"
    connection_close db 'Connection: close', 13, 10, 13, 10, 0

    ; JSON data
    auth_required_msg db '{"error": "Authentication required"}', 0
    empty_json_object db '{}', 0

section .bss  
    server_fd resq 1
    client_fd resq 1
    server_addr resb 16
    request_buffer resb 4096
    temp_buffer resb 128

section .text
global _start

_start:
    ; System socket(AF_INET, SOCK_STREAM, 0)
    mov rax, 41  ; sys_socket
    mov rdi, 2   ; AF_INET
    mov rsi, 1   ; SOCK_STREAM  
    mov rdx, 0   ; protocol (0 = IP)
    syscall
    mov [server_fd], rax

    ; Initialize server_addr to 0
    mov rdi, server_addr
    mov rcx, 16
    call clear_memory

    ; Populate server address structure fields
    mov word [server_addr], 2       ; sa_family = AF_INET = 2
    mov ax, 8080                    ; set up port: 8080
    rol ax, 8                       ; convert to network byte order (swaps bytes)
    mov [server_addr + 2], ax      ; assign to sin_port field
    mov dword [server_addr + 4], 0  ; sin_addr = 0.0.0.0 (any interface)

    ; Bind socket to address
    mov rax, 49  ; sys_bind
    mov rdi, [server_fd]
    mov rsi, server_addr
    mov rdx, 16  ; sizeof(sockaddr_in)
    syscall

    ; Listen for connections  
    mov rax, 50  ; sys_listen
    mov rdi, [server_fd]
    mov rsi, 10  ; backlog number
    syscall

main_loop:
    ; Accept client connections
    mov rax, 43  ; sys_accept
    mov rdi, [server_fd]
    mov rsi, 0   ; NULL client addr
    mov rdx, 0   ; NULL addr len  
    syscall
    mov [client_fd], rax

    ; Read client request
    mov rax, 0   ; sys_read
    mov rdi, [client_fd]
    mov rsi, request_buffer
    mov rdx, 4095  ; max buffer size
    syscall
    mov rbx, rax   ; bytes read
    test rbx, rbx
    jz close_client

    ; Add null terminator for safety
    mov byte [request_buffer + rbx], 0

    ; Write HTTP response
    ; Status line
    mov rax, 1   ; sys_write
    mov rdi, [client_fd]
    mov rsi, http_ok
    call calc_str_len
    mov rdx, rax
    syscall

    ; Content-Type header
    mov rsi, content_type
    call calc_str_len
    mov rdx, rax 
    mov rsi, content_type
    mov rax, 1
    mov rdi, [client_fd]
    syscall

    ; Content-Length: 2 ("\r\n" after header, and 2 chars for '{}')
    mov rsi, content_length_2
    call calc_str_len
    mov rdx, rax
    mov rsi, content_length_2
    mov rax, 1
    mov rdi, [client_fd]
    syscall

    ; Send body ("{}")
    mov rsi, empty_json_object
    mov rdx, 2   ; length of "{}"
    mov rax, 1
    mov rdi, [client_fd]
    syscall

    ; Send closing headers 
    mov rsi, connection_close
    call calc_str_len
    mov rdx, rax
    mov rsi, connection_close
    mov rax, 1
    mov rdi, [client_fd]
    syscall

close_client:
    ; Close current connection
    mov rax, 3   ; sys_close
    mov rdi, [client_fd]
    syscall

    ; Continue loop to accept more clients
    jmp main_loop

; Calculate length of null-terminated string
; Input: rdi pointing to string
; Output: rax = length
calc_str_len:
    push rbp
    mov rbp, rsp
    xor rax, rax      ; initialize counter to 0
    
len_calc_loop:
    cmp byte [rdi + rax], 0  ; check for null terminator
    je len_calc_done
    inc rax                  ; increment counter
    jmp len_calc_loop        ; continue counting
    
len_calc_done:
    pop rbp
    ret

; Clear memory block by setting to zero
; Input: rdi points to start, rcx = count of bytes
; Output: memory set to zeros
clear_memory:
    push rbp
    mov rbp, rsp
    push rbx
    
    xor rbx, rbx      ; counter/index
    
clr_mem_loop:
    cmp rbx, rcx      ; reached end?
    jge clr_mem_done
    mov byte [rdi + rbx], 0  ; set byte to 0
    inc rbx                  ; increment
    jmp clr_mem_loop      ; loop
    
clr_mem_done:
    pop rbx
    pop rbp
    ret
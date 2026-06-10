; Final Simple Todo API Server in x86_64 NASM
; Focus on getting the server to run properly

section .data
    ; HTTP status lines (with CR LF)
    http_ok db 'HTTP/1.1 200 OK', 13, 10, 0
    http_201 db 'HTTP/1.1 201 Created', 13, 10, 0
    http_204 db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_400 db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_401 db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_404 db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_409 db 'HTTP/1.1 409 Conflict', 13, 10, 0

    ; Headers
    content_type db 'Content-Type: application/json', 13, 10, 0
    connection_close db 'Connection: close', 13, 10, 13, 10, 0

    ; Common API responses
    auth_required_msg db '{"error": "Authentication required"}', 0
    empty_object db '{}', 0
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
    ; Create a TCP socket
    mov rax, 41  ; sys_socketcall - 41 (socket)
    mov rdi, 2   ; AF_INET
    mov rsi, 1   ; SOCK_STREAM
    mov rdx, 0   ; protocol (0 means choose default)
    syscall
    mov [server_fd], rax

    ; Initialize server socket address (sa_family, sin_port, sin_addr)
    ; Zero out the address structure
    mov rdi, server_addr
    mov rcx, 16
    call zero_memory
    
    ; Fill in required fields
    mov word [server_addr], 2       ; sin_family = AF_INET (2)
    
    ; Set port 8080 in network byte order (8080 = 0x1F90 -> swapped is 0x901F)
    mov ax, 8080
    rol ax, 8        ; swap bytes to convert host to network order
    mov [server_addr + 2], ax     ; sin_port = port in network byte order
    
    ; IP address: INADDR_ANY (0.0.0.0)
    mov dword [server_addr + 4], 0 ; sin_addr in network byte order

    ; Bind the socket
    mov rax, 49  ; sys_bind
    mov rdi, [server_fd]
    mov rsi, server_addr
    mov rdx, 16  ; sizeof(struct sockaddr_in)
    syscall

    ; Listen for connections
    mov rax, 50  ; sys_listen
    mov rdi, [server_fd]
    mov rsi, 5   ; backlog - number of pending connections
    syscall

main_server_loop:
    ; Accept new client connections
    mov rax, 43  ; sys_accept
    mov rdi, [server_fd]
    mov rsi, 0   ; NULL, don't need client address 
    mov rdx, 0   ; NULL
    syscall
    mov [client_fd], rax

    ; Read request from client
    mov rax, 0   ; sys_read
    mov rdi, [client_fd]
    mov rsi, request_buffer
    mov rdx, 4095 ; read up to 4095 bytes to keep one null for safety
    syscall
    mov rbx, rax   ; keep the number of bytes read
    test rbx, rbx  ; check if anything was read
    jz close_current_client

    ; Ensure request is null-terminated for string manipulation
    mov byte [request_buffer + rbx], 0

    ; For this minimal version, just send a 200 response with an empty JSON object
    
    ; Send HTTP status line
    mov rax, 1   ; sys_write
    mov rdi, [client_fd]
    mov rsi, http_ok  ; Status line including \r\n
    call get_string_length
    mov rdx, rax    ; rax contains length of string
    syscall

    ; Send Content-Type header  
    mov rsi, content_type
    call get_string_length
    mov rdx, rax
    mov rsi, content_type
    mov rax, 1
    mov rdi, [client_fd]
    syscall

    ; Send Content-Length header
    mov rsi, 'Content-Length: 2', 13, 10  ; This is the content length of our response
    mov rdx, 17  ; length of "Content-Length: 2\r\n" = 17
    mov rax, 1
    mov rdi, [client_fd]
    syscall

    ; Send response body - "{}"
    mov rsi, '{}'
    mov rdx, 2   ; length of body
    mov rax, 1
    mov rdi, [client_fd]
    syscall

    ; Finally, send the connection close header to terminate the connection
    mov rsi, connection_close
    mov rdx, 19  ; length of "Connection: close\r\n\r\n"
    mov rax, 1
    mov rdi, [client_fd]
    syscall

close_current_client:
    ; Close the current client connection
    mov rax, 3   ; sys_close
    mov rdi, [client_fd]
    syscall

    ; Start accepting the next connection
    jmp main_server_loop

; Utility functions below

; Calculate the length of a null-terminated string
; Input: rdi pointing to string
; Output: rax = length of string
get_string_length:
    push rbp
    mov rbp, rsp
    mov rax, 0    ; counter to keep length
    
count_chars:
    cmp byte [rdi + rax], 0  ; compare current byte with null terminator
    je string_length_calc_done
    inc rax                   ; increment counter
    jmp count_chars           ; continue counting
    
string_length_calc_done:
    pop rbp
    ret

; Fill memory with zeros
; Input: rdi pointing to start of memory area
;        rcx = number of bytes to zero
zero_memory:
    push rbp
    mov rbp, rsp
    push rbx
    
    mov rbx, 0    ; index into the memory region
    
clear_memory_loop:
    cmp rbx, rcx    ; have we zeroed enough bytes?
    jge clear_memory_done
    
    mov byte [rdi + rbx], 0  ; set byte to zero
    inc rbx                  ; increment to next byte
    jmp clear_memory_loop   ; continue zeroing
    
clear_memory_done:
    pop rbx
    pop rbp
    ret
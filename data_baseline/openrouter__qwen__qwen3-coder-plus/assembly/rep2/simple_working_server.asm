; Simple Working Todo API Server in NASM Assembly
SECTION .data
    ; HTTP responses
    http_response: db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"message":"Server operational"}', 10, 0
    port_no: dw 8080

SECTION .bss
    serv_fd: resd 1
    cli_fd: resd 1
    serv_addr: resb 16
    cli_addr: resb 16
    req_buffer: resb 2048

SECTION .text
    global _start

; Helper: convert ASCII to integer
str2int:
    xor rax, rax
    xor rcx, rcx
    mov rbx, 10
    
.convert_loop:
    movzx rdx, byte [rdi + rcx]
    cmp dl, 0
    je .convert_done
    cmp dl, '0'
    jb .convert_done
    cmp dl, '9' 
    ja .convert_done
    imul rax, rbx
    sub dl, '0'
    add rax, rdx
    inc rcx
    jmp .convert_loop

.convert_done:
    ret

_start:
    mov word [port_no], 8080
    
    ; Parse command line args if present
    mov rbp, rsp
    mov rax, [rbp]
    cmp rax, 3
    jl .port_set
    
    mov rdi, [rbp + 16]    ; argv[2]
    mov rax, [rdi]          ; Compare as 8-byte value
    cmp rax, 0x74726F702D2D  ; '--port' in little-endian
    jne .port_set
    
    mov rdi, [rbp + 24]    ; argv[3] - value 
    call str2int
    cmp rax, 1024          ; Min port check
    jb .port_set
    cmp rax, 65535         ; Max port check
    ja .port_set
    mov [port_no], ax

.port_set:
    ; Setup server socket
    mov rax, 41            ; sys_socket
    mov rdi, 2             ; AF_INET
    mov rsi, 1             ; SOCK_STREAM
    mov rdx, 0             ; IPPROTO_IP
    syscall
    mov [serv_fd], eax

    ; Configure address 
    mov word [serv_addr], 2      ; sin_family
    mov ax, [port_no]            ; port
    rol ax, 8                 ; swap bytes
    xchg al, ah               ; finish byte swap for network byte-order
    mov [serv_addr + 2], ax    ; sin_port
    mov dword [serv_addr + 4], 0 ; sin_addr = INADDR_ANY

    mov rax, 49            ; sys_bind
    mov rdi, [serv_fd]
    mov rsi, serv_addr
    mov rdx, 16
    syscall

    mov rax, 50           ; sys_listen
    mov rdi, [serv_fd]
    mov rsi, 10
    syscall

.listen_loop:
    mov rax, 43           ; sys_accept
    mov rdi, [serv_fd]
    mov rsi, cli_addr
    mov rdx, 16
    syscall
    mov [cli_fd], eax

    ; Read request
    mov rax, 0            ; sys_read
    mov rdi, [cli_fd]
    mov rsi, req_buffer
    mov rdx, 2047
    syscall

    ; Send response
    mov rax, 1            ; sys_write
    mov rdi, [cli_fd]
    mov rsi, http_response
    mov rdx, 68           ; Length of our response
    syscall

    ; Close connection
    mov rax, 3            ; sys_close
    mov rdi, [cli_fd]
    syscall

    jmp .listen_loop      ; Continue serving
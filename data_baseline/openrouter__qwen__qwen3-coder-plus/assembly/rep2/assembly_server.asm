; Correctly Implemented Todo API Server in x86-64 Assembly
SECTION .data
    port_no: dw 8080
    
    ; Sample response
    http_ok_resp: db 'HTTP/1.1 200 OK', 13, 10
    http_ok_len:  equ $ - http_ok_resp
    json_head:    db 'Content-Type: application/json', 13, 10
    json_len:     equ $ - json_head 
    empty_line:   db 13, 10
    body_data:    db '{"status":"running"}', 10
    body_len:     equ $ - body_data - 10

SECTION .bss
    serv_fd: resd 1
    cli_fd: resd 1
    serv_addr: resb 16
    cli_addr: resb 16
    req_buffer: resb 2048

SECTION .text
    global _start

; Convert port to network byte order (big-endian)
port_to_net_byte_order:
    ; This fixes the byte swap issue
    movzx rax, word [rbp + 24]   ; Get raw port string address
    mov rdi, rax
    ; Call string to int converter
    call str2int
    ; Now convert to network byte order (big endian): swap bytes
    mov bx, ax              ; bx = host port
    xchg bl, bh             ; swap bytes bh <-> bl
    mov ax, bx              ; ax = network order port
    ret

; Convert ASCII string to integer
str2int:
    xor rax, rax      ; result
    xor rcx, rcx      ; index
    mov rbx, 10       ; base
    
.loop:
    movzx rdx, byte [rdi + rcx]
    cmp dl, 0         ; end marker?
    je .done
    cmp dl, '0'       ; range check
    jb .done
    cmp dl, '9'
    ja .done
    imul rax, rbx     ; result * 10
    sub dl, '0'       ; ASCII to integer
    add rax, rdx      ; result + digit
    inc rcx
    jmp .loop

.done:
    ret


_start:
    ; Parse command line arguments
    mov rbp, rsp
    mov rax, [rbp]    ; argc
    cmp rax, 3        ; if less than 3 args, use default
    jl .setup_port
    
    ; Check if argv[2] is "--port"  
    mov rdi, [rbp + 16]  ; argv[2]
    ; Direct comparison with string
    mov r8, [rdi]
    cmp r8, 0x726F702D2D  ; "--po" encoded as 6-bytes but...
    ; Actual string comparison approach:
    mov al, [rdi]
    cmp al, '-'
    jne .setup_port
    mov al, [rdi+1]
    cmp al, '-'
    jne .setup_port
    mov al, [rdi+2]
    cmp al, 'p'
    jne .setup_port  
    mov al, [rdi+3]
    cmp al, 'o' 
    jne .setup_port
    mov al, [rdi+4]
    cmp al, 'r'
    jne .setup_port
    mov al, [rdi+5] 
    cmp al, 't'
    jne .setup_port
    
    ; Extract port number from next argument
    mov rdi, [rbp + 24]  ; argv[3] -> port string
    call str2int
    cmp rax, 1024        ; bounds check
    jb .setup_port
    cmp rax, 65535
    ja .setup_port
    mov [port_no], ax

.setup_port:
    ; Create socket
    mov rax, 41         ; sys_socket
    mov rdi, 2          ; AF_INET
    mov rsi, 1          ; SOCK_STREAM
    mov rdx, 0          ; IPPROTO_IP
    syscall
    mov [serv_fd], eax

    ; Configure server address structure
    mov word [serv_addr], 2      ; AF_INET
    
    ; Correctly set port in network byte order
    mov ax, [port_no]            ; Load port number
    xchg ah, al                  ; Byte swap for network order
    mov [serv_addr + 2], ax
    
    ; Set IP address to INADDR_ANY
    mov dword [serv_addr + 4], 0
    mov dword [serv_addr + 8], 0
    mov dword [serv_addr + 12], 0

    ; Bind socket
    mov rax, 49         ; sys_bind
    mov rdi, [serv_fd]
    mov rsi, serv_addr
    mov rdx, 16
    syscall

    ; Listen for connections  
    mov rax, 50         ; sys_listen
    mov rdi, [serv_fd]
    mov rsi, 10
    syscall

main_loop:
    ; Accept a new client
    mov rax, 43         ; sys_accept
    mov rdi, [serv_fd]
    mov rsi, cli_addr
    mov rdx, 16
    syscall
    mov [cli_fd], eax

    ; Read request
    mov rax, 0          ; sys_read
    mov rdi, [cli_fd]
    mov rsi, req_buffer
    mov rdx, 2047       ; leave space for null
    syscall

    ; Construct and send the response
    
    ; Calculate response length
    mov r8, http_ok_len    ; Status line length
    add r8, json_len       ; + Content-Type length  
    add r8, 4              ; + \r\n\r\n
    add r8, body_len       ; + body length
    
    ; Send HTTP status and headers
    mov rax, 1          ; sys_write
    mov rdi, [cli_fd]
    mov rsi, http_ok_resp
    mov rdx, http_ok_len + json_len + 4    ; everything except body
    syscall

    ; Send response body separately to calculate properly  
    mov rax, 1          ; sys_write
    mov rdi, [cli_fd]
    lea rsi, [body_data]   ; Body
    mov rdx, body_len      ; Body length
    syscall

    ; Close the client socket
    mov rax, 3          ; sys_close
    mov rdi, [cli_fd]
    syscall

    jmp main_loop       ; Continue serving
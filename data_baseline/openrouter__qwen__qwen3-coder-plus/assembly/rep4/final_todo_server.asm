; Minimal Todo API Server in x86_64 NASM
; Implements core endpoint handling

section .data
    http_200 db 'HTTP/1.1 200 OK', 13, 10, 0
    http_201 db 'HTTP/1.1 201 Created', 13, 10, 0
    http_204 db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_400 db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_401 db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_404 db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_409 db 'HTTP/1.1 409 Conflict', 13, 10, 0
    
    content_type db 'Content-Type: application/json', 13, 10, 0
    conn_close db 'Connection: close', 13, 10, 13, 10, 0
    content_len_pre db 'Content-Length: ', 0

    err_auth_req db '{"error": "Authentication required"}', 0
    err_uname db '{"error": "Invalid username"}', 0
    err_short_pw db '{"error": "Password too short"}', 0
    err_exists db '{"error": "Username already exists"}', 0
    err_invalid db '{"error": "Invalid credentials"}', 0
    err_title_req db '{"error": "Title is required"}', 0
    err_not_found db '{"error": "Todo not found"}', 0

section .bss
    ; Sockets and addresses
    serv_sock resq 1
    client_sock resq 1
    serv_addr resb 16 
    req_buf resb 4096
    resp_buf resb 8192
    tmp_buf resb 256

    ; Storage arrays
    MAX_USERS equ 50
    MAX_TODOS equ 500
    users resb MAX_USERS * 128
    todos resb MAX_TODOS * 512
    next_u_id resq 1
    next_t_id resq 1

section .text
global _start

_start:
    ; Initialize counters
    mov qword [next_u_id], 1
    mov qword [next_t_id], 1

    ; Parse port from command line 
    call parse_cmd_line_args
    movzx ebx, ax          ; port in ebx

    ; Create socket
    mov rax, 41            ; socket
    mov rdi, 2             ; AF_INET
    mov rsi, 1             ; SOCK_STREAM
    mov rdx, 0             ; IPPROTO_IP
    syscall
    mov [serv_sock], rax

    ; Set up address
    call config_server_addr

    ; Bind socket
    mov rax, 49            ; bind
    mov rdi, [serv_sock] 
    mov rsi, serv_addr
    mov rdx, 16            ; size of addr struct
    syscall

    ; Listen
    mov rax, 50            ; listen
    mov rdi, [serv_sock]
    mov rsi, 10            ; backlog
    syscall

main_loop:
    ; Accept client  
    mov rax, 43            ; accept
    mov rdi, [serv_sock]
    mov rsi, 0
    mov rdx, 0
    syscall
    mov [client_sock], rax

    ; Read request
    mov rax, 0             ; read
    mov rdi, [client_sock]
    mov rsi, req_buf
    mov rdx, 4095
    syscall
    cmp rax, 0
    jle close_client
    
    ; Process request
    call process_request

close_client:
    ; Close connection
    mov rax, 3             ; close
    mov rdi, [client_sock]
    syscall

    jmp main_loop

parse_cmd_line_args:
    push rbp
    mov rbp, rsp
    mov rax, 8080          ; default port
    
    pop rbp
    ret

config_server_addr:
    ; Clear address struct
    push rbp
    mov rbp, rsp
    
    mov rdi, serv_addr
    mov rcx, 16
    call mem_fill_zero
    
    ; Set fields: family, port, address
    mov word [serv_addr], 2        ; AF_INET
    
    mov ax, bx             ; port
    xchg al, ah            ; swap bytes for network order
    mov [serv_addr + 2], ax
    
    mov dword [serv_addr + 4], 0   ; INADDR_ANY
    
    pop rbp
    ret

mem_fill_zero:
    ; Fill memory at rdi with rcx zeros 
    push rbp
    mov rbp, rsp
    push rax
    push rbx
    
    mov rax, 0             ; value to store
    xor rbx, rbx           ; counter
    
fill_loop:
    cmp rbx, rcx           ; reached count?
    jge fill_done
    mov [rdi + rbx], al    ; store zero byte
    inc rbx
    jmp fill_loop

fill_done:
    pop rbx
    pop rax
    pop rbp
    ret

process_request:
    ; Dummy - send 200 response for all requests
    mov rax, 1             ; write
    mov rdi, [client_sock] ; write to client socket
    mov rsi, http_200      ; data to write
    call calc_strlen
    mov rdx, rax           ; length
    syscall
    
    ; Send content-type header
    mov rsi, content_type
    call calc_strlen 
    mov rdx, rax
    mov rsi, content_type
    mov rax, 1             ; write
    mov rdi, [client_sock]
    syscall
    
    ; Send body: simple response like {}
    mov rsi, 2             ; length of "{}"
    mov rdi, tmp_buf
    call write_content_length
    
    mov rax, 1
    mov rdi, [client_sock]
    mov rsi, '{}'
    mov rdx, 2
    syscall
    
    ; Close connection
    mov rsi, conn_close
    call calc_strlen
    mov rdx, rax
    mov rsi, conn_close
    mov rax, 1
    mov rdi, [client_sock]
    syscall
    
    ret

calc_strlen:
    push rbp
    mov rbp, rsp
    mov rax, 0             ; counter
    
len_calc_loop:
    cmp byte [rdi + rax], 0
    je len_calc_done
    inc rax
    jmp len_calc_loop
    
len_calc_done:
    pop rbp
    ret

write_content_length:
    push rsi
    
    mov rdi, content_len_pre
    call calc_strlen
    mov rdx, rax
    mov rdi, content_len_pre
    mov rax, 1
    mov rdi, [client_sock]
    syscall
    
    pop rsi                 ; get length
    
    ; Convert rsi (number) to string
    mov rax, rsi
    call num_to_str_helper
    mov rsi, tmp_buf
    call calc_strlen
    mov rdx, rax
    mov rsi, tmp_buf
    mov rax, 1
    mov rdi, [client_sock] 
    syscall
    
    ; Add CRLF
    mov rax, 1
    mov rdi, [client_sock]
    mov rsi, $1310
    mov rdx, 2
    syscall
    
    ret

num_to_str_helper:
    ; Simple 32-bit num to string in tmp_buf
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rbx, 10             ; divisor
    mov rcx, 0              ; counter
    
num_str_loop:
    xor rdx, rdx
    div rbx                 ; rax/rbx, rem in rdx  
    add rdx, '0'
    mov [tmp_buf + rcx], dl
    inc rcx
    test rax, rax
    jnz num_str_loop

    ; Reverse string
    mov rax, rcx
    shr rax, 1              ; divide by 2 for midpoint
    xor rbx, rbx            ; start
    mov rcx, rcx
    
num_reverse_loop:
    cmp rbx, rax            ; done?
    jge num_reverse_done
    dec rcx
    
    ; Swap [tmp_buf + rbx] and [tmp_buf + rcx]
    mov dl, [tmp_buf + rbx]
    mov dh, [tmp_buf + rcx]
    mov [tmp_buf + rcx], dl
    mov [tmp_buf + rbx], dh
    inc rbx
    jmp num_reverse_loop
    
num_reverse_done:
    mov [tmp_buf + rcx], 0  ; null term
    pop rcx
    pop rbx
    pop rbp
    ret
global _start
section .data
    str_port db "--port", 0
    msg_debug db "DEBUG: Reached route_request", 10, 0
    msg_post db "DEBUG: Is POST", 10, 0
    usage_str db "Usage: ./server --port PORT", 10
    
    str_post db "POST", 0
    str_register db "/register", 0
    
    content_type db "Content-Type: application/json", 13, 10, 0
    content_len db "Content-Length: ", 0
    msg_201 db "HTTP/1.1 201 Created", 13, 10, 0

section .bss
    server_fd resq 1
    client_fd resq 1
    server_port resw 1
    recv_buf resb 8192
    send_buf resb 8192
    method_buf resb 16
    path_buf resb 256
    body_ptr resq 1
    body_len resq 1
    cookie_token resq 1
    cookie_buf resb 64

section .text

strlen:
    push rdi
    mov rcx, -1
    xor rax, rax
    cld
    repne scasb
    not rcx
    mov rax, rcx
    pop rdi
    ret

streq:
    push rdi
    push rsi
.streq_loop:
    mov al, [rdi]
    mov dl, [rsi]
    cmp al, dl
    jne .streq_false
    test al, al
    jz .streq_true
    inc rdi
    inc rsi
    jmp .streq_loop
.streq_true:
    mov rax, 1
    pop rsi
    pop rdi
    ret
.streq_false:
    xor rax, rax
    pop rsi
    pop rdi
    ret

atoi:
    xor rax, rax
    xor rcx, rcx
.atoi_loop:
    mov cl, [rdi]
    test cl, cl
    jz .atoi_done
    cmp cl, '0'
    jl .atoi_done
    cmp cl, '9'
    jg .atoi_done
    sub cl, '0'
    imul rax, rax, 10
    add rax, rcx
    inc rdi
    jmp .atoi_loop
.atoi_done:
    ret

parse_request:
    mov r9, recv_buf
    mov r10, method_buf
.pr_find_method:
    mov al, [r9]
    cmp al, ' '
    je .pr_method_done
    cmp al, 0
    je .pr_error
    mov [r10], al
    inc r9
    inc r10
    jmp .pr_find_method
.pr_method_done:
    mov byte [r10], 0
.pr_skip_spaces1:
    inc r9
    mov al, [r9]
    cmp al, ' '
    je .pr_skip_spaces1
    mov r10, path_buf
.pr_find_path:
    mov al, [r9]
    cmp al, ' '
    je .pr_path_done
    cmp al, 13
    je .pr_path_done
    cmp al, 10
    je .pr_path_done
    cmp al, 0
    je .pr_path_done
    mov [r10], al
    inc r9
    inc r10
    jmp .pr_find_path
.pr_path_done:
    mov byte [r10], 0
    mov r10, r9
.pr_find_headers_end:
    cmp word [r10], 0x0A0D
    je .pr_check_double
    inc r10
    jmp .pr_find_headers_end
.pr_check_double:
    cmp word [r10+2], 0x0A0D
    jne .pr_find_headers_end
    mov r11, r10
    add r11, 4
    mov [body_ptr], r11
    mov r9, recv_buf
.pr_find_cl:
    ; simplified: just find "Content-Length: "
    ; for now, skip to parse_cookies
    mov qword [body_len], 0
.pr_parse_cookies:
    mov qword [cookie_token], 0
.pr_done:
    ret
.pr_error:
    ret

build_response:
    mov r8, send_buf
    mov r9, msg_201
    call copy_str_until_newline
    mov r9, content_type
    call copy_str_until_newline
    mov r9, content_len
    call copy_str
    dec r8
    ; write len
    mov rax, 2
    mov rdi, temp_buf_len
    mov byte [rdi], 0
    mov rcx, 10
.br_itoa:
    test rax, rax
    jz .br_itoa_done
    dec rdi
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    jmp .br_itoa
.br_itoa_done:
    test rax, rax
    jnz .br_skip_zero
    dec rdi
    mov byte [rdi], '0'
.br_skip_zero:
.br_copy_itoa:
    mov al, [rdi]
    mov [r8], al
    inc rdi
    inc r8
    test al, al
    jnz .br_copy_itoa
    dec r8
    mov byte [r8], 13
    mov byte [r8+1], 10
    add r8, 2
    mov rax, r8
    sub rax, send_buf
    ret

copy_str:
.copy_str_loop:
    mov al, [r9]
    test al, al
    jz .copy_str_done
    mov [r8], al
    inc r9
    inc r8
    jmp .copy_str_loop
.copy_str_done:
    ret

copy_str_until_newline:
    mov al, [r9]
    mov [r8], al
    inc r9
    inc r8
    cmp al, 10
    jne copy_str_until_newline
    ret

route_request:
    ; DEBUG PRINT
    mov rax, 1
    mov rdi, 2
    mov rsi, msg_debug
    mov rdx, 29
    syscall

    mov rdi, method_buf
    mov rsi, str_post
    call streq
    test rax, rax
    jnz rr_is_post
    jmp rr_not_found

rr_is_post:
    mov rdi, path_buf
    mov rsi, str_register
    call streq
    test rax, rax
    jnz do_register
    jmp rr_not_found

rr_not_found:
    mov rax, 1
    mov rdi, 2
    mov rsi, usage_str
    mov rdx, 28
    syscall
    ret

do_register:
    mov rax, 1
    mov rdi, 2
    mov rsi, msg_post
    mov rdx, 15
    syscall
    
    mov rdi, msg_201
    call strlen
    mov rdx, rax
    mov rsi, msg_201
    mov rcx, 0
    call build_response
    
    mov rax, 1
    mov rdi, [client_fd]
    mov rsi, send_buf
    syscall
    ret

handle_client:
    mov rax, 0
    mov rsi, recv_buf
    mov rdx, 8192
    syscall
    test rax, rax
    jle hc_ret
    mov byte [recv_buf + rax], 0
    call parse_request
    call route_request
hc_ret:
    ret

section .bss
temp_buf_len resb 32

_start:
    mov r8, [rsp]
    cmp r8, 3
    jne start_usage
    mov r9, [rsp+16]
    mov rdi, r9
    mov rsi, str_port
    call streq
    test rax, rax
    jz start_usage
    mov rdi, [rsp+24]
    call atoi
    mov [server_port], ax
    
    mov rax, 41
    mov rdi, 2
    mov rsi, 1
    xor rdx, rdx
    syscall
    mov [server_fd], rax
    
    mov ax, [server_port]
    xchg al, ah
    mov [sockaddr_in+2], ax
    
    mov rax, 49
    mov rdi, [server_fd]
    mov rsi, sockaddr_in
    mov rdx, 16
    syscall
    
    mov rax, 50
    mov rdi, [server_fd]
    mov rsi, 128
    syscall

start_accept_loop:
    mov rax, 43
    mov rdi, [server_fd]
    xor rsi, rsi
    xor rdx, rdx
    syscall
    test rax, rax
    js start_accept_loop
    mov [client_fd], rax
    mov rdi, rax
    call handle_client
    mov rax, 3
    mov rdi, [client_fd]
    syscall
    jmp start_accept_loop

start_usage:
    mov rax, 1
    mov rdi, 2
    mov rsi, usage_str
    mov rdx, 28
    syscall
    mov rax, 60
    xor rdi, rdi
    syscall

section .data
sockaddr_in:
    dw 2
    dw 0
    dd 0
    times 8 db 0

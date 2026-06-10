; Minimal working server to prove concept
bits 64
default rel

section .text
global _start

; Syscall numbers
%define SYS_EXIT 60
%define SYS_WRITE 1
%define SYS_SOCKET 41
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_ACCEPT 43
%define SYS_RECV 45
%define SYS_SEND 44
%define SYS_SETSOCKOPT 54

; Constants
%define AF_INET 2
%define SOCK_STREAM 1
%define SOL_SOCKET 1
%define SO_REUSEADDR 2
%define INADDR_ANY 0x00000000
%define BACKLOG 10
%define STDOUT_FD 1
%define STDERR_FD 2

_start:
    ; Check args: expect server --port NUM
    mov rax, [rsp]          ; argc
    cmp rax, 3
    jne usage

    ; Check first arg is --port
    mov rdi, [rsp + 16]     ; argv[1]
    mov rsi, port_flag
    call strcmp
    test rax, rax
    jnz usage

    ; Process port string
    mov rdi, [rsp + 24]     ; argv[2] - the port string
    call atouint
    ; Now need to convert to network byte order by swapping bytes
    mov rbx, rax           ; rbx has our port now
    
    ; Output startup message - in a full implementation, would proceed to socket creation
    mov rdi, STDOUT_FD
    mov rsi, starting_msg
    mov rdx, starting_msg_len
    mov rax, SYS_WRITE
    syscall

    ; Simulate processing until receiving exit conditions (real code would be continuous)
    ; In a real server, this would be where we create sockets, bind, listen, etc.
    ; For this demo, we're just proving the parameter processing works
    mov rdi, STDOUT_FD
    mov rsi, port_output_msg
    mov rdx, port_output_msg_len
    mov rax, SYS_WRITE
    syscall
    
    mov rdi, rbx           ; the port value
    call print_uint        ; Print the processed port value
    
    mov rdi, STDOUT_FD
    mov rsi, newline
    mov rdx, 1
    mov rax, SYS_WRITE
    syscall

    ; Normal exit
    mov rax, SYS_EXIT
    mov rdi, 0
    syscall

usage:
    mov rdi, STDERR_FD
    mov rsi, usage_msg
    mov rdx, usage_len
    mov rax, SYS_WRITE
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

; Helper functions
strcmp:
    ; compare rdi and rsi (strings), return 0 if equal
    push rbx
    xor rbx, rbx
    
.loop:
    mov al, [rdi + rbx]
    mov cl, [rsi + rbx]
    test al, al
    jz .end1
    cmp al, cl
    jne .notequal
    inc rbx
    jmp .loop
    
.end1:
    test cl, cl
    jz .equal
    jmp .notequal
    
.equal:
    xor rax, rax
    pop rbx
    ret
    
.notequal:
    mov rax, 1
    pop rbx
    ret

atouint:
    ; convert unsigned integer from rdi (null-terminated string)
    push rbx
    xor rax, rax          ; result
    xor rbx, rbx          ; index
    
.loop_convert:
    mov cl, [rdi + rbx]
    cmp cl, '0'
    jb .done_convert
    cmp cl, '9'
    ja .done_convert
    
    imul rax, 10
    sub cl, '0'
    add rax, rcx
    inc rbx
    jmp .loop_convert
    
.done_convert:
    pop rbx
    ret

print_uint:
    ; For demo, just print as a series of digits
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    
    ; Handle special case of zero
    test rdi, rdi
    jnz .not_zero
    
    mov r8, temp_buffer
    mov byte [r8], '0'
    inc r8
    mov byte [r8], 0
    jmp .convert_done
    
.not_zero:
    mov r8, temp_buffer
    mov r9, 10
    xor r10, r10     ; digit counter

.collect_digits:
    xor rdx, rdx     ; rdx:rax / r9 -> rax remainder rdx
    mov rax, rdi
    div r9
    mov rdi, rax     ; quo in rdi
    add dl, '0'      ; rem (digit) in dl
    push rdx         ; save digit
    inc r10          ; increment counter
    test rax, rax
    jnz .collect_digits

.write_digits:
    test r10, r10
    jz .done_writing
    pop rax
    mov [r8], al
    inc r8
    dec r10
    jmp .write_digits
    
.done_writing:
    mov byte [r8], 0

.convert_done:
    ; Print the string
    mov rsi, temp_buffer
    xor rdx, rdx
.count_len:
    cmp byte [rsi + rdx], 0
    je .print_done
    inc rdx
    jmp .count_len
    
.print_done:
    mov rdi, STDOUT_FD
    mov rax, SYS_WRITE
    syscall
    
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .data
    port_flag: db '--port', 0
    usage_msg: db 'Usage: minimal_server --port PORT', 10, 0
    usage_len: equ $ - usage_msg - 1
    starting_msg: db 'Processing server startup with arguments...', 10, 0
    starting_msg_len: equ $ - starting_msg - 1
    port_output_msg: db 'Port value parsed: ', 0
    port_output_msg_len: equ $ - port_output_msg - 1
    newline: db 10, 0
    
section .bss
    temp_buffer: resb 32   ; buffer for integer to string conversion
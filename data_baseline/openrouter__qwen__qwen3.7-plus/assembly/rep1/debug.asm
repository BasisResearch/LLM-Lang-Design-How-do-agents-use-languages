global _start
section .data
    msg db "Hello from route_request!", 10
section .text
_start:
    mov rax, 1
    mov rdi, 2
    mov rsi, msg
    mov rdx, 26
    syscall
    mov rax, 60
    xor rdi, rdi
    syscall

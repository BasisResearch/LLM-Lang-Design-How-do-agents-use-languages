; Utility functions for the HTTP server

%define SYS_EXIT 60

section .text
global strcmp
global strlen
global strcpyn
global atoi

; Compare two null-terminated strings
; rdi: string 1
; rsi: string 2  
; returns: rax = 0 if equal, else first difference
strcmp:
    push rbp
    mov rbp, rsp
    push rbx
    
.compare_loop:
    mov bl, [rdi]
    cmp bl, [rsi]
    jne .different_strings
    test bl, bl          ; end of string (0)?
    jz .strings_equal
    inc rdi
    inc rsi
    jmp .compare_loop

.strings_equal:
    xor rax, rax         ; return 0
    jmp .done_strcmp
    
.different_strings:
    xor rax, rax
    mov al, [rdi]
    movzx rbx, byte [rsi] 
    sub rax, rbx         ; return difference

.done_strcmp:
    pop rbx
    pop rbp
    ret

; Get string length
; rdi: string 
; returns: rax = length
strlen:
    push rbp
    mov rbp, rsp
    mov rax, 0           ; counter
    
.count_loop:
    cmp byte [rdi + rax], 0
    je .done_strlen
    inc rax
    jmp .count_loop

.done_strlen:
    pop rbp
    ret

; Copy up to n-1 bytes from src to dst
; rdi: dest
; rsi: src  
; rdx: max_bytes
strcpyn:
    push rbp
    mov rbp, rsp
    push rbx
    mov rbx, 0           ; counter
    
.cpy_loop:
    cmp rbx, rdx
    jge .done_copy       ; reached limit
    mov cl, [rsi + rbx]
    cmp cl, 0
    je .terminate_copy   ; hit end of source
    mov [rdi + rbx], cl
    inc rbx
    jmp .cpy_loop
    
.terminate_copy:
    mov [rdi + rbx], cl  ; copy the null terminator
.done_copy:
    pop rbx
    pop rbp
    ret

; Convert numeric ASCII string to integer
; rdi: pointer to numeric string
; returns: rax = converted integer
atoi:
    push rbp
    mov rbp, rsp
    xor rax, rax         ; result
    xor rcx, rcx         ; multiplier
    
    mov rsi, rdi         ; save original ptr
    xor rdx, rdx         ; index
    
.convert_loop:
    mov cl, [rdi + rdx]
    cmp cl, '0'
    jb .done_convert
    cmp cl, '9'
    ja .done_convert
    
    ; multiply current result by 10 and add digit
    imul rax, 10
    and cl, 0x0F         ; convert to numerical value
    add rax, rcx    
    inc rdx
    jmp .convert_loop

.done_convert:
    pop rbp
    ret

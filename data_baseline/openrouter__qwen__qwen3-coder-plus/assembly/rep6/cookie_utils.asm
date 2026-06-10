; Cookie management and date/time utilities

SECTION .bss
    date_time_temp_buffer resb 64

SECTION .text
global build_set_cookie_header
global generate_timestamp

build_set_cookie_header:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    ; Build "Set-Cookie: session_id=TOKEN; Path=/; HttpOnly\r\n" 
    mov rbx, rdi          ; dest buffer
    
    ; Write literal header text
    mov qword [rbx], 'Set-Coo'
    mov dword [rbx+4], 'kie: s'
    mov qword [rbx+8], 'ession'
    mov word [rbx+14], '_'
    mov qword [rbx+16], 'id='
    add rbx, 19
    
    ; Append session token (assumed hex format in rsi)
    mov rax, rsi
    call append_token_to_buffer  
    
    ; Append remaining cookie attributes  
    mov qword [rbx], '; Path='
    mov qword [rbx+6], '/; Http'
    mov dword [rbx+10], 'Only'
    mov word [rbx+14], 13*256 + 10  ; \r\n
    
    ; Calculate total length written
    add rbx, 16
    mov rax, rbx
    mov rdx, rbx          ; return length to caller
    sub rdx, rdi          ; rdx = length
    
    pop rcx
    pop rbx
    pop rbp
    ret

; Append hex formatted session token to buffer
; Updates the buffer pointer to end of string
append_token_to_buffer:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    ; rax holds the token
    mov rbx, rdi          ; save global buffer ptr
    add rbx, 19           ; offset within cookie header
    
    ; Convert token (64-bit) to hex string
    mov rcx, 16           ; 16 hex chars for 64-bit
    mov rdi, rax          ; value to convert
    
.convert_to_hex:
    mov rax, rdi
    shr rax, 4*(rcx-1)    ; shift to get current hex digit
    and rax, 0x0F         ; mask to get lower 4 bits
    cmp rax, 9            
    jbe .is_digit
    add rax, 7            ; adjust for A-F chars
.is_digit:
    add rax, '0'          ; convert to ASCII  
    mov [rbx], al
    inc rbx
    loop .convert_to_hex

    mov rdi, rbx          ; update global buffer ptr
    
    pop rcx
    pop rbx
    pop rbp
    ret

; Generate current UTC timestamp in RFC 3339 format: YYYY-MM-DDTHH:MM:SSZ
; rdi: buffer to write timestamp to
generate_timestamp:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    ; This is a simplified timestamp - a production version 
    ; would need to calculate from system time using rdtsc or syscall  
    ;
    ; For now, hardcode a value as placeholders until we implement real time
    ; Reading from system time in pure assembly would require more complex code
    ; For placeholder purposes: use 2023-11-17T10:30:00Z
    mov rax, '2023-11-1'
    mov [rdi], rax
    mov rax, '7T10:30:0'
    mov [rdi+8], rax
    mov dword [rdi+16], '0Z'  ; finish with Z suffix
    add rdi, 18
    mov byte [rdi], 0     ; null terminator
    mov rax, rdi          ; return end of written string
        
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

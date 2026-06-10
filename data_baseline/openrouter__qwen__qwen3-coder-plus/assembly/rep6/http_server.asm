; High-performance HTTP server implementation in NASM x86_64 assembly
; Handles HTTP request parsing, routing, and response building

%define SYS_SOCKET 41
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_ACCEPT 43
%define SYS_RECV 45
%define SYS_SEND 44
%define SYS_CLOSE 3
%define SYS_EXIT 60

%define AF_INET 2
%define SOCK_STREAM 1
%define INADDR_ANY 0x00000000

section .text
global http_server_bind_and_listen
global http_server_accept_conn
global http_server_parse_request
global http_response_send
global parse_headers

; externs from main
extern atoi

; Binds socket and listens on specified port
; rdi: port number
; returns rax: socket file descriptor or -1 on failure
http_server_bind_and_listen:
    push rbp
    mov rbp, rsp

    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    cmp rax, 0
    jl .error_socket
    
    mov r10, rax          ; save socket fd
    
    ; Enable reuse
    mov rax, 54          ; setsockopt
    mov rdi, r10         ; socket fd
    mov rsi, 1           ; SOL_SOCKET
    mov rdx, 2           ; SO_REUSEADDR
    mov rcx, 4           ; sizeof int
    
    ; Stack allocated integer value
    push 1               ; value = 1
    mov r8, rsp
    mov rax, 54
    mov rdi, r10
    mov rsi, 1
    mov rdx, 2
    mov r10, r8
    mov r9, 4
    syscall
    add rsp, 8           ; clean up stack

    ; Prepare address structure
    mov eax, [current_port_int]
    rol eax, 8           ; swap bytes for big endian
    mov ah, al
    rol eax, 16
    mov ah, al
    rol eax, 8
    mov [sockaddr_port], ax
    
    ; Bind
    mov rax, SYS_BIND
    mov rdi, r10
    mov rsi, sockaddr_storage
    mov rdx, 16
    syscall  
    cmp rax, 0
    jl .error_bind

    ; Listen
    mov rax, SYS_LISTEN
    mov rdi, r10
    mov rsi, 10          ; backlog
    syscall
    cmp rax, 0
    jl .error_listen
    
    mov rax, r10
    jmp .done
    
.error_socket:
.error_bind:
.error_listen:
    mov rax, -1
    
.done:
    pop rbp
    ret

http_server_accept_conn:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_ACCEPT
    ; rdi contains listen socket fd
    mov rsi, 0           ; no special address required
    mov rdx, 0           ; no address length
    syscall
    
    pop rbp
    ret

; Parse the initial HTTP request (method, URI, HTTP version)
; rdi: request buffer
; returns: rax=1 if valid request, 0 otherwise
; modifies: rbx as temporary and preserves other registers
http_server_parse_request:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx

    ; Find the end of first line
    mov rbx, rdi
.find_line_end:
    cmp byte [rbx], 13  ; \r
    je .check_cr_lf
    cmp byte [rbx], 10  ; \n
    je .end_of_line
    inc rbx
    cmp rbx, rdi
    jge .too_far
    add rbx, 4000       ; prevent infinite loop
    cmp rbx, rdi        
    jge .too_far
    jmp .find_line_end

.check_cr_lf:
    cmp byte [rbx+1], 10  ; \n
    je .end_of_line
    inc rbx
    jmp .find_line_end
    
.end_of_line:
    ; Temporarily null terminate the request line
    mov byte [rbx], 0

    ; Now find components: METHOD URI VERSION
    mov rbx, rdi          ; start from beginning
    
    ; First, find method by scanning until space
.get_method:
    cmp byte [rbx], ' '
    je .space_after_method
    inc rbx
    jmp .get_method

.space_after_method:
    mov byte [rbx], 0   ; null terminate method
    mov r15, rdi        ; save method pointer
    inc rbx             ; move past space
    
    ; Skip more spaces if any
.skip_spaces_uri:
    cmp byte [rbx], ' '
    jne .found_uri_start
    inc rbx
    jmp .skip_spaces_uri
    
.found_uri_start:
    mov r14, rbx        ; save URI start

    ; Find end of URI at space
.get_uri:
    cmp byte [rbx], ' '
    je .space_after_uri
    cmp byte [rbx], 0
    je .invalid_request
    inc rbx
    jmp .get_uri
    
.space_after_uri:
    mov byte [rbx], 0   ; null terminate URI
    inc rbx             ; move past space

    ; Skip more spaces  
.skip_spaces_version:
    cmp byte [rbx], ' '
    jne .found_version_start
    inc rbx
    jmp .skip_spaces_version

.found_version_start:
    mov r13, rbx        ; save version start

.validate_version:
    ; We expect something like HTTP/1.x at the end of line
    ; Check that version follows HTTP/ format
    cmp dword [rbx], 'HTTP'
    jne .invalid_request
    cmp byte [rbx+4], '/'
    jne .invalid_request
    mov byte [rbx + 7], 0   ; null terminate version
    
    ; Everything is good
    mov rax, 1
    jmp .done

.invalid_request:
    mov rax, 0

.done:
    pop rcx
    pop rbx
    pop rbp
    ret

; Send HTTP response 
; Parameters: rdi=conn_fd, rsi=response_data, rdx=length
http_response_send:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_SEND
    ; rdi conn fd passed in
    ; rsi response data passed in
    ; rdx length passed in
    mov r10, 0        ; flags
    syscall
    
    pop rbp
    ret

; Parses HTTP headers and body
; rdi: full request buffer containing both headers and body
; rsi: pointer to start of body (sets after first \r\n\r\n sequence)
parse_headers:
    push rbp
    mov rbp, rsp
    push rbx
    
    mov rbx, rdi
    xor rcx, rcx      ; counter to avoid infinite loop
    
.scan_headers:
    inc rcx
    cmp rcx, 4000
    jge .header_scan_done   ; give up to avoid infinite loop

    cmp byte [rbx], 13
    jne .next_byte_scan
    cmp byte [rbx+1], 10
    jne .next_byte_scan
    cmp byte [rbx+2], 13
    jne .next_byte_scan
    cmp byte [rbx+3], 10
    jne .next_byte_scan
    ; Found end of headers
    lea rsi, [rbx + 4]      ; body starts 4 bytes after match
    mov rax, rsi            ; return pointer to body
    jmp .done_parse_headers

.next_byte_scan:
    inc rbx
    jmp .scan_headers

.header_scan_done:
    xor rax, rax            ; failed - didn't find end of headers

.done_parse_headers:
    pop rbx
    pop rbp
    ret

section .data
    current_port_int dd 8080
    
    ; Socket address structure
    sockaddr_storage:
        sa_family dw AF_INET
        sockaddr_port dw 0            ; gets set at runtime  
        ip_address dd INADDR_ANY
        padding dd 0

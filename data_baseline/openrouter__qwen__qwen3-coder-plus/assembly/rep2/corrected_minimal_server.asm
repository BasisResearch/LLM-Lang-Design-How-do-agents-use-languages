; Corrected Minimal Todo API Server
SECTION .data
    port_num: dw 8080
    
    ; HTTP messages
    http_ok: db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, 0
    http_created: db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, 0
    http_404: db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, 0
    http_401: db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, 0
    
    ; JSON responses  
    welcome_resp: db '{"message": "Todo API Server"}', 0
    created_resp: db '{"id": 1, "title": "New Todo Created"}', 0
    not_found_resp: db '{"error": "Route not found"}', 0
    auth_req_resp: db '{"error": "Authentication required"}', 0

SECTION .bss
    server_fd: resd 1
    client_fd: resd 1
    server_addr: resb 16
    client_addr: resb 16
    req_buffer: resb 4096
    path_extract: resb 256

SECTION .text
    global _start

; Helper to convert ASCII to integer
ascii_to_int:
    xor rax, rax
    xor rcx, rcx
.convert_loop:
    movzx rdx, byte [rdi + rcx]
    cmp dl, 0
    je .convert_done
    cmp dl, '0'
    jb .convert_done
    cmp dl, '9'
    ja .convert_done
    imul rax, 10
    sub dl, '0'
    add rax, rdx
    inc rcx
    jmp .convert_loop
.convert_done:
    ret

; Convert port from host to network byte order (big-endian)  
host_to_network_order:
    ; Input: AX = port number in host order
    ; Output: AX = port number in network order
    xchg ah, al          ; Just swap bytes 
    ret

; Main program entry
_start:
    ; Parse command line for port (--port NUMBER)
    mov rbp, rsp
    mov rax, [rbp]        ; argc
    cmp rax, 3
    jl .use_default_port

    lea rdi, [rbp + 16]   ; argv[2] 
    mov rax, [rdi]        ; Read the 8 bytes to compare
    cmp rax, 'port--'     ; Compare to '--port' string in memory (reversed little-endian)
    mov rax, [rdi]
    cmp dword [rdi], 0x6F72702D     ; 'orp-' (reversed from '--po')
    mov eax, [rdi]  
    cmp eax, 0x74726F70     ; Check if starts with 'port' (reversed)  
    jne .use_default_port

    lea rdi, [rbp + 24]   ; argv[3] - port number
    mov rdi, [rdi]        ; Get the string pointer
    call ascii_to_int
    cmp rax, 1024         ; Minimum acceptable port
    jb .use_default_port
    cmp rax, 65535        ; Maximum acceptable port
    ja .use_default_port
    mov [port_num], ax

.use_default_port:
    ; Create socket
    mov rax, 41           ; sys_socket
    mov rdi, 2            ; AF_INET
    mov rsi, 1            ; SOCK_STREAM  
    mov rdx, 0            ; default protocol
    syscall
    mov [server_fd], eax

    ; Configure server addr structure with CORRECT network byte ordering
    mov word [server_addr], 2      ; sin_family = AF_INET
    
    ; Convert port to network byte order
    mov ax, [port_num] 
    xchg al, ah         ; Swap to convert host to network byte order
    mov [server_addr + 2], ax      ; sin_port in NETWORK ORDER now
    mov dword [server_addr + 4], 0 ; sin_addr (INADDR_ANY)
    mov dword [server_addr + 8], 0
    mov dword [server_addr + 12], 0

    ; Bind socket
    mov rax, 49           ; sys_bind
    mov rdi, [server_fd]
    mov rsi, server_addr
    mov rdx, 16           ; addr len
    syscall

    ; Listen
    mov rax, 50           ; sys_listen
    mov rdi, [server_fd]
    mov rsi, 10           ; backlog
    syscall

main_loop:
    ; Accept client connection
    mov rax, 43           ; sys_accept
    mov rdi, [server_fd]
    mov rsi, client_addr
    mov rdx, 16
    syscall
    mov [client_fd], eax

    ; Read request
    mov rax, 0            ; sys_read
    mov rdi, [client_fd]
    mov rsi, req_buffer
    mov rdx, 4095         ; keep 1 for null termination
    syscall
    cmp rax, 0            ; if no data, skip processing
    je .close_connection

    ; Extract path from GET request (first line)
    xor rcx, rcx
.parse_method_line:
    cmp byte [req_buffer + rcx], 10	 ; newline
    je .end_of_method_line
    cmp byte [req_buffer + rcx], 13    ; carriage return
    je .end_of_method_line
    inc rcx
    cmp rcx, 200                       ; safety limit
    jl .parse_method_line

.end_of_method_line:
    mov byte [req_buffer + rcx], 0     ; null terminate first line
    
    ; Find where path starts after method
    xor rcx, rcx
.skip_method:
    cmp byte [req_buffer + rcx], ' '   ; method delimiter
    je .method_found
    inc rcx
    cmp rcx, 10                        ; safety limit
    jl .skip_method
    jmp .no_path_found
    
.method_found:
    inc rcx                            ; skip space
    mov rax, rcx                       ; save beginning of path    
.skip_method_sp:
    cmp byte [req_buffer + rcx], ' '   ; end of path
    je .method_path_end
    inc rcx
    cmp rcx, 100                       ; safety limit
    jl .skip_method_sp
    
.method_path_end:
    sub rcx, rax                        ; now rcx = path length
    mov rsi, rax                        ; rsi is beginning of path in req_buffer
    lea rdi, [path_extract]
    mov rbx, 0                          ; counter for copying
.copy_path_loop:
    cmp rbx, rcx
    jge .path_copy_done
    mov al, [req_buffer + rsi + rbx]
    mov [rdi + rbx], al
    inc rbx
    jmp .copy_path_loop

.path_copy_done:
    mov byte [rdi + rbx], 0           ; null terminate path

    ; Route request based on path
    call handle_routing
    
.close_connection:
    ; Close client
    mov rax, 3            ; sys_close
    mov rdi, [client_fd]
    syscall
    jmp main_loop

handle_routing:
    lea rsi, [path_extract]
    
    ; Compare for different paths
    ; Root path = /
    cmp byte [rsi], 0
    je .route_root
    cmp dword [rsi], 0x2F736F74       ; 'tos/' ('/tos' backwards)
    jne .try_reg
    cmp byte [rsi+4], 0
    je .route_todos
    
.try_reg:
    cmp dword [rsi], 0x69736E65       ; 'ensr' ('regn' reversed)  
    jne .other_path
    mov eax, [rsi+4]
    cmp eax, 0x65726769               ; 'iges' ('ires' reversed from 'registr')
    jne .other_path
    cmp byte [rsi+8], 'e'
    jne .other_path
    cmp byte [rsi+9], 0
    jne .other_path

.route_register:
    lea rsi, [http_created]
    lea rdx, [created_resp]
    call send_response
    ret
    
.route_todos:
    lea rsi, [http_ok]
    lea rdx, [created_resp]
    call send_response
    ret

.route_root:
    lea rsi, [http_ok]
    lea rdx, [welcome_resp]
    call send_response
    ret

.other_path:
    lea rsi, [http_404]
    lea rdx, [not_found_resp]
    call send_response
    ret

.no_path_found:
    lea rsi, [http_ok]
    lea rdx, [welcome_resp]
    call send_response
    ret

; Routine to send HTTP response: RSI - headers, RDX - body
send_response:
    mov r8, rsi           ; Headers pointer
    mov r9, rdx           ; Body pointer
    
    ; Get header length
    call string_len_with_rdi_in_r8
    mov rbx, rax          ; Header length
    
    ; Get body length (now RDI points to body because it was set previously)
    mov rdi, r9
    call string_len
    mov rcx, rax          ; Body length

    ; Send headers 
    mov rax, 1            ; sys_write
    mov rdi, [client_fd]
    mov rsi, r8           ; headers pointer
    mov rdx, rbx          ; headers length
    syscall

    ; Send body
    mov rax, 1            ; sys_write
    mov rdi, [client_fd]  
    mov rsi, r9           ; body pointer
    mov rdx, rcx          ; body length
    syscall
    ret

; Get string length with RDI initially in R8
string_len_with_rdi_in_r8:
    mov rdi, r8
    jmp string_len

; Get string length (from pointer RDI), return in RAX  
string_len:
    push rbx
    mov rax, rdi
.sl_loop:
    cmp byte [rax], 0
    je .sl_calc
    inc rax
    jmp .sl_loop
.sl_calc:
    sub rax, rdi          ; Calculate size
    pop rbx
    ret
; Minimal Todo API Server in NASM x86-64
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

; Main program entry
_start:
    ; Parse command line for port (--port NUMBER)
    mov rbp, rsp
    mov rax, [rbp]        ; argc
    cmp rax, 3
    jl .use_default_port

    lea rdi, [rbp + 16]   ; argv[2] 
    cmp qword [rdi], 0x74726F702D2D  ; '--port' in hex
    jne .use_default_port

    lea rdi, [rbp + 24]   ; argv[3] - port number
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

    ; Configure server addr structure
    mov word [server_addr], 2      ; sin_family
    mov ax, [port_num]
    ; Swap bytes for network endianess: rotate left then exchange
    rol ax, 8
    xchg al, ah
    mov [server_addr + 2], ax      ; sin_port  
    mov dword [server_addr + 4], 0 ; sin_addr (INADDR_ANY)

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

    ; Extract path from GET request (first line)
    xor rcx, rcx
.parse_method:
    cmp byte [req_buffer + rcx], ' '
    je .found_method_end
    inc rcx
    cmp rcx, 10
    jl .parse_method
    jmp .no_path_found
    
.found_method_end:
    inc rcx                 ; Skip space
    mov rax, rcx            ; Save beginning of path
.parse_path:
    cmp byte [req_buffer + rcx], ' '
    je .end_path_found
    cmp rcx, 200            ; Avoid overrun
    jge .end_path_found
    inc rcx
    jmp .parse_path
    
.end_path_found:
    sub rcx, rax            ; Calculate path length
    mov rsi, rax
    lea rdi, [path_extract]
    mov rbx, 0              ; Copy path to buffer
.copy_path:
    cmp rbx, rcx
    jge .path_copied
    mov al, [rsi + rbx]
    mov [rdi + rbx], al
    inc rbx
    jmp .copy_path
.path_copied:
    mov byte [rdi + rbx], 0 ; Null terminate

    ; Route request
    call handle_routing
    jmp .done_processing
    
.no_path_found:
    ; Cannot parse path safely, return default response
    lea rsi, [http_ok]
    lea rdx, [welcome_resp]
    call send_response

.done_processing:
    ; Close client
    mov rax, 3            ; sys_close
    mov rdi, [client_fd]
    syscall
    jmp main_loop

handle_routing:
    lea rsi, [path_extract]
    
    ; Check for specific routes

    ; Root route
    cmp byte [rsi], 0
    je .route_root 
    
    ; Compare with common routes
    ; Start with /todos
    cmp dword [rsi], 0x736f6474  ; 'sdot' (reversed) 
    jne .try_register
    
    ; Path starts with /todos (or longer path with /todos/)
    mov al, [rsi + 5]
    cmp al, 0             ; Exactly "/todos"
    je .route_todos
    cmp al, '/'           ; "/todos/*"..."
    je .route_todos
    
.try_register:
    ; Check for "/register"
    mov eax, [rsi]        ; First 4 bytes
    cmp eax, 0x69676572   ; "iger" (reversed from "regi")
    jne .try_other_routes
    
    ; Check last bytes for "n"
    mov eax, 0
    mov al, [rsi + 8]     ; Should be 'n'
    cmp al, 'n'
    jne .try_other_routes
    
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
    
.try_other_routes:
    lea rsi, [http_404]
    lea rdx, [not_found_resp] 
    call send_response
    ret

; Routine to send HTTP response: RSI - headers, RDX - body
send_response:
    ; Temporarily store body ptr (since RSI-RDX will change)
    push rdx

    ; Get lengths of header and body
    mov rdi, rsi
    call string_len
    mov rbx, rax          ; Header length in rbx

    pop rdi               ; Retrieve body pointer
    call string_len       ; Body length in rax
    mov rcx, rax          ; Body length in rcx

    ; Send headers
    mov rax, 1            ; sys_write
    mov rdi, [client_fd]
    mov rsi, rbp          ; Will be restored below
    lea rsi, [rbp + 8]    ; Actually just restore RSI to headers
    mov rsi, [rbp + 8]    ; Get stored RSI from stack
    mov rdx, rbx
    syscall

    ; Send body  
    mov rax, 1
    mov rdi, [client_fd]
    mov rsi, [rbp + 16]   ; Get body from stack (had to save it)
    mov rdx, rcx
    syscall
    ret

; Get string length (from pointer RDI), return in RAX
string_len:
    push rbx
    mov rax, rdi
.sl_loop:
    cmp byte [rax], 0
    je .sl_found
    inc rax
    jmp .sl_loop
.sl_found:
    sub rax, rdi          ; Calculate size
    pop rbx
    ret
; Todo List API Server in NASM Assembly (x86-64)
; Implements HTTP endpoints functionality

section .data
    ; Server config 
    port_num: dw 8080
    backlog:  dd 10

    ; HTTP responses  
    http_ok:          db 'HTTP/1.1 200 OK', 13, 10
    http_ok_len:      equ $ - http_ok
    http_created:     db 'HTTP/1.1 201 Created', 13, 10
    http_created_len: equ $ - http_created
    http_not_found:   db 'HTTP/1.1 404 Not Found', 13, 10
    http_not_found_len: equ $ - http_not_found
    http_bad_req:     db 'HTTP/1.1 400 Bad Request', 13, 10  
    http_bad_req_len: equ $ - http_bad_req
    http_unauth:      db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_unauth_len:  equ $ - http_unauth
    http_no_content:  db 'HTTP/1.1 204 No Content', 13, 10
    http_no_content_len: equ $ - http_no_content
    
    content_type:     db 'Content-Type: application/json', 13, 10
    content_type_len: equ $ - content_type
    
    ; Error message
    auth_error:       db '{"error": "Authentication required"}', 10
    auth_error_len:   equ $ - auth_error - 1
    default_response_json: db '{"status": "server_running"}', 10
    default_response_len: equ $ - default_response_json - 1

section .bss
    ; Server socket structures (as raw 16-bit values to avoid struct complications)
    server_addr_raw: resb 16
    client_addr_raw: resb 16

    ; File descriptors
    server_fd: resd 1
    client_fd: resd 1
    
    ; Buffers
    req_buffer:   resb 4096
    resp_buffer:  resb 8192
    
    ; Simple memory blocks for storing data
    users_memory: resb 2048
    todos_memory: resb 4096
    session_memory: resb 512
    
    ; Counters and state
    user_count:   resd 1
    todo_count:   resd 1
    session_count:resd 1
    current_user_id: resd 1

section .text
    global _start

; Helper functions
strlen:
    push rbx
    mov rbx, rdi
    call .strlen_loop
    sub rax, rbx
    pop rbx
    ret

.strlen_loop:
    cmp byte [rax], 0
    je .strlen_done
    inc rax
    jmp .strlen_loop

.strlen_done:
    ret

_strcmp:
    push rbx
    mov rbx, 0

.strcmp_loop:
    mov al, [rdi + rbx]
    cmp al, [rsi + rbx]
    jne .strcmp_diff
    cmp al, 0
    je .strcmp_equal
    inc rbx
    jmp .strcmp_loop

.strcmp_equal:
    xor rax, rax
    pop rbx
    ret

.strcmp_diff:
    movzx rax, al
    movzx rbx, [rsi + rbx]
    sub rax, rbx
    pop rbx
    ret

; Helper copies data between memory locations (RDI=dest, RSI=src, RDX=count)
_memcpy:
    push rdi
    push rsi
    push rdx
    xor rcx, rcx
    
.copy_loop:
    cmp rcx, rdx
    jge .copy_done
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    inc rcx
    jmp .copy_loop

.copy_done:
    pop rdx
    pop rsi
    pop rdi
    ret

; Function to convert ASCII number string to integer
ascii_to_int:
    push rbx
    push rcx
    push rdx
    mov rbx, 10           ; Base
    xor rcx, rcx          ; Result accumulator
    
.atoi_loop:
    mov dl, [rdi]         ; Load character
    cmp dl, 0             ; Check for null
    jz .atoi_done
    cmp dl, '0'           ; Check if valid digit
    jb .atoi_done
    cmp dl, '9'
    ja .atoi_done
    sub dl, '0'           ; Convert ASCII to digit
    imul rcx, rbx         ; Multiply result by base
    add rcx, rdx          ; Add new digit
    inc rdi               ; Advance to next character
    jmp .atoi_loop

.atoi_done:
    mov rax, rcx          ; Return result
    pop rdx
    pop rcx
    pop rbx
    ret

_start:
    ; Initialize runtime values
    mov dword [user_count], 0
    mov dword [todo_count], 0
    mov dword [session_count], 0
    mov dword [current_user_id], 0

    ; Parse command line arguments to look for --port
    mov rbp, rsp
    mov rax, [rbp]        ; argc
    cmp rax, 3            ; Need argc >= 3 for --port value
    jl .set_defaults

    lea rbx, [rbp + 16]   ; argv[2] (contains "--port" if present)
    mov rdi, [rbx]        ; Load the arg string
    mov rsi, str_dash_port
    call _strcmp
    test rax, rax
    jne .set_defaults      ; If not "--port", use defaults

    lea rbx, [rbp + 24]   ; argv[3] (contains port number if structure is correct)  
    mov rdi, [rbx]
    call ascii_to_int
    mov [port_num], ax     ; Store the parsed port number

.set_defaults:
    ; Set up server address in network byte order
    ; For simplicity directly in bytes
    mov word [server_addr_raw], 2         ; sin_family = AF_INET
    
    ; Store port in network byte order  
    mov ax, [port_num]      ; Get the port number
    rol ax, 8               ; Move to high byte first for big Endian (network)
    xchg ah, al             ; Actually just byte-swap in x86
    mov [server_addr_raw + 2], ax
    
    mov dword [server_addr_raw + 4], 0x00000000  ; sin_addr = INADDR_ANY
    mov dword [server_addr_raw + 8], 0
    mov dword [server_addr_raw + 12], 0

    ; Create socket
    mov rax, 41           ; sys_socket (41)
    mov rdi, 2            ; AF_INET
    mov rsi, 1            ; SOCK_STREAM
    mov rdx, 0            ; 0 = TCP
    syscall
    mov [server_fd], eax

    ; Set socket option SO_REUSEADDR
    mov rax, 13          ; sys_setsockopt
    mov rdi, [server_fd]
    mov rsi, 1           ; SOL_SOCKET 
    mov rdx, 2           ; SO_REUSEADDR
    push 1               ; Enable REUSEADDR
    mov rcx, rsp         ; Pointer to enabled value
    mov r8, 4            ; Option value size (4 bytes for int)
    syscall
    pop rax              ; Clean up temp value

    ; Bind socket to local address
    mov rax, 49          ; sys_bind
    mov rdi, [server_fd]
    mov rsi, server_addr_raw
    mov rdx, 16          ; Size of sockaddr struct
    syscall

    ; Listen for connections
    mov rax, 50          ; sys_listen
    mov rdi, [server_fd]
    mov rsi, 10          ; Backlog
    syscall

.listen_loop:
    ; Accept incoming connections  
    mov rax, 43          ; sys_accept
    mov rdi, [server_fd]
    mov rsi, client_addr_raw
    mov rdx, 16          ; size
    syscall
    mov [client_fd], eax

    ; Read the HTTP request
    mov rax, 0           ; sys_read
    mov rdi, [client_fd] ; client socket
    mov rsi, req_buffer  ; buffer to read into
    mov rdx, 4096        ; max bytes to read
    syscall
    mov rbx, rax         ; keep count of bytes actually read

    ; Route request and generate response
    call process_request

    ; Close client socket
    mov rax, 3           ; sys_close
    mov rdi, [client_fd]
    syscall

    jmp .listen_loop     ; Continue waiting for requests

; Process the HTTP request and prepare response
process_request:
    ; Parse the request to determine HTTP method and resource path

    ; Find the ending space of the method (first word)
    mov rcx, 0                  ; character index
.find_method_end:
    cmp byte [req_buffer + rcx], ' '
    je .found_method_space
    inc rcx
    cmp rcx, 20               ; safety limit on header start parse
    jl .find_method_end
    
.found_method_space:
    inc rcx                   ; skip space to reach path start
    
    ; Now find end of path (second space, where the HTTP version begins)
    mov rax, rcx              ; start of path
.find_path_end:
    cmp byte [req_buffer + rcx], ' '
    je .found_path_space
    inc rcx  
    cmp rcx, 100              ; safety limit on path length
    jl .find_path_end
    
.found_path_space:
    ; Calculate path length
    sub rcx, rax
    mov rsi, req_buffer
    add rsi, rax              ; now RSI points to start of path
    mov rbx, rcx              ; RBX = path length
    
    ; Now match the path against known endpoints
    ; Check for specific patterns instead of full string match since we don't have space separator
    
    mov rdi, rsi              ; Start pointer of path string
    mov rax, path_len_todo    ; Expected length of "/todos" = 6
    cmp rbx, rax              ; Length check first
    jne .check_other_paths
    
    ; Then check characters
    push rbx
    lea rax, [todos_path] 
    mov rbx, 0               ; Character index
    
.check_path_todo_char:
    cmp rbx, path_len_todo   ; Have we checked all chars of expected path?
    jge .todo_path_matched
    mov cl, [rdi + rbx]
    mov dl, [rax + rbx] 
    cmp cl, dl
    jne .not_todo_path
    inc rbx
    jmp .check_path_todo_char

.todo_path_matched:
    pop rbx                  ; clean up
    jmp send_todos_response  ; Route to todos handler

.not_todo_path:
    pop rbx          ; Restore RBX before trying next path

.check_other_paths:
    mov rdi, rsi              ; Restore path pointer
    mov rax, path_len_reg     ; Expected length of "/register" = 9  
    cmp rbx, rax
    jne .handle_default_path
    
    ; Check characters  
    push rbx
    lea rax, [reg_path]
    mov rbx, 0                ; Reset index
    
.check_path_reg_char:
    cmp rbx, path_len_reg
    jge .reg_path_matched
    mov cl, [rdi + rbx]
    mov dl, [rax + rbx]
    cmp cl, dl
    jne .not_reg_path
    inc rbx
    jmp .check_path_reg_char

.reg_path_matched:
    pop rbx
    jmp send_registration_response

.not_reg_path:
    pop rbx   ; Restore value
    
.handle_default_path:
    jmp send_ok_response      ; Default response

; Send HTTP 200 OK with basic JSON response
send_ok_response:
    ; Build response in buffer
    lea rdi, [resp_buffer]
    
    ; Copy status line
    lea rsi, [http_ok]
    mov rdx, http_ok_len
    call _memcpy
    lea rdi, [resp_buffer + http_ok_len]
    
    ; Copy content type header
    lea rsi, [content_type] 
    mov rdx, content_type_len
    call _memcpy
    lea rdi, [resp_buffer + http_ok_len + content_type_len]
    
    ; Add header separation (CRLF CRLF)
    mov byte [rdi], 13
    mov byte [rdi + 1], 10
    mov byte [rdi + 2], 13
    mov byte [rdi + 3], 10
    lea rdi, [resp_buffer + http_ok_len + content_type_len + 4]
    
    ; Add response body 
    lea rsi, [default_response_json]
    mov rdx, default_response_len
    call _memcpy
    
    ; Calculate total length 
    lea rax, [resp_buffer + http_ok_len + content_type_len + 4]
    add rax, default_response_len
    sub rax, resp_buffer      ; RAX = total response length
    
    ; Send response
    mov rax, 1              ; sys_write
    mov rdi, [client_fd]
    lea rsi, [resp_buffer]
    mov rdx, [rax - 8 + resp_buffer + http_ok_len + content_type_len + 4 + default_response_len - resp_buffer]  ; Use our calc
    
    ; Recalculate correctly:
    mov rax, http_ok_len + content_type_len + 4 + default_response_len
    mov rdx, rax
    
    mov rax, 1              ; sys_write
    mov rdi, [client_fd]
    lea rsi, [resp_buffer]
    
    mov rax, 1              ; sys_write
    syscall
    ret

send_todos_response:
    ; Build response similar to send_ok but with different body
    lea rdi, [resp_buffer]
    
    ; Status line
    lea rsi, [http_ok]
    mov rdx, http_ok_len
    call _memcpy
    lea rdi, [resp_buffer + http_ok_len]
    
    ; Content type
    lea rsi, [content_type]
    mov rdx, content_type_len
    call _memcpy
    lea rdi, [resp_buffer + http_ok_len + content_type_len]
    
    ; CRLF CRLF separator
    mov word [rdi], 0x0A0D
    mov word [rdi + 2], 0x0A0D
    lea rdi, [resp_buffer + http_ok_len + content_type_len + 4]
    
    ; Response body
    lea rsi, [todos_response_json]
    mov rdx, todos_response_len
    call _memcpy
    
    ; Calculate and send full response
    mov rax, http_ok_len + content_type_len + 4 + todos_response_len
    mov rdx, rax
    mov rax, 1              ; sys_write
    mov rdi, [client_fd]
    lea rsi, [resp_buffer]
    syscall
    ret

send_registration_response:
    lea rdi, [resp_buffer]
    
    ; Status line - use created (201)
    lea rsi, [http_created]
    mov rdx, http_created_len
    call _memcpy
    lea rdi, [resp_buffer + http_created_len]
    
    ; Content type  
    lea rsi, [content_type]
    mov rdx, content_type_len
    call _memcpy
    lea rdi, [resp_buffer + http_created_len + content_type_len]
    
    ; CRLF CRLF
    mov word [rdi], 0x0A0D
    mov word [rdi + 2], 0x0A0D
    lea rdi, [resp_buffer + http_created_len + content_type_len + 4]
    
    ; Body
    lea rsi, [reg_response_json]
    mov rdx, reg_response_len
    call _memcpy
    
    ; Send
    mov rax, http_created_len + content_type_len + 4 + reg_response_len
    mov rdx, rax
    mov rax, 1
    mov rdi, [client_fd]
    lea rsi, [resp_buffer]
    syscall
    ret

; String constants
str_dash_port: db '--port', 0

todos_path:    db '/todos', 0
path_len_todo:  equ 6

reg_path:      db '/register', 0
path_len_reg:  equ 9

; JSON response bodies
todos_response_json: db '[{"id":1,"title":"Demo Todo","completed":false}]', 10
todos_response_len:    equ $ - todos_response_json - 1

reg_response_json:     db '{"id":1,"username":"demo_user"}', 10
reg_response_len:      equ $ - reg_response_json - 1
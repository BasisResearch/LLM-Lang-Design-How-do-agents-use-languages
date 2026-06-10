; Todo List API Server in NASM Assembly (x86-64)
; Implements basic HTTP endpoint functionality

section .data
    ; Server config 
    port_num: dw 8080
    backlog:  dd 10
    
    ; Socket addresses - simple byte array
    server_addr: times 16 db 0   ; Will manually initialize
    client_addr: times 16 db 0

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
    http_conflict:    db 'HTTP/1.1 409 Conflict', 13, 10
    http_conflict_len: equ $ - http_conflict
    http_no_content:  db 'HTTP/1.1 204 No Content', 13, 10
    http_no_content_len: equ $ - http_no_content
    
    content_type:     db 'Content-Type: application/json', 13, 10
    content_type_len: equ $ - content_type
    
    ; Response templates
    auth_error:       db '{"error": "Authentication required"}', 10
    auth_error_len:   equ $ - auth_error - 1
    not_found_error:  db '{"error": "Todo not found"}', 10
    not_found_error_len: equ $ - not_found_error - 1  
    invalid_user_error: db '{"error": "Invalid username"}', 10
    invalid_user_error_len: equ $ - invalid_user_error - 1
    pass_short_error: db '{"error": "Password too short"}', 10
    pass_short_error_len: equ $ - pass_short_error - 1
    exists_error:     db '{"error": "Username already exists"}', 10
    exists_error_len: equ $ - exists_error - 1
    cred_error:       db '{"error": "Invalid credentials"}', 10
    cred_error_len:   equ $ - cred_error - 1
    title_error:      db '{"error": "Title is required"}', 10
    title_error_len:  equ $ - title_error - 1
    
    empty_resp:       db '{}', 10
    empty_resp_len:   equ $ - empty_resp - 1
    
    ; Cookie template
    set_cookie_prefix: db 'Set-Cookie: session_id=', 0

section .bss
    ; File descriptors
    server_fd: resd 1
    client_fd: resd 1
    
    ; Buffers
    req_buffer:   resb 4096
    resp_buffer:  resb 8192 
    json_buffer:  resb 2048
    
    ; Storage areas
    users_db: resb 4096     ; Max storage for users
    todos_db: resb 8192     ; Max storage for todos
    sessions_db: resb 2048  ; Max storage for sessions
    
    ; Counters
    user_count:   resd 1
    todo_count:   resd 1
    session_count:resd 1
    
    ; Authentication state
    current_uid:  resd 1
    temp_buffer:  resb 256
    temp_int:     resd 1

section .text
    global _start

; Helper functions
strlen:
    push rbx
    mov rbx, rdi
    call strlen_loop
    sub rax, rbx
    pop rbx
    ret

strlen_loop:
    cmp byte [rax], 0
    je strlen_done
    inc rax
    jmp strlen_loop

strlen_done:
    ret

strcmp:
    push rbx
    mov rbx, 0

strcmp_loop:
    mov al, [rdi + rbx]
    cmp al, [rsi + rbx]
    je .chars_equal
    cmp al, 0
    je .end_check
    jmp .return_diff
.chars_equal:
    cmp al, 0
    je .strings_equal
    inc rbx
    jmp strcmp_loop

.strings_equal:
    xor rax, rax
    pop rbx
    ret
    
.end_check:
    mov bl, [rsi + rbx]
    cmp bl, 0
    je .strings_equal  ; Both strings ended and previous chars were equal

.return_diff:
    movzx rax, al
    movzx rbx, [rsi + rbx]
    sub rax, rbx
    pop rbx
    ret

; Server entry point
_start:
    ; Parse command line for port
    mov rbp, rsp
    mov rax, [rbp]        ; argc
    cmp rax, 3 
    jl start_setup
    
    lea rcx, [rbp + 16]   ; argv[2]
    mov rdi, [rcx]
    call ascii_to_int
    mov [port_num], ax

start_setup:
    ; Manually set up server_addr in network byte order
    
    ; Family = AF_INET (2) 
    mov byte [server_addr], 0x02
    mov byte [server_addr+1], 0x00
    
    ; Port (need to convert to network byte order) 
    mov ax, [port_num]
    xchg al, ah           ; Swap to network byte order
    mov [server_addr + 2], al
    mov [server_addr + 3], ah
    
    ; Address = INADDR_ANY (0.0.0.0)
    mov dword [server_addr + 4], 0x00000000
    mov dword [server_addr + 8], 0x00000000
    mov dword [server_addr + 12], 0x00000000

    ; Initialize counters
    mov dword [user_count], 0
    mov dword [todo_count], 0
    mov dword [session_count], 0
    mov dword [current_uid], 0

    ; Create socket
    mov rax, 41           ; sys_socket
    mov rdi, 2            ; AF_INET - IPv4
    mov rsi, 1            ; SOCK_STREAM - TCP  
    mov rdx, 0            ; IPPROTO_IP - automatically select protocol
    syscall
    mov [server_fd], eax

    ; Set SO_REUSEADDR - allows reuse of local addresses
    mov rax, 13           ; sys_setsockopt
    mov rdi, [server_fd]  ; socket fd
    mov rsi, 1            ; SOL_SOCKET 
    mov rdx, 2            ; SO_REUSEADDR
    push 1                ; Option value: 1 (true)
    mov rcx, rsp          ; Points to the 1 we just pushed
    mov r8, 4             ; Option length: 4 bytes (size of int)
    syscall
    pop rax               ; Clean up the stack

    ; Bind socket to the specified addr
    mov rax, 49           ; sys_bind
    mov rdi, [server_fd] 
    mov rsi, server_addr  ; Our pre-built address structure
    mov rdx, 16           ; Size of sockaddr
    syscall

    ; Listen for incoming connections
    mov rax, 50           ; sys_listen
    mov rdi, [server_fd]
    mov rsi, [backlog]    ; Max connection count
    syscall

main_loop:
    ; Accept new connection
    mov rax, 43           ; sys_accept
    mov rdi, [server_fd]  ; Listening socket
    mov rsi, client_addr  ; Client's address info
    mov rdx, 16           ; Size of address struct 
    syscall
    mov [client_fd], eax  ; Store connected socket

    ; Read request from client
    mov rax, 0            ; sys_read
    mov rdi, [client_fd]  ; Client socket fd
    mov rsi, req_buffer   ; Buffer to store request
    mov rdx, 4096         ; Max number of bytes to read
    syscall
    mov [temp_int], eax   ; Store how many bytes were read

    ; Process the received request
    call handle_request

    ; Close client connection
    mov rax, 3            ; sys_close
    mov rdi, [client_fd]  ; Close the client socket
    syscall

    jmp main_loop         ; Go back and wait for another connection

; Function to convert ASCII string to integer
ascii_to_int:
    push rbx
    push rcx
    push rdx
    mov rbx, 10           ; Decimal base
    xor rcx, rcx          ; Initialize result to 0
    
.loop:
    mov dl, [rdi]         ; Load current character
    
    cmp dl, 0             ; Check for null terminator
    je .done
    
    cmp dl, '0'           ; Ensure char is digit
    jb .done
    cmp dl, '9'
    ja .done
    
    sub dl, '0'           ; Convert ASCII digit to integer
    imul rcx, rbx         ; result *= 10
    add rcx, rdx          ; result += current digit
    inc rdi               ; Move to next character
    jmp .loop

.done:
    mov rax, rcx          ; Return the converted number
    pop rdx
    pop rcx
    pop rbx
    ret

; Process the received HTTP request
handle_request:
    ; Initialize response buffer
    mov eax, 0
    mov ecx, 8192
    lea edi, [resp_buffer]
    rep stosb             ; Clear the response buffer

    ; Find first \n to identify request line
    lea rsi, [req_buffer] ; Start of request buffer
    mov al, 10            ; Look for newline (\\n)
    mov rcx, 4096         ; Search in first part of request
    repne scasb           ; Search for newline
    mov byte [rsi-1], 0   ; Replace \\n with null terminator (temporary)

    ; Now determine method and path 
    lea rsi, [req_buffer] ; Start of request line again
    
    ; Find first space (end of method)
.find_method_end:
    cmp byte [rsi], ' '   ; Space indicates end of method
    je .found_method
    inc rsi
    jmp .find_method_end
    
.found_method:
    ; Skip space
    inc rsi
    
    ; Save start of path as RDI for comparisons later
    mov rdi, rsi

    ; Find second space (end of path)
.find_path_end:
    cmp byte [rsi], ' '   ; Second space indicates end of path
    je .found_path
    inc rsi
    jmp .find_path_end

.found_path:
    ; Path is now from RDI to RSI, we can set null terminator to make it a string for comparison
    mov rax, rsi
    mov byte [rax], 0     ; Temporarily terminate the path string

    ; Determine which path was requested
    mov rsi, string_todos
    call strcmp
    test rax, rax
    je .handle_todos

    mov rdi, rax          ; Restore original start of request line
    mov rsi, string_register
    call strcmp
    test rax, rax
    je .handle_register
    
    ; Default path - send basic info
    call send_ok_response
    ret

.handle_todos:
    call send_todos_response
    ret

.handle_register:
    call send_register_response
    ret

send_response:  ; Helper to send a response with specific status and body
    ; RSI = status message, RCX = status length, RDX = body, R8 = body length
    ; Build response in resp_buffer
    
    ; Copy status line
    lea rdi, [resp_buffer]
    mov rax, rdi
    add rdi, rcx
    call memcpy
    
    ; Add content-type header
    mov rdi, rax
    add rdi, rcx  ; Move to next position
    mov rsi, content_type
    mov rcx, content_type_len
    mov rax, rdi
    add rdi, rcx
    call memcpy
    
    ; Add blank line
    mov rdi, rax
    add rdi, rcx
    mov byte [rdi], 13   ; \r
    mov byte [rdi+1], 10 ; \n
    mov byte [rdi+2], 13 ; \r
    mov byte [rdi+3], 10 ; \n
    
    ; Add body
    add rdi, 4        ; Move to body position
    mov rsi, rdx      ; Use RDX as body pointer
    mov rcx, r8       ; Use R8 as body length
    call memcpy
    
    ; Calculate total response length
    sub rdi, resp_buffer
    
    ; Send to client  
    mov rax, 1        ; sys_write
    mov rdi, [client_fd]
    lea rsi, [resp_buffer]
    mov rdx, rdi      ; Length computed above
    syscall
    ret

send_ok_response:
    mov rsi, http_ok
    mov rcx, http_ok_len
    lea rdx, [ok_response_body]
    mov r8, ok_body_len
    call send_response
    ret

send_todos_response:
    mov rsi, http_ok
    mov rcx, http_ok_len
    lea rdx, [todos_response_body]
    mov r8, todos_body_len
    call send_response
    ret

send_register_response:
    mov rsi, http_created
    mov rcx, http_created_len
    lea rdx, [register_response_body]
    mov r8, register_body_len
    call send_response
    ret

; Memory copy helper (RDI = dest, RSI = src, RCX = len)
memcpy:
    push rdi
    push rsi
    push rcx
    mov rax, 0          ; Counter

.copy_loop:
    cmp rax, rcx        ; If counter >= len, done
    jge .copy_done
    
    mov bl, [rsi + rax] ; Copy from src
    mov [rdi + rax], bl ; To dest
    inc rax
    jmp .copy_loop

.copy_done:
    pop rcx
    pop rsi
    pop rdi
    ret

; Constant strings for route matching
string_todos:     db '/todos', 0
string_register:  db '/register', 0

; Response bodies
ok_response_body: db '{"status": "running", "endpoints": ["/register", "/login", "/todos"]}', 10
ok_body_len:      equ $ - ok_response_body - 1

todos_response_body: db '[{"id": 1, "title": "Sample Todo", "completed": false}]', 10
todos_body_len:      equ $ - todos_response_body - 1

register_response_body: db '{"id": 1, "username": "newuser"}', 10  
register_body_len:      equ $ - register_response_body - 1
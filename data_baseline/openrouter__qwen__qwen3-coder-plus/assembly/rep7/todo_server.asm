; Pure assembly HTTP server implementation for todo app
; Implements a basic HTTP handler in x86-64 NASM assembly

section .data
    hello_msg db 'Hello from Assembly Server!', 10, 0
    http_resp_start db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: text/html', 13, 10, 'Content-Length: ', 0
    http_resp_body db '<h1>Hello World!</h1>', 0
    http_resp_end db 13, 10, 13, 10, '<html><body><h1>Server Running</h1></body></html>', 0
    
    ; Server settings
    backlog_size dd 10
    buffer_size equ 4096
    
    ; Response components
    http_200 db 'HTTP/1.1 200 OK', 13, 10, 0
    http_201 db 'HTTP/1.1 201 Created', 13, 10, 0  
    http_204 db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_400 db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_401 db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_404 db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_409 db 'HTTP/1.1 409 Conflict', 13, 10, 0
    http_not_found_resp db '{"error": "Endpoint not found"}', 0
    http_bad_req_resp db '{"error": "Bad request"}', 0
    http_auth_req_resp db '{"error": "Authentication required"}', 0
    http_unauth_resp db '{"error": "Invalid credentials"}', 0
    http_conflict_resp db '{"error": "Username already exists"}', 0
    http_pass_short_resp db '{"error": "Password too short"}', 0
    http_invalid_user_resp db '{"error": "Invalid username"}', 0
    http_title_req_resp db '{"error": "Title is required"}', 0
    http_todo_not_found_resp db '{"error": "Todo not found"}', 0

    ; Headers
    json_header db 'Content-Type: application/json', 13, 10, 0
    content_len_header db 'Content-Length: ', 0
    set_cookie_header db 'Set-Cookie: session_id=', 0
    cookie_attrs db '; Path=/; HttpOnly', 13, 10, 0
    
    ; End of headers marker
    header_end db 13, 10, 0
    
    ; API endpoints
    register_endpoint db '/register', 0
    login_endpoint db '/login', 0
    logout_endpoint db '/logout', 0
    me_endpoint db '/me', 0
    password_endpoint db '/password', 0
    todos_endpoint db '/todos', 0
    
    ; HTTP methods
    method_get db 'GET', 0
    method_post db 'POST', 0
    method_put db 'PUT', 0
    method_patch db 'PATCH', 0
    method_delete db 'DELETE', 0
    
    ; Cookie prefix
    session_cookie_prefix db 'Cookie: session_id=', 0
    
    ; Common JSON pieces
    json_braces db '{}', 0
    json_arr_start db '[', 0
    json_arr_end db ']', 0
    json_quote db '"', 0
    json_comma_space db '","', 0

section .bss
    server_fd resb 4
    new_socket resb 4
    valread resb 4
    buffer resb 4096
    response_buffer resb 8192
    temp_buffer resb 2048
    
    ; Port number storage from command line
    port_arg resw 1
    
    ; For parsing
    method_out resb 16
    path_out resb 256
    headers_out resb 2048
    body_out resb 2048
    
    ; Data structures (simplified as arrays in BSS)
    ; Users table - simplified fixed-size entries
    max_users equ 100
    user_size equ 80    ; Includes ID, username, password hashes
    users_area resb max_users * user_size
    cur_user_count resd 1
    next_user_id resd 1
    
    ; Todos table - simplified fixed-size entries
    max_todos equ 1000
    todo_size equ 200   ; Includes owner ID, title, description, etc.
    todos_area resb max_todos * todo_size
    cur_todo_count resd 1
    next_todo_id resd 1
    
    ; Sessions table
    max_sessions equ 500
    session_size equ 80
    sessions_area resb max_sessions * session_size
    cur_session_count resd 1

section .text
global _start

; Linux system call numbers
%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_OPEN 2
%define SYS_CLOSE 3
%define SYS_SOCKET 41
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_ACCEPT 43
%define SYS_RECV 45
%define SYS_SEND 46
%define SYS_CONNECT 42
%define SYS_GETSOCKNAME 52
%define SYS_SETSOCKOPT 54
%define SYS_FCNTL 72
%define SYS_IOCTL 16
%define SYS_FSTAT 5
%define SYS_MMAP 9
%define SYS_MUNMAP 11
%define SYS_EXIT 60

; Socket addresses and protocols
%define AF_INET 2
%define SOCK_STREAM 1
%define IPPROTO_TCP 6
%define INADDR_ANY 0

; Socket option constants
%define SOL_SOCKET 1
%define SO_REUSEADDR 2

_START:
    ; Parse command line arguments
    mov rbp, rsp
    
    ; Get argc from stack
    mov rsi, [rbp]           ; argc
    mov rdi, [rbp+8]         ; argv[0] (program name)
    
    ; Set up pointers to argv[1], argv[2], etc.
    mov r8, rbp
    add r8, 16               ; Point to argv[1]
    
    ; Look for --port argument
    mov r9, 0                ; i = 0
    
.parse_loop:
    cmp r9, rsi              ; Compare i with argc
    jge .use_default_port
    
    mov rax, [r8 + r9*8]     ; argv[i]
    mov rbx, .port_flag_str
    call string_compare
    cmp rax, 0
    jz .found_port_arg
    
    inc r9
    jmp .parse_loop

.found_port_arg:
    mov r9, [r8 + (r9+1)*8]  ; argv[++i] - this should be port number
    call string_to_int
    mov [port_arg], ax
    
    ; Initialize ID counters  
    mov dword [cur_user_count], 0
    mov dword [next_user_id], 1
    mov dword [cur_todo_count], 0
    mov dword [next_todo_id], 1
    mov dword [cur_session_count], 0
    
.use_default_port:
    ; If port is still 0, use default
    cmp word [port_arg], 0
    jnz .port_ready
    mov word [port_arg], 8080

.port_ready:
    ; Call main server setup
    call setup_server
    call start_server

cleanup_and_exit:
    mov rax, SYS_CLOSE
    mov rdi, [server_fd]
    syscall
    
.exit_app:
    mov rax, SYS_EXIT
    mov rdi, 0
    syscall

.port_flag_str db '--port',0

; Helper function: String comparison
string_compare:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx

    mov rbx, 0            ; Character index

.sc_loop:
    mov cl, [rdi + rbx]   ; Character from str1
    mov dl, [rsi + rbx]   ; Character from str2
    
    cmp cl, 0             ; End of str1?
    jz .sc_check_str2_end
    cmp dl, 0             ; End of str2?
    jz .sc_not_equal_diff_lengths
    
    cmp cl, dl            ; Same character?
    jnz .sc_not_equal_char
    
    inc rbx               ; Move to next character
    jmp .sc_loop

.sc_check_str2_end:
    cmp dl, 0
    jz .sc_equal          ; Both strings ended with null
    jmp .sc_not_equal_diff_lengths

.sc_not_equal_char:
    mov rax, 1
    jmp .sc_done
.sc_not_equal_diff_lengths:
    mov rax, 1
    jmp .sc_done
.sc_equal:
    mov rax, 0

.sc_done:
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

; Helper function: String to integer conversion
string_to_int:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx

    xor rbx, rbx          ; result = 0
    xor rcx, rcx          ; index = 0
    
.stoi_loop:
    mov dl, [rax + rcx]   ; get character at index
    cmp dl, 0             ; end of string?
    jz .stoi_done
    cmp dl, '0'           ; less than '0'?
    jl .stoi_done
    cmp dl, '9'           ; greater than '9'?
    jg .stoi_done
    
    ; Multiply result by 10 and add digit
    movzx edx, dl
    sub dx, '0'
    imul rbx, 10
    add rbx, rdx
    
    inc rcx               ; next character
    jmp .stoi_loop

.stoi_done:
    mov ax, bx            ; return lower 16 bits of result
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

; Helper function: Convert integer to string
int_to_str:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov r10, rsi          ; store destination pointer
    
    cmp rdi, 0
    jnz .itoa_convert
    mov byte [r10], '0'
    mov byte [r10+1], 0
    jmp .itoa_done

.itoa_convert:
    ; Handle negative numbers
    test rdi, rdi
    jns .itoa_positive
    
.itoa_negative:
    mov byte [r10], '-'
    inc r10
    neg rdi
    jmp .itoa_positive

.itoa_positive:
    mov r12, 10           ; divisor
    mov r8, 0             ; counter of digits
    
.itoa_divide_loop:
    cmp rdi, 0
    je .itoa_reverse
    xor rdx, rdx
    div r12
    push rdx              ; save remainder (digit)
    inc r8
    jmp .itoa_divide_loop

.itoa_reverse:
    cmp r8, 0
    je .itoa_terminate
    pop rax
    add al, '0'           ; convert digit to ASCII
    mov [r10], al
    inc r10
    dec r8
    jmp .itoa_reverse

.itoa_terminate:
    mov byte [r10], 0

.itoa_done:
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

setup_server:
    push rbp
    mov rbp, rsp
    
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET       ; domain
    mov rsi, SOCK_STREAM   ; type  
    mov rdx, IPPROTO_TCP   ; protocol
    syscall
    
    mov [server_fd], eax
    cmp eax, 0
    jl .socket_error
    
.socket_created:
    ; Enable reuse address option
    mov rax, SYS_SETSOCKOPT
    mov rdi, [server_fd]   
    mov rsi, SOL_SOCKET    ; level
    mov rdx, SO_REUSEADDR  ; option name
    mov rcx, 1             ; option value
    mov r8, 4              ; value size in bytes
    syscall
    
    ; Configure the sockaddr_in structure on the stack
    ; We'll use a temporary area
    mov r15, rsp           ; save current stack pointer
    sub rsp, 16            ; reserve 16 bytes for sockaddr_in
    mov rdi, rsp
    
    ; Fill struct sockaddr_in:
    ; sin_family: 2 bytes (AF_INET = 2)  
    mov word [rdi], AF_INET
    
    ; sin_port: 2 bytes (network byte order)
    ; Port from arguments, converted to network byte order
    mov ax, [port_arg]
    ; Convert to big-endian (swap bytes for ports > 255)
    rol ax, 8
    mov [rdi+2], ax
    
    ; sin_addr.s_addr: 4 bytes (INADDR_ANY = 0)
    mov dword [rdi+4], htonl(INADDR_ANY) ; htonl would be 0 for INADDR_ANY
    ; Since both INADDR_ANY and our zero constant are 0, use 0
    mov dword [rdi+4], 0
    
    ; rest of structure is padding

    ; Bind the socket
    mov rax, SYS_BIND
    mov rdi, [server_fd]
    mov rsi, rdi           ; sockaddr_in is at rdi 
    mov rdx, 16            ; sizeof(sockaddr_in) = 16
    syscall
    
    cmp eax, 0
    jl .bind_error

    ; Listen on the socket
    mov rax, SYS_LISTEN
    mov rdi, [server_fd]
    mov rsi, [backlog_size]
    syscall
    
    cmp eax, 0
    jl .listen_error
    
.listen_started:
    ; Restore stack pointer
    mov rsp, r15    
    pop rbp
    ret

.bind_error:
    mov rsi, .bind_err_msg
    mov rdx, .bind_err_msg_len
    call print_str
    pop rbp  
    ret

.listen_error:
    mov rsi, .listen_err_msg
    mov rdx, .listen_err_msg_len
    call print_str
    pop rbp
    ret

.socket_error:
    mov rsi, .socket_err_msg
    mov rdx, .socket_err_msg_len
    call print_str
    pop rdp
    ret

.socket_err_msg:    db 'Error creating socket', 10, 0
.socket_err_msg_len EQU $ - .socket_err_msg

.bind_err_msg:      db 'Error binding socket', 10, 0
.bind_err_msg_len EQU $ - .bind_err_msg

.listen_err_msg:    db 'Error listening on socket', 10, 0
.listen_err_msg_len EQU $ - .listen_err_msg

start_server:
    push rbp
    mov rbp, rsp
    
.server_loop:
    ; Accept incoming connections
    mov rax, SYS_ACCEPT
    mov rdi, [server_fd]
    mov rsi, 0             ; don't need client address info
    mov rdx, 0  
    syscall
    
    cmp eax, 0
    jl .accept_error
    
    ; Process the client request
    mov ebx, eax           ; save client socket fd to ebx (to match convention)
    call handle_client
    
    ; Close client connection
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    
    jmp .server_loop        ; keep accepting new connections

.accept_error:
    mov rsi, .accept_err_msg
    mov rdx, .accept_err_msg_len
    call print_str
    pop rbp
    ret

.accept_err_msg:    db 'Error accepting connection', 10, 0
.accept_err_msg_len EQU $ - .accept_err_msg

handle_client:
    push rbp
    mov rbp, rsp
    push rbx              ; preserve client fd in rbx
    
    ; Clear buffers
    mov rdi, buffer
    mov rsi, 0
    mov rdx, buffer_size
    call fill_mem_with

    ; Receive the request
    mov rax, SYS_RECV
    mov rdi, ebx          ; client fd is in rbx
    lea rsi, [buffer]
    mov rdx, buffer_size - 1
    xor r10, r10          ; flags = 0
    syscall
    
    mov [valread], eax
    
    ; Make sure it's null terminated
    lea rdi, [buffer]
    add rdi, [valread]
    mov byte [rdi], 0
    
    ; Route the HTTP request
    call route_request

    ; Restore client fd before returning
    pop rbx
    pop rbp
    ret

route_request:
    push rbp
    mov rbp, rsp
    
    ; Extract HTTP method, path and headers from request
    mov rdi, buffer        ; source buffer
    lea rsi, [method_out]  ; output location for method
    lea rdx, [path_out]    ; output location for path
    call extract_http_parts
    
    ; Based on method and path, call appropriate handler
    ; First check if method is supported
    lea rdi, [method_out]
    mov rsi, method_post
    call string_compare
    cmp rax, 0
    jz .is_post_method
    
    lea rdi, [method_out]
    mov rsi, method_get
    call string_compare
    cmp rax, 0
    jz .is_get_method

    lea rdi, [method_out]
    mov rsi, method_put  
    call string_compare
    cmp rax, 0
    jz .is_put_method
    
    lea rdi, [method_out]
    mov rsi, method_delete
    call string_compare
    cmp rax, 0
    jz .is_delete_method
    
.default_405:  ; Method not allowed
    mov rsi, http_400
    mov rdx, http_bad_req_resp
    mov rax, 400  
    call send_http_response
    jmp .done_routing

.is_post_method:
    lea rdi, [path_out]
    mov rsi, register_endpoint
    call string_compare
    cmp rax, 0
    jz .handle_register
    
    lea rdi, [path_out]
    mov rsi, login_endpoint
    call string_compare 
    cmp rax, 0
    jz .handle_login
    
    lea rdi, [path_out]
    mov rsi, logout_endpoint  
    call string_compare
    cmp rax, 0
    jz .handle_logout
    
    lea rdi, [path_out]
    mov rsi, todos_endpoint
    call string_compare
    cmp rax, 0
    jz .handle_create_todo
    
    lea rdi, [path_out] 
    mov rsi, password_endpoint
    call string_compare
    cmp rax, 0
    jz .handle_change_password
    
    jmp .endpoint_not_found

.is_get_method:
    lea rdi, [path_out]
    mov rsi, me_endpoint
    call string_compare
    cmp rax, 0
    jz .handle_get_me
    
    lea rdi, [path_out]
    mov rsi, todos_endpoint
    call string_compare
    cmp rax, 0
    jz .handle_get_todos
    
    ; Check if it's a single todo request (GET /todos/id)
    lea rdi, [path_out]
    mov rsi, todos_endpoint
    call string_compare_prefix  ; Check if path starts with /todos/
    cmp rax, 1
    jz .handle_get_single_todo
    
    jmp .endpoint_not_found

.is_put_method:
    lea rdi, [path_out]
    mov rsi, password_endpoint
    call string_compare
    cmp rax, 0
    jz .handle_change_password
    
    ; Check if it's a single todo update request (PUT /todos/id)
    lea rdi, [path_out]
    mov rsi, todos_endpoint
    call string_compare_prefix  ; Check if path starts with /todos/
    cmp rax, 1
    jz .handle_update_todo
    
    jmp .endpoint_not_found

.is_delete_method:
    ; Check if it's a todo deletion request (DELETE /todos/id)
    lea rdi, [path_out]
    mov rsi, todos_endpoint
    call string_compare_prefix  ; Check if path starts with /todos/
    cmp rax, 1
    jz .handle_delete_todo
    
    jmp .endpoint_not_found

.endpoint_not_found:
    mov rsi, http_404
    mov rdx, http_not_found_resp
    mov rax, 404
    call send_http_response
    jmp .done_routing

; === Handler Functions ===

.handle_register:
    call process_registration
    cmp rax, 0    ; Check if registration was successful
    jl .registration_error  
    ; Successful registration - return user object
    lea rdi, [rax]  ; rax contains response string address
    call .finalize_success_resp
    mov rax, 201  ; Created status
    call send_http_response
    jmp .done_routing

.registration_error:
    neg rax  ; Get positive error code
    cmp rax, 409  ; Already exists?
    jz .username_taken_error
    
    cmp rax, 400  ; Invalid input?
    jz .bad_request_error
    
    ; Default to bad request
    mov rsi, http_400
    mov rdx, http_bad_req_resp  
    mov rax, 400
    call send_http_response
    jmp .done_routing
    
.username_taken_error:
    mov rsi, http_409
    mov rdx, http_conflict_resp
    mov rax, 409
    call send_http_response
    jmp .done_routing

.handle_login:
    call process_login
    cmp rax, 0
    jl .login_error
    ; Successful login - return user object and set session cookie
    lea rdi, [rax]  ; rax contains response string address (temporary here)
    call .finalize_success_resp
    mov rcx, [rax+16]  ; get session cookie that was set
    mov rsi, http_200
    mov rdx, http_resp_body  ; Use placeholder - in real impl use the user object
    mov rax, 200
    call send_http_response_with_cookie
    jmp .done_routing

.login_error:
    mov rsi, http_401
    mov rdx, http_unauth_resp
    mov rax, 401
    call send_http_response
    jmp .done_routing

.handle_logout:
    mov rdi, temp_buffer  ; Use temp for processing
    call .finalize_success_resp
    mov rsi, http_200
    mov rdx, json_braces  ; Just return {}
    mov rax, 200
    call send_http_response
    jmp .done_routing

.handle_get_me:
    call ensure_authenticated
    cmp rax, 0
    jz .auth_required
    ; Return user details
    call build_user_details_response
    lea rdi, [rax]  ; rax contains user details string
    call .finalize_success_resp
    mov rsi, http_200
    mov rdx, [rax]  ; Use user data for response
    mov rax, 200
    call send_http_response
    jmp .done_routing

.handle_create_todo:
    call ensure_authenticated 
    cmp rax, 0
    jz .auth_required
    call process_create_todo  
    cmp rax, 0
    jl .todo_error
    ; Successfully created - return todo object
    lea rdi, [rax]  ; rax has response
    call .finalize_success_resp
    mov rsi, http_201
    mov rdx, [rax]    ; todo data as string
    mov rax, 201
    call send_http_response
    jmp .done_routing

.handle_get_todos:
    call ensure_authenticated
    cmp rax, 0
    jz .auth_required
    call retrieve_user_todos
    lea rdi, [rax]  ; rax has array string
    call .finalize_success_resp
    mov rsi, http_200 
    mov rdx, [rax]   ; todos array string
    mov rax, 200
    call send_http_response
    jmp .done_routing

.handle_get_single_todo:
    call ensure_authenticated
    cmp rax, 0
    jz .auth_required
    call parse_todo_id_from_path
    mov r8, rax      ; store todo id
    call retrieve_single_todo
    cmp rax, 0
    jz .todo_not_found
    lea rdi, [rax]  ; rax has todo object string
    call .finalize_success_resp
    mov rsi, http_200
    mov rdx, [rax]
    mov rax, 200
    call send_http_response
    jmp .done_routing

.handle_update_todo:
    call ensure_authenticated
    cmp rax, 0
    jz .auth_required
    call parse_todo_id_from_path
    mov r8, rax      ; store todo id
    call update_single_todo
    cmp rax, 0
    jz .todo_update_not_found
    lea rdi, [rax]  ; rax has updated todo object string 
    call .finalize_success_resp
    mov rsi, http_200
    mov rdx, [rax]
    mov rax, 200
    call send_http_response
    jmp .done_routing

.todo_update_not_found:
.handle_delete_todo:
    call ensure_authenticated
    cmp rax, 0
    jz .auth_required 
    call parse_todo_id_from_path
    mov r8, rax      ; store todo id
    call delete_single_todo
    cmp rax, 0
    jz .todo_not_found
    ; On success for delete, return 204 No Content
    mov rsi, http_204
    mov rdx, 0        ; no body for no content
    mov rax, 204
    call send_http_response
    jmp .done_routing

.auth_required:
    mov rsi, http_401
    mov rdx, http_auth_req_resp
    mov rax, 401
    call send_http_response
    jmp .done_routing

.todo_not_found:
    mov rsi, http_404
    mov rdx, http_todo_not_found_resp
    mov rax, 404
    call send_http_response
    jmp .done_routing

.todo_error:
    cmp rax, -400    ; Title required
    jz .title_required_error
    
    mov rsi, http_400
    mov rdx, http_bad_req_resp
    mov rax, 400
    call send_http_response
    jmp .done_routing

.bad_request_error:
    mov rsi, http_400
    mov rdx, http_bad_req_resp
    mov rax, 400
    call send_http_response
    jmp .done_routing

.title_required_error:
    mov rsi, http_400
    mov rdx, http_title_req_resp
    mov rax, 400
    call send_http_response
    jmp .done_routing

.finalize_success_resp:
    ; This just passes through the response to the caller
    ; In a real implementation might do additional logging,etc
    ret

.done_routing:
    pop rbp
    ret

; Helper to compare if one string starts with another
string_compare_prefix:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx

    mov rbx, 0            ; Character index

.scp_loop:
    mov cl, [rsi + rbx]   ; Character from prefix string  
    cmp cl, 0             ; End of prefix? If so we found it
    jz .scp_match
    
    mov dl, [rdi + rbx]   ; Character from other string
    cmp dl, cl            ; Characters match?
    jnz .scp_nomatch
    
    inc rbx
    jmp .scp_loop

.scp_match:
    mov rax, 1  ; Return true
    jmp .scp_done
.scp_nomatch:
    mov rax, 0  ; Return false

.scp_done:
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

; Extract method, path and headers from HTTP request buffer
extract_http_parts:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx

    mov rbx, rdi          ; source buffer
    mov rcx, rsi          ; output for method
    mov rdx, rdx          ; output for path (rdx is already path_out address)

    ; Find first space (end of method)
    xor r8, r8            ; character index
.em_find_method_end:
    mov al, [rbx + r8]
    cmp al, ' '
    jz .em_copy_method
    cmp al, 0
    jz .em_failed
    inc r8
    jmp .em_find_method_end

.em_copy_method:
    mov r9, 0             ; copy index
.em_copy_method_loop:
    cmp r9, r8
    jge .em_advance_past_method
    mov al, [rbx + r9]
    mov [rcx + r9], al
    inc r9
    jmp .em_copy_method_loop

.em_advance_past_method:
    inc r8                ; Skip the space

    ; Find second space (end of path)
    mov r9, r8            ; New starting point after method and space
    mov r10, 0            ; Counter for path
.em_find_path_end:
    mov al, [rbx + r9 + r10]
    cmp al, ' '
    jz .em_copy_path
    cmp al, 0
    jz .em_path_failed
    inc r10
    jmp .em_find_path_end

.em_copy_path:
    mov r11, 0            ; copy path index
.em_copy_path_loop:
    cmp r11, r10
    jge .em_done
    mov al, [rbx + r9 + r11]
    mov [rdx + r11], al
    inc r11
    jmp .em_copy_path_loop
    
.em_done:
    mov byte [rcx + r8], 0   ; Null terminate method
    mov byte [rdx + r10], 0  ; Null terminate path

.em_done_clean:
    pop rdx
    pop rcx 
    pop rbx
    pop rbp
    ret

.em_failed:
.em_path_failed:
    mov byte [rcx], 0        ; Empty method
    mov byte [rdx], 0        ; Empty path
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

; Send HTTP response (status line + headers + body)
send_http_response:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    ; rsi = status line, rdx = body, rax = status code
    mov rbx, rsi          ; save status line
    mov rcx, rdx          ; save response body
    mov r8, rax           ; save status code

    ; Build response in response_buffer
    lea rdi, [response_buffer]
    
    ; Copy status line
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

    ; Add Content-Type header  
    lea rsi, [json_header]
    call copy_str
    lea rdi, [response_buffer]
    call str_len  
    lea rdi, [response_buffer + rax]

    ; Add Content-Length if body exists
    cmp rcx, 0
    jz .no_body_skip_cl

    ; Calculate content length
    mov rsi, rcx
    call str_len
    mov r9, rax           ; length

    ; Create Content-Length header
    lea rsi, [content_len_header] 
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]
    
    ; Convert length to string and add to response
    mov rdi, num_str_buffer
    mov rsi, r9           ; content length
    call int_to_str
    
    lea rsi, [num_str_buffer]
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

.no_body_skip_cl:
    ; Add end-of-headers marker
    lea rsi, [header_end]
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

    ; Add the actual body if it exists
    cmp rcx, 0
    jz .finish_response_build

    mov rsi, rcx
    call copy_str

.finish_response_build:
    ; Calculate total response length
    lea rdi, [response_buffer]
    call str_len
    mov r9, rax           ; total length
    
    ; Send response to client
    mov rax, SYS_SEND
    mov rdi, rbx          ; client fd in rbx (as preserved)
    lea rsi, [response_buffer]
    mov rdx, r9           ; length
    mov r10, 0            ; flags
    syscall

    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

; Send HTTP response with "Set-Cookie" header
send_http_response_with_cookie:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    
    mov rbx, rsi          ; save status line
    mov rcx, rdx          ; save response body  
    mov r8, rax           ; save status code
    mov r9, rdi           ; save cookie token

    ; Build response in response_buffer
    lea rdi, [response_buffer]
    mov rsi, rbx          ; status line
    call copy_str

    ; Add status line length to get next position
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

    ; Add Content-Type header
    lea rsi, [json_header]
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

    ; Add Set-Cookie header
    lea rsi, [set_cookie_header]
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

    ; Add the cookie token
    mov rsi, r9
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

    ; Add cookie attributes
    lea rsi, [cookie_attrs]
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

    ; Add Content-Length
    lea rsi, [content_len_header] 
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

    ; Calculate and add content length if body exists
    cmp rcx, 0
    jz .cookie_no_body

    mov rsi, rcx
    call str_len
    mov r10, rax
    
    ; Convert and add length
    mov rdi, num_str_buffer
    mov rsi, r10
    call int_to_str
    
    lea rsi, [num_str_buffer]
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

.cookie_no_body:
    ; Add end-of-headers
    lea rsi, [header_end]
    call copy_str
    lea rdi, [response_buffer]
    call str_len
    lea rdi, [response_buffer + rax]

    ; Add body if exists
    cmp rcx, 0
    jz .finish_cookie_response

    mov rsi, rcx
    call copy_str
    
.finish_cookie_response:
    ; Calculate length and send
    lea rdi, [response_buffer]
    call str_len
    mov r10, rax

    mov rax, SYS_SEND
    mov rdi, rbx
    lea rsi, [response_buffer]
    mov rdx, r10
    mov r10, 0
    syscall

    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

; === Data Manipulation Routines ===
; These will be implemented as stubs for core functionality

process_registration:
    ; Parse request body from 'buffer' for JSON
    ; Expected: {"username": "...", "password": "..."}
    ; Return: 0 for success, negative error code
    push rbp
    mov rbp, rsp
    mov rax, 0    ; Success
    pop rbp
    ret

process_login:
    ; Parse request body from 'buffer' for JSON
    ; Expected: {"username": "...", "password": "..."}
    ; Return: 0 for success + session token in temp var, negative error code
    push rbp
    mov rbp, rsp
    mov rax, 0    ; Success  
    pop rbp
    ret

ensure_authenticated:
    ; Check Cookie header for valid session_id
    ; Return: user ID or 0 if not authorized
    push rbp
    mov rbp, rsp
    mov rax, 1    ; Assume authenticated user ID = 1 for now
    pop rbp
    ret

build_user_details_response:
    ; Build a JSON response string from authenticated user details
    ; Return: pointer to response string
    push rbp
    mov rbp, rsp
    
    ; For now return a hardcoded JSON
    lea rax, [user_details_example_json]
    pop rbp
    ret

user_details_example_json db '{"id": 1, "username": "testuser"}', 0

process_create_todo:
    ; Parse request body from 'buffer' for JSON
    ; Expected: {"title": "...", "description": "..."}
    ; Return: 0 for success, negative error code for title validation etc.
    push rbp
    mov rbp, rsp
    mov rax, 0    ; Success
    pop rbp
    ret

retrieve_user_todos:
    ; Get all todos for authenticated user ID
    ; Return: JSON array string
    push rbp  
    mov rbp, rsp
    
    ; For now return empty array
    lea rax, [empty_todos_array]  
    pop rbp
    ret

empty_todos_array db '[]', 0

parse_todo_id_from_path:
    ; Extract the ID from a path like /todos/123
    ; Return: parsed integer ID or 0
    push rbp
    mov rbp, rsp
    mov rax, 1    ; Return dummy ID of 1
    pop rbp
    ret

retrieve_single_todo:
    ; Retrieve specific todo for authenticated user
    ; Return: JSON string of todo or NULL if not found
    push rbp
    mov rbp, rsp
    
    ; Return dummy example todo JSON  
    lea rax, [single_todo_example]
    pop rbp
    ret

single_todo_example db '{"id": 1, "title": "Test todo", "description": "A test task", "completed": false, "created_at": "2023-01-01T00:00:00Z", "updated_at": "2023-01-01T00:00:00Z"}', 0

update_single_todo:
    ; Update specific todo for authenticated user
    ; Return: updated JSON string of todo or NULL if not found
    push rbp
    mov rbp, rsp
    
    ; Return dummy example updated todo
    lea rax, [updated_todo_example]  
    pop rbp
    ret

updated_todo_example db '{"id": 1, "title": "Test todo", "description": "Updated task", "completed": true, "created_at": "2023-01-01T00:00:00Z", "updated_at": "2023-02-01T00:00:00Z"}', 0

delete_single_todo:
    ; Remove specific todo for authenticated user
    ; Return: 1 for removed successfully, 0 if not found
    push rbp
    mov rbp, rsp
    mov rax, 1    ; Successful deletion
    pop rbp
    ret

; === Utility Functions ===

fill_mem_with:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx

    mov rbx, rdi          ; buffer
    mov rcx, rdx          ; size  
    mov rdx, rsi          ; fill byte
    
    xor rsi, rsi          ; counter

.fm_loop:
    cmp rsi, rcx
    jge .fm_done
    mov [rbx + rsi], dl
    inc rsi
    jmp .fm_loop

.fm_done:
    pop rcx
    pop rbx
    pop rbp
    ret

str_len:
    push rbp
    mov rbp, rsp
    push rbx

    mov rbx, 0            ; counter

.sl_loop:
    cmp byte [rdi + rbx], 0
    jz .sl_done
    inc rbx
    jmp .sl_loop

.sl_done:
    mov rax, rbx
    pop rbx
    pop rbp
    ret

copy_str:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx

    mov rbx, 0            ; index

.cs_loop:
    mov cl, [rsi + rbx]
    mov [rdi + rbx], cl
    cmp cl, 0
    jz .cs_done
    inc rbx
    jmp .cs_loop

.cs_done:
    pop rcx
    pop rbx
    pop rbp
    ret

print_str:
    push rbp
    mov rbp, rsp
    
    call str_len
    mov rdx, rax          ; length
    
    mov rax, SYS_WRITE
    mov rdi, 1            ; stdout 
    syscall
    
    pop rbp
    ret
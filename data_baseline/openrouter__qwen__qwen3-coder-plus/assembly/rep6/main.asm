; Main entry point for the Todo API server

%include "macros.inc"

EXTERN http_server_bind_and_listen
EXTERN http_server_accept_conn
EXTERN http_server_parse_request
EXTERN http_response_send
EXTERN parse_headers
EXTERN init_datastore
EXTERN datastore_add_user
EXTERN datastore_find_user_by_username
EXTERN datastore_add_todo
EXTERN datastore_find_todo_by_id
EXTERN datastore_remove_todo
EXTERN strcmp
EXTERN strlen
EXTERN strcpyn
EXTERN atoi
EXTERN init_auth_system
EXTERN create_session_for_user
EXTERN validate_session_token
EXTERN revoke_session
EXTERN parse_auth_from_request
EXTERN build_json_response
EXTERN build_set_cookie_header
EXTERN generate_timestamp
EXTERN parse_simple_json
EXTERN extract_json_value

section .bss
    request_buffer resb 8192
    response_buffer resb 16384
    client_sock_addr resb 64

section .text
global _start

_start:
    ; Parse command line arguments
    mov rbp, [rsp + 16]   ; argc is at stack position
    mov rsi, [rsp + 24]   ; argv at position after argc

    cmp rbp, 3            ; need at least 3 args: programname --port portnum  
    jl print_usage

    ; Extract arg values  
    mov rax, [rsi + 8]    ; first arg
    mov rbx, port_param
    call strcmp
    test rax, rax
    jnz print_usage

    ; Convert second arg (port number) to integer
    mov rdi, [rsi + 16]   ; second arg
    call atoi
    mov [current_port], eax

    ; Initialize the application
    call init_datastore
    call init_auth_system 

    ; Start the server
    mov rdi, [current_port]
    call http_server_bind_and_listen
    cmp rax, 0
    jl server_start_error

    mov r13, rax          ; r13 = server socket fd

main_loop:
    mov rdi, r13          ; pass server socket
    call http_server_accept_conn
    cmp rax, 0
    jl accept_error

    mov r14, rax          ; r14 = client socket fd

    ; Receive incoming request
    xor rax, rax
    mov rdi, r14          ; client socket
    mov rsi, request_buffer
    mov rdx, 8191         ; 1 byte less than buffer size for null termination
    mov r10, 0            ; flags
    mov rax, 10           ; recv syscall for socket
    syscall

    cmp rax, 0
    jle .done_with_connection

    ; Parse the HTTP request  
    mov rdi, request_buffer
    call http_server_parse_request
    test rax, rax
    jz .done_with_connection

    ; Process the request and send response
    call process_request

.done_with_connection:
    mov rdi, r14          ; close client fd
    mov rax, 3            ; close syscall
    syscall

    jmp main_loop

server_start_error:
    mov rdi, stderr_str
    mov rsi, stderr_len
    call write_error
    mov rdi, 1
    mov rax, 60           ; exit syscall
    syscall

print_usage:
    mov rdi, usage_msg
    mov rsi, usage_msg_len
    call write_output
    mov rdi, 1
    mov rax, 60
    syscall

accept_error:
    mov rdi, accept_err_str
    mov rsi, accept_err_len
    call write_error
    ; Continue accepting other connections
    jmp main_loop

; Process and dispatch the request to correct handler  
process_request:
    push rbp
    mov rbp, rsp

    ; Extract URI from parsed request (in global r14 register during parsing) 
    ; Since we're simplifying without maintaining the globals here:
    mov rdi, request_buffer
    call detect_request_method_and_uri
    jc .invalid_request

    ; Route based on URI and method
    cmp dword [request_method], 'POST'  
    je .route_post
    cmp dword [request_method], 'GET'
    je .route_get
    cmp dword [request_method], 'PUT'
    je .route_put  
    cmp dword [request_method], 'DELE'  ; First 4 chars of 'DELETE'
    je .route_delete

    ; Unsupported method
    mov rax, 405
    call send_status_code_response
    
.do_return:
    pop rbp
    ret

.route_post:
    mov rdi, request_uri
    call handle_post_request
    jmp .do_return
    
.route_get:
    mov rdi, request_uri  
    call handle_get_request
    jmp .do_return
    
.route_put:
    mov rdi, request_uri
    call handle_put_request
    jmp .do_return
    
.route_delete:
    mov rdi, request_uri
    call handle_delete_request
    jmp .do_return

.invalid_request:
    mov rax, 400          ; bad request
    call send_status_code_response
    jmp .do_return

; Send standard response based on HTTP status code
send_status_code_response:
    push rbp
    mov rbp, rsp
    mov r8, rax           ; save status code
    
    ; Lookup response template
    cmp r8, 400
    je .send_bad_req_res
    cmp r8, 401
    je .send_unauth_res
    cmp r8, 404
    je .send_not_found_res
    cmp r8, 405
    je .send_method_na_res
    cmp r8, 409
    je .send_conflict_res
    
    ; Default to internal server error for unexpected codes
    mov rsi, internal_serv_err
    mov rdx, internal_serv_err_len  
    jmp .send_formatted_response

.send_bad_req_res:
    mov rsi, bad_request_response
    mov rdx, bad_request_response_len
    jmp .send_formatted_response
    
.send_unauth_res:
    mov rsi, unauthorized_response
    mov rdx, unauthorized_response_len
    jmp .send_formatted_response
    
.send_not_found_res:
    mov rsi, not_found_response
    mov rdx, not_found_response_len
    jmp .send_formatted_response
    
.send_method_na_res:
    mov rsi, method_na_response
    mov rdx, method_na_response_len
    jmp .send_formatted_response
    
.send_conflict_res:
    mov rsi, conflict_response
    mov rdx, conflict_response_len
    
.send_formatted_response:
    ; Send complete HTTP response
    mov rdi, rsi   ; data to send
    mov rax, rdx   ; length of data
    ; Call send function
    mov rdx, rax   ; length in rdx
    mov rax, 84    ; for sendto (socket call)
    mov rdi, r14   ; client socket fd
    mov rsi, rdi   ; response data
    mov r10, 0     ; flags
    syscall
    jmp .status_sent
    
.status_sent:
    pop rbp
    ret

write_output:
    push rbp
    mov rbp, rsp
    mov rax, 1               ; sys_write
    mov rdi, 1               ; stdout
    syscall
    pop rbp
    ret

write_error:  
    push rbp
    mov rbp, rsp
    mov rax, 1               ; sys_write
    mov rdi, 2               ; stderr
    syscall
    pop rbp
    ret

detect_request_method_and_uri:
    push rbp
    mov rbp, rsp
    push rsi
    push rbx
    
    mov rsi, rdi             ; rdi is request start
    mov rbx, 0               ; counter for char reads

.read_method:
    ; Read first token (METHOD) - assume no more than 10 chars
    cmp byte [rsi + rbx], ' '
    je .method_found
    cmp rbx, 10
    jae .malformed_request
    mov [request_method + rbx], byte [rsi + rbx]
    inc rbx
    jmp .read_method

.method_found:
    mov [request_method + rbx], byte 0   ; null terminate
    inc rbx                  ; skip space

    ; Now read URI
    xor rax, rax
.store_uri_loop:  
    cmp byte [rsi + rbx + rax], ' '
    je .uri_found
    cmp rax, 200              ; max URI length for safety
    jae .malformed_request
    mov [request_uri + rax], byte [rsi + rbx + rax]
    inc rax
    jmp .store_uri_loop

.uri_found: 
    mov [request_uri + rax], byte 0  ; null terminate
    clc                        ; clear carry flag (success) 
    jmp .detect_done

.malformed_request:
    stc                        ; set carry flag (error)
    
.detect_done:
    pop rbx
    pop rsi
    pop rbp
    ret

; Handler functions for different request types
handle_post_request:
    push rbp
    mov rbp, rsp
    
    ; Check specific URIs for POST
    mov rax, [rdi] ; read first few bytes of URI 
    cmp dword [rdi], '/reg'  ; starts with /register?
    je handle_register
    cmp dword [rdi], '/log'  ; /login?
    je handle_login
    cmp dword [rdi], '/out'  ; /logout?
    je handle_logout
    cmp rdi, todos_full_path  ; /todos completely?
    je handle_create_todo
    ; Check for /password endpoint
    cmp qword [rdi], '/passwo' 
    cmp dword [rdi+6], 'rd'
    je handle_change_password
    
    ; Special case: check if starts with /todos/ and followed by digits
    cmp qword [rdi], '/todos/'  ; "/todos/"
    je check_specific_todo_post
    
    ; Not handled - 404 Not Found
    mov rax, 404
    call send_status_code_response
    jmp .post_complete

check_specific_todo_post:
    ; This should not have POST methods (should probably return 405)
    mov rax, 405
    call send_status_code_response
    jmp .post_complete

.post_complete:
    pop rbp
    ret

; Actual endpoint handlers that follow the specification
handle_register:
    push rbp
    mov rbp, rsp
    
    ; Parse JSON body to get username and password
    lea rdi, request_buffer
    call locate_request_body_start
    test rdi, rdi            ; Ensure body exists
    jz .bad_request_reg
    
    ; Extract username and password from JSON
    mov rsi, username_field
    call extract_json_value
    test rax, rax
    jz .invalid_request_reg
    
    mov r15, rax             ; store username pointer
    
    mov rsi, password_field
    call extract_json_value
    test rax, rax
    jz .invalid_request_reg
    
    mov r14, rax             ; store password pointer
    
    ; Validate inputs
    call validate_username_password_inputs
    test rax, rax            ; If 0, inputs were invalid  
    jz .bad_request_reg
    
    ; Check if user already exists
    mov rdi, r15             ; username
    call datastore_find_user_by_username
    test rax, rax            ; If not 0, user exists
    jnz .conflict_user_reg   ; Return 409
    
    ; Create the new user 
    mov rdi, r15             ; username
    mov rsi, r14             ; password
    call datastore_add_user
    test rax, rax            ; If 0, add failed
    jz .internal_error_reg
    
    ; Build success response
    mov rdi, response_buffer
    mov rsi, 2              ; Format with id and username
    mov rdx, rax            ; user id from add_user
    mov r10, r15            ; username string
    call build_json_response
    
    ; Format full HTTP response
    call prepare_success_json_response
    jmp .reg_complete

.conflict_user_reg :
    mov rax, 409            ; Conflict - username taken
    call send_status_code_response
    jmp .reg_complete

.invalid_request_reg:
.bad_request_reg:
    mov rax, 400
    call send_status_code_response
    jmp .reg_complete

.internal_error_reg:
    mov rax, 500
    call send_status_code_response
    
.reg_complete:
    pop rbp
    ret

validate_username_password_inputs:
    push rbp
    mov rbp, rsp
    push rbx
    
    mov rbx, r15             ; username
    call validate_username  
    test rax, rax
    jz .validation_failed
    
    mov rbx, r14             ; password
    call validate_password
    test rax, rax
    jz .validation_failed
    
    mov rax, 1               ; success
    jmp .validation_done
    
.validation_failed:
    xor rax, rax             ; 0 for failure
        
.validation_done:
    pop rbx
    pop rbp
    ret

validate_username:
    ; Validate username length (3-50 chars) and characters (alnum + underscore)
    ; rbx = username string pointer
    push rbp
    mov rbp, rsp
    push rcx
    push rdx
    
    xor rcx, rcx
    
.username_len_loop:
    cmp byte [rbx + rcx], 0
    je .username_length_check
    inc rcx
    cmp rcx, 51             ; exceed max?
    jae .username_invalid
    jmp .username_len_loop

.username_length_check:  
    ; Min check (>= 3)
    cmp rcx, 3
    jb .username_invalid
    
    ; Max check (<= 50)  
    cmp rcx, 50
    ja .username_invalid

    ; Character validation loop
    xor rcx, rcx
.char_validate_loop:
    cmp byte [rbx + rcx], 0
    je .username_valid
    
    mov dl, [rbx + rcx]
    cmp dl, 'a'
    jb .char_upper_check
    cmp dl, 'z' 
    jbe .char_validated
    
.char_upper_check:
    cmp dl, 'A'
    jb .char_digit_check
    cmp dl, 'Z' 
    jbe .char_validated
    
.char_digit_check:
    cmp dl, '0'
    jb .char_under_check
    cmp dl, '9'
    jbe .char_validated
    
.char_under_check:
    cmp dl, '_'
    jne .username_invalid
    
.char_validated:
    inc rcx
    jmp .char_validate_loop
    
.username_valid:
    mov rax, 1              ; valid
    jmp .username_done

.username_invalid:  
    xor rax, rax            ; invalid

.username_done:
    pop rdx
    pop rcx
    pop rbp
    ret

validate_password:
    ; Validate password minimum length 8 chars
    ; rbx = password string pointer
    push rbp
    mov rbp, rsp
    push rcx
    
    xor rcx, rcx
.password_len_loop:
    cmp byte [rbx + rcx], 0
    je .password_length_check
    inc rcx
    jmp .password_len_loop

.password_length_check:
    cmp rcx, 8
    jb .password_too_short
    
    mov rax, 1              ; valid
    jmp .password_done
    
.password_too_short:
    xor rax, rax            ; invalid

.password_done:
    pop rcx
    pop rbp
    ret

locate_request_body_start:
    ; Find where request body begins after headers
    ; (request_buffer) contains the entire HTTP request
    push rbp
    mov rbp, rsp
    
    lea rax, request_buffer
    mov rbx, rax
    
.headers_scan_loop:
    cmp dword [rbx], 1718178564  ; \r\n\r\n as 4-byte integer
    je .headers_terminator_found 
    ; Ensure we don't scan too far
    sub rbx, request_buffer
    cmp rbx, 7000           ; don't scan beyond reasonable header portion
    ja .body_start_early
    add rbx, request_buffer
    inc rbx
    jmp .headers_scan_loop
    
.headers_terminator_found:
    add rbx, 4              ; skip past \r\n\r\n
    mov rax, rbx
    jmp .locate_done
    
.body_start_early:
    lea rax, request_buffer
    add rax, 500              ; skip a fixed amount as fallback

.locate_done:
    pop rbp
    ret

prepare_success_json_response:
    ; Build complete HTTP/1.1 201 response with JSON
    push rbp
    mov rbp, rsp
    
    mov rdi, response_buffer
    ; Copy status line
    mov rax, 'HTTP/1.1 201 Created\r\n'
    mov [rdi], rax
    mov rax, 'Content-Type: applica'
    mov [rdi+20], rax 
    mov rax, 'tion/json\r'
    mov [rdi+40], rax
    mov word [rdi+50], 0x0A0D ; \r\n
    add rdi, 52
    
    ; Add empty line before body (required by HTTP)
    mov word [rdi], 0x0A0D    ; \r\n
    add rdi, 2
    
    ; Body is already in response_buffer at correct pos
    ; Just need final newline and send
    mov byte [rdi], 0         ; null terminator
    
    ; Calculate length
    lea rax, response_buffer
    mov rdx, rdi
    sub rdx, rax
    
    ; Send response  
    mov rax, sys_send
    mov rdi, r14              ; client socket
    mov rsi, rax              ; original response start
    mov rax, rdx              ; length calculated
    mov r10, 0                ; flags
    syscall
    
    pop rbp
    ret

section .data
    port_param db "--port", 0
    usage_msg db "Usage: ./server --port PORT", 10, 0
    usage_msg_len equ $ - usage_msg
    stderr_str db "Error starting server", 10, 0
    stderr_len equ $ - stderr_str  
    accept_err_str db "Accept error", 10, 0
    accept_err_len equ $ - accept_err_str
    
    bad_request_response db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Bad Request"}', 10, 0
    bad_request_response_len equ $ - bad_request_response
    
    unauthorized_response db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Authentication required"}', 10, 0
    unauthorized_response_len equ $ - unauthorized_response
    
    not_found_response db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Not Found"}', 10, 0
    not_found_response_len equ $ - not_found_response
    
    method_na_response db 'HTTP/1.1 405 Method Not Allowed', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Method not allowed"}', 10, 0
    method_na_response_len equ $ - method_na_response
    
    conflict_response db 'HTTP/1.1 409 Conflict', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Username already exists"}', 10, 0
    conflict_response_len equ $ - conflict_response
    
    internal_serv_err db 'HTTP/1.1 500 Internal Server Error', 13, 10, 0
    internal_serv_err_len equ $ - internal_serv_err
    
    username_field db "username", 0
    password_field db "password", 0
    todos_full_path db "/todos", 0
    
    current_port dd 8080
    request_method resb 16  ; Store method string temporarily
    request_uri resb 128    ; Store URI string temporarily

; Additional syscall numbers that aren't defined in macros.inc
%ifndef sys_send
%define sys_send 44
%endif

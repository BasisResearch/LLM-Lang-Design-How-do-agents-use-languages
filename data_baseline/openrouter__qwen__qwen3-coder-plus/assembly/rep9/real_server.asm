; Complete Todo API server in x86-64 NASM Assembly
; Uses direct Linux syscalls with proper implementation

bits 64
default rel

section .text
global _start

; Syscall definitions
%define SYS_READ     0
%define SYS_WRITE    1
%define SYS_OPEN     2
%define SYS_CLOSE    3
%define SYS_SOCKET   41
%define SYS_BIND     49
%define SYS_LISTEN   50
%define SYS_ACCEPT   43
%define SYS_RECV     45
%define SYS_SEND     44
%define SYS_SETSOCKOPT 54
%define SYS_EXIT     60

; Network constants
%define AF_INET      2
%define SOCK_STREAM  1
%define SOL_SOCKET   1
%define SO_REUSEADDR 2
%define INADDR_ANY   0x00000000
%define BACKLOG      10

_start:
    ; Parse command-line arguments - expecting --port port_number
    mov rbp, rsp
    and rbp, -16               ; Align stack to 16-byte boundary
    mov rax, [rsp]             ; argc
    cmp rax, 3                 ; We expect 3 args: program, --port, port_num
    jne print_usage

    ; Get port argument
    mov rdi, [rsp+16]          ; argv[1] should be --port
    mov rsi, cmdline_port_flag
    call str_cmp               ; Compare with --port
    test rax, rax
    jnz print_usage

    mov rdi, [rsp+24]          ; argv[2] - port number string
    call parse_uint            ; Parse port number
    movzx r15, ax              ; Store port in r15 (to preserve across syscalls)
    rol r15, 8                 ; Swap byte order for network compatibility
    rol r15, 8

    ; Initialize global counters
    mov dword [next_user_id], 1
    mov dword [next_todo_id], 1
    mov dword [next_session_idx], 0

    call create_server_socket
    mov r12, rax               ; Server socket fd

    call configure_socket
    call bind_to_address
    call start_listening

    ; Enter server loop
server_loop:
    call accept_client
    mov r13, rax               ; Client socket fd

    ; Receive HTTP request
    mov rdi, r13               ; client fd
    mov rsi, req_buffer        ; buffer
    mov rdx, REQ_BUFFER_SIZE   ; size
    call recv_data
    mov r14, rax               ; Number of bytes received

    ; Skip request to check if successful
    test rax, rax
    jle skip_process           ; Skip if recv returned error or 0

    ; Process request
    call reset_current_user
    call parse_request
    call route_request

    ; Send response
    mov rdi, r13               ; client fd
    mov rsi, res_buffer        ; response buffer
    mov rdx, [res_buffer_pos]  ; response length
    call send_all

skip_process:
    ; Close client connection
    mov rdi, r13
    call close_fd

    jmp server_loop

print_usage:
    mov rdi, 2
    mov rsi, usage_text
    mov rdx, usage_len
    call write_exact
    mov rdi, 1
    call exit

; Socket functions
create_server_socket:
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    ret

configure_socket:
    ; Set SO_REUSEADDR
    mov rdi, r12               ; fd
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    push 1
    mov r10, rsp
    mov r8, 4
    mov rax, SYS_SETSOCKOPT
    syscall
    add rsp, 8
    ret

bind_to_address:
    ; Create sockaddr_in structure: {family, port, address}
    push 0                     ; Pad to align properly
    push DWORD INADDR_ANY      ; IP address
    push WORD [r15-2]          ; Port number (network byte order)
    push WORD AF_INET          ; Address family

    mov rdi, r12               ; fd
    mov rsi, rsp               ; pointer to address
    mov rdx, 16                ; Size of sockaddr_in
    mov rax, SYS_BIND
    syscall

    add rsp, 16                ; Clean up stack (remove sockaddr_in)
    ret

start_listening:
    mov rax, SYS_LISTEN
    mov rdi, r12               ; fd
    mov rsi, BACKLOG
    syscall
    ret

accept_client:
    mov rax, SYS_ACCEPT
    mov rdi, r12               ; server fd
    mov rsi, 0                 ; addr (NULL)
    mov rdx, 0                 ; addrlen (NULL)
    syscall
    ret

recv_data:
    ; rdi = client socket fd, rsi = buffer, rdx = size
    mov rax, SYS_RECV
    push rdi                   ; Store fd to return later
    mov r10, 0                 ; flags
    syscall
    pop rax                    ; Restore fd to return
    cmp rax, 0
    jl .error
    ret

.error:
    mov rax, -1
    ret

send_all:
    ; rdi = fd, rsi = buffer, rdx = size
    push rsi
    push rdx

.send_loop:
    test rdx, rdx
    jz .send_complete

    mov rax, SYS_SEND
    push rdx
    push rsi
    push rdi
    mov r10, 0                 ; flags
    syscall
    pop rdi
    pop rsi
    pop rdx

    cmp rax, 0
    jle .error

    ; Update buffer and size
    add rsi, rax
    sub rdx, rax
    jmp .send_loop

.send_complete:
    pop rdx
    pop rsi
    mov rax, 1
    ret

.error:
    pop rdx
    pop rsi
    mov rax, -1
    ret

; Parsing functions
parse_request:
    ; Reset parsing position
    xor r10, r10
    mov [req_parse_pos], r10

    ; Parse HTTP method
    mov eax, [req_parse_pos]
    mov edi, req_buffer
    add rdi, rax
    mov rsi, req_method
    call read_until_space
    add dword [req_parse_pos], eax   ; Update parse position
    inc dword [req_parse_pos]        ; Skip space

    ; Parse path
    mov eax, [req_parse_pos]
    mov edi, req_buffer
    add rdi, rax
    mov rsi, req_path
    call read_until_next_space
    add dword [req_parse_pos], eax
    inc dword [req_parse_pos]

    ; Extract path parameters if relevant (/todos/:id)
    mov rdi, req_path
    mov rsi, path_todos_slash
    call str_starts_with
    test rax, rax
    jz .try_cookies

    ; Extract ID after "/todos/"
    mov rdi, req_path
    add rdi, path_todos_slash_len
    call parse_uint
    mov [req_param_id], eax

.try_cookies:
    ; Look for Cookie header in request
    call find_cookie_in_headers

    ; Look for body after headers
    call find_body_in_request
    ret

find_cookie_in_headers:
    mov rax, [req_parse_pos]    ; After method and path
    mov rbx, 0                  ; Local pos counter

.scan_headers:
    ; Look for cookie header pattern
    mov rdi, req_buffer
    add rdi, rax
    add rdi, rbx
    mov rsi, cookie_hdr_start
    call str_includes_at_offset
    test rax, rax
    jnz .cookie_found

    ; Move to next header (end line)
.find_line_end:
    mov cl, [rdi]
    cmp cl, 10                  ; \n
    je .line_ends
    cmp cl, 0
    je .header_scan_done
    inc rbx
    jmp .find_line_end

.line_ends:
    inc rbx                     ; Move past \n
    cmp DWORD [rdi+rbx-2], 0x0A0D    ; Check for \r\n
    je .double_line_end
    cmp BYTE [rdi+rbx-1], 10    ; Another \n?
    jne .scan_headers
    jmp .header_scan_done        ; Two \n indicates end of headers

.double_line_end:
    jmp .scan_headers

.cookie_found:
    ; Extract token starting after 'session_id='
    mov rsi, rdi
    add rsi, cookie_hdr_start_len    ; Skip past "Cookie: session_id="
    call read_cookie_value
    ret

.header_scan_done:
    mov [session_cookie_id], byte 0    ; No cookie found
    ret

read_cookie_value:
    ; rsi points to token value
    mov rdi, session_cookie_id
    xor rax, rax              ; Character counter
    
.copy_cookie:
    cmp al, 63                 ; Max length
    jae .cookie_copied
    mov bl, [rsi + rax]
    cmp bl, ';'                ; End of session token?
    je .cookie_copied
    cmp bl, ' '                ; Space?
    je .cookie_copied
    cmp bl, 13                 ; CR?
    je .cookie_copied
    cmp bl, 10                 ; LF?
    je .cookie_copied
    test bl, bl                ; Null?
    jz .cookie_copied
    
    mov [rdi + rax], bl
    inc rax
    jmp .copy_cookie

.cookie_copied:
    mov byte [rdi + rax], 0    ; Null terminate
    ret

find_body_in_request:
    ; Look for double CRLF
    mov rsi, req_buffer
    mov rax, 0

.find_body_separator:
    cmp dword [rsi + rax], 0x0A0D0A0D    ; \r\n\r\n
    je .separator_found
    cmp byte [rsi + rax], 0    ; End of request?
    je .no_body_present
    inc rax
    cmp rax, 4000              ; Reasonable limit
    jb .find_body_separator
    
.no_body_present:
    mov rax, req_buffer
    add rax, rax               ; End at itself, meaning no body
    mov [req_body_ptr], rax    ; Mark body as beginning after header end
    ret
    
.separator_found:
    add rax, 4                 ; Skip \r\n\r\n
    mov [req_body_ptr], rax
    ret

; HTTP routing
route_request:
    call process_route_auth
    test rax, rax              ; Is auth required and failed?
    jnz .auth_fail

    ; Route based on method and path
    mov rdi, req_method
    call compare_methods

.auth_fail:
    ret

compare_methods:
    mov rsi, GET_str
    call str_cmp
    test rax, rax
    jz .do_get_method

    mov rsi, POST_str
    call str_cmp
    test rax, rax
    jz .do_post_method

    mov rsi, PUT_str
    call str_cmp
    test rax, rax
    jz .do_put_method

    mov rsi, DELETE_str
    call str_cmp
    test rax, rax
    jz .do_delete_method

    ; Unknown method
    call http_response_405
    ret

.do_get_method:
    mov rdi, req_path
    mov rsi, path_register
    call str_cmp
    test rax, rax
    jz .bad_method

    mov rsi, path_login
    call str_cmp
    test rax, rax
    jz .bad_method

    mov rsi, path_logout
    call str_cmp
    test rax, rax
    jz .bad_method

    mov rsi, path_me
    call str_cmp
    test rax, rax
    jz handle_get_me

    mov rsi, path_password
    call str_cmp
    test rax, rax
    jz .bad_method

    mov rsi, path_todos
    call str_cmp
    test rax, rax
    jz handle_get_todos

    ; Handle /todos/:id
    mov rsi, path_todos_slash
    call str_starts_with
    test rax, rax
    jz handle_get_todo_by_id

.bad_method:
    call http_response_405
    ret

.do_post_method:
    mov rdi, req_path
    mov rsi, path_register
    call str_cmp
    test rax, rax
    jz handle_post_register

    mov rsi, path_login
    call str_cmp
    test rax, rax
    jz handle_post_login

    mov rsi, path_logout
    call str_cmp
    test rax, rax
    jz handle_post_logout

    mov rsi, path_todos
    call str_cmp
    test rax, rax
    jz handle_post_todos

    call http_response_405
    ret

.do_put_method:
    mov rdi, req_path
    mov rsi, path_password
    call str_cmp
    test rax, rax
    jz handle_put_password

    ; Handle /todos/:id
    mov rsi, path_todos_slash
    call str_starts_with
    test rax, rax
    jz handle_put_todo_by_id

    call http_response_405
    ret

.do_delete_method:
    mov rdi, req_path
    mov rsi, path_todos_slash
    call str_starts_with
    test rax, rax
    jz handle_delete_todo_by_id
    
    call http_response_405
    ret

reset_current_user:
    mov dword [current_user_id], 0
    ret

process_route_auth:
    ; Check if requested path requires authentication
    mov rdi, req_path

    ; Check against protected paths
    mov rsi, path_me
    call str_cmp
    test rax, rax
    jz .requires_auth

    mov rsi, path_logout
    call str_cmp
    test rax, rax
    jz .requires_auth

    mov rsi, path_password
    call str_cmp
    test rax, rax
    jz .requires_auth

    mov rsi, path_todos
    call str_cmp
    test rax, rax
    jz .requires_auth

    ; Check for todos with ID path
    mov rsi, path_todos_slash
    call str_starts_with
    test rax, rax
    jnz .does_not_require_auth     ; This is an exception

.requires_auth:
    ; Check for session cookie
    cmp byte [session_cookie_id], 0
    je .auth_failed

    ; Validate session
    mov rdi, session_cookie_id
    call validate_session_token
    test rax, rax
    jz .auth_failed

    ; Store authenticated user ID
    mov [current_user_id], eax
    xor rax, rax
    ret

.auth_failed:
    call http_response_401
    mov rax, 1                   ; Non-zero means auth failed
    ret

.does_not_require_auth:
    xor rax, rax                 ; Auth not required
    ret

; Response generators
http_response_200:
    mov rdi, res_buffer
    mov rsi, http_header_200
    mov rdx, http_header_200_size
    call write_exact
    ret

http_response_201:
    mov rdi, res_buffer
    mov rsi, http_header_201
    mov rdx, http_header_201_size
    call write_exact  
    ret
    
http_response_204:  
    mov rdi, res_buffer
    mov rsi, http_header_204
    mov rdx, http_header_204_size
    call write_exact
    mov qword [res_buffer_pos], http_header_204_size
    ret

http_response_400:
    mov rdi, res_buffer
    mov rsi, http_header_400
    mov rdx, http_header_400_size
    call write_exact
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_error_prefix  
    call str_copy_with_length
    add [res_buffer_pos], rax
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]  
    mov rsi, error_bad_request_str
    call str_copy_with_length
    add [res_buffer_pos], rax
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_error_suffix
    call str_copy_with_length
    add [res_buffer_pos], rax
    mov rax, 1
    ret

http_response_401:
    mov rdi, res_buffer
    mov rsi, http_header_401
    mov rdx, http_header_401_size
    call write_exact
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_error_prefix
    call str_copy_with_length
    add [res_buffer_pos], rax
    mov rdi, res_buffer 
    add rdi, [res_buffer_pos]
    mov rsi, error_auth_required_str
    call str_copy_with_length
    add [res_buffer_pos], rax
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_error_suffix
    call str_copy_with_length
    add [res_buffer_pos], rax
    mov rax, 1
    ret

http_response_404:
    mov rdi, res_buffer
    mov rsi, http_header_404
    mov rdx, http_header_404_size
    call write_exact
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_error_prefix
    call str_copy_with_length
    add [res_buffer_pos], rax
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, error_not_found_str
    call str_copy_with_length
    add [res_buffer_pos], rax
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_error_suffix
    call str_copy_with_length
    add [res_buffer_pos], rax
    mov rax, 1
    ret

http_response_405:
    mov rdi, res_buffer
    mov rsi, http_header_405
    mov rdx, http_header_405_size
    call write_exact
    ret

; Main handlers
handle_get_me:
    call require_auth
    test rax, rax
    .je .authorized
    
    call http_response_401
    ret

.authorized:
    ; Build response with current user information
    call http_response_200
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov al, '{'
    mov [rdi], al
    inc rdi
    mov [res_buffer_pos], rdi
    sub rdi, res_buffer
    
    ; Add ID field
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_key_id
    call str_copy_with_length
    add [res_buffer_pos], rax
    
    ; Add user id
    mov eax, [current_user_id]
    call int_to_str
    add [res_buffer_pos], rax

    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov al, ','
    mov [rdi], al
    inc rdi
    mov [res_buffer_pos], rdi
    sub rdi, res_buffer
    
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_key_username_q
    call str_copy_with_length
    add [res_buffer_pos], rax
    
    ; Add username
    mov eax, [current_user_id]
    dec eax
    mov ebx, USER_STRUCT_SIZE
    mul ebx
    lea rbx, [users_memory]
    add rbx, rax
    
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, rbx
    add rsi, USER_FIELD_USERNAME
    call str_copy_with_length
    add [res_buffer_pos], rax
    
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov al, '"'
    mov [rdi], al
    inc rdi
    mov al, '}'
    mov [rdi], al
    inc rdi
    mov al, 10  ; \n
    mov [rdi], al
    inc rdi
    mov [res_buffer_pos], rdi
    sub rdi, res_buffer
    ret

handle_post_register:
    ; Extract username and password from request body
    call extract_username_password
    mov r8, rax    ; Save extracted user
    mov r9, rdx    ; Save extracted password

    ; Validate username
    cmp r8, 0
    je .invalid_input
    call validate_username
    test rax, rax
    jz .invalid_username
    
    ; Validate password
    cmp r9, 0
    je .invalid_input
    call validate_password
    test rax, rax
    jz .invalid_password

    ; Check if username already exists
    mov rdi, r8          ; username ptr
    call user_exists
    test rax, rax
    jnz .username_exists

    ; Create user
    call create_user
    test rax, rax
    jz .creation_error

    ; Build response
    call http_response_201
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_open_brace
    call str_copy_with_length
    add [res_buffer_pos], rax

    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_key_id
    call str_copy_with_length
    add [res_buffer_pos], rax

    mov eax, [last_created_user_id]
    call int_to_str
    add [res_buffer_pos], rax
    
    mov rdi, res_buffer  
    add rdi, [res_buffer_pos]
    mov al, ','
    mov [rdi], al
    inc rdi
    mov [res_buffer_pos], rdi
    sub rdi, res_buffer
    
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_key_username_q
    call str_copy_with_length
    add [res_buffer_pos], rax
    
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, r8         ; original username
    call str_copy_with_length
    add [res_buffer_pos], rax
    
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov al, '"'
    mov [rdi], al
    inc rdi
    mov al, '}'
    mov [rdi], al
    inc rdi
    mov al, 10  ; \n
    mov [rdi], al
    inc rdi
    mov [res_buffer_pos], rdi
    sub rdi, res_buffer
    ret

.invalid_input:
.invalid_username:
    call http_response_400
    mov rdi, res_buffer
    add rdi, [res_buffer_pos] 
    mov rsi, error_invalid_username_str
    call str_copy_with_length
    add [res_buffer_pos], rax - len_err_stub
    ret

.invalid_password:
    call http_response_400
    mov rdi, res_buffer
    add rdi, [res_buffer_pos] 
    mov rsi, error_password_short_str
    call str_copy_with_length
    add [res_buffer_pos], rax - len_err_stub
    ret

.username_exists:
    call http_response_409
    mov rsi, error_username_taken_str
    call str_copy_with_length
    add [res_buffer_pos], rax
    ret

.creation_error:
    call http_response_500
    ret

handle_post_login:
    ; Extract credentials
    call extract_username_password
    mov r8, rax    ; Save username
    mov r9, rdx    ; Save password

    ; Validate and look up user
    mov rdi, r8
    mov rsi, r9
    call authenticate_user
    test rax, rax
    jz .auth_fail_login

    ; Create session
    mov [req_user_auth_id], eax        ; Save user id
    call create_session
    mov [current_session_id], eax      ; Save session id

    ; Send response with session cookie
    call http_response_200
    ; Add Set-Cookie header
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, header_set_cookie_prefix
    call str_copy_with_length
    add [res_buffer_pos], rax
    
    ; Add session token
    mov rdi, res_buffer
    add rdi, [res_buffer_pos] 
    mov eax, [current_session_id]
    ; Convert to hex representation for session token
    call gen_session_token
    
    ; Add rest of cookie attrs
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, header_cookie_attrs
    call str_copy_with_length
    add [res_buffer_pos], rax

    ; Add JSON response body
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_open_brace
    call str_copy_with_length
    add [res_buffer_pos], rax

    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_key_id
    call str_copy_with_length
    add [res_buffer_pos], rax

    mov eax, [req_user_auth_id]
    call int_to_str
    add [res_buffer_pos], rax

    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov al, ','
    mov [rdi], al
    inc rdi
    mov [res_buffer_pos], rdi
    sub rdi, res_buffer
    
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_key_username_q
    call str_copy_with_length
    add [res_buffer_pos], rax

    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov ebx, [req_user_auth_id]
    dec ebx
    mov ecx, USER_STRUCT_SIZE
    mul ecx
    lea rcx, [users_memory]
    add rcx, rax
    
    mov rdi, res_buffer 
    add rdi, [res_buffer_pos]
    mov rsi, rcx
    add rsi, USER_FIELD_USERNAME
    call str_copy_with_length
    add [res_buffer_pos], rax
    
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov al, '"'
    mov [rdi], al
    inc rdi
    mov al, '}'
    mov [rdi], al
    inc rdi
    mov al, 10
    mov [rdi], al
    inc rdi
    mov [res_buffer_pos], rdi
    sub rdi, res_buffer
    ret

.auth_fail_login:
    call http_response_401
    mov rdi, res_buffer
    add rdi, [res_buffer_pos] 
    mov rsi, error_invalid_creds_str
    call str_copy_with_length
    add [res_buffer_pos], rax - len_err_stub
    ret

handle_post_logout:
    call require_auth
    test rax, rax
    jz .do_logout
    
    call http_response_401
    ret

.do_logout:
    ; Invalidate current session
    mov eax, [current_user_id]
    call remove_session_by_user

    call http_response_200
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov rsi, json_empty_object
    call str_copy_with_length
    add [res_buffer_pos], rax
    ret

handle_get_todos:
    call require_auth
    test rax, rax
    jz .get_auth_okay
    
    call http_response_401
    ret

.get_auth_okay:
    ; Build array of user's todos
    call http_response_200
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov al, '['  ; Start JSON array
    mov [rdi], al
    inc rdi
    mov [res_buffer_pos], rdi
    sub rdi, res_buffer

    mov edi, 0  ; Counter
    mov esi, [current_user_id]

.find_user_todos:
    cmp edi, [next_todo_id]
    jge .todos_done
    cmp edi, 0
    je .skip_zero_id

    ; Access todo
    mov eax, edi
    dec eax
    mov ebx, TODO_STRUCT_SIZE
    mul ebx
    lea rbx, [todos_memory]
    add rbx, rax

    ; Check if todo exists and belongs to user
    cmp byte [rbx + TODO_FIELD_VALID], 0
    je .next_todo
    mov ecx, [rbx + TODO_FIELD_USER_ID]
    cmp ecx, esi
    jne .next_todo

    ; Add comma if not first element
    cmp edi, 1
    je .first_todo_skip_comma
    mov rbx, res_buffer
    add rbx, [res_buffer_pos]
    mov al, ','
    mov [rbx], al
    inc rbx
    mov [res_buffer_pos], rbx
    sub rbx, res_buffer

.first_todo_skip_comma:
    ; Add todo object to response
    mov eax, edi
    call todo_to_json
    add [res_buffer_pos], rax

.next_todo:
    inc edi
    jmp .find_user_todos

.todos_done:
    mov rdi, res_buffer
    add rdi, [res_buffer_pos]
    mov al, ']'
    mov [rdi], al
    inc rdi
    mov al, 10
    mov [rdi], al
    inc rdi
    mov [res_buffer_pos], rdi
    sub rdi, res_buffer
    ret

.skip_zero_id:
    inc edi
    jmp .find_user_todos

; TODO: Complete implementations for remaining handlers:
; - handle_post_todos
; - handle_get_todo_by_id  
; - handle_put_todo_by_id
; - handle_put_password
; - handle_delete_todo_by_id

handle_post_todos:
    ; This requires complete body parsing and JSON extraction
    call require_auth
    test rax, rax
    jz .todo_auth_ok
    
    call http_response_401
    ret

.todo_auth_ok:
    call extract_title_description
    test rax, rax
    jz .missing_title

    ; Create todo entry
    mov esi, [current_user_id]    ; User ID
    mov edi, eax                 ; Title ptr  
    mov r8d, edx                 ; Desc ptr

    call create_todo
    mov [new_todo_id], eax

    call http_response_201
    ; Convert new todo to JSON
    mov eax, [new_todo_id]
    call todo_to_json
    add [res_buffer_pos], rax  
    ret

.missing_title:
    call http_response_400
    mov rdi, res_buffer
    add rdi, [res_buffer_pos] 
    mov rsi, error_title_required_str
    call str_copy_with_length
    add [res_buffer_pos], rax - len_err_stub
    ret

require_auth:
    cmp dword [current_user_id], 0
    jne .is_auth
    xor rax, rax
    ret
.is_auth:
    mov rax, 1
    ret

; Utility functions
str_cmp:
    ; rdi and rsi -> strings (null-terminated)
    ; returns 0 if same, non-zero if different
    push rbx
    xor rbx, rbx

 .loop:
    mov al, [rdi + rbx]
    mov cl, [rsi + rbx]
    test al, al
    jz .check_s_end
    cmp al, cl
    jne .different
    
    inc rbx
    jmp .loop

 .check_s_end:
    test cl, cl
    jz .equal
    
 .different:
    mov rax, 1
    pop rbx
    ret
    
 .equal:
    xor rax, rax
    pop rbx
    ret

str_copy_with_length:
    ; rdi = dest, rsi = src
    ; returns length written
    push rcx
    push rsi
    push rdi
    xor rcx, rcx

 .copy_loop:
    mov al, [rsi + rcx]
    test al, al
    jz .copy_done
    mov [rdi + rcx], al
    inc rcx
    jmp .copy_loop

 .copy_done:
    pop rdi
    pop rsi
    pop rax  ; return original length
    ret

parse_uint:
    ; rdi points to string of digits
    ; returns integer in rax
    push rbx
    push rsi
    xor rax, rax               ; result
    mov rsi, rdi               ; keep original
    xor rbx, rbx               ; index

 .convert:
    mov cl, [rsi + rbx]        ; Get next character
    cmp cl, '0'
    jb .done
    cmp cl, '9'
    ja .done

    ; Accumulate number  
    imul rax, 10
    sub cl, '0'
    add rax, rcx
    inc rbx
    jmp .convert

 .done:
    pop rsi
    pop rbx
    ret

int_to_str:
    ; eax = number to convert
    ; rdi = output buffer
    ; returns length of string

    push rdi
    push rbx
    push rcx
    
    test eax, eax
    jnz .non_zero_start
    
    ; Special case for zero
    mov byte [rdi], '0'
    mov rbx, 1
    jmp .int_to_str_finish

.non_zero_start:
    mov ebx, 10
    xor rcx, rcx               ; digit counter

 .collect_digits:
    xor rdx, rdx
    div ebx                    ; eax /= 10, rdx = remainder
    add dl, '0'                ; convert to ASCII
    push rdx                   ; save digit on stack
    inc rcx
    test eax, eax
    jnz .collect_digits

    ; Write digits to buffer in correct order
    mov rbx, rcx               ; length counter
    
 .write_backwards:
    cmp rbx, 0
    je .int_to_str_finish
    pop rax                    ; get digit from stack  
    mov [rdi + rcx - rbx], al  ; position at end-first
    dec rbx
    jmp .write_backwards

.int_to_str_finish:
    pop rcx
    pop rbx
    pop rax
    ret

str_includes_at_offset:
    ; rdi = text, rsi = pattern
    ; Return 1 if pattern found at current position, 0 if not
    push rax
    push rbx
    xor rbx, rbx          ; counter

 .check_chars:
    mov al, [rsi + rbx]   ; Pattern char
    test al, al           ; End of pattern?
    jz .found_match
    cmp al, [rdi + rbx]   ; Same as text char?
    jne .no_match
    inc rbx
    jmp .check_chars

 .found_match:
    mov rax, 1
    jmp .finish

 .no_match:
    xor rax, rax

 .finish:
    pop rbx
    pop rax
    ret

str_starts_with:
    ; rdi = string, rsi = pattern
    ; 1 if string starts with pattern, 0 otherwise
    jmp str_includes_at_offset

read_until_space:
    ; rdi = src, rsi = dst
    ; reads until space character, copies to dest, returns # of chars processed
    push rcx
    xor rcx, rcx

 .read_loop:
    mov al, [rdi + rcx]    ; Next char
    cmp al, ' '            ; Space delimiter?
    je .reading_done
    mov [rsi + rcx], al    ; Copy char
    inc rcx                ; Next char
    cmp cl, 63             ; Max reasonable length?  
    jb .read_loop
    jmp .reading_done

 .reading_done:
    mov byte [rsi + rcx], 0    ; Null terminate
    mov rax, rcx
    pop rcx
    ret

read_until_next_space:
    ; Similar to above but continues past current word till next space
    jmp read_until_space

write_exact:
    ; rdi = fd, rsi = buffer, rdx = count
    mov rax, SYS_WRITE
    syscall
    ret

close_fd:
    ; rdi = fd to close  
    mov rax, SYS_CLOSE
    syscall
    ret

exit:
    ; rdi = exit code
    mov rax, SYS_EXIT
    syscall

; Data section
section .data
    cmdline_port_flag: db '--port', 0
    usage_text: db 'Usage: server --port PORT', 10, 0
    usage_len equ $ - usage_text - 1
    
    GET_str:    db 'GET ', 0
    POST_str:   db 'POST ', 0
    PUT_str:    db 'PUT ', 0
    DELETE_str: db 'DELETE ', 0
    
    path_register:    db '/register', 0
    path_login:       db '/login', 0
    path_logout:      db '/logout', 0
    path_me:          db '/me', 0
    path_password:     db '/password', 0
    path_todos:       db '/todos', 0
    path_todos_slash: db '/todos/', 0
    path_todos_slash_len equ $ - path_todos_slash - 1

    cookie_hdr_start: db 'Cookie: session_id=', 0
    cookie_hdr_start_len equ $ - cookie_hdr_start - 1

    ; HTTP responses
    http_header_200: times 128 db 0
    http_header_200_template: db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    http_header_200_size equ $ - http_header_200_template

    http_header_201: times 128 db 0  
    http_header_201_template: db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    http_header_201_size equ $ - http_header_201_template

    http_header_204: times 64 db 0
    http_header_204_template: db 'HTTP/1.1 204 No Content', 13, 10, 13, 10  
    http_header_204_size equ $ - http_header_204_template

    http_header_400: times 128 db 0
    http_header_400_template: db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    http_header_400_size equ $ - http_header_400_template

    http_header_401: times 128 db 0
    http_header_401_template: db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    http_header_401_size equ $ - http_header_401_template

    http_header_404: times 128 db 0
    http_header_404_template: db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    http_header_404_size equ $ - http_header_404_template

    http_header_405: times 64 db 0
    http_header_405_template: db 'HTTP/1.1 405 Method Not Allowed', 13, 10, 13, 10
    http_header_405_size equ $ - http_header_405_template

    json_error_prefix: db '{"error":"', 0
    json_error_suffix: db '"}', 10, 0
    json_error_prefix_len: equ $ - json_error_prefix - 1
    json_error_suffix_len: equ $ - json_error_suffix - 1

    error_auth_required_str: db 'Authentication required', 0
    error_auth_required_len: equ $ - error_auth_required_str - 1
    
    error_invalid_username_str: db 'Invalid username', 0
    error_invalid_username_len: equ $ - error_invalid_username_str - 1
    
    error_password_short_str: db 'Password too short', 0
    error_password_short_len: equ $ - error_password_short_str - 1
    
    error_username_taken_str: db 'Username already exists', 0
    error_username_taken_len: equ $ - error_username_taken_str - 1

    error_invalid_creds_str: db 'Invalid credentials', 0
    error_invalid_creds_len: equ $ - error_invalid_creds_str - 1

    error_not_found_str: db 'Todo not found', 0
    error_not_found_len: equ $ - error_not_found_str - 1

    error_title_required_str: db 'Title is required', 0
    error_title_required_len: equ $ - error_title_required_str - 1

    error_bad_request_str: db 'Bad Request', 0
    error_bad_request_len: equ $ - error_bad_request_str - 1
    
    json_key_id: db '"id":', 0
    json_key_id_len: equ $ - json_key_id - 1
    
    json_key_username_q: db ',"username":"', 0
    json_key_username_q_len: equ $ - json_key_username_q - 1
    
    json_key_title_q: db ',"title":"', 0
    json_key_title_q_len: equ $ - json_key_title_q - 1
    
    json_key_description_q: db ',"description":"', 0
    json_key_description_q_len: equ $ - json_key_description_q - 1
    
    json_key_completed: db ',"completed":', 0
    json_key_completed_len: equ $ - json_key_completed - 1
    
    json_open_brace: db '{', 0
    json_close_brace: db '}', 10, 0
    
    json_empty_object: db '{}', 10, 0
    
    header_set_cookie_prefix: db 'Set-Cookie: session_id=', 0
    header_cookie_attrs: db '; Path=/; HttpOnly', 13, 10, 0

;%define USER_STRUCT_SIZE 256
USER_STRUCT_SIZE equ 256
TIMES USER_FIELD_ID EQU 0
TIMES USER_FIELD_USERNAME EQU 4  
TIMES USER_FIELD_PASSWORD EQU 54
TIMES USER_FIELD_VALID EQU 86
;%define TODO_STRUCT_SIZE 512
TODO_STRUCT_SIZE equ 512
TODO_FIELD_ID EQU 0
TODO_FIELD_USER_ID EQU 4
TODO_FIELD_TITLE EQU 8
TODO_FIELD_DESCRIPTION EQU 264
TODO_FIELD_COMPLETED EQU 519
TODO_FIELD_CREATED_AT EQU 520
TODO_FIELD_UPDATED_AT EQU 541
TODO_FIELD_VALID EQU 562

len_err_stub equ 9  ; Length of '{"error":"' string

REQ_BUFFER_SIZE equ 4096
RES_BUFFER_SIZE equ 8192

; BSS sections
section .bss
    ; Main buffers
    req_buffer:        resb REQ_BUFFER_SIZE
    res_buffer:        resb RES_BUFFER_SIZE
    tmp_buffer:        resb 512

    ; Request parts
    req_method:        resb 10
    req_path:          resb 128
    req_body:          resb 2048  
    req_body_ptr:      resq 1
    req_parse_pos:     resd 1
    req_param_id:      resd 1
    
    ; Headers and cookies
    session_cookie_id: resb 64
    
    ; Authentication
    current_user_id:   resd 1
    req_user_auth_id:  resd 1
    current_session_id:resd 1
    
    ; Response tracking
    res_buffer_pos:    resq 1
    
    ; Global IDs
    next_user_id:      resd 1
    next_todo_id:      resd 1
    next_session_idx:  resd 1
    last_created_user_id: resd 1
    new_todo_id:       resd 1
    
    ; Database storage
    users_memory:      resb 1000 * USER_STRUCT_SIZE  ; Up to 1000 users
    todos_memory:      resb 10000 * TODO_STRUCT_SIZE ; Up to 10000 todos
    session_memory:    resb 1000 * 80              ; Sessions (id + userid + token)
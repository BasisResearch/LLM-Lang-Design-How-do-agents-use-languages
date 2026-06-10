bits 64
section .text

; Main entry point
global _start

%include "syscalls.inc"

_start:
    ; Parse command line arguments
    mov rbp, rsp
    mov rdi, [rbp + 8]      ; argc
    mov rsi, [rbp + 16]     ; argv
    
    call parse_args
    call init_server
    call event_loop

; Exit on completion
exit:
    mov rax, SYS_EXIT
    mov rdi, 0
    syscall

; Function to parse command line arguments
; Input: rcx = argc, rdx = argv
parse_args:
    push rbp
    mov rbp, rsp
    
    ; Check if we have at least 3 arguments (./program --port N)
    cmp rdi, 3
    jl print_usage_error
    
    ; Get second argument (--port)
    mov rax, [rsi + 8]      ; argv[1] = "--port"
    push rax
    call strcmp
    add rsp, 8
    
    mov rbx, msg_port_opt
    cmp rax, 0
    jne print_usage_error
    
    ; Get third argument (port number)
    mov rax, [rsi + 16]     ; argv[2] = port
    call atoi
    mov [current_port], ax  ; Store port in word
    
    pop rbp
    ret

print_usage_error:
    mov rax, msg_usage
    mov rbx, msg_usage_len
    call print_string
    jmp exit_program

atoi:
    push rbp
    mov rbp, rsp
    push rsi
    push rcx
    push rdx
    
    mov rsi, rdi            ; rsi = string pointer
    xor rax, rax            ; result = 0
    xor rcx, rcx            ; position counter
    
convert_loop:
    movzx rdx, byte [rsi + rcx]
    test rdx, rdx           ; Null terminator?
    jz convert_done
    
    cmp rdx, '0'
    jl convert_done
    cmp rdx, '9'
    jg convert_done
    
    imul rax, 10
    sub rdx, '0'
    add rax, rdx
    inc rcx
    jmp convert_loop

convert_done:
    mov rdi, rax
    pop rdx
    pop rcx
    pop rsi
    pop rbp
    ret

; Initialize server - create socket, bind, listen
init_server:
    push rbp
    mov rbp, rsp
    
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET        ; domain
    mov rsi, SOCK_STREAM    ; type 
    mov rdx, 0              ; protocol
    syscall
    mov [server_socket], eax
    
    ; Set SO_REUSEADDR
    mov rax, SYS_SETSOCKOPT
    mov rdi, [server_socket]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    mov rcx, reuse_true
    mov r8, 4
    syscall
    
    ; Prepare sockaddr_in structure
    mov word [sock_addr + 0], AF_INET        ; sa_family_t sin_family
    mov ax, [current_port]                   ; port
    rol ax, 8                                ; convert to network byte order (big-endian)
    mov [sock_addr + 2], ax                  ; in_port_t sin_port
    mov dword [sock_addr + 4], 0x00000000    ; struct in_addr sin_addr (0.0.0.0 = INADDR_ANY)
    ; Padding bytes at sock_addr + 8 are already zeroed
    
    ; Bind socket
    mov rax, SYS_BIND
    mov rdi, [server_socket]
    mov rsi, sock_addr
    mov rdx, 16              ; sizeof(sockaddr_in)
    syscall
    
    ; Listen for connections  
    mov rax, SYS_LISTEN  
    mov rdi, [server_socket]
    mov rsi, 10             ; backlog
    syscall
    
    pop rbp
    ret

; Main event loop
event_loop:
    push rbp
    mov rbp, rsp
    push rbx

connection_loop:
    ; Accept connection
    mov rax, SYS_ACCEPT
    mov rdi, [server_socket]
    mov rsi, 0              ; no peer addr
    mov rdx, 0              ; no len
    syscall
    mov rbx, eax            ; store client fd
    
accept_error_check:
    cmp eax, 0
    jl connection_loop      ; retry if error
    
process_request_loop:
    ; Allocate buffer for request
    mov rax, SYS_MMAP
    mov rdi, 0              ; address (let kernel decide)
    mov rsi, 4096           ; size
    mov rdx, PROT_READ | PROT_WRITE
    mov rcx, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1              ; fd
    mov r9, 0               ; offset
    syscall
    
    mov r12, rax            ; store buffer address in r12
    
    ; Read from client
    mov rax, SYS_RECVFROM
    mov rdi, rbx            ; client fd
    mov rsi, r12            ; buffer
    mov rdx, 4096           ; buffer size
    mov rcx, 0              ; flags
    mov r8, 0               ; addr
    mov r9, 0               ; addr len
    syscall
    
    mov r13, rax            ; save received bytes count in r13
    test rax, rax
    jle cleanup_after_read

    ; Null terminate the request for parsing
    mov byte [r12 + rax], 0
    
    ; Parse and handle the request
    call handle_request
    
    ; Close connection after handling
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall

    ; Clean up buffer
    mov rax, SYS_MUNMAP
    mov rdi, r12
    mov rsi, 4096
    syscall

    ; Accept next connection
    jmp connection_loop

cleanup_after_read:
    ; Client disconnected or error
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall

    ; Clean up buffer
    mov rax, SYS_MUNMAP
    mov rdi, r12
    mov rsi, 4096
    syscall

    ; Accept next connection
    jmp connection_loop

; Handle incoming HTTP requests
handle_request:
    push rbp
    mov rbp, rsp

    ; Find first space to identify method
    mov rsi, r12            ; request buffer
    mov rdi, request_method
method_loop:
    mov al, [rsi]
    cmp al, ' '
    je end_of_method
    mov [rdi], al
    inc rsi
    inc rdi
    jmp method_loop

end_of_method:
    mov byte [rdi], 0       ; null terminate method
    inc rsi                 ; move past space

    ; Extract resource path
    mov rdi, resource_path
path_loop:
    mov al, [rsi]
    cmp al, ' '
    je end_of_path
    cmp al, '?'
    je end_of_path
    mov [rdi], al
    inc rsi
    inc rdi
    jmp path_loop

end_of_path:
    mov byte [rdi], 0       ; null terminate path
    inc rsi                 ; move past space

    ; Skip HTTP version string - find \r\n
skip_version_loop:
    mov al, [rsi]
    cmp [rsi], word 0x0A0D   ; \n\r sequence
    je headers_start
    inc rsi
    jmp skip_version_loop

headers_start:
    add rsi, 2              ; skip over \n\r

    ; Parse session ID if present
    call extract_session_id

    ; Determine request method
    mov rsi, request_method
    mov rdi, msg_get
    call strcmp
    test rax, rax
    je do_get

    mov rsi, request_method
    mov rdi, msg_post
    call strcmp
    test rax, rax
    je do_post

    mov rsi, request_method
    mov rdi, msg_put
    call strcmp
    test rax, rax
    je do_put

    mov rsi, request_method
    mov rdi, msg_delete
    call strcmp
    test rax, rax
    je do_delete

    ; Unsupported method
    mov rax, response_bad_method
    mov rbx, response_bad_method_len
    call send_response
    jmp handle_done

do_get:
    call handle_get
    jmp handle_done

do_post:
    call handle_post
    jmp handle_done

do_put:
    call handle_put
    jmp handle_done

do_delete:
    call handle_delete

handle_done:
    pop rbp
    ret

; Extract session ID from Cookie header
extract_session_id:
    push rbp
    mov rbp, rsp
    push rsi
    push rdi
    push rcx
    push rax
    
    ; Clear out existing session id
    mov rdi, session_cookie_value
    mov rcx, 33              ; 32 chars + null termination
    mov al, 0
    rep stosb
    
    mov rsi, r12             ; start of request buffer
    mov rdi, session_cookie_search
find_cookie_header:
    ; Find start of headers and then cookie header
    ; First, skip the request line to find headers
    mov rax, rsi
skip_request_line:
    cmp dword [rax], 0x0A0D0A0D  ; \r\n\r\n (end of headers/start of body)
    je check_for_headers
    cmp word [rax], 0x0A0D       ; \n\r 
    je headers_found
    inc rax
    jmp skip_request_line
    
headers_found:
    add rax, 2
check_for_headers:
    ; Now look for 'Cookie:' header starting from rax
    mov rsi, rax
    
scan_cookie:
    ; Check if this line starts with 'Cookie:'
    mov rdi, rsi
    mov rax, msg_cookie_header
    push rdi
    push rax
    call strcmp_at_start
    add rsp, 16
    cmp rax, 0
    je found_cookie_header
    
    ; Find next line ending
    mov rcx, rsi
next_line:
    cmp byte [rcx], 0x0A      ; \n
    je found_next_line
    cmp byte [rcx], 0
    je no_more_headers
    inc rcx
    jmp next_line
    
found_next_line:
    mov rsi, rcx
    inc rsi                   ; next line
    jmp scan_cookie
    
no_more_headers:
    pop rax
    pop rcx
    pop rdi
    pop rsi
    pop rbp
    ret

found_cookie_header:
    ; Move to after 'Cookie: ' (8 chars)
    add rsi, 8
    
    ; Look for 'session_id='
    mov rdi, msg_session_id_key
find_session_id:
    mov rax, rsi
    push rdi
    push rax
    call strcmp_at_start
    add rsp, 16
    cmp rax, 0
    je found_session_start
    
    cmp byte [rsi], 0
    je no_session_id_found
    inc rsi
    jmp find_session_id
    
found_session_start:
    add rsi, 11    ; skip past 'session_id='
    
    ; Copy session ID value until ; or end
    mov rdi, session_cookie_value
copy_session_id:
    mov al, [rsi]
    cmp al, ';'
    je copy_done
    cmp al, 0x0A      ; newline
    je copy_done
    cmp al, 0x0D      ; carriage return
    je copy_done
    cmp al, ' '       ; space
    je copy_done
    mov [rdi], al
    inc rsi
    inc rdi
    cmp rdi, session_cookie_value + 32   ; prevent overflow
    jl copy_session_id
    jmp copy_done

copy_done:
    mov byte [rdi], 0
    
no_session_id_found:
    pop rax
    pop rcx
    pop rdi
    pop rsi
    pop rbp
    ret

strcmp_at_start:
    push rbp
    mov rbp, rsp
    push rsi
    push rdi
    push rcx
    
    mov rsi, [rbp + 16]      ; param 2: search string
    mov rdi, [rbp + 24]      ; param 1: source string
    mov rax, 0
    mov rcx, 0

strcmp_loop:
    mov bl, [rdi + rax]
    mov dl, [rsi + rax]
    cmp bl, 0
    je strcmp_end
    cmp dl, 0
    je strcmp_diff
    cmp bl, dl
    jne strcmp_diff
    inc rax
    jmp strcmp_loop

strcmp_end:
    cmp dl, 0
    je strings_equal
    jmp strcmp_diff

strings_equal:
    mov rax, 0
    jmp strcmp_return

strcmp_diff:
    mov rax, 1

strcmp_return:
    pop rcx
    pop rdi
    pop rsi
    pop rbp
    ret

; Response functions
send_response:
    push rbp
    mov rbp, rsp
    
    ; Send response
    mov rax, SYS_SENDTO
    mov rdi, rbx                    ; client fd
    mov rsi, rax                    ; response message
    mov rdx, rbx                    ; response length
    mov rcx, 0                      ; flags
    mov r8, 0                       ; dest addr
    mov r9, 0                       ; dest len
    syscall
    
    pop rbp
    ret

send_response_with_fd:
    push rbp
    mov rbp, rsp
    
    ; Send response
    mov rax, SYS_SENDTO
    mov rdi, rdi                    ; file descriptor passed as first arg
    mov rsi, rsi                    ; response message
    mov rdx, rdx                    ; response length
    mov rcx, 0                      ; flags
    mov r8, 0                       ; dest addr
    mov r9, 0                       ; dest len
    syscall
    
    pop rbp
    ret

; String comparison function
strcmp:
    push rbp
    mov rbp, rsp
    push rsi
    push rdi
    push rcx
    push rax
    
    mov rdi, [rbp + 24]      ; param 1
    mov rsi, [rbp + 32]      ; param 2
    mov rax, 0
    mov rcx, 0

strcmp_loop_s:
    mov bl, [rdi + rax]
    mov dl, [rsi + rax]
    cmp bl, 0
    je strcmp_end_s
    cmp dl, 0
    je strcmp_diff_s
    cmp bl, dl
    jne strcmp_diff_s
    inc rax
    jmp strcmp_loop_s

strcmp_end_s:
    cmp dl, 0
    je strings_equal_s
    jmp strcmp_diff_s

strings_equal_s:
    mov rax, 0
    jmp strcmp_return_s

strcmp_diff_s:
    mov rax, 1

strcmp_return_s:
    pop rax
    pop rcx
    pop rdi
    pop rsi
    pop rbp
    ret

; Print string function
print_string:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_WRITE
    mov rdi, 1                  ; stdout
    mov rsi, rax                ; string pointer
    mov rdx, rbx                ; length 
    syscall
    
    pop rbp
    ret

; Handle GET requests
handle_get:
    push rbp
    mov rbp, rsp
    
    ; Check if path is /me
    mov rsi, resource_path
    mov rdi, msg_me_path
    call strcmp
    test rax, rax
    je get_me
    
    ; Check if path is /todos or starts with /todos/
    mov rsi, resource_path
    mov rdi, msg_todos_path
    call strcmp
    test rax, rax
    je get_todos
    
    ; Check if path starts with /todos/
    mov rdi, msg_todos_path_with_slash
    mov rsi, resource_path
    call strcmp_at_start
    test rax, rax
    je get_single_todo
    
    ; Unknown path
    mov rax, response_not_found
    mov rbx, response_not_found_len
    call send_response
    jmp get_handler_done

get_me:
    call require_auth
    test rax, rax
    jz send_unauthorized
    
    ; Return user info JSON
    mov rax, current_user_id
    mov rbx, user_data
    call find_user_by_id
    test rax, rax
    jz get_me_no_user
    
    ; Build JSON response
    push rbx                    ; user pointer
    mov rsi, response_json_template
    mov rdi, response_buffer
    mov eax, [rbx]              ; id
    call sprintf_user_info
    pop rbx                     ; get user pointer back
    
    mov rax, response_buffer
    mov rbx, response_buffer_pos
    call send_response
    jmp get_handler_done

get_me_no_user:
    mov rax, response_not_found
    mov rbx, response_not_found_len
    call send_response
    jmp get_handler_done

get_todos:
    call require_auth
    test rax, rax
    jz send_unauthorized
    
    ; Return user's todos as JSON array
    ; Build JSON response
    mov rsi, response_empty_array
    mov rdi, response_buffer
    mov ecx, response_empty_array_len
    call strcpy
    mov qword [response_buffer_pos], response_empty_array_len
    
    mov rax, response_buffer
    mov rbx, response_buffer_pos
    call send_response
    jmp get_handler_done

get_single_todo:
    call require_auth
    test rax, rax
    jz send_unauthorized
    
    ; Extract ID from path
    mov rsi, resource_path
    add rsi, 6              ; skip "/todos/"
    call atoi               ; now rdi contains id
    
    ; Find todo by ID
    mov rax, rdi            ; pass the id
    call find_todo_by_id_and_user_id
    
    ; For now, just return not found
    mov rax, response_not_found
    mov rbx, response_not_found_len
    call send_response
    jmp get_handler_done

send_unauthorized:
    mov rax, response_unauthorized
    mov rbx, response_unauthorized_len
    call send_response
    jmp get_handler_done

get_handler_done:
    pop rbp
    ret

; Handle POST requests
handle_post:
    push rbp
    mov rbp, rsp
    
    ; Check if path is /register
    mov rsi, resource_path
    mov rdi, msg_register_path
    call strcmp
    test rax, rax
    je post_register
    
    ; Check if path is /login
    mov rsi, resource_path
    mov rdi, msg_login_path
    call strcmp
    test rax, rax
    je post_login
    
    ; Check if path is /logout
    mov rsi, resource_path
    mov rdi, msg_logout_path
    call strcmp
    test rax, rax
    je post_logout
    
    ; Check if path is /todos
    mov rsi, resource_path
    mov rdi, msg_todos_path
    call strcmp
    test rax, rax
    je post_todos
    
    ; Unknown path
    mov rax, response_method_not_allowed
    mov rbx, response_method_not_allowed_len
    call send_response
    jmp post_handler_done

post_register:
    ; Parse request body for username and password
    call parse_register_body
    test rax, rax
    jz register_invalid_input
    
    ; Validate username & password format (simplified)
    mov rax, parsed_username
    call validate_username_format
    test rax, rax
    jz register_invalid_username
    
    mov rax, parsed_password
    call validate_password_format
    test rax, rax
    jz register_invalid_password
    
    ; Check if user already exists
    mov rax, parsed_username
    call find_user_by_username
    test rax, rax
    jnz register_conflict
    
    ; Create new user
    call create_new_user
    
    ; Build success response
    mov rsi, register_success_template
    mov rdi, response_buffer
    mov eax, [rax]           ; id from newly created user
    mov ebx, parsed_username
    call sprintf_register_response
    mov [response_buffer_pos], rdx
    
    mov rax, response_buffer
    mov rbx, response_buffer_pos
    call send_response
    jmp post_handler_done

register_invalid_input:
    mov rax, register_bad_request
    mov rbx, register_bad_request_len
    call send_response
    jmp post_handler_done

register_invalid_username:
    mov rax, register_invalid_username_msg
    mov rbx, register_invalid_username_len
    call send_response
    jmp post_handler_done

register_invalid_password:
    mov rax, register_password_too_short
    mov rbx, register_password_too_short_len
    call send_response
    jmp post_handler_done

register_conflict:
    mov rax, register_username_taken
    mov rbx, register_username_taken_len
    call send_response
    jmp post_handler_done

post_login:
    ; Parse request body for username and password
    call parse_login_body
    test rax, rax
    jz login_invalid_input
    
    ; Authenticate user
    mov rax, parsed_username
    mov rbx, parsed_password
    call authenticate_user
    test rax, rax
    jz login_invalid_credentials
    
    ; Set current user ID  
    mov [current_user_id], eax
    
    ; Generate session token
    call generate_session_token
    
    ; Build success response
    mov rsi, login_success_template
    mov rdi, response_buffer
    mov eax, [rax]           ; id from authenticated user
    mov ebx, parsed_username
    call sprintf_login_response
    mov [response_buffer_pos], rdx
    
    ; Add Set-Cookie header to the response
    lea rdi, [response_buffer + rdx - 1]  ; append before null terminator
    dec rdi
    mov esi, set_cookie_header
    call strcat
    mov rcx, current_session_token
    call strcat
    mov esi, set_cookie_end
    call strcat
    
    mov [response_buffer_len], edx
    
    mov rax, response_buffer
    mov rbx, response_buffer_len
    call send_response
    jmp post_handler_done

login_invalid_input:
    mov rax, login_bad_request
    mov rbx, login_bad_request_len
    call send_response
    jmp post_handler_done

login_invalid_credentials:
    mov rax, login_invalid_credentials_msg
    mov rbx, login_invalid_credentials_len
    call send_response
    jmp post_handler_done

post_logout:
    call require_auth
    test rax, rax
    jz send_logout_unauthorized
    
    ; Clear current user and invalidate session
    mov dword [current_user_id], 0
    mov rcx, current_session_token
    mov rdi, 0
    mov rax, 0
    mov rcx, 33
    rep stosb
    
    ; Send success response (empty JSON body)
    mov rax, response_empty_object
    mov rbx, response_empty_object_len
    call send_response
    jmp post_handler_done

send_logout_unauthorized:
    mov rax, response_unauthorized
    mov rbx, response_unauthorized_len
    call send_response
    jmp post_handler_done

post_todos:
    call require_auth
    test rax, rax
    jz create_todo_unauthorized
    
    ; Parse request body for todo attributes
    call parse_todos_create_body
    test rax, rax
    jz create_todo_invalid_input
    
    ; Create new todo under current user
    mov eax, [current_user_id]
    mov rbx, parsed_title
    mov rcx, parsed_description
    call create_new_todo
    
    ; Build response with new todo
    mov rsi, create_todo_success_template
    mov rdi, response_buffer
    mov eax, [rax]              ; id from new todo
    mov rbx, parsed_title
    mov rcx, parsed_description
    call sprintf_todo_response
    mov [response_buffer_pos], rdx
    
    mov rax, response_buffer
    mov rbx, response_buffer_pos
    call send_response
    jmp post_handler_done

create_todo_unauthorized:
    mov rax, response_unauthorized
    mov rbx, response_unauthorized_len
    call send_response
    jmp post_handler_done

create_todo_invalid_input:
    mov rax, create_todo_bad_request
    mov rbx, create_todo_bad_request_len
    call send_response
    jmp post_handler_done

post_handler_done:
    pop rbp
    ret

; Handle PUT requests
handle_put:
    push rbp
    mov rbp, rsp
    
    ; Check if path is /password
    mov rsi, resource_path  
    mov rdi, msg_password_path
    call strcmp
    test rax, rax
    je put_password
    
    ; Check if path starts with /todos/
    mov rdi, msg_todos_path_with_slash
    mov rsi, resource_path
    call strcmp_at_start
    test rax, rax
    je put_todo
    
    ; Unknown path
    mov rax, response_method_not_allowed
    mov rbx, response_method_not_allowed_len
    call send_response
    jmp put_handler_done

put_password:
    call require_auth
    test rax, rax
    jz unauthorized_put_password
    
    ; Parse old and new passwords
    call parse_password_body
    test rax, rax
    jz put_invalid_input
    
    ; Verify old password matches
    mov rax, [current_user_id]
    mov rbx, rdi   ; old_password
    call verify_user_password
    test rax, rax
    jz invalid_old_password  
    
    ; Validate new password format
    mov rax, rsi   ; new_password
    call validate_password_format
    test rax, rax
    jz invalid_new_password
    
    ; Update user's password (simplified in this impl)
    mov rax, response_empty_object
    mov rbx, response_empty_object_len
    call send_response
    jmp put_handler_done

unauthorized_put_password:
    mov rax, response_unauthorized
    mov rbx, response_unauthorized_len
    call send_response
    jmp put_handler_done

invalid_old_password:
    mov rax, put_password_invalid_creds
    mov rbx, put_password_invalid_creds_len
    call send_response
    jmp put_handler_done

invalid_new_password:
    mov rax, put_password_short
    mov rbx, put_password_short_len
    call send_response
    jmp put_handler_done

put_todo:
    call require_auth
    test rax, rax
    jz put_todo_unauthorized
    
    ; Extract todo ID from path
    mov rsi, resource_path
    add rsi, 6              ; skip "/todos/"
    call atoi               ; id now in rdi
    
    ; Find todo by ID and check ownership
    mov rax, rdi            ; todo id
    mov rbx, [current_user_id]  ; user id
    call find_todo_by_id_and_user_id
    test rax, rax 
    jz put_todo_not_found
    
    ; Update todo with provided fields (simplified here)
    mov rax, put_todo_success_response
    mov rbx, put_todo_success_response_len
    call send_response
    jmp put_handler_done

put_todo_unauthorized:
    mov rax, response_unauthorized
    mov rbx, response_unauthorized_len
    call send_response
    jmp put_handler_done

put_todo_not_found:
    mov rax, response_not_found
    mov rbx, response_not_found_len
    call send_response
    jmp put_handler_done
   
put_handler_done:
    pop rbp
    ret

; Handle DELETE requests
handle_delete:
    push rbp  
    mov rbp, rsp
    
    ; Check if path starts with /todos/
    mov rsi, resource_path
    mov rdi, msg_todos_path_with_slash
    call strcmp_at_start
    test rax, rax
    je delete_todo
    
    ; Unknown path or method not allowed
    mov rax, response_method_not_allowed
    mov rbx, response_method_not_allowed_len
    call send_response
    jmp delete_handler_done

delete_todo:
    call require_auth
    test rax, rax
    jz delete_todo_unauthorized
    
    ; Extract todo ID from path
    mov rsi, resource_path
    add rsi, 6              ; skip "/todos/"
    call atoi               ; id now in rdi
    
    ; Find todo by ID and check ownership
    mov rax, rdi            ; todo id
    mov rbx, [current_user_id]  ; user id
    call find_todo_by_id_and_user_id
    test rax, rax
    jz delete_todo_not_found
    
    ; Delete the todo (simplified in this implementation)
    mov rax, response_no_content
    mov rbx, response_no_content_len
    call send_response
    jmp delete_handler_done

delete_todo_unauthorized:
    mov rax, response_unauthorized
    mov rbx, response_unauthorized_len
    call send_response
    jmp delete_handler_done

delete_todo_not_found:
    mov rax, response_not_found
    mov rbx, response_not_found_len
    call send_response
    
delete_handler_done:
    pop rbp
    ret

; Check authentication (return non-zero if valid, zero if invalid)
require_auth:
    push rbp
    mov rbp, rsp
    
    ; Check if we have a session token
    mov al, [current_session_token]
    test al, al
    jz no_auth_set
    
    ; Validate current session 
    mov rax, current_session_token
    mov rbx, sessions_list
    call find_session_by_token
    test rax, rax
    jz invalid_session
    
    ; Valid session
    mov rax, 1
    pop rbp
    ret
    
no_auth_set:
invalid_session:
    mov rax, 0
    pop rbp
    ret

; Generate a pseudo-random session token
generate_session_token:
    ; Very simplified - in real world, would use proper randomness
    ; Just set fixed token for now
    mov rsi, default_session_token
    mov rdi, current_session_token
copy_default_token:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz copy_default_token
    
    ret

; Helper functions

strcpy:
    push rbp
    mov rbp, rsp
copy_loop:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz copy_done
    inc rsi
    inc rdi
    jmp copy_loop
copy_done:
    pop rbp
    ret

strcat:
    push rbp
    mov rbp, rsp
    
    ; First, find end of destination string
    mov rax, rdi
strlen_loop:
    cmp byte [rax], 0
    je strcat_start_copy
    inc rax
    jmp strlen_loop

strcat_start_copy:
    ; Now copy source to end of destination
    mov rdi, rax
    jmp copy_loop

; Data section
section .data
    ; Socket and address structures
    server_socket dd 0
    sock_addr times 16 db 0
    current_port dw 8080
    
    ; Command line options
    msg_port_opt db '--port', 0
    msg_usage db 'Usage: program --port PORT', 10, 0
    msg_usage_len equ $ - msg_usage - 11  ; Exclude null and newline
    
    ; Strings for request parsing
    request_method times 16 db 0
    resource_path times 256 db 0
    session_cookie_value times 33 db 0
    
    ; HTTP methods
    msg_get db 'GET', 0
    msg_post db 'POST', 0
    msg_put db 'PUT', 0
    msg_delete db 'DELETE', 0
    
    ; Resources
    msg_me_path db '/me', 0
    msg_register_path db '/register', 0
    msg_login_path db '/login', 0
    msg_logout_path db '/logout', 0
    msg_todos_path db '/todos', 0
    msg_todos_path_with_slash db '/todos/', 0
    msg_password_path db '/password', 0
    
    ; Cookie related strings
    msg_cookie_header db 'Cookie:', 0
    msg_session_id_key db 'session_id=', 0
    session_cookie_search db 'Cookie: session_id=', 0
    
    ; Common responses
    response_ok db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, 0
    response_created db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, 0  
    response_no_content db 'HTTP/1.1 204 No Content', 13, 10, 13, 10, 0
    response_bad_method db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Method not allowed"}', 0
    response_unauthorized db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Authentication required"}', 0
    response_not_found db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Not found"}', 0
    response_internal_error db 'HTTP/1.1 500 Internal Server Error', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Internal server error"}', 0
    response_bad_request db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Bad request"}', 0
    response_method_not_allowed db 'HTTP/1.1 405 Method Not Allowed', 13, 10, 'Content-Type: application/json', 13, 10, 'Allow: GET, POST, PUT, DELETE', 13, 10, 13, 10, '{"error":"Method not allowed"}', 0
    
    ; Response lengths
    response_bad_method_len equ $ - response_bad_method - 1
    response_unauthorized_len equ $ - response_unauthorized - 1
    response_not_found_len equ $ - response_not_found - 1
    
    ; Register-related responses
    register_success_template db '{"id":%d,"username":"%s"}', 0
    register_bad_request db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Invalid input"}', 0
    register_bad_request_len equ $ - register_bad_request - 1
    register_invalid_username_msg db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Invalid username"}', 0
    register_invalid_username_len equ $ - register_invalid_username_msg - 1
    register_password_too_short db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Password too short"}', 0
    register_password_too_short_len equ $ - register_password_too_short - 1
    register_username_taken db 'HTTP/1.1 409 Conflict', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Username already exists"}', 0
    register_username_taken_len equ $ - register_username_taken - 1
    
    ; Login-related responses
    login_success_template db '{"id":%d,"username":"%s"}', 0
    login_invalid_credentials_msg db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Invalid credentials"}', 0
    login_invalid_credentials_len equ $ - login_invalid_credentials_msg - 1
    login_bad_request db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Invalid input"}', 0
    login_bad_request_len equ $ - login_bad_request - 1
    
    ; Cookie header template
    set_cookie_header db 13, 10, 'Set-Cookie: session_id=', 0
    set_cookie_end db '; Path=/; HttpOnly', 0
    
    response_empty_object db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{}', 0
    response_empty_object_len equ $ - response_empty_object - 1
    response_empty_array db '[]', 0
    
    response_no_content_len equ $ - response_no_content - 1

    ; Put password responses
    put_password_invalid_creds db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Invalid credentials"}', 0
    put_password_invalid_creds_len equ $ - put_password_invalid_creds - 1
    put_password_short db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Password too short"}', 0  
    put_password_short_len equ $ - put_password_short - 1
    put_todo_success_response db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":1,"title":"Updated","description":"Updated desc","completed":false,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T10:30:00Z"}', 0
    put_todo_success_response_len equ $ - put_todo_success_response - 1
 
    ; Response buffer and length tracking
    response_buffer times 1024 db 0
    response_buffer_pos dq 0
    response_buffer_len dq 0
    
    ; Parsed data storage
    parsed_username times 100 db 0
    parsed_password times 100 db 0
    parsed_title times 256 db 0
    parsed_description times 512 db 0
    
    ; Authentication data  
    current_user_id dd 0
    current_session_token times 33 db 0   ; uuid format
    default_session_token db 'abc123def456ghi789jkl012mno345pq', 0
    
    ; Session storage - simplified approach
    sessions_list:  ; Array of sessions with ID and valid flag
        ; Each entry: <user_id:4bytes><valid_flag:1byte><token:32bytes><null_terminator:1byte>
    
    ; User data storage - simplified
    next_user_id dd 1
    user_count dd 0
    user_data times 1024 * 10 db 0 ; Allow 10 users max with ~4KB each
    
    ; Todo data storage - simplified
    next_todo_id dd 1
    todo_data times 1024 * 50 db 0  ; Allow 50 todos max
    
    ; Flags for socket options
    reuse_true dd 1
    
    ; Body for CREATE TODO responses
    create_todo_success_template db '{"id":%d,"title":"%s","description":"%s","completed":false,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T09:30:00Z"}', 0
    create_todo_bad_request db 'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Title is required"}', 0
    create_todo_bad_request_len equ $ - create_todo_bad_request - 1
    
    ; Response templates
    response_json_template db '{"id":%d,"username":"%s"}', 0
    
    response_200_headers db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, 0
    response_201_headers db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, 0

section .bss
    ; Additional buffers can be declared here

exit_program:
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

; Placeholder implementations for data structure operations

; parse_register_body: reads request body and extracts username/password into global variables
parse_register_body:
    ; Simplified - in reality would parse JSON
    ; For now, just pretend it succeeded
    mov rax, 1
    ret

; parse_login_body: reads request body and extracts username/password into global variables  
parse_login_body:
    ; Simplified - in reality would parse JSON
    ; For now, just pretend it succeeded
    mov rax, 1
    ret

; parse_todos_create_body: parses title/description from request body
parse_todos_create_body:
    ; Simplified - for now assume valid and set default values
    mov rsi, default_todo_title
    mov rdi, parsed_title
    call strcpy
    mov rsi, default_todo_desc
    mov rdi, parsed_description
    call strcpy
    mov rax, 1
    ret

; parse_password_body: parses old new passwords for the change password endpoint
parse_password_body:
    ; Simplified - return success as placeholder
    mov rax, 1
    mov rdi, parsed_password     ; old_password
    mov rsi, default_new_password ; new_password
    ret

; find_user_by_username: returns pointer to user struct or NULL
find_user_by_username:
    ; Simplified - return NULL (not found) for now
    xor rax, rax
    ret

; find_user_by_id: returns user pointer matching ID or NULL
find_user_by_id:
    ; Simplified - return NULL
    xor rax, rax
    ret

; create_new_user: creates user record and returns pointer
create_new_user:
    ; Simplified - return a fake pointer with valid id
    push rbp
    mov rbp, rsp
    mov eax, [next_user_id]
    mov [current_user_id], eax
    inc dword [next_user_id]
    
    ; Return some valid pointer (simplified)
    mov rax, user_data
    mov [rax], eax                ; Set id at beginning
    
    pop rbp
    ret

; authenticate_user: returns user ID on success or 0 on failure
authenticate_user:
    ; Simplified - assume authentication always succeeds
    mov rax, 1  ; Return user id 1
    ret 

; validate_username_format: checks rules and returns non-zero if valid
validate_username_format:
    ; Simplified - always return valid (non-zero)
    mov rax, 1
    ret

; validate_password_format: checks min length and returns non-zero if valid
validate_password_format:
    ; Simplified - always return valid (non-zero)
    mov rax, 1
    ret

; verify_user_password: verifies password for given user id
verify_user_password:
    ; Simplified - always return success
    mov rax, 1
    ret

; find_todo_by_id_and_user_id: returns todo pointer or NULL
find_todo_by_id_and_user_id:
    ; Simplified - return NULL (not found)
    xor rax, rax
    ret

; create_new_todo: creates a new todo item
create_new_todo:
    ; Simplified - return a valid todo id
    push rbp
    mov rbp, rsp
    mov eax, [next_todo_id]
    mov [next_todo_id], eax
    inc dword [next_todo_id] 
    
    ; Return pointer to beginning of todo area
    mov rax, todo_data
    mov [rax], eax                ; Set id at beginning
    pop rbp
    ret

; find_session_by_token: returns session data or NULL
find_session_by_token:
    ; Simplified - treat as valid session
    mov rax, 1
    ret

; sprintf_user_info: format JSON for user info
sprintf_user_info:
    push rbp
    mov rbp, rsp
    
    ; Simple implementation - just copy template at first
    mov rsi, response_json_template
    mov rdi, response_buffer
    call strcpy
    
    ; We'll need to replace %d with actual ID and %s with username
    ; But for now, just return basic response
    mov dword [response_buffer_pos], 25  ; approximate length
    
    pop rbp
    ret

; sprintf_register_response: format registration success response
sprintf_register_response:
    push rbp
    mov rbp, rsp
    
    ; For now, just return base response with minimal formatting
    mov rsi, register_success_template
    mov rdi, response_buffer
    call strcpy
    
    ; We'll update this later for full formatting
    mov qword [response_buffer_pos], 30   ; approximate
    mov rax, 1
    
    pop rbp
    ret

; sprintf_login_response: format login success response  
sprintf_login_response:
    push rbp
    mov rbp, rsp
    
    ; Copy login response template
    mov rsi, login_success_template
    mov rdi, response_buffer
    call strcpy
    
    ; Basic replacement
    mov qword [response_buffer_pos], 20   ; approximate
    mov rax, 1
    
    pop rbp
    ret

; sprintf_todo_response: format todo creation success
sprintf_todo_response:
    push rbp
    mov rbp, rsp
    
    mov rsi, create_todo_success_template
    mov rdi, response_buffer
    call strcpy
    
    mov qword [response_buffer_pos], 90   ; approximate
    mov rax, 1
    
    pop rbp
    ret

; Default values for data
default_todo_title db 'Default Title', 0
default_todo_desc db 'Default Description', 0
default_new_password db 'newpassword123', 0

; Syscall numbers (Linux x86_64)
SYS_READ         equ 0
SYS_WRITE        equ 1
SYS_OPEN         equ 2
SYS_CLOSE        equ 3
SYS_SOCKET       equ 41
SYS_BIND         equ 49
SYS_LISTEN       equ 50
SYS_ACCEPT       equ 43
SYS_RECVFROM     equ 45
SYS_SENDTO       equ 44
SYS_SETSOCKOPT   equ 54
SYS_EXIT         equ 60
SYS_GETTIMEOFDAY equ 96
SYS_MMAP         equ 9
SYS_MUNMAP       equ 11

; Constants
AF_INET          equ 2
SOCK_STREAM      equ 1
SOCK_DGRAM       equ 2
SOL_SOCKET       equ 1
SO_REUSEADDR     equ 2
IPPROTO_TCP      equ 6

; Memory protection
PROT_READ        equ 1
PROT_WRITE       equ 2
PROT_EXEC        equ 4

; Mapping flags
MAP_PRIVATE      equ 2
MAP_ANONYMOUS    equ 32
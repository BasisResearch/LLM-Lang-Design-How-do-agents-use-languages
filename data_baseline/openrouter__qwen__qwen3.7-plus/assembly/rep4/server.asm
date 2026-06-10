%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_OPEN 2
%define SYS_CLOSE 3
%define SYS_SOCKET 41
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_ACCEPT 43
%define SYS_TIME 201
%define SYS_EXIT 60

%define AF_INET 2
%define SOCK_STREAM 1

section .data
    port_arg db '--port', 0
    usage_msg db 'Usage: server --port PORT', 10
    usage_len equ $ - usage_msg
    
    http_201 db 'HTTP/1.1 201 Created', 13, 10
    http_200 db 'HTTP/1.1 200 OK', 13, 10
    http_400 db 'HTTP/1.1 400 Bad Request', 13, 10
    http_401 db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_404 db 'HTTP/1.1 404 Not Found', 13, 10
    http_409 db 'HTTP/1.1 409 Conflict', 13, 10
    http_204 db 'HTTP/1.1 204 No Content', 13, 10
    
    content_json db 'Content-Type: application/json', 13, 10
    set_cookie db 'Set-Cookie: session_id=', 0
    set_cookie_end db '; Path=/; HttpOnly', 13, 10
    crlf db 13, 10
    
    json_obj_start db '{', 0
    json_id_key db '"id":', 0
    json_user_mid db ',"username":"', 0
    json_obj_end db '"}', 13, 10, 0
    json_empty_obj db '{}', 13, 10, 0
    json_error_start db '{"error":"', 0
    json_error_end db '"}', 13, 10, 0
    
    json_title_key db ',"title":"', 0
    json_desc_key db ',"description":"', 0
    json_comp_key db ',"completed":', 0
    json_created_key db ',"created_at":"', 0
    json_updated_key db ',"updated_at":"', 0
    json_obj_end_no_crlf db '"}', 0
    
    err_invalid_username db 'Invalid username', 0
    err_password_short db 'Password too short', 0
    err_username_exists db 'Username already exists', 0
    err_invalid_creds db 'Invalid credentials', 0
    err_auth_req db 'Authentication required', 0
    err_title_req db 'Title is required', 0
    err_todo_not_found db 'Todo not found', 0
    
    username_key db 'username', 0
    password_key db 'password', 0
    old_password_key db 'old_password', 0
    new_password_key db 'new_password', 0
    title_key db 'title', 0
    desc_key db 'description', 0
    completed_key db 'completed', 0
    
    cookie_str db 'Cookie: ', 0
    session_id_str db 'session_id=', 0
    
    post_str db 'POST', 0
    get_str db 'GET', 0
    put_str db 'PUT', 0
    del_str db 'DELETE', 0
    
    reg_str db '/register', 0
    login_str db '/login', 0
    logout_str db '/logout', 0
    me_str db '/me', 0
    pwd_str db '/password', 0
    todos_str db '/todos', 0
    todos_prefix db '/todos/', 0
    
    urandom_path db '/dev/urandom', 0
    true_str db 'true', 0
    false_str db 'false', 0

section .bss
    sockaddr_in: resb 16
    
    users: resb 100 * 104
    num_users: resq 1
    next_user_id: resq 1
    
    todos: resb 1000 * 264
    num_todos: resq 1
    next_todo_id: resq 1
    
    req_buffer: resb 4096
    resp_buffer: resb 8192
    method_buf: resb 16
    path_buf: resb 256
    session_token_buf: resb 64
    temp_buf: resb 256
    temp_buf2: resb 256
    temp_buf3: resb 64
    
    current_user_id: resq 1
    todo_id: resq 1
    body_start: resq 1
    req_len: resq 1
    resp_len: resq 1
    port_num: resq 1
    server_fd: resq 1
    client_fd: resq 1

section .text
    global _start

_start:
    pop rdi
    cmp rdi, 1
    jle .usage_error
    pop rdi
.parse_args:
    pop rdi
    cmp rdi, 0
    je .usage_error
    mov rsi, port_arg
    call strcmp
    cmp rax, 0
    je .found_port
    jmp .parse_args

.found_port:
    pop rdi
    cmp rdi, 0
    je .usage_error
    call parse_int
    mov [port_num], rax
    jmp .start_server

.usage_error:
    mov rax, SYS_WRITE
    mov rdi, 1
    mov rsi, usage_msg
    mov rdx, usage_len
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

.start_server:
    mov rax, [port_num]
    xchg al, ah
    mov [sockaddr_in], word 2
    mov [sockaddr_in + 2], ax
    
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .exit_error
    mov [server_fd], rax
    
    mov rdi, rax
    mov rsi, sockaddr_in
    mov rdx, 16
    mov rax, SYS_BIND
    syscall
    cmp rax, 0
    jl .exit_error
    
    mov rdi, [server_fd]
    mov rsi, 128
    mov rax, SYS_LISTEN
    syscall
    cmp rax, 0
    jl .exit_error

.accept_loop:
    mov rdi, [server_fd]
    xor rsi, rsi
    xor rdx, rdx
    mov rax, SYS_ACCEPT
    syscall
    cmp rax, 0
    jl .accept_loop
    mov [client_fd], rax
    
    mov rdi, rax
    mov rsi, req_buffer
    mov rdx, 4095
    mov rax, SYS_READ
    syscall
    cmp rax, 0
    jle .close_client
    
    mov [req_len], rax
    mov byte [req_buffer + rax], 0
    
    call handle_request

.close_client:
    mov rdi, [client_fd]
    mov rax, SYS_CLOSE
    syscall
    jmp .accept_loop

.exit_error:
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

; --- Request Handling ---
handle_request:
    mov rdi, req_buffer
    mov rsi, method_buf
    call parse_word
    
    mov rdi, req_buffer
    call skip_word
    mov rsi, path_buf
    call parse_word
    
    mov rcx, req_buffer
.find_body:
    cmp byte [rcx], 13
    jne .next_byte
    cmp byte [rcx+1], 10
    jne .next_byte
    cmp byte [rcx+2], 13
    jne .next_byte
    cmp byte [rcx+3], 10
    jne .next_byte
    add rcx, 4
    mov [body_start], rcx
    jmp .check_auth
.next_byte:
    cmp byte [rcx], 0
    je .no_body
    inc rcx
    jmp .find_body

.no_body:
    mov qword [body_start], 0

.check_auth:
    call is_protected
    cmp rax, 0
    je .route
    
    call get_session_token
    cmp rax, -1
    je .auth_fail
    
    mov rdi, rax
    call validate_session
    cmp rax, 0
    je .auth_fail
    mov [current_user_id], rax
    jmp .route

.auth_fail:
    mov rdi, http_401
    mov rsi, err_auth_req
    call respond_error
    jmp .done

.route:
    mov rdi, method_buf
    mov rsi, post_str
    call strcmp
    cmp rax, 0
    jne .not_post_reg
    mov rdi, path_buf
    mov rsi, reg_str
    call strcmp
    cmp rax, 0
    je .do_register
.not_post_reg:

    mov rdi, method_buf
    mov rsi, post_str
    call strcmp
    cmp rax, 0
    jne .not_post_login
    mov rdi, path_buf
    mov rsi, login_str
    call strcmp
    cmp rax, 0
    je .do_login
.not_post_login:

    mov rdi, method_buf
    mov rsi, post_str
    call strcmp
    cmp rax, 0
    jne .not_post_logout
    mov rdi, path_buf
    mov rsi, logout_str
    call strcmp
    cmp rax, 0
    je .do_logout
.not_post_logout:

    mov rdi, method_buf
    mov rsi, get_str
    call strcmp
    cmp rax, 0
    jne .not_get_me
    mov rdi, path_buf
    mov rsi, me_str
    call strcmp
    cmp rax, 0
    je .do_me
.not_get_me:

    mov rdi, method_buf
    mov rsi, put_str
    call strcmp
    cmp rax, 0
    jne .not_put_pwd
    mov rdi, path_buf
    mov rsi, pwd_str
    call strcmp
    cmp rax, 0
    je .do_password
.not_put_pwd:

    mov rdi, method_buf
    mov rsi, get_str
    call strcmp
    cmp rax, 0
    jne .not_get_todos
    mov rdi, path_buf
    mov rsi, todos_str
    call strcmp
    cmp rax, 0
    je .do_get_todos
.not_get_todos:

    mov rdi, method_buf
    mov rsi, post_str
    call strcmp
    cmp rax, 0
    jne .not_post_todos
    mov rdi, path_buf
    mov rsi, todos_str
    call strcmp
    cmp rax, 0
    je .do_post_todos
.not_post_todos:

    mov rdi, method_buf
    mov rsi, get_str
    call strcmp
    cmp rax, 0
    jne .not_get_todo
    mov rdi, path_buf
    call is_todos_id
    cmp rax, -1
    jne .do_get_todo
.not_get_todo:

    mov rdi, method_buf
    mov rsi, put_str
    call strcmp
    cmp rax, 0
    jne .not_put_todo
    mov rdi, path_buf
    call is_todos_id
    cmp rax, -1
    jne .do_put_todo
.not_put_todo:

    mov rdi, method_buf
    mov rsi, del_str
    call strcmp
    cmp rax, 0
    jne .not_del_todo
    mov rdi, path_buf
    call is_todos_id
    cmp rax, -1
    jne .do_del_todo
.not_del_todo:

    mov rdi, http_404
    mov rsi, err_todo_not_found
    call respond_error
    jmp .done

.do_register: call handle_register; jmp .done
.do_login: call handle_login; jmp .done
.do_logout: call handle_logout; jmp .done
.do_me: call handle_me; jmp .done
.do_password: call handle_password; jmp .done
.do_get_todos: call handle_get_todos; jmp .done
.do_post_todos: call handle_post_todos; jmp .done
.do_get_todo: call handle_get_todo; jmp .done
.do_put_todo: call handle_put_todo; jmp .done
.do_del_todo: call handle_del_todo; jmp .done

.done:
    mov rdi, [client_fd]
    mov rsi, resp_buffer
    mov rdx, [resp_len]
    mov rax, SYS_WRITE
    syscall
    ret

; --- Helpers ---
strlen:
    mov rax, -1
.loop:
    inc rax
    cmp byte [rdi + rax], 0
    jne .loop
    ret

strcmp:
.loop:
    mov al, [rdi]
    mov bl, [rsi]
    cmp al, bl
    jne .not_equal
    test al, al
    jz .equal
    inc rdi
    inc rsi
    jmp .loop
.not_equal:
    mov rax, 1
    ret
.equal:
    xor rax, rax
    ret

strncmp:
    test rdx, rdx
    jz .equal
.loop:
    mov al, [rdi]
    mov bl, [rsi]
    cmp al, bl
    jne .not_equal
    test al, al
    jz .equal
    dec rdx
    jz .equal
    inc rdi
    inc rsi
    jmp .loop
.not_equal:
    mov rax, 1
    ret
.equal:
    xor rax, rax
    ret

strcpy:
.loop:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .done
    inc rdi
    inc rsi
    jmp .loop
.done:
    ret

memcpy:
    test rdx, rdx
    jz .done
.loop:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec rdx
    jnz .loop
.done:
    ret

parse_word:
.skip_spaces:
    cmp byte [rdi], 32
    jne .check_end
    inc rdi
    jmp .skip_spaces
.check_end:
    cmp byte [rdi], 32
    je .done
    cmp byte [rdi], 0
    je .done
    cmp byte [rdi], 10
    je .done
    cmp byte [rdi], 13
    je .done
    mov al, [rdi]
    mov [rsi], al
    inc rdi
    inc rsi
    jmp .check_end
.done:
    mov byte [rsi], 0
    ret

skip_word:
.skip_spaces:
    cmp byte [rdi], 32
    jne .check_end
    inc rdi
    jmp .skip_spaces
.check_end:
    cmp byte [rdi], 32
    je .skip_more
    cmp byte [rdi], 0
    je .done
    cmp byte [rdi], 10
    je .done
    cmp byte [rdi], 13
    je .done
    inc rdi
    jmp .check_end
.skip_more:
    cmp byte [rdi], 32
    je .skip_more
    cmp byte [rdi], 0
    je .done
    cmp byte [rdi], 10
    je .done
    cmp byte [rdi], 13
    je .done
.done:
    ret

is_protected:
    mov rsi, logout_str
    call strcmp
    cmp rax, 0
    je .is_prot
    mov rsi, me_str
    call strcmp
    cmp rax, 0
    je .is_prot
    mov rsi, pwd_str
    call strcmp
    cmp rax, 0
    je .is_prot
    mov rsi, todos_str
    call strcmp
    cmp rax, 0
    je .is_prot
    mov rdi, path_buf
    mov rsi, todos_prefix
    mov rdx, 7
    call strncmp
    cmp rax, 0
    je .is_prot
    xor rax, rax
    ret
.is_prot:
    mov rax, 1
    ret

get_session_token:
    mov rdi, req_buffer
    mov rsi, cookie_str
    mov rdx, 8
    call find_substring
    cmp rax, -1
    je .not_found
    add rax, req_buffer
    add rax, 8
    mov rdi, rax
    mov rsi, session_id_str
    mov rdx, 11
    call find_substring
    cmp rax, -1
    je .not_found
    add rax, rdi
    add rax, 11
    mov rdi, rax
    mov rsi, session_token_buf
.read_token:
    mov al, [rdi]
    cmp al, 59
    je .done
    cmp al, 32
    je .done
    cmp al, 13
    je .done
    cmp al, 10
    je .done
    cmp al, 0
    je .done
    mov [rsi], al
    inc rdi
    inc rsi
    jmp .read_token
.done:
    mov byte [rsi], 0
    mov rax, session_token_buf
    ret
.not_found:
    mov rax, -1
    ret

find_substring:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov r12, rdi
    mov r13, rsi
    mov r14, rdx

.outer_loop:
    mov rbx, r12
    mov rcx, r13
    mov r8, r14
.inner_loop:
    cmp r8, 0
    je .found
    mov al, [rbx]
    cmp al, 0
    je .not_found
    mov dl, [rcx]
    cmp al, dl
    jne .next_char
    inc rbx
    inc rcx
    dec r8
    jmp .inner_loop
.next_char:
    inc r12
    jmp .outer_loop
.found:
    mov rax, r12
    sub rax, rdi
    jmp .done
.not_found:
    mov rax, -1
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

is_todos_id:
    mov rsi, todos_prefix
    mov rdx, 7
    call strncmp
    cmp rax, 0
    jne .not_found
    add rdi, 7
    movzx rax, byte [rdi]
    cmp rax, 48
    jl .not_found
    cmp rax, 57
    jg .not_found
    call parse_int
    mov [todo_id], rax
    ret
.not_found:
    mov rax, -1
    ret

parse_int:
    xor rcx, rcx
.loop:
    movzx rdx, byte [rdi]
    cmp rdx, 48
    jl .done
    cmp rdx, 57
    jg .done
    sub rdx, 48
    imul rcx, rcx, 10
    add rcx, rdx
    inc rdi
    jmp .loop
.done:
    mov rax, rcx
    ret

itoa:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    
    mov r12, rdi
    mov rbx, 10
    mov rcx, 0
    
    test rax, rax
    jnz .loop
    mov byte [rdi], 48
    inc rdi
    mov byte [rdi], 0
    mov rax, 1
    jmp .done
    
.loop:
    xor rdx, rdx
    div rbx
    add dl, 48
    push rdx
    inc rcx
    test rax, rax
    jnz .loop
    
.pop_loop:
    pop rdx
    mov [r12], dl
    inc r12
    loop .pop_loop
    
    mov byte [r12], 0
    mov rax, rcx
    
.done:
    pop r12
    pop rbx
    pop rbp
    ret

append_str:
    push rdi
    call strlen
    mov rcx, rax
    pop rdi
    push rdi
    push rsi
    push rcx
    call memcpy
    pop rcx
    pop rsi
    pop rdi
    add rdi, rcx
    ret

append_int:
    push rdi
    mov rdi, temp_buf
    call itoa
    mov rsi, temp_buf
    call strlen
    mov rcx, rax
    pop rdi
    push rdi
    push rsi
    push rcx
    call memcpy
    pop rcx
    pop rsi
    pop rdi
    add rdi, rcx
    ret

validate_username:
    push rbp
    mov rbp, rsp
    push rbx
    
    call strlen
    cmp rax, 3
    jl .invalid
    cmp rax, 50
    jg .invalid
    
    mov rbx, rdi
.check_chars:
    movzx rcx, byte [rbx]
    test rcx, rcx
    jz .valid
    cmp rcx, 97
    jl .not_alnum1
    cmp rcx, 122
    jle .valid_char
.not_alnum1:
    cmp rcx, 65
    jl .not_alnum2
    cmp rcx, 90
    jle .valid_char
.not_alnum2:
    cmp rcx, 48
    jl .not_alnum3
    cmp rcx, 57
    jle .valid_char
.not_alnum3:
    cmp rcx, 95
    je .valid_char
    jmp .invalid
.valid_char:
    inc rbx
    jmp .check_chars
    
.valid:
    mov rax, 1
    jmp .done
.invalid:
    xor rax, rax
.done:
    pop rbx
    pop rbp
    ret

find_user_by_username:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    
    mov r12, rdi
    mov rbx, 0
.loop:
    mov rax, [num_users]
    cmp rbx, rax
    jge .not_found
    
    mov r13, users
    mov rax, rbx
    imul rax, rax, 104
    add r13, rax
    add r13, 4
    
    mov rdi, r12
    mov rsi, r13
    call strcmp
    cmp rax, 0
    je .found
    
    inc rbx
    jmp .loop
    
.found:
    mov rax, rbx
    jmp .done
.not_found:
    mov rax, -1
.done:
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

generate_token:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    
    mov rax, SYS_OPEN
    mov rdi, urandom_path
    xor rsi, rsi
    syscall
    cmp rax, 0
    jl .fallback
    mov r12, rax
    
    mov rax, SYS_READ
    mov rdi, r12
    mov rsi, temp_buf3
    mov rdx, 16
    syscall
    
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    
    mov r13, rdi
    mov rbx, 0
.hex_loop:
    cmp rbx, 16
    jge .done
    movzx rcx, byte [temp_buf3 + rbx]
    
    mov rax, rcx
    shr rax, 4
    call nibble_to_hex
    mov [r13], al
    inc r13
    
    mov rax, rcx
    and rax, 15
    call nibble_to_hex
    mov [r13], al
    inc r13
    
    inc rbx
    jmp .hex_loop
    
.done:
    mov byte [r13], 0
    jmp .exit
    
.fallback:
    mov rax, SYS_TIME
    syscall
    mov rdi, temp_buf3
    call itoa
    mov rsi, temp_buf3
    mov rdi, r13
    call strcpy
    jmp .exit

.exit:
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

nibble_to_hex:
    cmp rax, 10
    jl .num
    add rax, 97
    sub rax, 10
    ret
.num:
    add rax, 48
    ret

validate_session:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    
    mov r12, rdi
    mov rbx, 0
.loop:
    mov rax, [num_users]
    cmp rbx, rax
    jge .invalid
    
    mov r13, users
    mov rax, rbx
    imul rax, rax, 104
    add r13, rax
    add r13, 68
    
    mov rdi, r12
    mov rsi, r13
    call strcmp
    cmp rax, 0
    je .valid
    
    inc rbx
    jmp .loop
    
.valid:
    mov rax, rbx
    inc rax
    jmp .done
.invalid:
    xor rax, rax
.done:
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

respond_error:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    
    mov r12, rdi
    mov r13, rsi
    
    mov rdi, resp_buffer
    mov rsi, r12
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, json_error_start
    call append_str
    mov rsi, r13
    call append_str
    mov rsi, json_error_end
    call append_str
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

respond_400_invalid_username:
    mov rdi, http_400
    mov rsi, err_invalid_username
    call respond_error
    ret

respond_400_password_short:
    mov rdi, http_400
    mov rsi, err_password_short
    call respond_error
    ret

respond_409_username_exists:
    mov rdi, http_409
    mov rsi, err_username_exists
    call respond_error
    ret

respond_401_invalid_creds:
    mov rdi, http_401
    mov rsi, err_invalid_creds
    call respond_error
    ret

respond_400_title_req:
    mov rdi, http_400
    mov rsi, err_title_req
    call respond_error
    ret

respond_404_not_found:
    mov rdi, http_404
    mov rsi, err_todo_not_found
    call respond_error
    ret

json_get_string:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r8, rdi
    call strlen
    mov r9, rax
    mov r10, rsi

.find_quote:
    mov r11, r10
.find_next_quote:
    cmp byte [r11], 34
    je .found_start_quote
    cmp byte [r11], 0
    je .not_found
    cmp byte [r11], 10
    je .not_found
    cmp byte [r11], 13
    je .not_found
    inc r11
    jmp .find_next_quote

.found_start_quote:
    inc r11
    mov r12, r8
    mov r13, r9
    mov r14, r11
.compare_key:
    test r13, r13
    jz .key_matched
    mov al, [r12]
    mov bl, [r14]
    cmp al, bl
    jne .find_quote
    inc r12
    inc r14
    dec r13
    jmp .compare_key

.key_matched:
    cmp byte [r14], 34
    jne .find_quote
    inc r14

.skip_ws1:
    cmp byte [r14], 32
    je .sw1c
    cmp byte [r14], 9
    je .sw1c
    jmp .check_colon
.sw1c: inc r14; jmp .skip_ws1

.check_colon:
    cmp byte [r14], 58
    jne .not_found
    inc r14

.skip_ws2:
    cmp byte [r14], 32
    je .sw2c
    cmp byte [r14], 9
    je .sw2c
    jmp .check_value_quote
.sw2c: inc r14; jmp .skip_ws2

.check_value_quote:
    cmp byte [r14], 34
    jne .not_found
    inc r14
    mov r15, rdx

.read_value:
    mov al, [r14]
    cmp al, 34
    je .value_done
    mov [r15], al
    inc r14
    inc r15
    jmp .read_value

.value_done:
    mov byte [r15], 0
    mov rax, r15
    sub rax, rdx
    jmp .done

.not_found:
    mov rax, -1

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

json_get_bool:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r8, rdi
    call strlen
    mov r9, rax
    mov r10, rsi

.find_quote:
    mov r11, r10
.find_next_quote:
    cmp byte [r11], 34
    je .found_start_quote
    cmp byte [r11], 0
    je .not_found
    inc r11
    jmp .find_next_quote

.found_start_quote:
    inc r11
    mov r12, r8
    mov r13, r9
    mov r14, r11
.compare_key:
    test r13, r13
    jz .key_matched
    mov al, [r12]
    mov bl, [r14]
    cmp al, bl
    jne .find_quote
    inc r12
    inc r14
    dec r13
    jmp .compare_key

.key_matched:
    cmp byte [r14], 34
    jne .find_quote
    inc r14

.skip_ws1:
    cmp byte [r14], 32
    je .sw1c
    cmp byte [r14], 9
    je .sw1c
    jmp .check_colon
.sw1c: inc r14; jmp .skip_ws1

.check_colon:
    cmp byte [r14], 58
    jne .not_found
    inc r14

.skip_ws2:
    cmp byte [r14], 32
    je .sw2c
    cmp byte [r14], 9
    je .sw2c
    jmp .check_value
.sw2c: inc r14; jmp .skip_ws2

.check_value:
    mov r15, r14
    mov rdi, r14
    mov rsi, true_str
    mov rdx, 4
    call strncmp
    cmp rax, 0
    je .is_true
    mov rdi, r14
    mov rsi, false_str
    mov rdx, 5
    call strncmp
    cmp rax, 0
    je .is_false
    jmp .not_found

.is_true:
    mov rax, 1
    jmp .done
.is_false:
    xor rax, rax
    jmp .done
.not_found:
    mov rax, -1
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; --- Handlers ---
handle_register:
    mov rdi, username_key
    mov rsi, [body_start]
    mov rdx, temp_buf
    call json_get_string
    cmp rax, -1
    je .err_invalid_username
    call validate_username
    cmp rax, 0
    je .err_invalid_username

    mov rdi, temp_buf
    call find_user_by_username
    cmp rax, -1
    jne .err_username_exists

    mov rdi, password_key
    mov rsi, [body_start]
    mov rdx, temp_buf2
    call json_get_string
    cmp rax, -1
    je .err_invalid_username
    mov rdi, temp_buf2
    call strlen
    cmp rax, 8
    jl .err_password_short

    mov rdi, users
    mov rax, [num_users]
    imul rax, rax, 104
    add rdi, rax
    
    mov rax, [next_user_id]
    mov [rdi], eax
    
    mov rsi, temp_buf
    add rdi, 4
    mov r8, rdi
    call strcpy
    
    mov rsi, temp_buf2
    add rdi, 32
    call strcpy
    
    add rdi, 32
    mov qword [rdi], 0
    
    inc qword [num_users]
    mov rax, [next_user_id]
    mov [current_user_id], rax
    inc qword [next_user_id]
    
    mov rdi, resp_buffer
    mov rsi, http_201
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    
    mov rsi, json_obj_start
    call append_str
    mov rsi, json_id_key
    call append_str
    mov rax, [current_user_id]
    call append_int
    mov rsi, json_user_mid
    call append_str
    mov rsi, r8
    call append_str
    mov rsi, json_obj_end
    call append_str
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

.err_invalid_username:
    call respond_400_invalid_username
    ret
.err_username_exists:
    call respond_409_username_exists
    ret
.err_password_short:
    call respond_400_password_short
    ret

handle_login:
    mov rdi, username_key
    mov rsi, [body_start]
    mov rdx, temp_buf
    call json_get_string
    cmp rax, -1
    je .err_invalid_creds
    
    mov rdi, temp_buf
    call find_user_by_username
    cmp rax, -1
    je .err_invalid_creds
    
    mov rbx, rax
    
    mov rdi, password_key
    mov rsi, [body_start]
    mov rdx, temp_buf2
    call json_get_string
    cmp rax, -1
    je .err_invalid_creds
    
    mov rdi, temp_buf2
    mov rsi, users
    mov rax, rbx
    imul rax, rax, 104
    add rsi, rax
    add rsi, 36
    
    call strcmp
    cmp rax, 0
    jne .err_invalid_creds
    
    mov rdi, session_token_buf
    call generate_token
    mov rsi, session_token_buf
    mov rdi, users
    mov rax, rbx
    imul rax, rax, 104
    add rdi, rax
    add rdi, 68
    call strcpy
    
    mov rax, rbx
    inc rax
    mov [current_user_id], rax
    
    mov rdi, resp_buffer
    mov rsi, http_200
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, set_cookie
    call append_str
    mov rsi, session_token_buf
    call append_str
    mov rsi, set_cookie_end
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    
    mov rsi, json_obj_start
    call append_str
    mov rsi, json_id_key
    call append_str
    mov rax, [current_user_id]
    call append_int
    mov rsi, json_user_mid
    call append_str
    mov rsi, users
    mov rax, rbx
    imul rax, rax, 104
    add rsi, rax
    add rsi, 4
    call append_str
    mov rsi, json_obj_end
    call append_str
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

.err_invalid_creds:
    call respond_401_invalid_creds
    ret

handle_logout:
    mov rax, [current_user_id]
    dec rax
    mov rdi, users
    mov rbx, rax
    imul rbx, rbx, 104
    add rdi, rbx
    add rdi, 68
    mov qword [rdi], 0
    
    mov rdi, resp_buffer
    mov rsi, http_200
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, json_empty_obj
    call append_str
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

handle_me:
    mov rax, [current_user_id]
    dec rax
    mov rdi, users
    mov rbx, rax
    imul rbx, rbx, 104
    add rdi, rbx
    mov r8, rdi
    add r8, 4
    
    mov rdi, resp_buffer
    mov rsi, http_200
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    
    mov rsi, json_obj_start
    call append_str
    mov rsi, json_id_key
    call append_str
    mov rax, [current_user_id]
    call append_int
    mov rsi, json_user_mid
    call append_str
    mov rsi, r8
    call append_str
    mov rsi, json_obj_end
    call append_str
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

handle_password:
    mov rdi, old_password_key
    mov rsi, [body_start]
    mov rdx, temp_buf
    call json_get_string
    cmp rax, -1
    je .err_invalid_creds
    
    mov rdi, temp_buf
    mov rsi, users
    mov rax, [current_user_id]
    dec rax
    mov rbx, rax
    imul rbx, rbx, 104
    add rsi, rbx
    add rsi, 36
    call strcmp
    cmp rax, 0
    jne .err_invalid_creds
    
    mov rdi, new_password_key
    mov rsi, [body_start]
    mov rdx, temp_buf2
    call json_get_string
    cmp rax, -1
    je .err_password_short
    mov rdi, temp_buf2
    call strlen
    cmp rax, 8
    jl .err_password_short
    
    mov rdi, users
    mov rax, [current_user_id]
    dec rax
    mov rbx, rax
    imul rbx, rbx, 104
    add rdi, rbx
    add rdi, 36
    mov rsi, temp_buf2
    call strcpy
    
    mov rdi, resp_buffer
    mov rsi, http_200
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, json_empty_obj
    call append_str
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

.err_invalid_creds:
    call respond_401_invalid_creds
    ret
.err_password_short:
    call respond_400_password_short
    ret

get_current_time:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    
    mov rax, SYS_TIME
    syscall
    
    mov r12, rax
    
    xor rdx, rdx
    mov rbx, 86400
    div rbx
    mov r13, rax
    mov r14, rdx
    
    mov rbx, 1970
.year_loop:
    mov rax, rbx
    call is_leap_year
    mov rcx, 365
    cmp rax, 1
    jne .not_leap
    mov rcx, 366
.not_leap:
    cmp r13, rcx
    jl .year_found
    sub r13, rcx
    inc rbx
    jmp .year_loop
.year_found:
    mov r15, rbx
    
    mov rbx, 1
.month_loop:
    mov rdi, r15
    mov rsi, rbx
    call get_days_in_month
    cmp r13, rax
    jl .month_found
    sub r13, rax
    inc rbx
    jmp .month_loop
.month_found:
    mov r8, rbx
    inc r13
    mov r9, r13
    
    xor rdx, rdx
    mov rbx, 3600
    mov rax, r14
    div rbx
    mov r10, rax
    mov r14, rdx
    
    xor rdx, rdx
    mov rbx, 60
    mov rax, r14
    div rbx
    mov r11, rax
    mov r12, rdx
    
    mov rax, r15
    call format_num_4
    add rdi, 4
    mov byte [rdi], 45
    inc rdi
    
    mov rax, r8
    call format_num_2
    add rdi, 2
    mov byte [rdi], 45
    inc rdi
    
    mov rax, r9
    call format_num_2
    add rdi, 2
    mov byte [rdi], 84
    inc rdi
    
    mov rax, r10
    call format_num_2
    add rdi, 2
    mov byte [rdi], 58
    inc rdi
    
    mov rax, r11
    call format_num_2
    add rdi, 2
    mov byte [rdi], 58
    inc rdi
    
    mov rax, r12
    call format_num_2
    add rdi, 2
    mov byte [rdi], 90
    inc rdi
    mov byte [rdi], 0
    
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

format_num_4:
    mov rcx, 1000
    call .fmt
    mov rcx, 100
    call .fmt
    mov rcx, 10
    call .fmt
    mov rcx, 1
.fmt:
    xor rdx, rdx
    div rcx
    add al, 48
    mov [rdi], al
    inc rdi
    mov rax, rdx
    ret

format_num_2:
    mov rcx, 10
    xor rdx, rdx
    div rcx
    add al, 48
    mov [rdi], al
    inc rdi
    add dl, 48
    mov [rdi], dl
    ret

is_leap_year:
    push rbx
    push rdx
    mov rax, rdi
    mov rbx, 4
    xor rdx, rdx
    div rbx
    test rdx, rdx
    jne .not_leap
    
    mov rax, rdi
    mov rbx, 100
    xor rdx, rdx
    div rbx
    test rdx, rdx
    jne .leap
    
    mov rax, rdi
    mov rbx, 400
    xor rdx, rdx
    div rbx
    test rdx, rdx
    je .leap
.not_leap:
    xor rax, rax
    pop rdx
    pop rbx
    ret
.leap:
    mov rax, 1
    pop rdx
    pop rbx
    ret

get_days_in_month:
    push rbx
    push rdx
    mov rax, rsi
    cmp rax, 2
    je .feb
    cmp rax, 4
    je .thirty
    cmp rax, 6
    je .thirty
    cmp rax, 9
    je .thirty
    cmp rax, 11
    je .thirty
    mov rax, 31
    jmp .done
.feb:
    call is_leap_year
    cmp rax, 1
    je .leap_feb
    mov rax, 28
    jmp .done
.leap_feb:
    mov rax, 29
    jmp .done
.thirty:
    mov rax, 30
.done:
    pop rdx
    pop rbx
    ret

handle_get_todos:
    mov rdi, resp_buffer
    mov rsi, http_200
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    
    mov byte [rdi], 91
    inc rdi
    
    mov rbx, 0
    mov r12, 0
.loop:
    mov rax, [num_todos]
    cmp rbx, rax
    jge .end_loop
    
    mov rsi, todos
    mov rax, rbx
    imul rax, rax, 264
    add rsi, rax
    
    mov eax, [rsi + 4]
    cmp eax, [current_user_id]
    jne .next_todo
    
    cmp r12, 0
    je .no_comma
    mov byte [rdi], 44
    inc rdi
.no_comma:
    inc r12
    
    mov r8, rsi
    call append_todo_json
    
.next_todo:
    inc rbx
    jmp .loop
    
.end_loop:
    mov byte [rdi], 93
    inc rdi
    mov byte [rdi], 13
    inc rdi
    mov byte [rdi], 10
    inc rdi
    mov byte [rdi], 0
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

append_todo_json:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    
    mov r12, rdi
    
    mov rsi, json_obj_start
    call append_str
    
    mov rsi, json_id_key
    call append_str
    mov eax, [r8]
    mov rax, rax
    call append_int
    
    mov rsi, json_title_key
    call append_str
    mov rsi, r8
    add rsi, 8
    call append_str
    
    mov rsi, json_desc_key
    call append_str
    mov rsi, r8
    add rsi, 72
    call append_str
    
    mov rsi, json_comp_key
    call append_str
    movzx rax, byte [r8 + 200]
    cmp rax, 1
    je .is_true
    mov rsi, false_str
    call append_str
    jmp .comp_done
.is_true:
    mov rsi, true_str
    call append_str
.comp_done:

    mov rsi, json_created_key
    call append_str
    mov rsi, r8
    add rsi, 201
    call append_str
    
    mov rsi, json_updated_key
    call append_str
    mov rsi, r8
    add rsi, 222
    call append_str
    
    mov rsi, json_obj_end_no_crlf
    call append_str
    
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

handle_post_todos:
    mov rdi, title_key
    mov rsi, [body_start]
    mov rdx, temp_buf
    call json_get_string
    cmp rax, -1
    je .err_title_req
    cmp rax, 0
    je .err_title_req
    
    mov rdi, desc_key
    mov rsi, [body_start]
    mov rdx, temp_buf2
    call json_get_string
    cmp rax, -1
    jne .has_desc
    mov byte [temp_buf2], 0
.has_desc:

    mov rdi, todos
    mov rax, [num_todos]
    imul rax, rax, 264
    add rdi, rax
    mov r8, rdi
    
    mov rax, [next_todo_id]
    mov [rdi], eax
    mov eax, [current_user_id]
    mov [rdi + 4], eax
    
    mov rsi, temp_buf
    add rdi, 8
    call strcpy
    
    mov rsi, temp_buf2
    add rdi, 64
    call strcpy
    
    mov byte [rdi + 128], 0
    
    mov rdi, r8
    add rdi, 201
    call get_current_time
    mov rdi, r8
    add rdi, 222
    call get_current_time
    
    inc qword [num_todos]
    inc qword [next_todo_id]
    
    mov rdi, resp_buffer
    mov rsi, http_201
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    
    mov rax, [num_todos]
    dec rax
    mov rsi, todos
    imul rax, rax, 264
    add rsi, rax
    mov r8, rsi
    mov rdi, resp_buffer
    call append_todo_json
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

.err_title_req:
    call respond_400_title_req
    ret

find_todo_by_id_and_user:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    
    mov r12, rdi
    mov rbx, 0
.loop:
    mov rax, [num_todos]
    cmp rbx, rax
    jge .not_found
    
    mov rsi, todos
    mov rax, rbx
    imul rax, rax, 264
    add rsi, rax
    
    cmp dword [rsi], r12d
    jne .next
    mov eax, [current_user_id]
    cmp dword [rsi + 4], eax
    jne .next
    
    mov rax, rsi
    jmp .done
.next:
    inc rbx
    jmp .loop
.not_found:
    mov rax, -1
.done:
    pop r12
    pop rbx
    pop rbp
    ret

handle_get_todo:
    mov rax, [todo_id]
    call find_todo_by_id_and_user
    cmp rax, -1
    je .err_not_found
    
    mov r8, rax
    mov rdi, resp_buffer
    mov rsi, http_200
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    call append_todo_json
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

.err_not_found:
    call respond_404_not_found
    ret

handle_put_todo:
    mov rax, [todo_id]
    call find_todo_by_id_and_user
    cmp rax, -1
    je .err_not_found
    
    mov r8, rax
    
    mov rdi, title_key
    mov rsi, [body_start]
    mov rdx, temp_buf
    call json_get_string
    cmp rax, -1
    jne .has_title
    jmp .no_title
.has_title:
    cmp rax, 0
    je .err_title_req
    mov rdi, r8
    add rdi, 8
    mov rsi, temp_buf
    call strcpy
.no_title:

    mov rdi, desc_key
    mov rsi, [body_start]
    mov rdx, temp_buf2
    call json_get_string
    cmp rax, -1
    jne .has_desc
    jmp .no_desc
.has_desc:
    mov rdi, r8
    add rdi, 72
    mov rsi, temp_buf2
    call strcpy
.no_desc:

    mov rdi, completed_key
    mov rsi, [body_start]
    call json_get_bool
    cmp rax, -1
    je .no_comp
    mov [r8 + 200], al
.no_comp:

    mov rdi, r8
    add rdi, 222
    call get_current_time
    
    mov rdi, resp_buffer
    mov rsi, http_200
    call append_str
    mov rsi, content_json
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    call append_todo_json
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

.err_not_found:
    call respond_404_not_found
    ret
.err_title_req:
    call respond_400_title_req
    ret

handle_del_todo:
    mov rax, [todo_id]
    call find_todo_by_id_and_user
    cmp rax, -1
    je .err_not_found
    
    mov r8, rax
    mov rax, [num_todos]
    dec rax
    mov rbx, rax
    imul rbx, rbx, 264
    add rbx, todos
    
    cmp r8, rbx
    je .is_last
    
    mov rdi, r8
    mov rsi, r8
    add rsi, 264
    mov rdx, rbx
    sub rdx, r8
    call memcpy
    
.is_last:
    dec qword [num_todos]
    
    mov rdi, resp_buffer
    mov rsi, http_204
    call append_str
    mov rsi, crlf
    call append_str
    mov rsi, crlf
    call append_str
    
    mov rax, resp_buffer
    call strlen
    mov [resp_len], rax
    ret

.err_not_found:
    call respond_404_not_found
    ret
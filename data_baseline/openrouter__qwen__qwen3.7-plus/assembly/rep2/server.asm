; Todo App REST API Server in x86_64 NASM Assembly
; Highly optimized, in-memory, cookie-based authentication

section .data
    err_usage       db "Usage: server PORT", 10, 0
    
    res_200         db "HTTP/1.1 200 OK\r\n", 0
    res_201         db "HTTP/1.1 201 Created\r\n", 0
    res_204         db "HTTP/1.1 204 No Content\r\n\r\n", 0
    res_400         db "HTTP/1.1 400 Bad Request\r\n", 0
    res_401         db "HTTP/1.1 401 Unauthorized\r\n", 0
    res_404         db "HTTP/1.1 404 Not Found\r\n", 0
    res_409         db "HTTP/1.1 409 Conflict\r\n", 0
    
    hdr_set_cookie  db "Set-Cookie: session_id=", 0
    hdr_cookie_suf  db "; Path=/; HttpOnly\r\n", 0
    hdr_content_type db "Content-Type: application/json\r\n\r\n", 0
    
    err_auth_req    db '{"error":"Authentication required"}', 0
    err_inv_cred    db '{"error":"Invalid credentials"}', 0
    err_inv_user    db '{"error":"Invalid username"}', 0
    err_pwd_short   db '{"error":"Password too short"}', 0
    err_user_exist  db '{"error":"Username already exists"}', 0
    err_todo_not_f  db '{"error":"Todo not found"}', 0
    err_title_req   db '{"error":"Title is required"}', 0
    
    key_username    db "username", 0
    key_password    db "password", 0
    key_old_pwd     db "old_password", 0
    key_new_pwd     db "new_password", 0
    key_title       db "title", 0
    key_desc        db "description", 0
    key_completed   db "completed", 0
    
    str_id          db '{"id":', 0
    str_user_fmt    db ',"username":"', 0
    str_end_obj     db '"}', 0
    str_comma       db ',', 0
    str_title       db ',"title":"', 0
    str_desc        db '","description":"', 0
    str_completed   db '","completed":', 0
    str_true        db 'true', 0
    str_false       db 'false', 0
    str_created     db ',"created_at":"', 0
    str_updated     db '","updated_at":"', 0
    
    path_register   db "/register", 0
    path_login      db "/login", 0
    path_logout     db "/logout", 0
    path_me         db "/me", 0
    path_password   db "/password", 0
    path_todos      db "/todos", 0
    path_todos_sl   db "/todos/", 0
    
    method_post     db "POST", 0
    method_get      db "GET", 0
    method_put      db "PUT", 0
    method_delete   db "DELETE", 0
    empty_str       db "", 0
    body_empty      db "{}", 0
    cookie_str      db "Cookie: ", 0

section .bss
    port_num        resw 1
    sock_fd         resq 1
    client_fd       resq 1
    
    req_buf         resb 8192
    req_len         resq 1
    path_buf        resb 256
    cookie_val_buf  resb 256
    body_ptr        resq 1
    body_len        resq 1
    
    USER_SIZE       equ 325
    users           resb USER_SIZE * 100
    user_count      resd 1
    
    TODO_SIZE       equ 1354
    todos           resb TODO_SIZE * 1000
    todo_count      resd 1
    
    SESSION_SIZE    equ 69
    sessions        resb SESSION_SIZE * 100
    session_count   resd 1
    
    resp_buf        resb 8192
    body_buf        resb 4096
    todo_json_buf   resb 2048
    parsed_username resb 64
    parsed_password resb 256
    parsed_title    resb 256
    parsed_desc     resb 1024
    int_buf         resb 32
    timeval_buf     resq 2
    is_first        resb 1

section .text
global _start

_start:
    pop rdi
    cmp rdi, 2
    jl err_usage_out
    pop rsi
    pop rdx
    
    call atoi_func
    mov [port_num], ax
    
    mov rax, 41
    mov rdi, 2
    mov rsi, 1
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl err_usage_out
    mov [sock_fd], rax
    
    mov rdi, rax
    mov rax, 49
    lea rsi, [sockaddr]
    mov rdx, 16
    mov word [sockaddr], 2
    mov ax, [port_num]
    xchg al, ah
    mov [sockaddr + 2], ax
    mov dword [sockaddr + 4], 0
    syscall
    cmp rax, 0
    jl err_usage_out
    
    mov rdi, [sock_fd]
    mov rax, 50
    mov rsi, 128
    syscall
    cmp rax, 0
    jl err_usage_out

accept_loop:
    mov rdi, [sock_fd]
    mov rax, 43
    xor rsi, rsi
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl accept_loop
    mov [client_fd], rax
    
    push rax
    call handle_client_func
    pop rdi
    
    mov rax, 3
    syscall
    jmp accept_loop

err_usage_out:
    mov rax, 1
    mov rdi, 1
    lea rsi, [err_usage]
    mov rdx, 19
    syscall
    mov rax, 60
    xor rdi, rdi
    syscall

strlen_func:
    xor rax, rax
.str_loop:
    cmp byte [rdi + rax], 0
    je .str_done
    inc rax
    jmp .str_loop
.str_done:
    ret

strcpy_func:
    xor rcx, rcx
.strcpy_loop:
    mov al, byte [rsi + rcx]
    mov byte [rdi + rcx], al
    test al, al
    jz .strcpy_done
    inc rcx
    jmp .strcpy_loop
.strcpy_done:
    ret

strcmp_func:
    xor rcx, rcx
.strcmp_loop:
    mov al, byte [rdi + rcx]
    cmp al, byte [rsi + rcx]
    jne .strcmp_ret
    test al, al
    jz .strcmp_ret
    inc rcx
    jmp .strcmp_loop
.strcmp_ret:
    movzx rax, al
    movzx rdx, byte [rsi + rcx]
    sub rax, rdx
    ret

startswith_func:
    xor rcx, rcx
.start_loop:
    mov al, byte [rsi + rcx]
    test al, al
    jz .start_success
    cmp al, byte [rdi + rcx]
    jne .start_fail
    inc rcx
    jmp .start_loop
.start_success:
    xor rax, rax
    ret
.start_fail:
    mov rax, -1
    ret

atoi_func:
    xor rcx, rcx
    xor rax, rax
.atoi_loop:
    movzx rdx, byte [rdi + rcx]
    cmp rdx, 0
    je .atoi_done
    cmp rdx, '0'
    jl .atoi_done
    cmp rdx, '9'
    jg .atoi_done
    imul rax, rax, 10
    sub rdx, '0'
    add rax, rdx
    inc rcx
    jmp .atoi_loop
.atoi_done:
    ret

append_int_func:
    push rbp
    mov rbp, rsp
    mov rcx, rdi
.find_end:
    cmp byte [rcx], 0
    je .found_end
    inc rcx
    jmp .find_end
.found_end:
    lea r9, [int_buf + 31]
    mov byte [r9], 0
    mov r10, r9
    mov rax, rsi
    test rax, rax
    jnz .conv_loop
    dec r10
    mov byte [r10], '0'
    jmp .copy_loop
.conv_loop:
    test rax, rax
    jz .copy_loop
    xor rdx, rdx
    mov rbx, 10
    div rbx
    add dl, '0'
    dec r10
    mov byte [r10], dl
    jmp .conv_loop
.copy_loop:
    mov al, byte [r10]
    mov byte [rcx], al
    inc rcx
    inc r10
    cmp byte [r10], 0
    jne .copy_loop
    pop rbp
    mov rax, rcx
    ret

append_str_func:
    push rbp
    mov rbp, rsp
    mov rcx, rdi
.find_str_end:
    cmp byte [rcx], 0
    je .found_str_end
    inc rcx
    jmp .find_str_end
.found_str_end:
.copy_str_loop:
    mov al, byte [rsi]
    mov byte [rcx], al
    inc rcx
    inc rsi
    test al, al
    jnz .copy_str_loop
    pop rbp
    mov rax, rcx
    ret

extract_json_string_func:
    push rbp
    mov rbp, rsp
    push rdi; push rsi; push rdx; push rcx; push r8
    mov r9, rdi
    mov r10, rsi
.search_loop:
    cmp r10, 0
    jle .not_found_str
    push rcx; push rdi; push rsi
    mov rdi, r9
    mov rsi, rdx
    call strcmp_func
    pop rsi; pop rdi; pop rcx
    cmp rax, 0
    je .found_key_str
    inc r9
    dec r10
    jmp .search_loop
.found_key_str:
    mov rdi, rdx
    call strlen_func
    mov r11, rax
    mov rdi, r9
    add rdi, r11
.skip_to_quote:
    cmp byte [rdi], '"'
    je .found_open_quote
    inc rdi
    jmp .skip_to_quote
.found_open_quote:
    inc rdi
    mov rsi, rcx
    xor r12, r12
.read_value:
    cmp r12, r8
    jge .done_read_str
    mov al, byte [rdi]
    cmp al, '"'
    je .done_read_str
    cmp al, 0
    je .done_read_str
    mov byte [rsi + r12], al
    inc rdi
    inc r12
    jmp .read_value
.done_read_str:
    mov byte [rsi + r12], 0
    mov rax, r12
    jmp .exit_str
.not_found_str:
    mov rax, -1
.exit_str:
    mov r8, [rbp+40]
    mov rcx, [rbp+32]
    mov rdx, [rbp+24]
    mov rsi, [rbp+16]
    mov rdi, [rbp+8]
    pop rbp
    ret

extract_json_bool_func:
    push rbp
    mov rbp, rsp
    mov r8, rdx
    call strlen_func
    mov r9, rax
    mov r10, rdi
.search_bool:
    push rcx; push rdi; push rsi
    mov rdi, r10
    mov rsi, r8
    call strcmp_func
    pop rsi; pop rdi; pop rcx
    cmp rax, 0
    je .found_bool
    inc r10
    jmp .search_bool
.found_bool:
    add r10, r9
.skip_bool:
    cmp byte [r10], 't'
    je .is_true_bool
    cmp byte [r10], 'f'
    je .is_false_bool
    cmp byte [r10], 0
    je .not_found_bool
    inc r10
    jmp .skip_bool
.is_true_bool:
    mov rax, 1
    jmp .exit_bool
.is_false_bool:
    mov rax, 0
    jmp .exit_bool
.not_found_bool:
    mov rax, -1
.exit_bool:
    pop rbp
    ret

validate_username_func:
    xor rcx, rcx
.val_loop:
    mov al, byte [rdi + rcx]
    test al, al
    jz .val_success
    cmp al, 'a'
    jl .check_A_val
    cmp al, 'z'
    jle .val_ok
.check_A_val:
    cmp al, 'A'
    jl .check_0_val
    cmp al, 'Z'
    jle .val_ok
.check_0_val:
    cmp al, '0'
    jl .check_und_val
    cmp al, '9'
    jle .val_ok
.check_und_val:
    cmp al, '_'
    je .val_ok
    jmp .val_fail
.val_ok:
    inc rcx
    jmp .val_loop
.val_success:
    xor rax, rax
    ret
.val_fail:
    mov rax, -1
    ret

get_current_time_func:
    push rdi
    mov rax, 96
    lea rsi, [timeval_buf]
    xor rdx, rdx
    syscall
    mov rdi, [timeval_buf]
    pop rsi
    call epoch_to_utc_func
    ret

epoch_to_utc_func:
    push rbp
    mov rbp, rsp
    push rbx; push r12; push r13; push r14; push r15
    mov rax, rdi
    mov rbx, 86400
    xor rdx, rdx
    div rbx
    mov r8, rdx
    mov rcx, rax
    add rcx, 719468
    
    mov r9, rcx
    cmp r9, 0
    jge .pos_z_utc
    sub r9, 146096
.pos_z_utc:
    mov rax, r9
    xor rdx, rdx
    mov rbx, 146097
    div rbx
    mov r10, rax
    mov rax, r10
    imul rax, 146097
    mov r11, rcx
    sub r11, rax
    
    mov rax, r11
    mov rbx, 1460
    xor rdx, rdx
    div rbx
    mov r12, r11
    sub r12, rax
    mov rax, r11
    mov rbx, 36524
    xor rdx, rdx
    div rbx
    add r12, rax
    mov rax, r11
    mov rbx, 146096
    xor rdx, rdx
    div rbx
    sub r12, rax
    
    mov rax, r12
    mov rbx, 365
    xor rdx, rdx
    div rbx
    mov r13, rax
    mov rax, r10
    imul rax, 400
    add rax, r13
    mov r14, rax
    
    mov rax, r13
    mov rbx, 4
    xor rdx, rdx
    div rbx
    mov r15, r13
    sub r15, rax
    mov rax, r13
    mov rbx, 100
    xor rdx, rdx
    div rbx
    add r15, rax
    mov rax, 365
    imul rax, r13
    add rax, r15
    mov r15, r11
    sub r15, rax
    
    mov rax, r15
    imul rax, 5
    add rax, 2
    mov rbx, 153
    xor rdx, rdx
    div rbx
    mov r15, rax
    mov rax, r15
    imul rax, 153
    add rax, 2
    mov rbx, 5
    xor rdx, rdx
    div rbx
    mov rdx, r15
    sub rdx, rax
    inc rdx
    
    mov rax, r15
    cmp rax, 10
    jge .m_else_utc
    add rax, 3
    jmp .m_end_utc
.m_else_utc:
    sub rax, 9
.m_end_utc:
    mov r15, rax
    cmp r15, 2
    jg .y_end_utc
    inc r14
.y_end_utc:
    mov rdi, rsi
    mov rax, r14
    call .app4_utc
    mov byte [rdi], '-'
    inc rdi
    mov rax, r15
    call .app2_utc
    mov byte [rdi], '-'
    inc rdi
    mov rax, rdx
    call .app2_utc
    mov byte [rdi], 'T'
    inc rdi
    mov rax, r8
    mov rbx, 3600
    xor rdx, rdx
    div rbx
    mov r8, rdx
    mov rax, rax
    call .app2_utc
    mov byte [rdi], ':'
    inc rdi
    mov rax, r8
    mov rbx, 60
    xor rdx, rdx
    div rbx
    mov rax, rax
    call .app2_utc
    mov byte [rdi], ':'
    inc rdi
    mov rax, rdx
    call .app2_utc
    mov byte [rdi], 'Z'
    inc rdi
    mov byte [rdi], 0
    
    pop r15; pop r14; pop r13; pop r12; pop rbx; pop rbp
    ret
.app4_utc:
    mov rbx, 1000
    xor rdx, rdx
    div rbx
    add dl, '0'
    mov byte [rdi], dl
    inc rdi
    mov rax, rdx
    mov rbx, 100
    xor rdx, rdx
    div rbx
    add dl, '0'
    mov byte [rdi], dl
    inc rdi
    mov rax, rdx
    mov rbx, 10
    xor rdx, rdx
    div rbx
    add dl, '0'
    mov byte [rdi], dl
    inc rdi
    mov rax, rdx
    add al, '0'
    mov byte [rdi], al
    inc rdi
    ret
.app2_utc:
    mov rbx, 10
    xor rdx, rdx
    div rbx
    add dl, '0'
    mov byte [rdi], dl
    inc rdi
    mov rax, rdx
    add al, '0'
    mov byte [rdi], al
    inc rdi
    ret

generate_token_func:
    mov rax, 318
    mov rdi, rdi
    mov rsi, 32
    xor rdx, rdx
    syscall
    push rdi
    mov rsi, rdi
    mov rcx, 32
    add rdi, 64
    mov byte [rdi], 0
    dec rdi
.conv_token:
    test rcx, rcx
    jz .done_token
    movzx rbx, byte [rsi + rcx - 1]
    mov r8b, bl
    shr r8b, 4
    cmp r8b, 9
    jle .n1_token
    add r8b, 7
.n1_token:
    add r8b, '0'
    mov byte [rdi], r8b
    dec rdi
    mov r8b, bl
    and r8b, 0x0F
    cmp r8b, 9
    jle .n2_token
    add r8b, 7
.n2_token:
    add r8b, '0'
    mov byte [rdi], r8b
    dec rdi
    dec rcx
    jmp .conv_token
.done_token:
    pop rdi
    ret

check_auth_func:
    lea rdi, [cookie_val_buf]
    call strlen_func
    cmp rax, 0
    je .invalid_auth
    mov rcx, [session_count]
    xor rbx, rbx
.auth_loop:
    cmp rbx, rcx
    je .invalid_auth
    mov rax, rbx
    imul rax, SESSION_SIZE
    lea rdi, [sessions + rax]
    lea rsi, [cookie_val_buf]
    call strcmp_func
    cmp rax, 0
    jne .next_auth
    mov rax, rbx
    imul rax, SESSION_SIZE
    cmp byte [sessions + rax + 68], 0
    je .invalid_auth
    mov eax, [sessions + rax + 64]
    ret
.next_auth:
    inc rbx
    jmp .auth_loop
.invalid_auth:
    xor rax, rax
    ret

parse_request_func:
    lea rdi, [req_buf]
.parse_loop:
    cmp byte [rdi], ' '
    je .found_space
    inc rdi
    jmp .parse_loop
.found_space:
    inc rdi
    mov rsi, path_buf
.parse_loop2:
    mov al, byte [rdi]
    cmp al, ' '
    je .done_parse_path
    cmp al, 13
    je .done_parse_path
    cmp al, 10
    je .done_parse_path
    cmp al, 0
    je .done_parse_path
    mov byte [rsi], al
    inc rdi
    inc rsi
    jmp .parse_loop2
.done_parse_path:
    mov byte [rsi], 0
    
    lea rdi, [req_buf]
    lea r8, [req_buf + 8192]
.body_loop:
    cmp rdi, r8
    jge .no_body
    cmp word [rdi], 0x0a0d
    jne .nxt_body
    cmp word [rdi + 2], 0x0a0d
    je .found_body
.nxt_body:
    inc rdi
    jmp .body_loop
.found_body:
    lea rax, [rdi + 4]
    mov [body_ptr], rax
    lea r8, [req_buf + 8192]
    sub r8, rax
    mov [body_len], r8
    jmp .find_cookie_parse
.no_body:
    mov qword [body_ptr], 0
    mov qword [body_len], 0
.find_cookie_parse:
    lea rdi, [req_buf]
    lea r8, [req_buf + 8192]
    lea r9, [cookie_str]
.cookie_loop:
    cmp rdi, r8
    jge .no_cookie_parse
    mov rcx, 8
    mov rsi, r9
    repe cmpsb
    je .found_cookie_parse
    inc rdi
    jmp .cookie_loop
.found_cookie_parse:
    mov rsi, cookie_val_buf
    xor rcx, rcx
.cookie_read:
    mov al, byte [rdi + rcx]
    cmp al, 13
    je .cookie_done
    cmp al, 10
    je .cookie_done
    cmp al, 0
    je .cookie_done
    mov byte [rsi + rcx], al
    inc rcx
    jmp .cookie_read
.cookie_done:
    mov byte [rsi + rcx], 0
    jmp .done_parse_full
.no_cookie_parse:
    mov byte [cookie_val_buf], 0
.done_parse_full:
    ret

send_json_response_func:
    push rbp
    mov rbp, rsp
    push rdi; push rsi; push rdx
    lea rcx, [resp_buf]
    mov rdi, rcx
    mov r8, [rbp+16]
    call strcpy_func
    mov rdi, rcx
    mov r8, [rbp+32]
    test r8, r8
    jz .no_cookie_resp
    lea rsi, [hdr_set_cookie]
    call append_str_func
    mov rdi, rcx
    mov rsi, r8
    call append_str_func
    lea rsi, [hdr_cookie_suf]
    call append_str_func
.no_cookie_resp:
    mov rdi, rcx
    lea rsi, [hdr_content_type]
    call append_str_func
    mov rdi, rcx
    mov r8, [rbp+24]
    call append_str_func
    mov rdi, [client_fd]
    lea rsi, [resp_buf]
    call strlen_func
    mov rdx, rax
    mov rax, 1
    syscall
    pop rdx; pop rsi; pop rdi
    pop rbp
    ret

send_204_func:
    lea rdi, [resp_buf]
    lea rsi, [res_204]
    call strcpy_func
    mov rdi, [client_fd]
    lea rsi, [resp_buf]
    call strlen_func
    mov rdx, rax
    mov rax, 1
    syscall
    ret

get_todo_id_func:
    lea rdi, [path_buf]
    lea rsi, [path_todos_sl]
    call startswith_func
    cmp rax, 0
    jne .fail_todo_id
    lea rdi, [path_buf + 7]
    call atoi_func
    ret
.fail_todo_id:
    xor rax, rax
    ret

build_todo_response_func:
    mov rax, rbx
    imul rax, TODO_SIZE
    lea rdi, [todo_json_buf]
    mov byte [rdi], '{'
    inc rdi
    lea rsi, [str_id]
    call append_str_func
    mov rdi, rax
    mov eax, [todos + rax]
    mov rsi, rax
    call append_int_func
    mov rdi, rax
    lea rsi, [str_title]
    call append_str_func
    mov rdi, rax
    lea rsi, [todos + rax + 8]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_desc]
    call append_str_func
    mov rdi, rax
    lea rsi, [todos + rax + 264]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_completed]
    call append_str_func
    mov rdi, rax
    cmp byte [todos + rax + 1288], 0
    je .gf_build
    lea rsi, [str_true]
    jmp .gc_build
.gf_build:
    lea rsi, [str_false]
.gc_build:
    call append_str_func
    mov rdi, rax
    lea rsi, [str_created]
    call append_str_func
    mov rdi, rax
    lea rsi, [todos + rax + 1289]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_updated]
    call append_str_func
    mov rdi, rax
    lea rsi, [todos + rax + 1321]
    call append_str_func
    lea rsi, [str_end_obj]
    call append_str_func
    mov rdi, rax
    mov byte [rdi], 0
    lea rdi, [res_200]
    lea rsi, [todo_json_buf]
    xor rdx, rdx
    call send_json_response_func
    ret

route_request_func:
    lea rdi, [req_buf]
    lea rsi, [method_post]
    call startswith_func
    cmp rax, 0
    jne .chk_login_route
    lea rdi, [path_buf]
    lea rsi, [path_register]
    call strcmp_func
    cmp rax, 0
    je handler_register

.chk_login_route:
    lea rdi, [req_buf]
    lea rsi, [method_post]
    call startswith_func
    cmp rax, 0
    jne .chk_logout_route
    lea rdi, [path_buf]
    lea rsi, [path_login]
    call strcmp_func
    cmp rax, 0
    je handler_login

.chk_logout_route:
    lea rdi, [req_buf]
    lea rsi, [method_post]
    call startswith_func
    cmp rax, 0
    jne .chk_me_route
    lea rdi, [path_buf]
    lea rsi, [path_logout]
    call strcmp_func
    cmp rax, 0
    je handler_logout

.chk_me_route:
    lea rdi, [req_buf]
    lea rsi, [method_get]
    call startswith_func
    cmp rax, 0
    jne .chk_password_route
    lea rdi, [path_buf]
    lea rsi, [path_me]
    call strcmp_func
    cmp rax, 0
    je handler_me

.chk_password_route:
    lea rdi, [req_buf]
    lea rsi, [method_put]
    call startswith_func
    cmp rax, 0
    jne .chk_get_todos_route
    lea rdi, [path_buf]
    lea rsi, [path_password]
    call strcmp_func
    cmp rax, 0
    je handler_password

.chk_get_todos_route:
    lea rdi, [req_buf]
    lea rsi, [method_get]
    call startswith_func
    cmp rax, 0
    jne .chk_post_todos_route
    lea rdi, [path_buf]
    lea rsi, [path_todos]
    call strcmp_func
    cmp rax, 0
    je handler_get_todos
    lea rdi, [path_buf]
    lea rsi, [path_todos_sl]
    call startswith_func
    cmp rax, 0
    je handler_get_todo_id

.chk_post_todos_route:
    lea rdi, [req_buf]
    lea rsi, [method_post]
    call startswith_func
    cmp rax, 0
    jne .chk_put_todo_route
    lea rdi, [path_buf]
    lea rsi, [path_todos]
    call strcmp_func
    cmp rax, 0
    je handler_post_todos

.chk_put_todo_route:
    lea rdi, [req_buf]
    lea rsi, [method_put]
    call startswith_func
    cmp rax, 0
    jne .chk_del_todo_route
    lea rdi, [path_buf]
    lea rsi, [path_todos_sl]
    call startswith_func
    cmp rax, 0
    je handler_put_todo_id

.chk_del_todo_route:
    lea rdi, [req_buf]
    lea rsi, [method_delete]
    call startswith_func
    cmp rax, 0
    jne .ret_route
    lea rdi, [path_buf]
    lea rsi, [path_todos_sl]
    call startswith_func
    cmp rax, 0
    je handler_delete_todo_id

.ret_route:
    ret

handler_register:
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_username]
    lea rcx, [parsed_username]
    mov r8, 64
    call extract_json_string_func
    cmp rax, -1
    je .err_u_reg
    cmp rax, 3
    jl .err_u_reg
    cmp rax, 50
    jg .err_u_reg
    lea rdi, [parsed_username]
    call validate_username_func
    cmp rax, 0
    jne .err_u_reg
    
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_password]
    lea rcx, [parsed_password]
    mov r8, 256
    call extract_json_string_func
    cmp rax, -1
    je .err_p_reg
    cmp rax, 8
    jl .err_p_reg
    
    mov rcx, [user_count]
    xor rbx, rbx
.uchk_reg:
    cmp rbx, rcx
    je .create_reg
    mov rax, rbx
    imul rax, USER_SIZE
    lea rdi, [users + rax + 4]
    lea rsi, [parsed_username]
    call strcmp_func
    cmp rax, 0
    je .err_exist_reg
    inc rbx
    jmp .uchk_reg
.create_reg:
    mov rcx, [user_count]
    inc rcx
    mov [user_count], rcx
    dec rcx
    mov rax, rcx
    inc rax
    mov rdi, rbx
    imul rdi, USER_SIZE
    mov [users + rdi], eax
    lea rsi, [parsed_username]
    call strcpy_func
    lea rdi, [users + rdi + 68]
    lea rsi, [parsed_password]
    call strcpy_func
    mov byte [users + rdi + 256], 1
    
    lea rdi, [body_buf]
    mov byte [rdi], '{'
    inc rdi
    lea rsi, [str_id]
    call append_str_func
    mov rdi, rax
    mov rsi, rcx
    inc rsi
    call append_int_func
    mov rdi, rax
    lea rsi, [str_user_fmt]
    call append_str_func
    mov rdi, rax
    lea rsi, [parsed_username]
    call append_str_func
    lea rsi, [str_end_obj]
    call append_str_func
    mov rdi, rax
    mov byte [rdi], 0
    
    lea rdi, [res_201]
    lea rsi, [body_buf]
    xor rdx, rdx
    call send_json_response_func
    ret
.err_u_reg:
    lea rdi, [res_400]; lea rsi, [err_inv_user]; xor rdx, rdx; call send_json_response_func; ret
.err_p_reg:
    lea rdi, [res_400]; lea rsi, [err_pwd_short]; xor rdx, rdx; call send_json_response_func; ret
.err_exist_reg:
    lea rdi, [res_409]; lea rsi, [err_user_exist]; xor rdx, rdx; call send_json_response_func; ret

handler_login:
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_username]
    lea rcx, [parsed_username]
    mov r8, 64
    call extract_json_string_func
    cmp rax, -1
    je .err_c_login
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_password]
    lea rcx, [parsed_password]
    mov r8, 256
    call extract_json_string_func
    cmp rax, -1
    je .err_c_login
    
    mov rcx, [user_count]
    xor rbx, rbx
.lchk_login:
    cmp rbx, rcx
    je .err_c_login
    mov rax, rbx
    imul rax, USER_SIZE
    lea rdi, [users + rax + 4]
    lea rsi, [parsed_username]
    call strcmp_func
    cmp rax, 0
    jne .lnxt_login
    lea rdi, [users + rax + 68]
    lea rsi, [parsed_password]
    call strcmp_func
    cmp rax, 0
    je .lsucc_login
.lnxt_login:
    inc rbx
    jmp .lchk_login
.lsucc_login:
    mov rcx, [session_count]
    cmp rcx, 100
    jge .err_c_login
    mov rax, rcx
    imul rax, SESSION_SIZE
    lea rdi, [sessions + rax]
    call generate_token_func
    mov rax, rbx
    inc rax
    mov rdi, rcx
    imul rdi, SESSION_SIZE
    mov [sessions + rdi + 64], eax
    mov byte [sessions + rdi + 68], 1
    inc rcx
    mov [session_count], rcx
    
    lea rdi, [body_buf]
    mov byte [rdi], '{'
    inc rdi
    lea rsi, [str_id]
    call append_str_func
    mov rdi, rax
    mov rsi, rbx
    inc rsi
    call append_int_func
    mov rdi, rax
    lea rsi, [str_user_fmt]
    call append_str_func
    mov rdi, rax
    lea rsi, [parsed_username]
    call append_str_func
    lea rsi, [str_end_obj]
    call append_str_func
    mov rdi, rax
    mov byte [rdi], 0
    
    lea rdi, [res_200]
    lea rsi, [body_buf]
    dec rcx
    mov rax, rcx
    imul rax, SESSION_SIZE
    lea rdx, [sessions + rax]
    call send_json_response_func
    ret
.err_c_login:
    lea rdi, [res_401]; lea rsi, [err_inv_cred]; xor rdx, rdx; call send_json_response_func; ret

handler_logout:
    call check_auth_func
    test rax, rax
    jz .err_a_logout
    mov rcx, [session_count]
    xor rbx, rbx
.ochk_logout:
    cmp rbx, rcx
    je .done_o_logout
    mov rax, rbx
    imul rax, SESSION_SIZE
    lea rdi, [sessions + rax]
    lea rsi, [cookie_val_buf]
    call strcmp_func
    cmp rax, 0
    jne .onxt_logout
    mov byte [sessions + rax + 68], 0
    jmp .done_o_logout
.onxt_logout:
    inc rbx
    jmp .ochk_logout
.done_o_logout:
    lea rdi, [res_200]
    lea rsi, [body_empty]
    xor rdx, rdx
    call send_json_response_func
    ret
.err_a_logout:
    lea rdi, [res_401]; lea rsi, [err_auth_req]; xor rdx, rdx; call send_json_response_func; ret

handler_me:
    call check_auth_func
    test rax, rax
    jz .err_a_me
    mov rbx, rax
    dec rbx
    lea rdi, [body_buf]
    mov byte [rdi], '{'
    inc rdi
    lea rsi, [str_id]
    call append_str_func
    mov rdi, rax
    mov rsi, rbx
    inc rsi
    call append_int_func
    mov rdi, rax
    lea rsi, [str_user_fmt]
    call append_str_func
    mov rdi, rax
    mov rax, rbx
    imul rax, USER_SIZE
    lea rsi, [users + rax + 4]
    call append_str_func
    lea rsi, [str_end_obj]
    call append_str_func
    mov rdi, rax
    mov byte [rdi], 0
    lea rdi, [res_200]
    lea rsi, [body_buf]
    xor rdx, rdx
    call send_json_response_func
    ret
.err_a_me:
    lea rdi, [res_401]; lea rsi, [err_auth_req]; xor rdx, rdx; call send_json_response_func; ret

handler_password:
    call check_auth_func
    test rax, rax
    jz .err_a_pwd
    mov r12, rax
    dec r12
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_old_pwd]
    lea rcx, [parsed_password]
    mov r8, 256
    call extract_json_string_func
    cmp rax, -1
    je .err_c_pwd
    mov rax, r12
    imul rax, USER_SIZE
    lea rdi, [users + rax + 68]
    lea rsi, [parsed_password]
    call strcmp_func
    cmp rax, 0
    jne .err_c_pwd
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_new_pwd]
    lea rcx, [parsed_password]
    mov r8, 256
    call extract_json_string_func
    cmp rax, -1
    je .err_p2_pwd
    cmp rax, 8
    jl .err_p2_pwd
    mov rax, r12
    imul rax, USER_SIZE
    lea rdi, [users + rax + 68]
    lea rsi, [parsed_password]
    call strcpy_func
    lea rdi, [res_200]
    lea rsi, [body_empty]
    xor rdx, rdx
    call send_json_response_func
    ret
.err_p2_pwd:
    lea rdi, [res_400]; lea rsi, [err_pwd_short]; xor rdx, rdx; call send_json_response_func; ret
.err_c_pwd:
    lea rdi, [res_401]; lea rsi, [err_inv_cred]; xor rdx, rdx; call send_json_response_func; ret

handler_get_todos:
    call check_auth_func
    test rax, rax
    jz .err_a_gtodos
    mov rbx, rax
    lea rdi, [body_buf]
    mov byte [rdi], '['
    inc rdi
    mov r14, rdi
    mov byte [is_first], 1
    mov rcx, [todo_count]
    xor r12, r12
.gtloop_todos:
    cmp r12, rcx
    je .gtend_todos
    mov rax, r12
    imul rax, TODO_SIZE
    cmp byte [todos + rax + 1353], 0
    je .gtnxt_todos
    cmp dword [todos + rax + 4], ebx
    jne .gtnxt_todos
    cmp byte [is_first], 1
    jne .gtnotf_todos
    mov byte [is_first], 0
    jmp .gtapp_todos
.gtnotf_todos:
    lea rsi, [str_comma]
    mov rdi, r14
    call append_str_func
    mov r14, rax
.gtapp_todos:
    lea rdi, [todo_json_buf]
    mov byte [rdi], '{'
    inc rdi
    lea rsi, [str_id]
    call append_str_func
    mov rdi, rax
    mov eax, [todos + rax]
    mov rsi, rax
    call append_int_func
    mov rdi, rax
    lea rsi, [str_title]
    call append_str_func
    mov rdi, rax
    lea rsi, [todos + rax + 8]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_desc]
    call append_str_func
    mov rdi, rax
    lea rsi, [todos + rax + 264]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_completed]
    call append_str_func
    mov rdi, rax
    cmp byte [todos + rax + 1288], 0
    je .gtf_todos
    lea rsi, [str_true]
    jmp .gtc_todos
.gtf_todos:
    lea rsi, [str_false]
.gtc_todos:
    call append_str_func
    mov rdi, rax
    lea rsi, [str_created]
    call append_str_func
    mov rdi, rax
    lea rsi, [todos + rax + 1289]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_updated]
    call append_str_func
    mov rdi, rax
    lea rsi, [todos + rax + 1321]
    call append_str_func
    lea rsi, [str_end_obj]
    call append_str_func
    mov rdi, r14
    lea rsi, [todo_json_buf]
    call append_str_func
    mov r14, rax
.gtnxt_todos:
    inc r12
    jmp .gtloop_todos
.gtend_todos:
    mov rdi, r14
    mov byte [rdi], ']'
    inc rdi
    mov byte [rdi], 0
    lea rdi, [res_200]
    lea rsi, [body_buf]
    xor rdx, rdx
    call send_json_response_func
    ret
.err_a_gtodos:
    lea rdi, [res_401]; lea rsi, [err_auth_req]; xor rdx, rdx; call send_json_response_func; ret

handler_post_todos:
    call check_auth_func
    test rax, rax
    jz .err_a_ptodos
    mov r12, rax
    
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_title]
    lea rcx, [parsed_title]
    mov r8, 256
    call extract_json_string_func
    cmp rax, -1
    je .err_t_ptodos
    cmp rax, 0
    je .err_t_ptodos
    
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_desc]
    lea rcx, [parsed_desc]
    mov r8, 1024
    call extract_json_string_func
    mov r15, rax
    
    mov rcx, [todo_count]
    inc rcx
    mov [todo_count], rcx
    dec rcx
    mov r14, rcx
    
    mov rax, r14
    inc rax
    mov rdi, r14
    imul rdi, TODO_SIZE
    mov [todos + rdi], eax
    mov [todos + rdi + 4], r12d
    
    lea rsi, [parsed_title]
    call strcpy_func
    
    lea rdi, [todos + rdi + 264]
    cmp r15, -1
    jne .has_desc_ptodos
    lea rsi, [empty_str]
    jmp .set_desc_ptodos
.has_desc_ptodos:
    lea rsi, [parsed_desc]
.set_desc_ptodos:
    call strcpy_func
    
    mov rax, r14
    imul rax, TODO_SIZE
    mov byte [todos + rax + 1288], 0
    lea rdi, [todos + rax + 1289]
    call get_current_time_func
    lea rdi, [todos + rax + 1321]
    call get_current_time_func
    mov byte [todos + rax + 1353], 1
    
    lea rdi, [todo_json_buf]
    mov byte [rdi], '{'
    inc rdi
    lea rsi, [str_id]
    call append_str_func
    mov rdi, rax
    mov eax, [todos + rax]
    mov rsi, rax
    call append_int_func
    mov rdi, rax
    lea rsi, [str_title]
    call append_str_func
    mov rdi, rax
    lea rsi, [parsed_title]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_desc]
    call append_str_func
    mov rdi, rax
    mov rax, r14
    imul rax, TODO_SIZE
    lea rsi, [todos + rax + 264]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_completed]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_false]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_created]
    call append_str_func
    mov rdi, rax
    mov rax, r14
    imul rax, TODO_SIZE
    lea rsi, [todos + rax + 1289]
    call append_str_func
    mov rdi, rax
    lea rsi, [str_updated]
    call append_str_func
    mov rdi, rax
    mov rax, r14
    imul rax, TODO_SIZE
    lea rsi, [todos + rax + 1321]
    call append_str_func
    lea rsi, [str_end_obj]
    call append_str_func
    mov rdi, rax
    mov byte [rdi], 0
    
    lea rdi, [res_201]
    lea rsi, [todo_json_buf]
    xor rdx, rdx
    call send_json_response_func
    ret
.err_t_ptodos:
    lea rdi, [res_400]; lea rsi, [err_title_req]; xor rdx, rdx; call send_json_response_func; ret
.err_a_ptodos:
    lea rdi, [res_401]; lea rsi, [err_auth_req]; xor rdx, rdx; call send_json_response_func; ret

handler_get_todo_id:
    call check_auth_func
    test rax, rax
    jz .err_a_gtid
    mov r12, rax
    call get_todo_id_func
    mov r13, rax
    test r13, r13
    jz .err_nf_gtid
    mov rcx, [todo_count]
    xor rbx, rbx
.gidchk_gtid:
    cmp rbx, rcx
    je .err_nf_gtid
    mov rax, rbx
    imul rax, TODO_SIZE
    cmp dword [todos + rax], r13d
    jne .gidnxt_gtid
    cmp dword [todos + rax + 4], r12d
    jne .err_nf_gtid
    jmp .gfound_gtid
.gidnxt_gtid:
    inc rbx
    jmp .gidchk_gtid
.gfound_gtid:
    cmp byte [todos + rax + 1353], 0
    je .err_nf_gtid
    call build_todo_response_func
    ret
.err_nf_gtid:
    lea rdi, [res_404]; lea rsi, [err_todo_not_f]; xor rdx, rdx; call send_json_response_func; ret
.err_a_gtid:
    lea rdi, [res_401]; lea rsi, [err_auth_req]; xor rdx, rdx; call send_json_response_func; ret

handler_put_todo_id:
    call check_auth_func
    test rax, rax
    jz .err_a_ptid
    mov r12, rax
    call get_todo_id_func
    mov r13, rax
    test r13, r13
    jz .err_nf_ptid
    mov rcx, [todo_count]
    xor rbx, rbx
.pidchk_ptid:
    cmp rbx, rcx
    je .err_nf_ptid
    mov rax, rbx
    imul rax, TODO_SIZE
    cmp dword [todos + rax], r13d
    jne .pidnxt_ptid
    cmp dword [todos + rax + 4], r12d
    jne .err_nf_ptid
    jmp .pfound_ptid
.pidnxt_ptid:
    inc rbx
    jmp .pidchk_ptid
.pfound_ptid:
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_title]
    lea rcx, [parsed_title]
    mov r8, 256
    call extract_json_string_func
    cmp rax, -1
    je .pskip_t_ptid
    cmp rax, 0
    je .err_t2_ptid
    mov rdi, rbx
    imul rdi, TODO_SIZE
    lea rdi, [todos + rdi + 8]
    lea rsi, [parsed_title]
    call strcpy_func
.pskip_t_ptid:
    mov rdi, [body_ptr]
    mov rsi, [body_len]
    lea rdx, [key_desc]
    lea rcx, [parsed_desc]
    mov r8, 1024
    call extract_json_string_func
    cmp rax, -1
    je .pskip_d_ptid
    mov rdi, rbx
    imul rdi, TODO_SIZE
    lea rdi, [todos + rdi + 264]
    lea rsi, [parsed_desc]
    call strcpy_func
.pskip_d_ptid:
    lea rdx, [key_completed]
    call extract_json_bool_func
    cmp rax, -1
    je .pskip_c_ptid
    mov rdi, rbx
    imul rdi, TODO_SIZE
    mov byte [todos + rdi + 1288], al
.pskip_c_ptid:
    mov rdi, rbx
    imul rdi, TODO_SIZE
    lea rdi, [todos + rdi + 1321]
    call get_current_time_func
    call build_todo_response_func
    ret
.err_t2_ptid:
    lea rdi, [res_400]; lea rsi, [err_title_req]; xor rdx, rdx; call send_json_response_func; ret
.err_nf_ptid:
    lea rdi, [res_404]; lea rsi, [err_todo_not_f]; xor rdx, rdx; call send_json_response_func; ret
.err_a_ptid:
    lea rdi, [res_401]; lea rsi, [err_auth_req]; xor rdx, rdx; call send_json_response_func; ret

handler_delete_todo_id:
    call check_auth_func
    test rax, rax
    jz .err_a_dtid
    mov r12, rax
    call get_todo_id_func
    mov r13, rax
    test r13, r13
    jz .err_nf_dtid
    mov rcx, [todo_count]
    xor rbx, rbx
.didchk_dtid:
    cmp rbx, rcx
    je .err_nf_dtid
    mov rax, rbx
    imul rax, TODO_SIZE
    cmp dword [todos + rax], r13d
    jne .didnxt_dtid
    cmp dword [todos + rax + 4], r12d
    jne .err_nf_dtid
    jmp .dfound_dtid
.didnxt_dtid:
    inc rbx
    jmp .didchk_dtid
.dfound_dtid:
    mov rax, rbx
    imul rax, TODO_SIZE
    mov byte [todos + rax + 1353], 0
    call send_204_func
    ret
.err_nf_dtid:
    lea rdi, [res_404]; lea rsi, [err_todo_not_f]; xor rdx, rdx; call send_json_response_func; ret
.err_a_dtid:
    lea rdi, [res_401]; lea rsi, [err_auth_req]; xor rdx, rdx; call send_json_response_func; ret

handle_client_func:
    mov rax, 0
    mov rsi, req_buf
    mov rdx, 8192
    syscall
    cmp rax, 0
    jle .ret_client
    mov [req_len], rax
    call parse_request_func
    call route_request_func
.ret_client:
    ret

section .data
sockaddr:
    dw 0
    dw 0
    dd 0
    times 8 db 0
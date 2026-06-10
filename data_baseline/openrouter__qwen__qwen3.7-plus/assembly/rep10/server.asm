global _start

section .data
    str_port_arg db "--port", 0
    crlf db 13, 10, 0
    crlfcrlf db 13, 10, 13, 10, 0
    cookie_str db "Cookie:", 0
    session_id_str db "session_id=", 0
    cl_str db "Content-Length:", 0
    urandom_path db "/dev/urandom", 0
    
    http_ok db "HTTP/1.1 200 OK", 13, 10, 0
    http_created db "HTTP/1.1 201 Created", 13, 10, 0
    http_no_content db "HTTP/1.1 204 No Content", 13, 10, 0
    http_bad_req db "HTTP/1.1 400 Bad Request", 13, 10, 0
    http_unauth db "HTTP/1.1 401 Unauthorized", 13, 10, 0
    http_not_found db "HTTP/1.1 404 Not Found", 13, 10, 0
    http_conflict db "HTTP/1.1 409 Conflict", 13, 10, 0
    ct_json db "Content-Type: application/json", 13, 10, 0
    cl_header db "Content-Length: ", 0
    
    method_get db "GET", 0
    method_post db "POST", 0
    method_put db "PUT", 0
    method_delete db "DELETE", 0
    path_me db "/me", 0
    path_register db "/register", 0
    path_login db "/login", 0
    path_logout db "/logout", 0
    path_password db "/password", 0
    path_todos db "/todos", 0
    path_todos_slash db "/todos/", 0
    
    str_key_username db '"username"', 0
    str_key_password db '"password"', 0
    str_key_old_password db '"old_password"', 0
    str_key_new_password db '"new_password"', 0
    str_key_title db '"title"', 0
    str_key_desc db '"description"', 0
    str_key_completed db '"completed"', 0
    
    str_user_open db '{"id":', 0
    str_user_close db '}', 0
    str_username db '"username":', 0
    str_todo_open db "{", 0
    str_todo_close db "}", 0
    str_id db '"id":', 0
    str_title db '"title":', 0
    str_desc db '"description":', 0
    str_completed db '"completed":', 0
    str_created db '"created_at":', 0
    str_updated db '"updated_at":', 0
    str_quote db '"', 0
    str_comma db ",", 0
    str_true db "true", 0
    str_false db "false", 0
    str_array_open db "[", 0
    str_array_close db "]", 0
    str_set_cookie db "Set-Cookie: session_id=", 0
    str_cookie_path db "; Path=/; HttpOnly", 13, 10, 0
    
    err_invalid_username db '{"error":"Invalid username"}', 0
    err_password_short db '{"error":"Password too short"}', 0
    err_user_exists db '{"error":"Username already exists"}', 0
    err_invalid_creds db '{"error":"Invalid credentials"}', 0
    err_auth_required db '{"error":"Authentication required"}', 0
    err_title_required db '{"error":"Title is required"}', 0
    err_todo_not_found db '{"error":"Todo not found"}', 0
    err_logout_success db '{}', 0
    err_password_success db '{}', 0

    month_days_array db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    
    g_days dq 0
    g_sec_in_day dq 0
    g_hours dq 0
    g_minutes dq 0
    g_seconds dq 0
    g_year dq 0
    g_month dq 0
    g_day dq 0
    g_day_of_year dq 0
    g_is_leap dq 0

section .bss
    g_sock_fd resq 1
    g_client_fd resq 1
    g_port resw 1
    g_user_count resq 1
    g_session_count resq 1
    g_todo_count resq 1
    g_current_user_id resq 1
    g_todo_id resq 1
    g_body_len resq 1
    
    g_users resb 100 * 328
    g_sessions resb 100 * 40
    g_todos resb 1000 * 704
    
    g_req_buf resb 8192
    g_res_buf resb 16384
    g_body_buf resb 4096
    g_temp_buf resb 1024
    g_temp_val_buf resb 256
    g_temp_val_buf2 resb 256
    g_temp_todo_buf resb 1024
    g_res_body_buf resb 8192
    g_temp_header_buf resb 256
    g_temp_ts_buf resb 32
    g_cookie_token resb 36
    g_method resb 16
    g_path resb 256
    
    g_sockaddr resb 16

section .text

util_strlen:
    push rdi
    xor rax, rax
    cld
    mov rcx, -1
    xor al, al
    repne scasb
    not rcx
    dec rcx
    mov rax, rcx
    pop rdi
    ret

util_strcmp:
    push rdi
    push rsi
.util_strcmp_loop:
    mov al, [rdi]
    mov bl, [rsi]
    cmp al, bl
    jne .util_strcmp_done
    test al, al
    jz .util_strcmp_done
    inc rdi
    inc rsi
    jmp .util_strcmp_loop
.util_strcmp_done:
    movsx rax, al
    movsx rbx, bl
    sub rax, rbx
    pop rsi
    pop rdi
    ret

util_strstr:
    push rsi
    push rdi
    mov r8, rdi
    mov r9, rsi
    call util_strlen
    mov r10, rax
    test r10, r10
    jz .util_strstr_found
.util_strstr_outer:
    mov rdi, r8
    mov rsi, r9
    mov rcx, r10
    repe cmpsb
    je .util_strstr_found
    inc r8
    mov al, [r8]
    test al, al
    jnz .util_strstr_outer
    xor rax, rax
    jmp .util_strstr_done
.util_strstr_found:
    mov rax, r8
.util_strstr_done:
    pop rdi
    pop rsi
    ret

util_parse_int:
    push rbx
    push rcx
    push rdx
    xor rax, rax
.util_parse_int_loop:
    mov bl, [rdi]
    cmp bl, '0'
    jb .util_parse_int_done
    cmp bl, '9'
    ja .util_parse_int_done
    sub bl, '0'
    movzx rbx, bl
    imul rax, rax, 10
    add rax, rbx
    inc rdi
    jmp .util_parse_int_loop
.util_parse_int_done:
    pop rdx
    pop rcx
    pop rbx
    ret

util_itoa:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    
    mov r8, rdi
    mov rcx, 10
    mov r9, 0
    test rax, rax
    jnz .util_itoa_not_zero
    mov byte [r8], '0'
    mov byte [r8+1], 0
    jmp .util_itoa_done
.util_itoa_not_zero:
    mov r10, g_temp_buf
    add r10, 32
.util_itoa_conv_loop:
    test rax, rax
    jz .util_itoa_conv_done
    xor rdx, rdx
    div rcx
    add dl, '0'
    dec r10
    mov [r10], dl
    inc r9
    jmp .util_itoa_conv_loop
.util_itoa_conv_done:
    mov rcx, r9
    mov rsi, r10
    mov rdi, r8
    rep movsb
    mov byte [rdi], 0
.util_itoa_done:
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

util_append_str:
    push rcx
    push rsi
.util_append_str_find_end:
    cmp byte [rdi], 0
    je .util_append_str_found_end
    inc rdi
    jmp .util_append_str_find_end
.util_append_str_found_end:
.util_append_str_copy:
    mov al, [rsi]
    test al, al
    jz .util_append_str_done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .util_append_str_copy
.util_append_str_done:
    mov byte [rdi], 0
    pop rsi
    pop rcx
    ret

ts_format_4_digits:
    mov rcx, 10
    mov r8, rdi
    add rdi, 4
    mov byte [rdi], 0
    dec rdi
    mov r9, 4
.ts_format_4_loop:
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    dec rdi
    dec r9
    jnz .ts_format_4_loop
    mov rdi, r8
    add rdi, 4
    ret

ts_format_2_digits:
    mov rcx, 10
    mov r8, rdi
    add rdi, 2
    mov byte [rdi], 0
    dec rdi
    mov r9, 2
.ts_format_2_loop:
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    dec rdi
    dec r9
    jnz .ts_format_2_loop
    mov rdi, r8
    add rdi, 2
    ret

get_current_timestamp:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push rdi
    
    sub rsp, 16
    mov rax, 228
    mov rdi, 0
    mov rsi, rsp
    syscall
    mov rax, [rsp]
    add rsp, 16
    
    mov r8, rax
    mov rdx, 0
    mov rcx, 86400
    div rcx
    mov [g_days], rax
    mov [g_sec_in_day], rdx
    
    mov rax, rdx
    mov rdx, 0
    mov rcx, 3600
    div rcx
    mov [g_hours], rax
    
    mov rax, rdx
    mov rdx, 0
    mov rcx, 60
    div rcx
    mov [g_minutes], rax
    mov [g_seconds], rdx
    
    mov rcx, [g_days]
    mov r9, 1970
.ts_year_loop:
    mov rax, r9
    mov rdx, 0
    mov rbx, 4
    div rbx
    mov r10, 0
    test rdx, rdx
    jnz .ts_not_leap
    mov rax, r9
    mov rdx, 0
    mov rbx, 100
    div rbx
    test rdx, rdx
    jnz .ts_is_leap
    mov rax, r9
    mov rdx, 0
    mov rbx, 400
    div rbx
    test rdx, rdx
    jz .ts_not_leap
.ts_is_leap:
    mov r10, 1
    jmp .ts_calc_days
.ts_not_leap:
    mov r10, 0
.ts_calc_days:
    mov rax, 365
    add rax, r10
    cmp rcx, rax
    jb .ts_year_found
    sub rcx, rax
    inc r9
    jmp .ts_year_loop
    
.ts_year_found:
    mov [g_year], r9
    mov [g_day_of_year], rcx
    mov [g_is_leap], r10
    
    mov rcx, [g_day_of_year]
    mov r8, 1
    mov r9, month_days_array
.ts_month_loop:
    movzx r10, byte [r9 + r8 - 1]
    cmp r8, 2
    jne .ts_no_feb
    add r10, [g_is_leap]
.ts_no_feb:
    cmp rcx, r10
    jb .ts_month_found
    sub rcx, r10
    inc r8
    jmp .ts_month_loop
    
.ts_month_found:
    inc rcx
    mov [g_month], r8
    mov [g_day], rcx
    
    pop rdi
    mov rax, [g_year]
    push rdi
    call ts_format_4_digits
    mov byte [rdi], '-'
    inc rdi
    mov rax, [g_month]
    call ts_format_2_digits
    mov byte [rdi], '-'
    inc rdi
    mov rax, [g_day]
    call ts_format_2_digits
    mov byte [rdi], 'T'
    inc rdi
    mov rax, [g_hours]
    call ts_format_2_digits
    mov byte [rdi], ':'
    inc rdi
    mov rax, [g_minutes]
    call ts_format_2_digits
    mov byte [rdi], ':'
    inc rdi
    mov rax, [g_seconds]
    call ts_format_2_digits
    mov byte [rdi], 'Z'
    inc rdi
    mov byte [rdi], 0
    pop rdi
    
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

parse_find_json_string:
    push rbp
    mov rbp, rsp
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    push r10
    push r11
    
    call util_strlen
    mov r8, rax
    mov r9, rdi
.parse_find_json_loop:
    mov rdi, r9
    mov rcx, r8
    repe cmpsb
    je .parse_find_json_found
    inc r9
    mov al, [r9]
    test al, al
    jnz .parse_find_json_loop
    xor rax, rax
    jmp .parse_find_json_done
.parse_find_json_found:
    add r9, r8
.parse_skip_ws:
    mov bl, [r9]
    cmp bl, ' '
    je .parse_skip_ws_inc
    cmp bl, 9
    je .parse_skip_ws_inc
    cmp bl, 10
    je .parse_skip_ws_inc
    cmp bl, 13
    je .parse_skip_ws_inc
    cmp bl, ':'
    jne .parse_find_json_not_found
    inc r9
    jmp .parse_skip_ws
.parse_skip_ws_inc:
    inc r9
    jmp .parse_skip_ws
.parse_skip_ws2:
    mov bl, [r9]
    cmp bl, ' '
    je .parse_skip_ws2_inc
    cmp bl, 9
    je .parse_skip_ws2_inc
    cmp bl, 10
    je .parse_skip_ws2_inc
    cmp bl, 13
    je .parse_skip_ws2_inc
    jmp .parse_check_quote
.parse_skip_ws2_inc:
    inc r9
    jmp .parse_skip_ws2
.parse_check_quote:
    cmp byte [r9], '"'
    jne .parse_find_json_not_found
    inc r9
    mov r10, [rbp-24]
    mov r11, 0
.parse_copy_val:
    mov bl, [r9]
    cmp bl, '"'
    je .parse_str_end
    cmp bl, 0
    je .parse_find_json_not_found
    mov [r10 + r11], bl
    inc r9
    inc r11
    cmp r11, qword [rbp-16]
    jae .parse_find_json_not_found
    jmp .parse_copy_val
.parse_str_end:
    mov byte [r10 + r11], 0
    mov rax, 1
    jmp .parse_find_json_done
.parse_find_json_not_found:
    xor rax, rax
.parse_find_json_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    ret

parse_request:
    push rbp
    mov rbp, rsp
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    
    mov r8, rdi
    mov rdi, r8
    mov al, ' '
    mov rcx, 256
    repne scasb
    jne .parse_req_err
    dec rdi
    mov r9, rdi
    sub r9, r8
    mov rcx, r9
    mov rdi, g_method
    mov rsi, r8
    rep movsb
    mov byte [rdi], 0
    
    inc r9
    mov rsi, r8
    add rsi, r9
    mov rdi, rsi
    mov al, ' '
    mov rcx, 512
    repne scasb
    jne .parse_req_err
    dec rdi
    mov r9, rdi
    sub r9, rsi
    mov rcx, r9
    mov rdi, g_path
    rep movsb
    mov byte [rdi], 0
    
    mov rdi, r8
    mov rsi, crlfcrlf
    call util_strstr
    test rax, rax
    jz .parse_req_err
    mov r9, rax
    add r9, 4
    
    mov rdi, r8
    mov rsi, cookie_str
    call util_strstr
    test rax, rax
    jz .parse_req_no_cookie
    mov rdi, rax
    mov rsi, session_id_str
    call util_strstr
    test rax, rax
    jz .parse_req_no_cookie
    add rax, 11
    mov rdi, g_cookie_token
.parse_req_copy_cookie:
    mov bl, [rax]
    cmp bl, ';'
    je .parse_req_cookie_done
    cmp bl, 13
    je .parse_req_cookie_done
    cmp bl, 10
    je .parse_req_cookie_done
    cmp bl, 0
    je .parse_req_cookie_done
    mov [rdi], bl
    inc rax
    inc rdi
    jmp .parse_req_copy_cookie
.parse_req_cookie_done:
    mov byte [rdi], 0
    jmp .parse_req_find_cl
.parse_req_no_cookie:
    mov byte [g_cookie_token], 0
    
.parse_req_find_cl:
    mov rdi, r8
    mov rsi, cl_str
    call util_strstr
    test rax, rax
    jz .parse_req_no_cl
    add rax, 16
    mov rdi, rax
    call util_parse_int
    mov [g_body_len], rax
    jmp .parse_req_done
.parse_req_no_cl:
    mov qword [g_body_len], 0
    
.parse_req_done:
    mov rcx, [g_body_len]
    test rcx, rcx
    jz .parse_req_no_body
    mov rdi, g_body_buf
    mov rsi, r9
    rep movsb
    mov byte [rdi], 0
.parse_req_no_body:
    mov rax, 1
    jmp .parse_req_exit
.parse_req_err:
    xor rax, rax
.parse_req_exit:
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    ret

auth_check:
    mov rdi, g_cookie_token
    call auth_find_session
    test rax, rax
    js .auth_check_invalid
    mov rsi, g_sessions
    imul rdx, rax, 40
    add rsi, rdx
    mov eax, [rsi + 32]
    ret
.auth_check_invalid:
    xor rax, rax
    ret

auth_find_session:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rsi
    push rdi
    
    mov rcx, [g_session_count]
    test rcx, rcx
    jz .auth_find_sess_not_found
    mov rbx, 0
.auth_find_sess_loop:
    cmp rbx, rcx
    jge .auth_find_sess_not_found
    mov rsi, g_sessions
    imul rax, rbx, 40
    add rsi, rax
    cmp byte [rsi + 36], 0
    jne .auth_find_sess_next
    mov rdi, [rbp-8]
    push rcx
    push rbx
    mov rcx, 32
    repe cmpsb
    pop rbx
    pop rcx
    je .auth_find_sess_found
.auth_find_sess_next:
    inc rbx
    jmp .auth_find_sess_loop
.auth_find_sess_not_found:
    mov rax, -1
    jmp .auth_find_sess_done
.auth_find_sess_found:
    mov rax, rbx
.auth_find_sess_done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rbp
    ret

auth_generate_uuid:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    
    mov rax, 2
    mov rdi, urandom_path
    xor rsi, rsi
    xor rdx, rdx
    syscall
    test rax, rax
    js .auth_gen_uuid_err
    mov r8, rax
    
    mov rax, 0
    mov rdi, r8
    mov rsi, g_temp_buf
    mov rdx, 16
    syscall
    
    push rax
    mov rax, 3
    mov rdi, r8
    syscall
    pop rax
    
    mov r9, rdi
    mov r10, g_temp_buf
    mov rcx, 16
.auth_gen_hex_loop:
    movzx r11, byte [r10]
    mov rax, r11
    shr rax, 4
    call auth_hex_digit
    mov [r9], al
    inc r9
    mov rax, r11
    and rax, 0x0F
    call auth_hex_digit
    mov [r9], al
    inc r9
    inc r10
    loop .auth_gen_hex_loop
    mov byte [r9], 0
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret
.auth_gen_uuid_err:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

auth_hex_digit:
    cmp al, 9
    jbe .auth_hex_is_num
    add al, 'a' - 10
    ret
.auth_hex_is_num:
    add al, '0'
    ret

auth_create_session:
    push rbp
    mov rbp, rsp
    push rdi
    push rbx
    
    mov rdi, g_temp_buf
    call auth_generate_uuid
    
    mov rcx, 100
    mov rbx, 0
.auth_create_sess_find:
    cmp rbx, rcx
    jge .auth_create_sess_no_slot
    mov rsi, g_sessions
    imul rdx, rbx, 40
    add rsi, rdx
    cmp byte [rsi + 36], 0
    je .auth_create_sess_found_slot
    inc rbx
    jmp .auth_create_sess_find
.auth_create_sess_no_slot:
    mov rax, -1
    jmp .auth_create_sess_done
.auth_create_sess_found_slot:
    mov rdi, rsi
    mov rsi, g_temp_buf
    mov rcx, 32
    rep movsb
    mov [rsi + 32], edi
    mov byte [rsi + 36], 1
    mov rax, rbx
.auth_create_sess_done:
    pop rbx
    pop rdi
    pop rbp
    ret

validate_username:
    push rcx
    push rsi
    call util_strlen
    cmp rax, 3
    jb .valid_user_invalid
    cmp rax, 50
    ja .valid_user_invalid
    mov rcx, rax
    mov rsi, rdi
.valid_user_check:
    mov al, [rsi]
    cmp al, 'a'
    jb .valid_user_check_A
    cmp al, 'z'
    jbe .valid_user_ok
.valid_user_check_A:
    cmp al, 'A'
    jb .valid_user_check_0
    cmp al, 'Z'
    jbe .valid_user_ok
.valid_user_check_0:
    cmp al, '0'
    jb .valid_user_invalid
    cmp al, '9'
    jbe .valid_user_ok
    cmp al, '_'
    je .valid_user_ok
    jmp .valid_user_invalid
.valid_user_ok:
    inc rsi
    loop .valid_user_check
    mov rax, 1
    jmp .valid_user_done
.valid_user_invalid:
    xor rax, rax
.valid_user_done:
    pop rsi
    pop rcx
    ret

data_find_user_by_name:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rsi
    push rdi
    
    mov rcx, [g_user_count]
    test rcx, rcx
    jz .data_find_user_name_not_found
    mov rbx, 0
.data_find_user_name_loop:
    cmp rbx, rcx
    jge .data_find_user_name_not_found
    mov rsi, g_users
    imul rdx, rbx, 328
    add rsi, rdx
    add rsi, 4
    push rcx
    push rbx
    call util_strcmp
    pop rbx
    pop rcx
    test rax, rax
    jz .data_find_user_name_found
    inc rbx
    jmp .data_find_user_name_loop
.data_find_user_name_not_found:
    mov rax, -1
    jmp .data_find_user_name_done
.data_find_user_name_found:
    mov rax, rbx
.data_find_user_name_done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rbp
    ret

data_find_user_by_id:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdi
    
    mov rcx, [g_user_count]
    test rcx, rcx
    jz .data_find_user_id_not_found
    mov rbx, 0
.data_find_user_id_loop:
    cmp rbx, rcx
    jge .data_find_user_id_not_found
    mov rsi, g_users
    imul rdx, rbx, 328
    add rsi, rdx
    cmp dword [rsi], edi
    je .data_find_user_id_found
    inc rbx
    jmp .data_find_user_id_loop
.data_find_user_id_not_found:
    mov rax, -1
    jmp .data_find_user_id_done
.data_find_user_id_found:
    mov rax, rbx
.data_find_user_id_done:
    pop rdi
    pop rcx
    pop rbx
    pop rbp
    ret

data_create_user:
    push rbp
    mov rbp, rsp
    push rdi
    push rsi
    push r8
    push r9
    
    mov r8, [g_user_count]
    cmp r8, 100
    jge .data_create_user_no_space
    
    mov r9, g_users
    imul rdx, r8, 328
    add r9, rdx
    
    mov eax, r8d
    inc eax
    mov [r9], eax
    
    mov rdi, r9
    add rdi, 4
    mov rsi, [rbp-8]
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    
    mov rdi, r9
    add rdi, 68
    mov rsi, [rbp-16]
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    
    inc qword [g_user_count]
    mov rax, r8
    inc rax
    jmp .data_create_user_done
.data_create_user_no_space:
    mov rax, -1
.data_create_user_done:
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rbp
    ret

data_find_todo:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdi
    
    mov rcx, [g_todo_count]
    test rcx, rcx
    jz .data_find_todo_not_found
    mov rbx, 0
.data_find_todo_loop:
    cmp rbx, rcx
    jge .data_find_todo_not_found
    mov rsi, g_todos
    imul rdx, rbx, 704
    add rsi, rdx
    cmp dword [rsi], edi
    je .data_find_todo_found
    inc rbx
    jmp .data_find_todo_loop
.data_find_todo_not_found:
    mov rax, -1
    jmp .data_find_todo_done
.data_find_todo_found:
    mov rax, rbx
.data_find_todo_done:
    pop rdi
    pop rcx
    pop rbx
    pop rbp
    ret

data_build_todo_json:
    push rbp
    mov rbp, rsp
    push rdi
    push r8
    push r9
    
    mov r8, g_temp_todo_buf
    mov rdi, r8
    
    mov rsi, str_todo_open
    call util_append_str
    
    mov rsi, str_id
    call util_append_str
    mov eax, [rdi]
    push rdi
    mov rdi, g_temp_buf
    call util_itoa
    mov rsi, g_temp_buf
    call util_append_str
    pop rdi
    mov rsi, str_comma
    call util_append_str
    
    mov rsi, str_title
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, rdi
    add rsi, 8
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, str_comma
    call util_append_str
    
    mov rsi, str_desc
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, rdi
    add rsi, 136
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, str_comma
    call util_append_str
    
    mov rsi, str_completed
    call util_append_str
    mov rsi, rdi
    add rsi, 648
    cmp byte [rsi], 1
    je .data_build_todo_is_true
    mov rsi, str_false
    call util_append_str
    jmp .data_build_todo_completed_done
.data_build_todo_is_true:
    mov rsi, str_true
    call util_append_str
.data_build_todo_completed_done:
    mov rsi, str_comma
    call util_append_str
    
    mov rsi, str_created
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, rdi
    add rsi, 649
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, str_comma
    call util_append_str
    
    mov rsi, str_updated
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, rdi
    add rsi, 670
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    
    mov rsi, str_todo_close
    call util_append_str
    
    pop r9
    pop r8
    pop rdi
    pop rbp
    ret

send_json_response:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    
    mov r8, g_res_buf
    mov rdi, r8
    
    mov rsi, [rbp-16]
    cmp rsi, 200
    je .send_json_ok
    cmp rsi, 201
    je .send_json_created
    cmp rsi, 204
    je .send_json_no_content
    cmp rsi, 400
    je .send_json_bad
    cmp rsi, 401
    je .send_json_unauth
    cmp rsi, 404
    je .send_json_not_found
    cmp rsi, 409
    je .send_json_conflict
.send_json_ok:
    mov rsi, http_ok
    call util_append_str
    jmp .send_json_cont
.send_json_created:
    mov rsi, http_created
    call util_append_str
    jmp .send_json_cont
.send_json_no_content:
    mov rsi, http_no_content
    call util_append_str
    mov rsi, crlf
    call util_append_str
    mov rsi, crlf
    call util_append_str
    jmp .send_json_send
.send_json_bad:
    mov rsi, http_bad_req
    call util_append_str
    jmp .send_json_cont
.send_json_unauth:
    mov rsi, http_unauth
    call util_append_str
    jmp .send_json_cont
.send_json_not_found:
    mov rsi, http_not_found
    call util_append_str
    jmp .send_json_cont
.send_json_conflict:
    mov rsi, http_conflict
    call util_append_str
    jmp .send_json_cont
    
.send_json_cont:
    mov rsi, ct_json
    call util_append_str
    
    mov r9, [rbp-24]
    test r9, r9
    jz .send_json_no_extra
    mov rsi, r9
    call util_append_str
.send_json_no_extra:
    
    mov rsi, cl_header
    call util_append_str
    
    mov rdi, [rbp-8]
    test rdi, rdi
    jz .send_json_zero_len
    call util_strlen
    jmp .send_json_got_len
.send_json_zero_len:
    xor rax, rax
.send_json_got_len:
    mov [rbp-32], rax
    push rdi
    mov rdi, g_temp_buf
    call util_itoa
    mov rsi, g_temp_buf
    call util_append_str
    pop rdi
    
    mov rsi, crlf
    call util_append_str
    mov rsi, crlf
    call util_append_str
    
    mov rax, [rbp-32]
    test rax, rax
    jz .send_json_skip_body
    mov rdi, r8
    mov rsi, [rbp-8]
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    
.send_json_skip_body:
.send_json_send:
    mov rdi, r8
    call util_strlen
    mov rdx, rax
    mov rax, 1
    mov rdi, [g_client_fd]
    mov rsi, r8
    syscall
    
    add rsp, 32
    pop rbp
    ret

ep_get_me:
    call auth_check
    test rax, rax
    jz ep_auth_required
    mov [g_current_user_id], rax
    
    mov rdi, rax
    call data_find_user_by_id
    test rax, rax
    js ep_auth_required
    
    mov rsi, g_users
    imul rdx, rax, 328
    add rsi, rdx
    mov r9, rsi
    
    mov r8, g_res_body_buf
    mov rdi, r8
    mov rsi, str_user_open
    call util_append_str
    mov rsi, str_id
    call util_append_str
    mov eax, [r9]
    push rdi
    mov rdi, g_temp_buf
    call util_itoa
    mov rsi, g_temp_buf
    call util_append_str
    pop rdi
    mov rsi, str_comma
    call util_append_str
    mov rsi, str_username
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, r9
    add rsi, 4
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, str_user_close
    call util_append_str
    
    mov rdi, g_res_body_buf
    mov rsi, 200
    xor rdx, rdx
    call send_json_response
    ret

ep_get_todos:
    call auth_check
    test rax, rax
    jz ep_auth_required
    mov [g_current_user_id], rax
    
    mov r8, g_res_body_buf
    mov rdi, r8
    mov rsi, str_array_open
    call util_append_str
    
    mov rcx, [g_todo_count]
    test rcx, rcx
    jz ep_get_todos_end_array
    
    mov rbx, 0
    mov r9, 0
.ep_get_todos_loop:
    cmp rbx, rcx
    jge ep_get_todos_end_array
    
    mov rsi, g_todos
    imul rdx, rbx, 704
    add rsi, rdx
    
    mov eax, [rsi + 4]
    cmp eax, [g_current_user_id]
    jne .ep_get_todos_next
    
    test r9, r9
    jz .ep_get_todos_first
    mov rsi, str_comma
    call util_append_str
.ep_get_todos_first:
    push rcx
    push rbx
    push r9
    mov rdi, rsi
    call data_build_todo_json
    mov rsi, g_temp_todo_buf
    call util_append_str
    inc r9
    pop r9
    pop rbx
    pop rcx
    
.ep_get_todos_next:
    inc rbx
    jmp .ep_get_todos_loop
    
.ep_get_todos_end_array:
    mov rsi, str_array_close
    call util_append_str
    
    mov rdi, g_res_body_buf
    mov rsi, 200
    xor rdx, rdx
    call send_json_response
    ret

ep_get_todo_by_id:
    mov rdi, g_path
    mov rsi, path_todos_slash
    call util_strstr
    add rax, 8
    mov rdi, rax
    call util_parse_int
    mov [g_todo_id], rax
    
    call auth_check
    test rax, rax
    jz ep_auth_required
    mov [g_current_user_id], rax
    
    mov rdi, [g_todo_id]
    call data_find_todo
    test rax, rax
    js ep_todo_not_found
    
    mov rbx, rax
    mov rsi, g_todos
    imul rdx, rbx, 704
    add rsi, rdx
    
    mov ecx, [rsi + 4]
    cmp ecx, [g_current_user_id]
    jne ep_todo_not_found
    
    mov rdi, rsi
    call data_build_todo_json
    mov rdi, g_temp_todo_buf
    mov rsi, 200
    xor rdx, rdx
    call send_json_response
    ret

ep_post_register:
    mov rdi, g_body_buf
    mov rsi, str_key_username
    mov rdx, g_temp_val_buf
    mov rcx, 64
    call parse_find_json_string
    test rax, rax
    jz ep_reg_invalid_username
    mov rdi, g_temp_val_buf
    call validate_username
    test rax, rax
    jz ep_reg_invalid_username
    
    mov rdi, g_body_buf
    mov rsi, str_key_password
    mov rdx, g_temp_val_buf2
    mov rcx, 256
    call parse_find_json_string
    test rax, rax
    jz ep_reg_password_short
    mov rdi, g_temp_val_buf2
    call util_strlen
    cmp rax, 8
    jb ep_reg_password_short
    
    mov rdi, g_temp_val_buf
    call data_find_user_by_name
    test rax, rax
    jns ep_reg_user_exists
    
    mov rdi, g_temp_val_buf
    mov rsi, g_temp_val_buf2
    call data_create_user
    test rax, rax
    js ep_handle_404
    
    mov r8, g_res_body_buf
    mov rdi, r8
    mov rsi, str_user_open
    call util_append_str
    mov rsi, str_id
    call util_append_str
    mov rdi, g_temp_buf
    call util_itoa
    mov rsi, g_temp_buf
    call util_append_str
    mov rsi, str_comma
    call util_append_str
    mov rsi, str_username
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, g_temp_val_buf
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, str_user_close
    call util_append_str
    
    mov rdi, g_res_body_buf
    mov rsi, 201
    xor rdx, rdx
    call send_json_response
    ret

ep_reg_invalid_username:
    mov rdi, err_invalid_username
    mov rsi, 400
    xor rdx, rdx
    call send_json_response
    ret
ep_reg_password_short:
    mov rdi, err_password_short
    mov rsi, 400
    xor rdx, rdx
    call send_json_response
    ret
ep_reg_user_exists:
    mov rdi, err_user_exists
    mov rsi, 409
    xor rdx, rdx
    call send_json_response
    ret

ep_post_login:
    mov rdi, g_body_buf
    mov rsi, str_key_username
    mov rdx, g_temp_val_buf
    mov rcx, 64
    call parse_find_json_string
    test rax, rax
    jz ep_login_invalid
    
    mov rdi, g_body_buf
    mov rsi, str_key_password
    mov rdx, g_temp_val_buf2
    mov rcx, 256
    call parse_find_json_string
    test rax, rax
    jz ep_login_invalid
    
    mov rdi, g_temp_val_buf
    call data_find_user_by_name
    test rax, rax
    js ep_login_invalid
    
    mov rbx, rax
    mov rsi, g_users
    imul rdx, rbx, 328
    add rsi, rdx
    
    mov rdi, g_temp_val_buf2
    push rsi
    add rsi, 68
    call util_strcmp
    pop rsi
    test rax, rax
    jnz ep_login_invalid
    
    mov rdi, dword [rsi]
    call auth_create_session
    test rax, rax
    js ep_login_invalid
    
    mov rdi, g_temp_header_buf
    mov rsi, str_set_cookie
    call util_append_str
    mov rsi, g_temp_buf
    call util_append_str
    mov rsi, str_cookie_path
    call util_append_str
    
    mov r8, g_res_body_buf
    mov rdi, r8
    mov rsi, str_user_open
    call util_append_str
    mov rsi, str_id
    call util_append_str
    mov eax, [rsi]
    push rdi
    mov rdi, g_temp_buf
    call util_itoa
    mov rsi, g_temp_buf
    call util_append_str
    pop rdi
    mov rsi, str_comma
    call util_append_str
    mov rsi, str_username
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, rsi
    add rsi, 4
    call util_append_str
    mov rsi, str_quote
    call util_append_str
    mov rsi, str_user_close
    call util_append_str
    
    mov rdi, g_res_body_buf
    mov rsi, 200
    mov rdx, g_temp_header_buf
    call send_json_response
    ret

ep_login_invalid:
    mov rdi, err_invalid_creds
    mov rsi, 401
    xor rdx, rdx
    call send_json_response
    ret

ep_post_logout:
    call auth_check
    test rax, rax
    jz ep_auth_required
    
    mov rdi, g_cookie_token
    call auth_find_session
    test rax, rax
    js ep_auth_required
    
    mov rsi, g_sessions
    imul rdx, rax, 40
    add rsi, rdx
    mov byte [rsi + 36], 0
    
    mov rdi, err_logout_success
    mov rsi, 200
    xor rdx, rdx
    call send_json_response
    ret

ep_post_todos:
    call auth_check
    test rax, rax
    jz ep_auth_required
    mov [g_current_user_id], rax
    
    mov rdi, g_body_buf
    mov rsi, str_key_title
    mov rdx, g_temp_val_buf
    mov rcx, 128
    call parse_find_json_string
    test rax, rax
    jz ep_post_title_required
    mov rdi, g_temp_val_buf
    call util_strlen
    test rax, rax
    jz ep_post_title_required
    
    mov rdi, g_body_buf
    mov rsi, str_key_desc
    mov rdx, g_temp_val_buf2
    mov rcx, 512
    call parse_find_json_string
    test rax, rax
    jz .ep_post_todos_no_desc
    jmp .ep_post_todos_has_desc
.ep_post_todos_no_desc:
    mov rdi, g_temp_val_buf2
    mov byte [rdi], 0
.ep_post_todos_has_desc:
    
    mov rcx, [g_todo_count]
    cmp rcx, 1000
    jge ep_handle_404
    
    mov rsi, g_todos
    imul rdx, rcx, 704
    add rsi, rdx
    
    mov eax, ecx
    inc eax
    mov [rsi], eax
    
    mov eax, [g_current_user_id]
    mov [rsi + 4], eax
    
    mov rdi, rsi
    add rdi, 8
    mov rsi, g_temp_val_buf
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    
    mov rdi, rsi
    add rdi, 136
    mov rsi, g_temp_val_buf2
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    
    mov byte [rsi + 648], 0
    
    mov rdi, g_temp_ts_buf
    call get_current_timestamp
    mov rdi, rsi
    add rdi, 649
    mov rsi, g_temp_ts_buf
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    
    mov rdi, rsi
    add rdi, 670
    mov rsi, g_temp_ts_buf
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    
    inc qword [g_todo_count]
    
    mov rdi, rsi
    call data_build_todo_json
    mov rdi, g_temp_todo_buf
    mov rsi, 201
    xor rdx, rdx
    call send_json_response
    ret

ep_post_title_required:
    mov rdi, err_title_required
    mov rsi, 400
    xor rdx, rdx
    call send_json_response
    ret

ep_put_password:
    call auth_check
    test rax, rax
    jz ep_auth_required
    mov [g_current_user_id], rax
    
    mov rdi, g_body_buf
    mov rsi, str_key_old_password
    mov rdx, g_temp_val_buf
    mov rcx, 256
    call parse_find_json_string
    test rax, rax
    jz ep_put_pwd_invalid
    
    mov rdi, g_body_buf
    mov rsi, str_key_new_password
    mov rdx, g_temp_val_buf2
    mov rcx, 256
    call parse_find_json_string
    test rax, rax
    jz ep_put_pwd_invalid
    
    mov rdi, g_temp_val_buf2
    call util_strlen
    cmp rax, 8
    jb ep_put_pwd_short
    
    mov rdi, [g_current_user_id]
    call data_find_user_by_id
    test rax, rax
    js ep_put_pwd_invalid
    
    mov rsi, g_users
    imul rdx, rax, 328
    add rsi, rdx
    add rsi, 68
    mov rdi, g_temp_val_buf
    push rsi
    call util_strcmp
    pop rsi
    test rax, rax
    jnz ep_put_pwd_invalid
    
    mov rdi, rsi
    mov rsi, g_temp_val_buf2
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    
    mov rdi, err_password_success
    mov rsi, 200
    xor rdx, rdx
    call send_json_response
    ret

ep_put_pwd_invalid:
    mov rdi, err_invalid_creds
    mov rsi, 401
    xor rdx, rdx
    call send_json_response
    ret
ep_put_pwd_short:
    mov rdi, err_password_short
    mov rsi, 400
    xor rdx, rdx
    call send_json_response
    ret

ep_put_todo_by_id:
    call auth_check
    test rax, rax
    jz ep_auth_required
    mov [g_current_user_id], rax
    
    mov rdi, g_path
    mov rsi, path_todos_slash
    call util_strstr
    add rax, 8
    mov rdi, rax
    call util_parse_int
    mov [g_todo_id], rax
    
    mov rdi, [g_todo_id]
    call data_find_todo
    test rax, rax
    js ep_todo_not_found
    
    mov rbx, rax
    mov rsi, g_todos
    imul rdx, rbx, 704
    add rsi, rdx
    
    mov ecx, [rsi + 4]
    cmp ecx, [g_current_user_id]
    jne ep_todo_not_found
    
    mov rdi, g_body_buf
    mov rsi, str_key_title
    mov rdx, g_temp_val_buf
    mov rcx, 128
    call parse_find_json_string
    test rax, rax
    jnz .ep_put_todo_has_title
    jmp .ep_put_todo_check_desc
.ep_put_todo_has_title:
    mov rdi, g_temp_val_buf
    call util_strlen
    test rax, rax
    jz ep_put_title_required
    
    mov rdi, rsi
    add rdi, 8
    push rsi
    mov rsi, g_temp_val_buf
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    pop rsi
    
.ep_put_todo_check_desc:
    mov rdi, g_body_buf
    mov rsi, str_key_desc
    mov rdx, g_temp_val_buf
    mov rcx, 512
    call parse_find_json_string
    test rax, rax
    jnz .ep_put_todo_has_desc
    jmp .ep_put_todo_check_completed
.ep_put_todo_has_desc:
    mov rdi, rsi
    add rdi, 136
    push rsi
    mov rsi, g_temp_val_buf
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    pop rsi
    
.ep_put_todo_check_completed:
    mov rdi, g_body_buf
    mov rsi, str_key_completed
    call util_strstr
    test rax, rax
    jz .ep_put_todo_update_time
    
    add rax, 12
.ep_put_todo_skip_ws:
    mov bl, [rax]
    cmp bl, ' '
    je .ep_put_todo_skip_ws_inc
    cmp bl, 9
    je .ep_put_todo_skip_ws_inc
    cmp bl, 10
    je .ep_put_todo_skip_ws_inc
    cmp bl, 13
    je .ep_put_todo_skip_ws_inc
    cmp bl, ':'
    jne .ep_put_todo_update_time
    inc rax
    jmp .ep_put_todo_skip_ws
.ep_put_todo_skip_ws_inc:
    inc rax
    jmp .ep_put_todo_skip_ws
    
    mov rdi, rax
    mov rsi, str_true
    call util_strstr
    test rax, rax
    jnz .ep_put_todo_set_true
    mov rdi, rax
    mov rsi, str_false
    call util_strstr
    test rax, rax
    jnz .ep_put_todo_set_false
    jmp .ep_put_todo_update_time
    
.ep_put_todo_set_true:
    mov byte [rsi + 648], 1
    jmp .ep_put_todo_update_time
.ep_put_todo_set_false:
    mov byte [rsi + 648], 0
    
.ep_put_todo_update_time:
    mov rdi, g_temp_ts_buf
    call get_current_timestamp
    mov rdi, rsi
    add rdi, 670
    mov rsi, g_temp_ts_buf
    call util_strlen
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    
    mov rdi, rsi
    call data_build_todo_json
    mov rdi, g_temp_todo_buf
    mov rsi, 200
    xor rdx, rdx
    call send_json_response
    ret

ep_put_title_required:
    mov rdi, err_title_required
    mov rsi, 400
    xor rdx, rdx
    call send_json_response
    ret

ep_delete_todo_by_id:
    call auth_check
    test rax, rax
    jz ep_auth_required
    mov [g_current_user_id], rax
    
    mov rdi, g_path
    mov rsi, path_todos_slash
    call util_strstr
    add rax, 8
    mov rdi, rax
    call util_parse_int
    mov [g_todo_id], rax
    
    mov rdi, [g_todo_id]
    call data_find_todo
    test rax, rax
    js ep_todo_not_found
    
    mov rbx, rax
    mov rsi, g_todos
    imul rdx, rbx, 704
    add rsi, rdx
    
    mov ecx, [rsi + 4]
    cmp ecx, [g_current_user_id]
    jne ep_todo_not_found
    
    mov rcx, [g_todo_count]
    sub rcx, rbx
    dec rcx
    test rcx, rcx
    jz .ep_delete_todo_shift_done
    
    mov rdi, rsi
    mov rsi, rdi
    add rsi, 704
    mov rax, [g_todo_count]
    sub rax, rbx
    dec rax
    imul rcx, rax, 704
    cld
    rep movsb
    
    dec qword [g_todo_count]
.ep_delete_todo_shift_done:
    
    mov rdi, 0
    mov rsi, 204
    xor rdx, rdx
    call send_json_response
    ret

ep_todo_not_found:
    mov rdi, err_todo_not_found
    mov rsi, 404
    xor rdx, rdx
    call send_json_response
    ret

ep_auth_required:
    mov rdi, err_auth_required
    mov rsi, 401
    xor rdx, rdx
    call send_json_response
    ret

ep_handle_404:
    mov rdi, err_todo_not_found
    mov rsi, 404
    xor rdx, rdx
    call send_json_response
    ret

ep_handle_get:
    mov rdi, g_path
    mov rsi, path_me
    call util_strcmp
    je ep_get_me
    
    mov rdi, g_path
    mov rsi, path_todos
    call util_strcmp
    je ep_get_todos
    
    mov rdi, g_path
    mov rsi, path_todos_slash
    call util_strstr
    test rax, rax
    jnz ep_get_todo_by_id
    
    jmp ep_handle_404

ep_handle_post:
    mov rdi, g_path
    mov rsi, path_register
    call util_strcmp
    je ep_post_register
    
    mov rdi, g_path
    mov rsi, path_login
    call util_strcmp
    je ep_post_login
    
    mov rdi, g_path
    mov rsi, path_logout
    call util_strcmp
    je ep_post_logout
    
    mov rdi, g_path
    mov rsi, path_todos
    call util_strcmp
    je ep_post_todos
    
    jmp ep_handle_404

ep_handle_put:
    mov rdi, g_path
    mov rsi, path_password
    call util_strcmp
    je ep_put_password
    
    mov rdi, g_path
    mov rsi, path_todos_slash
    call util_strstr
    test rax, rax
    jnz ep_put_todo_by_id
    
    jmp ep_handle_404

ep_handle_delete:
    mov rdi, g_path
    mov rsi, path_todos_slash
    call util_strstr
    test rax, rax
    jnz ep_delete_todo_by_id
    
    jmp ep_handle_404

_start:
    mov rax, [rsp]
    cmp rax, 3
    jne ._start_default_port
    mov rdi, [rsp + 16]
    mov rsi, str_port_arg
    call util_strcmp
    test rax, rax
    jne ._start_default_port
    mov rdi, [rsp + 24]
    call util_parse_int
    test rax, rax
    jz ._start_default_port
    mov [g_port], ax
    jmp ._start_init
._start_default_port:
    mov word [g_port], 8080
._start_init:
    mov qword [g_user_count], 1
    mov qword [g_session_count], 1
    mov qword [g_todo_count], 1
    
    mov ax, [g_port]
    xchg al, ah
    mov [g_sockaddr + 2], ax
    
    mov rax, 41
    mov rdi, 2
    mov rsi, 1
    xor rdx, rdx
    syscall
    mov [g_sock_fd], rax
    
    mov rax, 49
    mov rdi, [g_sock_fd]
    mov rsi, g_sockaddr
    mov rdx, 16
    syscall
    
    mov rax, 50
    mov rdi, [g_sock_fd]
    mov rsi, 128
    syscall
    
._start_main_loop:
    mov rax, 43
    mov rdi, [g_sock_fd]
    xor rsi, rsi
    xor rdx, rdx
    syscall
    test rax, rax
    js ._start_main_loop
    mov [g_client_fd], rax
    
    mov rax, 0
    mov rdi, [g_client_fd]
    mov rsi, g_req_buf
    mov rdx, 8192
    syscall
    test rax, rax
    jle ._start_close_client
    
    mov rdi, g_req_buf
    call parse_request
    test rax, rax
    jz ._start_bad_request
    
    mov rdi, g_method
    mov rsi, method_get
    call util_strcmp
    je ep_handle_get
    
    mov rdi, g_method
    mov rsi, method_post
    call util_strcmp
    je ep_handle_post
    
    mov rdi, g_method
    mov rsi, method_put
    call util_strcmp
    je ep_handle_put
    
    mov rdi, g_method
    mov rsi, method_delete
    call util_strcmp
    je ep_handle_delete
    
._start_bad_request:
    mov rdi, err_invalid_username
    mov rsi, 400
    xor rdx, rdx
    call send_json_response
    jmp ._start_close_client
    
._start_close_client:
    mov rax, 3
    mov rdi, [g_client_fd]
    syscall
    jmp ._start_main_loop

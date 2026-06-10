global _start
section .data
    str_port db "--port", 0
    dev_urandom db "/dev/urandom", 0
    
    msg_200 db "HTTP/1.1 200 OK", 13, 10, 0
    msg_201 db "HTTP/1.1 201 Created", 13, 10, 0
    msg_204 db "HTTP/1.1 204 No Content", 13, 10, 0
    msg_400 db "HTTP/1.1 400 Bad Request", 13, 10, 0
    msg_401 db "HTTP/1.1 401 Unauthorized", 13, 10, 0
    msg_404 db "HTTP/1.1 404 Not Found", 13, 10, 0
    msg_409 db "HTTP/1.1 409 Conflict", 13, 10, 0
    msg_500 db "HTTP/1.1 500 Internal Server Error", 13, 10, 0

    content_type db "Content-Type: application/json", 13, 10, 0
    content_len db "Content-Length: ", 0
    set_cookie db "Set-Cookie: session_id=", 0
    cookie_attrs db "; Path=/; HttpOnly", 13, 10, 0
    
    str_post db "POST", 0
    str_get db "GET", 0
    str_put db "PUT", 0
    str_delete db "DELETE", 0
    
    str_register db "/register", 0
    str_login db "/login", 0
    str_logout db "/logout", 0
    str_me db "/me", 0
    str_password db "/password", 0
    str_todos db "/todos", 0
    str_todos_slash db "/todos/", 0
    
    str_content_length db "Content-Length: ", 0
    str_cookie db "Cookie: ", 0
    str_session_id db "session_id=", 0
    
    str_key_username db '"username": "', 0
    str_key_password db '"password": "', 0
    str_key_old_pass db '"old_password": "', 0
    str_key_new_pass db '"new_password": "', 0
    str_key_title db '"title": "', 0
    str_key_desc db '"description": "', 0
    str_key_comp db '"completed": ', 0
    
    str_todo_start db '{"id":', 0
    str_title db ',"title":"', 0
    str_desc db '","description":"', 0
    str_completed db '","completed":', 0
    str_true db 'true', 0
    str_false db 'false', 0
    str_created db ',"created_at":"', 0
    str_updated db '","updated_at":"', 0
    str_todo_end db '"}', 0
    
    err_invalid_username db '{"error": "Invalid username"}', 0
    err_pass_short db '{"error": "Password too short"}', 0
    err_user_exists db '{"error": "Username already exists"}', 0
    err_invalid_cred db '{"error": "Invalid credentials"}', 0
    err_auth_req db '{"error": "Authentication required"}', 0
    err_title_req db '{"error": "Title is required"}', 0
    err_todo_not_found db '{"error": "Todo not found"}', 0
    err_empty_obj db '{}', 0
    usage_str db "Usage: ./server --port PORT", 10

    sockaddr_in:
        dw 2              ; AF_INET
        dw 0              ; port
        dd 0              ; 0.0.0.0
        times 8 db 0

section .bss
    server_fd resq 1
    client_fd resq 1
    server_port resw 1
    current_user_idx resq 1
    
    recv_buf resb 8192
    send_buf resb 8192
    temp_buf resb 512
    token_buf resb 33
    
    method_buf resb 16
    path_buf resb 256
    body_ptr resq 1
    body_len resq 1
    cookie_token resq 1
    cookie_buf resb 64
    
    timespec resq 2
    
    MAX_USERS EQU 100
    MAX_SESSIONS EQU 1000
    MAX_TODOS EQU 1000
    
    user_count resq 1
    user_usernames resb MAX_USERS * 51
    user_passwords resb MAX_USERS * 257
    
    session_count resq 1
    session_tokens resb MAX_SESSIONS * 33
    session_user_ids resq MAX_SESSIONS
    
    todo_count resq 1
    todo_user_ids resq MAX_TODOS
    todo_titles resb MAX_TODOS * 257
    todo_descriptions resb MAX_TODOS * 1025
    todo_completed resb MAX_TODOS
    todo_created_at resb MAX_TODOS * 21
    todo_updated_at resb MAX_TODOS * 21

section .text
global _start


; ============================================================================
; Utility Functions
; ============================================================================

strlen:
    push rdi
    mov rcx, -1
    xor rax, rax
    cld
    repne scasb
    not rcx
    mov rax, rcx
    pop rdi
    ret

streq:
    push rdi
    push rsi
.streq_loop:
    mov al, [rdi]
    mov dl, [rsi]
    cmp al, dl
    jne .streq_false
    test al, al
    jz .streq_true
    inc rdi
    inc rsi
    jmp .streq_loop
.streq_true:
    mov rax, 1
    pop rsi
    pop rdi
    ret
.streq_false:
    xor rax, rax
    pop rsi
    pop rdi
    ret

startswith:
    push rdi
    push rsi
.startswith_loop:
    mov al, [rsi]
    test al, al
    jz .startswith_true
    mov dl, [rdi]
    cmp al, dl
    jne .startswith_false
    inc rdi
    inc rsi
    jmp .startswith_loop
.startswith_true:
    mov rax, 1
    pop rsi
    pop rdi
    ret
.startswith_false:
    xor rax, rax
    pop rsi
    pop rdi
    ret

atoi:
    xor rax, rax
    xor rcx, rcx
.atoi_loop:
    mov cl, [rdi]
    test cl, cl
    jz .atoi_done
    cmp cl, '0'
    jl .atoi_done
    cmp cl, '9'
    jg .atoi_done
    sub cl, '0'
    imul rax, rax, 10
    add rax, rcx
    inc rdi
    jmp .atoi_loop
.atoi_done:
    ret

copy_str:
.copy_str_loop:
    mov al, [r9]
    test al, al
    jz .copy_str_done
    mov [r8], al
    inc r9
    inc r8
    jmp .copy_str_loop
.copy_str_done:
    ret

copy_str_escaped:
.copy_esc_loop:
    mov al, [r9]
    test al, al
    jz .copy_esc_done
    cmp al, '"'
    je .escape_quote
    cmp al, '\'
    je .escape_backslash
    cmp al, 10
    je .escape_newline
    mov [r8], al
    inc r9
    inc r8
    jmp .copy_esc_loop
.escape_quote:
    mov byte [r8], 92   ; '\'
    mov byte [r8+1], 34 ; '"'
    add r8, 2
    inc r9
    jmp .copy_esc_loop
.escape_backslash:
    mov byte [r8], 92   ; '\'
    mov byte [r8+1], 92 ; '\'
    add r8, 2
    inc r9
    jmp .copy_esc_loop
.escape_newline:
    mov byte [r8], 92   ; '\'
    mov byte [r8+1], 110 ; 'n'
    add r8, 2
    inc r9
    jmp .copy_esc_loop
.copy_esc_done:
    ret

find_key:
    push rdi
    push rsi
    push rcx
    mov rcx, 4096
.find_key_search:
    mov r8, rdi
    mov r9, rsi
.find_key_check:
    mov al, [r8]
    mov dl, [r9]
    cmp al, dl
    jne .find_key_next
    test al, al
    jz .find_key_found
    inc r8
    inc r9
    jmp .find_key_check
.find_key_next:
    inc rdi
    dec rcx
    jnz .find_key_search
    xor rax, rax
    jmp .find_key_done
.find_key_found:
    mov rax, r8
.find_key_done:
    pop rcx
    pop rsi
    pop rdi
    ret

extract_string_value:
    cmp byte [rdi], 34 ; '"'
    jne .ext_str_fail
    inc rdi
.ext_str_loop:
    mov al, [rdi]
    cmp al, 34 ; '"'
    je .ext_str_done
    cmp al, 0
    je .ext_str_fail
    mov [rsi], al
    inc rsi
    inc rdi
    loop .ext_str_loop
.ext_str_fail:
    xor rax, rax
    ret
.ext_str_done:
    mov rax, 1
    ret

extract_bool:
    mov al, [rdi]
    cmp al, 't'
    jne .ext_bool_check_f
    mov al, [rdi+1]
    cmp al, 'r'
    jne .ext_bool_check_f
    mov al, [rdi+2]
    cmp al, 'u'
    jne .ext_bool_check_f
    mov al, [rdi+3]
    cmp al, 'e'
    jne .ext_bool_check_f
    mov rax, 1
    ret
.ext_bool_check_f:
    mov al, [rdi]
    cmp al, 'f'
    jne .ext_bool_neither
    mov al, [rdi+1]
    cmp al, 'a'
    jne .ext_bool_neither
    mov al, [rdi+2]
    cmp al, 'l'
    jne .ext_bool_neither
    mov al, [rdi+3]
    cmp al, 's'
    jne .ext_bool_neither
    mov al, [rdi+4]
    cmp al, 'e'
    jne .ext_bool_neither
    mov rax, 0
    ret
.ext_bool_neither:
    mov rax, -1
    ret

find_user_by_username:
    mov rcx, [user_count]
    xor rbx, rbx
.fubu_loop:
    cmp rbx, rcx
    jge .fubu_not_found
    mov r8, user_usernames
    mov rax, rbx
    imul rax, 51
    add r8, rax
    push rdi
    mov rsi, r8
    call streq
    pop rdi
    test rax, rax
    jz .fubu_found
    inc rbx
    jmp .fubu_loop
.fubu_not_found:
    mov rbx, -1
.fubu_found:
    ret

find_session:
    mov rcx, [session_count]
    xor rbx, rbx
.fs_loop:
    cmp rbx, rcx
    jge .fs_not_found
    mov r8, session_tokens
    mov rax, rbx
    imul rax, 33
    add r8, rax
    push rdi
    mov rsi, r8
    call streq
    pop rdi
    test rax, rax
    jz .fs_found
    inc rbx
    jmp .fs_loop
.fs_not_found:
    mov rbx, -1
.fs_found:
    ret

add_session:
    mov rcx, [session_count]
    xor rbx, rbx
.as_loop:
    cmp rbx, rcx
    jge .as_append
    mov r8, session_tokens
    mov rax, rbx
    imul rax, 33
    add r8, rax
    cmp byte [r8], 0
    je .as_reuse
    inc rbx
    jmp .as_loop
.as_reuse:
    mov r8, session_tokens
    mov rax, rbx
    imul rax, 33
    add r8, rax
    jmp .as_copy
.as_append:
    cmp rcx, MAX_SESSIONS
    jge .as_error
    mov rbx, rcx
    mov r8, session_tokens
    mov rax, rbx
    imul rax, 33
    add r8, rax
    inc qword [session_count]
.as_copy:
    mov rcx, 32
    rep movsb
    mov byte [r8], 0
    mov rax, rbx
    mov [session_user_ids + rax*8], rsi
    ret
.as_error:
    mov rbx, -1
    ret

find_todo_by_id:
    mov rcx, [todo_count]
    xor rbx, rbx
.ftbi_loop:
    cmp rbx, rcx
    jge .ftbi_not_found
    mov rax, [todo_user_ids + rbx*8]
    test rax, rax
    jz .ftbi_skip
    mov rax, rbx
    inc rax
    cmp rax, rdi
    je .ftbi_found
.ftbi_skip:
    inc rbx
    jmp .ftbi_loop
.ftbi_not_found:
    mov rbx, -1
.ftbi_found:
    ret

validate_username:
    cmp rsi, 3
    jl .vu_invalid
    cmp rsi, 50
    jg .vu_invalid
    xor rcx, rcx
.vu_loop:
    cmp rcx, rsi
    jge .vu_valid
    mov al, [rdi + rcx]
    cmp al, 'a'
    jl .vu_check_upper
    cmp al, 'z'
    jle .vu_ok
.vu_check_upper:
    cmp al, 'A'
    jl .vu_check_digit
    cmp al, 'Z'
    jle .vu_ok
.vu_check_digit:
    cmp al, '0'
    jl .vu_invalid
    cmp al, '9'
    jle .vu_ok
    cmp al, '_'
    je .vu_ok
.vu_invalid:
    xor rax, rax
    ret
.vu_ok:
    inc rcx
    jmp .vu_loop
.vu_valid:
    mov rax, 1
    ret

unix_to_utc:
    mov rax, rdi
    xor rdx, rdx
    mov rcx, 86400
    div rcx
    mov r8, rdx
    
    xor rdx, rdx
    mov rcx, 3600
    div rcx
    mov r9, rax
    
    mov rax, r8
    xor rdx, rdx
    mov rcx, 60
    div rcx
    mov r10, rax
    mov r11, rdx
    
    mov rax, rdi
    add rax, 719468
    xor rdx, rdx
    mov rcx, 146097
    div rcx
    mov r12, rax
    mov r13, rdx
    
    mov rax, r13
    xor rdx, rdx
    mov rcx, 1460
    div rcx
    mov r14, rax
    
    mov rax, r13
    xor rdx, rdx
    mov rcx, 36524
    div rcx
    mov r15, rax
    
    mov rax, r13
    xor rdx, rdx
    mov rcx, 146096
    div rcx
    mov rbx, rax
    
    mov rax, r13
    sub rax, r14
    add rax, r15
    sub rax, rbx
    xor rdx, rdx
    mov rcx, 365
    div rcx
    mov r14, rax
    
    mov rax, r12
    imul rax, 400
    add rax, r14
    mov r15, rax
    
    mov rax, r14
    imul rax, 365
    mov rbx, rax
    mov rax, r14
    xor rdx, rdx
    mov rcx, 4
    div rcx
    add rbx, rax
    mov rax, r14
    xor rdx, rdx
    mov rcx, 100
    div rcx
    sub rbx, rax
    mov rax, r13
    sub rax, rbx
    mov r13, rax
    
    mov rax, r13
    imul rax, 5
    add rax, 2
    xor rdx, rdx
    mov rcx, 153
    div rcx
    mov r12, rax
    
    mov rax, r12
    imul rax, 153
    add rax, 2
    xor rdx, rdx
    mov rcx, 5
    div rcx
    mov rbx, rax
    mov rax, r13
    sub rax, rbx
    inc rax
    mov r13, rax
    
    cmp r12, 10
    jl .utc_m_plus_3
    sub r12, 9
    jmp .utc_m_done
.utc_m_plus_3:
    add r12, 3
.utc_m_done:
    cmp r12, 2
    jle .utc_y_plus_1
    jmp .utc_format_date
.utc_y_plus_1:
    inc r15
    
.utc_format_date:
    mov rdi, rsi
    mov rax, r15
    mov r8, 4
    call write_num_padded
    
    mov byte [rsi+4], '-'
    lea rdi, [rsi+5]
    mov rax, r12
    mov r8, 2
    call write_num_padded
    
    mov byte [rsi+7], '-'
    lea rdi, [rsi+8]
    mov rax, r13
    mov r8, 2
    call write_num_padded
    
    mov byte [rsi+10], 'T'
    lea rdi, [rsi+11]
    mov rax, r9
    mov r8, 2
    call write_num_padded
    
    mov byte [rsi+13], ':'
    lea rdi, [rsi+14]
    mov rax, r10
    mov r8, 2
    call write_num_padded
    
    mov byte [rsi+16], ':'
    lea rdi, [rsi+17]
    mov rax, r11
    mov r8, 2
    call write_num_padded
    
    mov byte [rsi+19], 'Z'
    mov byte [rsi+20], 0
    ret

write_num_padded:
    push rdi
    push rax
    push r8
    add rdi, r8
    mov rcx, 10
.wnp_loop:
    dec rdi
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    dec r8
    jnz .wnp_loop
    pop r8
    pop rax
    pop rdi
    ret

get_timestamp:
    mov rax, 228
    mov rdi, 0
    mov rdx, timespec
    syscall
    mov rdi, [timespec]
    call unix_to_utc
    ret

generate_token:
    mov rax, 2
    mov rdi, dev_urandom
    xor rsi, rsi
    syscall
    mov r12, rax
    
    mov rax, 0
    mov rdi, r12
    mov rsi, temp_buf
    mov rdx, 16
    syscall
    
    mov rax, 3
    mov rdi, r12
    syscall
    
    mov r10, token_buf
    mov r9, temp_buf
    mov r8, 16
.gt_hex_loop:
    mov al, [r9]
    mov dl, al
    shr dl, 4
    cmp dl, 9
    jle .gt_num1
    add dl, 7
.gt_num1:
    add dl, '0'
    mov [r10], dl
    inc r10
    
    mov dl, al
    and dl, 0x0F
    cmp dl, 9
    jle .gt_num2
    add dl, 7
.gt_num2:
    add dl, '0'
    mov [r10], dl
    inc r10
    
    inc r9
    dec r8
    jnz .gt_hex_loop
    mov byte [r10], 0
    mov r11, 32
    ret

; ============================================================================
; HTTP Parsing
; ============================================================================

parse_request:
    mov r9, recv_buf
    
    mov r10, method_buf
.pr_find_method:
    mov al, [r9]
    cmp al, ' '
    je .pr_method_done
    cmp al, 0
    je .pr_error
    mov [r10], al
    inc r9
    inc r10
    jmp .pr_find_method
.pr_method_done:
    mov byte [r10], 0
    
.pr_skip_spaces1:
    inc r9
    mov al, [r9]
    cmp al, ' '
    je .pr_skip_spaces1
    
    mov r10, path_buf
.pr_find_path:
    mov al, [r9]
    cmp al, ' '
    je .pr_path_done
    cmp al, 13
    je .pr_path_done
    cmp al, 10
    je .pr_path_done
    cmp al, 0
    je .pr_path_done
    mov [r10], al
    inc r9
    inc r10
    jmp .pr_find_path
.pr_path_done:
    mov byte [r10], 0
    
    mov r10, r9
.pr_find_headers_end:
    cmp word [r10], 0x0A0D
    je .pr_check_double
    inc r10
    jmp .pr_find_headers_end
.pr_check_double:
    cmp word [r10+2], 0x0A0D
    jne .pr_find_headers_end
    
    mov r11, r10
    add r11, 4
    mov [body_ptr], r11
    
    mov r9, recv_buf
.pr_find_cl:
    mov rsi, str_content_length
    call startswith
    test rax, rax
    jnz .pr_found_cl
    mov al, [r9]
    cmp al, 10
    je .pr_check_cl_next
    inc r9
    jmp .pr_find_cl
.pr_check_cl_next:
    inc r9
    cmp word [r9], 0x0A0D
    je .pr_no_cl
    jmp .pr_find_cl
    
.pr_found_cl:
    add r9, 16
    call atoi
    mov [body_len], rax
    jmp .pr_parse_cookies
    
.pr_no_cl:
    mov qword [body_len], 0
    
.pr_parse_cookies:
    mov r9, recv_buf
.pr_find_cookie:
    mov rsi, str_cookie
    call startswith
    test rax, rax
    jnz .pr_found_cookie
    mov al, [r9]
    cmp al, 10
    je .pr_check_cookie_next
    inc r9
    jmp .pr_find_cookie
.pr_check_cookie_next:
    inc r9
    cmp word [r9], 0x0A0D
    je .pr_no_cookie
    jmp .pr_find_cookie
    
.pr_found_cookie:
    add r9, 8
.pr_find_sid:
    mov rsi, str_session_id
    call startswith
    test rax, rax
    jnz .pr_found_sid
    mov al, [r9]
    cmp al, ';'
    je .pr_next_cookie_part
    cmp al, ' '
    je .pr_next_cookie_part
    inc r9
    jmp .pr_find_sid
.pr_next_cookie_part:
    inc r9
    jmp .pr_found_cookie
    
.pr_found_sid:
    add r9, 11
    mov r10, cookie_buf
.pr_extract_sid:
    mov al, [r9]
    cmp al, ';'
    je .pr_sid_done
    cmp al, ' '
    je .pr_sid_done
    cmp al, 13
    je .pr_sid_done
    cmp al, 10
    je .pr_sid_done
    cmp al, 0
    je .pr_sid_done
    mov [r10], al
    inc r9
    inc r10
    jmp .pr_extract_sid
.pr_sid_done:
    mov byte [r10], 0
    mov rax, cookie_buf
    mov [cookie_token], rax
    jmp .pr_done
    
.pr_no_cookie:
    mov qword [cookie_token], 0
    
.pr_done:
    ret
.pr_error:
    ret

; ============================================================================
; Response Building
; ============================================================================

build_response:
    mov r8, send_buf
    
    mov r9, rdi
    call copy_str_until_newline
    
    mov r9, content_type
    call copy_str_until_newline
    
    test rcx, rcx
    jz .br_no_cookie
    mov r9, set_cookie
    call copy_str
    dec r8
    
    mov r10, rcx
    mov r11, 32
.br_copy_token:
    mov al, [r10]
    mov [r8], al
    inc r10
    inc r8
    dec r11
    jnz .br_copy_token
    
    mov r9, cookie_attrs
    call copy_str_until_newline
    
.br_no_cookie:
    mov r9, content_len
    call copy_str
    dec r8
    
    push r8
    push rdx
    mov rax, rdx
    mov rdi, temp_buf + 64
    mov byte [rdi], 0
    mov rcx, 10
.br_itoa_loop:
    test rax, rax
    jz .br_itoa_done
    dec rdi
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    jmp .br_itoa_loop
.br_itoa_done:
    test rax, rax
    jnz .br_skip_zero
    dec rdi
    mov byte [rdi], '0'
.br_skip_zero:
.br_copy_itoa:
    mov al, [rdi]
    mov [r8], al
    inc rdi
    inc r8
    test al, al
    jnz .br_copy_itoa
    dec r8
    pop rdx
    pop r8
    
    mov byte [r8], 13
    mov byte [r8+1], 10
    add r8, 2
    
    test rdx, rdx
    jz .br_done_build
    test rsi, rsi
    jz .br_done_build
.br_copy_body:
    mov al, [rsi]
    mov [r8], al
    inc rsi
    inc r8
    dec rdx
    jnz .br_copy_body
    
.br_done_build:
    mov rax, r8
    sub rax, send_buf
    ret

copy_str_until_newline:
    mov al, [r9]
    mov [r8], al
    inc r9
    inc r8
    cmp al, 10
    jne copy_str_until_newline
    ret

; ============================================================================
; Endpoints
; ============================================================================

format_todo_json:
    mov r8, rsi
    
    mov r9, str_todo_start
    call copy_str
    
    mov rax, rbx
    inc rax
    push r8
    mov rdi, temp_buf + 64
    mov byte [rdi], 0
    mov rcx, 10
.ftj_itoa_id:
    test rax, rax
    jz .ftj_itoa_id_done
    dec rdi
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    jmp .ftj_itoa_id
.ftj_itoa_id_done:
    test rax, rax
    jnz .ftj_skip_zero_id
    dec rdi
    mov byte [rdi], '0'
.ftj_skip_zero_id:
    pop r8
.ftj_copy_id:
    mov al, [rdi]
    mov [r8], al
    inc rdi
    inc r8
    test al, al
    jnz .ftj_copy_id
    dec r8
    
    mov r9, str_title
    call copy_str
    mov r9, todo_titles
    mov rax, rbx
    imul rax, 257
    add r9, rax
    call copy_str_escaped
    
    mov r9, str_desc
    call copy_str
    mov r9, todo_descriptions
    mov rax, rbx
    imul rax, 1025
    add r9, rax
    call copy_str_escaped
    
    mov r9, str_completed
    call copy_str
    mov rax, rbx
    mov al, [todo_completed + rax]
    test al, al
    jz .ftj_is_false
    mov r9, str_true
    jmp .ftj_write_bool
.ftj_is_false:
    mov r9, str_false
.ftj_write_bool:
    call copy_str
    
    mov r9, str_created
    call copy_str
    mov r9, todo_created_at
    mov rax, rbx
    imul rax, 21
    add r9, rax
    call copy_str
    
    mov r9, str_updated
    call copy_str
    mov r9, todo_updated_at
    mov rax, rbx
    imul rax, 21
    add r9, rax
    call copy_str
    
    mov r9, str_todo_end
    call copy_str
    
    mov rax, r8
    sub rax, rsi
    ret

; --- Global Error handlers ---
err_400_invalid_user:
    mov rdi, msg_400
    mov rsi, err_invalid_username
    call strlen
    mov rdx, rax
    mov rcx, 0
    call build_response
    jmp resp_send

err_400_pass_short:
    mov rdi, msg_400
    mov rsi, err_pass_short
    call strlen
    mov rdx, rax
    mov rcx, 0
    call build_response
    jmp resp_send

err_400_title_req:
    mov rdi, msg_400
    mov rsi, err_title_req
    call strlen
    mov rdx, rax
    mov rcx, 0
    call build_response
    jmp resp_send

err_401_invalid_cred:
    mov rdi, msg_401
    mov rsi, err_invalid_cred
    call strlen
    mov rdx, rax
    mov rcx, 0
    call build_response
    jmp resp_send

err_401_auth_req:
    mov rdi, msg_401
    mov rsi, err_auth_req
    call strlen
    mov rdx, rax
    mov rcx, 0
    call build_response
    jmp resp_send

err_404_not_found:
    mov rdi, msg_404
    mov rsi, err_todo_not_found
    call strlen
    mov rdx, rax
    mov rcx, 0
    call build_response
    jmp resp_send

err_409_user_exists:
    mov rdi, msg_409
    mov rsi, err_user_exists
    call strlen
    mov rdx, rax
    mov rcx, 0
    call build_response
    jmp resp_send

err_500_internal:
    mov rdi, msg_500
    xor rsi, rsi
    xor rdx, rdx
    xor rcx, rcx
    call build_response
    jmp resp_send

resp_send:
    mov rax, 1
    mov rdi, [client_fd]
    mov rsi, send_buf
    syscall
    ret

check_auth:
    mov rdi, [cookie_token]
    test rdi, rdi
    jz check_auth_fail
    call find_session
    cmp rbx, -1
    je check_auth_fail
    mov rax, [session_user_ids + rbx*8]
    test rax, rax
    jz check_auth_fail
    dec rax
    mov [current_user_idx], rax
    mov rax, 1
    ret
check_auth_fail:
    xor rax, rax
    ret

do_register:
    mov rdi, [body_ptr]
    mov rsi, str_key_username
    call find_key
    test rax, rax
    jz err_401_invalid_cred
    mov rdi, rax
    mov rsi, temp_buf
    mov rcx, 50
    call extract_string_value
    test rax, rax
    jz err_401_invalid_cred
    
    mov rdi, temp_buf
    call strlen
    mov r8, rax
    push rax
    mov rsi, rax
    call validate_username
    pop rax
    test rax, rax
    jz err_400_invalid_user
    
    mov rdi, [body_ptr]
    mov rsi, str_key_password
    call find_key
    test rax, rax
    jz err_401_invalid_cred
    mov rdi, rax
    mov rsi, temp_buf + 64
    mov rcx, 256
    call extract_string_value
    test rax, rax
    jz err_401_invalid_cred
    
    mov rdi, temp_buf + 64
    call strlen
    cmp rax, 8
    jl err_400_pass_short
    
    mov rdi, temp_buf
    call find_user_by_username
    cmp rbx, -1
    je dr_create_user
    jmp err_409_user_exists
    
dr_create_user:
    mov rcx, [user_count]
    cmp rcx, MAX_USERS
    jge err_500_internal
    mov rbx, rcx
    
    mov r8, user_usernames
    mov rax, rbx
    imul rax, 51
    add r8, rax
    mov r9, temp_buf
    call copy_str
    
    mov r8, user_passwords
    mov rax, rbx
    imul rax, 257
    add r8, rax
    mov r9, temp_buf + 64
    call copy_str
    
    inc qword [user_count]
    
    mov rsi, temp_buf + 128
    mov r8, rsi
    mov r9, str_todo_start
    call copy_str
    dec r8
    
    mov rax, rbx
    inc rax
    mov rdi, temp_buf + 200
    mov byte [rdi], 0
    mov rcx, 10
dr_itoa_reg:
    test rax, rax
    jz dr_ido_reg
    dec rdi
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    jmp dr_itoa_reg
dr_ido_reg:
    test rax, rax
    jnz dr_skip_zero_reg
    dec rdi
    mov byte [rdi], '0'
dr_skip_zero_reg:
dr_copy_reg_id:
    mov al, [rdi]
    mov [r8], al
    inc rdi
    inc r8
    test al, al
    jnz dr_copy_reg_id
    dec r8
    
    mov r9, str_title
    call copy_str
    mov r9, temp_buf
    call copy_str_escaped
    mov r9, str_todo_end
    call copy_str
    
    mov rdi, msg_201
    mov rdx, r8
    sub rdx, rsi
    mov rcx, 0
    call build_response
    jmp resp_send

do_login:
    mov rdi, [body_ptr]
    mov rsi, str_key_username
    call find_key
    test rax, rax
    jz dl_fail
    mov rdi, rax
    mov rsi, temp_buf
    mov rcx, 50
    call extract_string_value
    test rax, rax
    jz dl_fail
    
    mov rdi, [body_ptr]
    mov rsi, str_key_password
    call find_key
    test rax, rax
    jz dl_fail
    mov rdi, rax
    mov rsi, temp_buf + 64
    mov rcx, 256
    call extract_string_value
    test rax, rax
    jz dl_fail
    
    mov rdi, temp_buf
    call find_user_by_username
    cmp rbx, -1
    je dl_fail
    
    mov r8, user_passwords
    mov rax, rbx
    imul rax, 257
    add r8, rax
    mov rsi, r8
    mov rdi, temp_buf + 64
    call streq
    test rax, rax
    jnz dl_fail
    
    call generate_token
    mov rdi, token_buf
    mov rsi, rbx
    inc rsi
    call add_session
    cmp rbx, -1
    je err_500_internal
    
    mov rsi, temp_buf + 128
    mov r8, rsi
    mov r9, str_todo_start
    call copy_str
    dec r8
    mov rax, rbx
    inc rax
    mov rdi, temp_buf + 200
    mov byte [rdi], 0
    mov rcx, 10
dl_itoa_log:
    test rax, rax
    jz dl_ido_log
    dec rdi
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    jmp dl_itoa_log
dl_ido_log:
    test rax, rax
    jnz dl_skip_zero_log
    dec rdi
    mov byte [rdi], '0'
dl_skip_zero_log:
dl_copy_log_id:
    mov al, [rdi]
    mov [r8], al
    inc rdi
    inc r8
    test al, al
    jnz dl_copy_log_id
    dec r8
    mov r9, str_title
    call copy_str
    mov r9, temp_buf
    call copy_str_escaped
    mov r9, str_todo_end
    call copy_str
    
    mov rdi, msg_200
    mov rdx, r8
    sub rdx, rsi
    mov rcx, token_buf
    call build_response
    jmp resp_send

dl_fail:
    jmp err_401_invalid_cred

do_logout:
    call check_auth
    test rax, rax
    jz err_401_auth_req
    mov rax, rbx
    mov r8, session_tokens
    imul rax, 33
    add r8, rax
    mov byte [r8], 0
    
    mov rdi, msg_200
    mov rsi, err_empty_obj
    call strlen
    mov rdx, rax
    mov rcx, 0
    call build_response
    jmp resp_send

do_me:
    call check_auth
    test rax, rax
    jz err_401_auth_req
    mov rbx, [current_user_idx]
    
    mov rsi, temp_buf + 128
    mov r8, rsi
    mov r9, str_todo_start
    call copy_str
    dec r8
    mov rax, rbx
    inc rax
    mov rdi, temp_buf + 200
    mov byte [rdi], 0
    mov rcx, 10
dm_itoa_me:
    test rax, rax
    jz dm_ido_me
    dec rdi
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    jmp dm_itoa_me
dm_ido_me:
    test rax, rax
    jnz dm_skip_zero_me
    dec rdi
    mov byte [rdi], '0'
dm_skip_zero_me:
dm_copy_me_id:
    mov al, [rdi]
    mov [r8], al
    inc rdi
    inc r8
    test al, al
    jnz dm_copy_me_id
    dec r8
    mov r9, str_title
    call copy_str
    mov r8, user_usernames
    mov rax, rbx
    imul rax, 51
    add r8, rax
    call copy_str_escaped
    mov r9, str_todo_end
    call copy_str
    
    mov rdi, msg_200
    mov rdx, r8
    sub rdx, rsi
    mov rcx, 0
    call build_response
    jmp resp_send

do_password:
    call check_auth
    test rax, rax
    jz err_401_auth_req
    mov rbx, [current_user_idx]
    
    mov rdi, [body_ptr]
    mov rsi, str_key_old_pass
    call find_key
    test rax, rax
    jz dp_fail
    mov rdi, rax
    mov rsi, temp_buf + 64
    mov rcx, 256
    call extract_string_value
    
    mov r8, user_passwords
    mov rax, rbx
    imul rax, 257
    add r8, rax
    mov rsi, r8
    mov rdi, temp_buf + 64
    call streq
    test rax, rax
    jnz dp_fail
    
    mov rdi, [body_ptr]
    mov rsi, str_key_new_pass
    call find_key
    test rax, rax
    jz dp_fail
    mov rdi, rax
    mov rsi, temp_buf + 128
    mov rcx, 256
    call extract_string_value
    
    mov rdi, temp_buf + 128
    call strlen
    cmp rax, 8
    jl err_400_pass_short
    
    mov r8, user_passwords
    mov rax, rbx
    imul rax, 257
    add r8, rax
    mov r9, temp_buf + 128
    call copy_str
    
    mov rdi, msg_200
    mov rsi, err_empty_obj
    call strlen
    mov rdx, rax
    mov rcx, 0
    call build_response
    jmp resp_send

dp_fail:
    jmp err_401_invalid_cred

do_get_todos:
    call check_auth
    test rax, rax
    jz err_401_auth_req
    mov r12, [current_user_idx]
    inc r12
    
    mov rsi, temp_buf + 128
    mov r8, rsi
    mov byte [r8], '['
    inc r8
    mov r13, 0
    
    mov rcx, [todo_count]
    xor rbx, rbx
dgt_loop_todos:
    cmp rbx, rcx
    jge dgt_end_todos
    mov rax, [todo_user_ids + rbx*8]
    test rax, rax
    jz dgt_next_todo
    cmp rax, r12
    jne dgt_next_todo
    
    cmp r13, 0
    je dgt_first_todo
    mov byte [r8], ','
    inc r8
dgt_first_todo:
    mov rax, rbx
    push r8
    call format_todo_json
    pop r8
    add r8, rax
    inc r13
dgt_next_todo:
    inc rbx
    jmp dgt_loop_todos
dgt_end_todos:
    mov byte [r8], ']'
    inc r8
    
    mov rdi, msg_200
    mov rdx, r8
    sub rdx, rsi
    mov rcx, 0
    call build_response
    jmp resp_send

do_post_todo:
    call check_auth
    test rax, rax
    jz err_401_auth_req
    mov r12, [current_user_idx]
    inc r12
    
    mov rdi, [body_ptr]
    mov rsi, str_key_title
    call find_key
    test rax, rax
    jz err_400_title_req
    mov rdi, rax
    mov rsi, temp_buf
    mov rcx, 256
    call extract_string_value
    test rax, rax
    jz err_400_title_req
    
    mov rdi, temp_buf
    call strlen
    test rax, rax
    jz err_400_title_req
    
    mov rdi, [body_ptr]
    mov rsi, str_key_desc
    call find_key
    test rax, rax
    jz dpt_no_desc
    mov rdi, rax
    mov rsi, temp_buf + 256
    mov rcx, 1024
    call extract_string_value
    jmp dpt_create_todo
dpt_no_desc:
    mov byte [temp_buf + 256], 0
    
dpt_create_todo:
    mov rcx, [todo_count]
    cmp rcx, MAX_TODOS
    jge err_500_internal
    mov rbx, rcx
    
    mov rax, r12
    mov [todo_user_ids + rbx*8], rax
    
    mov r8, todo_titles
    mov rax, rbx
    imul rax, 257
    add r8, rax
    mov r9, temp_buf
    call copy_str
    
    mov r8, todo_descriptions
    mov rax, rbx
    imul rax, 1025
    add r8, rax
    mov r9, temp_buf + 256
    call copy_str
    
    mov rax, rbx
    mov byte [todo_completed + rax], 0
    
    mov rsi, temp_buf + 320
    call get_timestamp
    mov r8, todo_created_at
    mov rax, rbx
    imul rax, 21
    add r8, rax
    mov r9, temp_buf + 320
    call copy_str
    mov r8, todo_updated_at
    mov rax, rbx
    imul rax, 21
    add r8, rax
    mov r9, temp_buf + 320
    call copy_str
    
    inc qword [todo_count]
    
    mov rsi, temp_buf + 400
    call format_todo_json
    mov r9, rax
    mov rdi, msg_201
    mov rsi, temp_buf + 400
    mov rdx, r9
    mov rcx, 0
    call build_response
    jmp resp_send

parse_todo_id:
    mov rsi, str_todos_slash
    call startswith
    test rax, rax
    jz pti_fail
    add rdi, 8
    call atoi
    test rax, rax
    jz pti_fail
    ret
pti_fail:
    xor rax, rax
    ret

do_get_todo:
    call check_auth
    test rax, rax
    jz err_401_auth_req
    mov r12, [current_user_idx]
    inc r12
    
    mov rdi, path_buf
    call parse_todo_id
    test rax, rax
    jz err_404_not_found
    mov rdi, rax
    call find_todo_by_id
    cmp rbx, -1
    je err_404_not_found
    mov rax, [todo_user_ids + rbx*8]
    cmp rax, r12
    jne err_404_not_found
    
    mov rsi, temp_buf + 128
    call format_todo_json
    mov r9, rax
    mov rdi, msg_200
    mov rsi, temp_buf + 128
    mov rdx, r9
    mov rcx, 0
    call build_response
    jmp resp_send

do_put_todo:
    call check_auth
    test rax, rax
    jz err_401_auth_req
    mov r12, [current_user_idx]
    inc r12
    
    mov rdi, path_buf
    call parse_todo_id
    test rax, rax
    jz err_404_not_found
    mov rdi, rax
    call find_todo_by_id
    cmp rbx, -1
    je err_404_not_found
    mov rax, [todo_user_ids + rbx*8]
    cmp rax, r12
    jne err_404_not_found
    
    mov rdi, [body_ptr]
    mov rsi, str_key_title
    call find_key
    test rax, rax
    jz dptu_check_desc
    mov rdi, rax
    mov rsi, temp_buf
    mov rcx, 256
    call extract_string_value
    test rax, rax
    jz dptu_check_desc
    mov rdi, temp_buf
    call strlen
    test rax, rax
    jz err_400_title_req
    mov r8, todo_titles
    mov rax, rbx
    imul rax, 257
    add r8, rax
    mov r9, temp_buf
    call copy_str
    
dptu_check_desc:
    mov rdi, [body_ptr]
    mov rsi, str_key_desc
    call find_key
    test rax, rax
    jz dptu_check_comp
    mov rdi, rax
    mov rsi, temp_buf + 256
    mov rcx, 1024
    call extract_string_value
    mov r8, todo_descriptions
    mov rax, rbx
    imul rax, 1025
    add r8, rax
    mov r9, temp_buf + 256
    call copy_str
    
dptu_check_comp:
    mov rdi, [body_ptr]
    mov rsi, str_key_comp
    call find_key
    test rax, rax
    jz dptu_update_ts
    mov rdi, rax
    call extract_bool
    cmp rax, -1
    je dptu_update_ts
    mov r8, rbx
    mov [todo_completed + r8], al
    
dptu_update_ts:
    mov rsi, temp_buf + 320
    call get_timestamp
    mov r8, todo_updated_at
    mov rax, rbx
    imul rax, 21
    add r8, rax
    mov r9, temp_buf + 320
    call copy_str
    
    mov rsi, temp_buf + 128
    call format_todo_json
    mov r9, rax
    mov rdi, msg_200
    mov rsi, temp_buf + 128
    mov rdx, r9
    mov rcx, 0
    call build_response
    jmp resp_send

do_delete_todo:
    call check_auth
    test rax, rax
    jz err_401_auth_req
    mov r12, [current_user_idx]
    inc r12
    
    mov rdi, path_buf
    call parse_todo_id
    test rax, rax
    jz err_404_not_found
    mov rdi, rax
    call find_todo_by_id
    cmp rbx, -1
    je err_404_not_found
    mov rax, [todo_user_ids + rbx*8]
    cmp rax, r12
    jne err_404_not_found
    
    mov qword [todo_user_ids + rbx*8], 0
    
    mov rdi, msg_204
    xor rsi, rsi
    xor rdx, rdx
    xor rcx, rcx
    call build_response
    jmp resp_send

; ============================================================================
; Main Loop
; ============================================================================

route_request:
    mov rdi, method_buf
    mov rsi, str_post
    call streq
    test rax, rax
    jnz rr_is_post
    
    mov rdi, method_buf
    mov rsi, str_get
    call streq
    test rax, rax
    jnz rr_is_get
    
    mov rdi, method_buf
    mov rsi, str_put
    call streq
    test rax, rax
    jnz rr_is_put
    
    mov rdi, method_buf
    mov rsi, str_delete
    call streq
    test rax, rax
    jnz rr_is_delete
    
    jmp err_404_not_found

rr_is_post:
    mov rdi, path_buf
    mov rsi, str_register
    call streq
    test rax, rax
    jnz do_register
    
    mov rdi, path_buf
    mov rsi, str_login
    call streq
    test rax, rax
    jnz do_login
    
    mov rdi, path_buf
    mov rsi, str_logout
    call streq
    test rax, rax
    jnz do_logout
    
    mov rdi, path_buf
    mov rsi, str_todos
    call streq
    test rax, rax
    jnz do_post_todo
    
    jmp err_404_not_found

rr_is_get:
    mov rdi, path_buf
    mov rsi, str_me
    call streq
    test rax, rax
    jnz do_me
    
    mov rdi, path_buf
    mov rsi, str_todos
    call streq
    test rax, rax
    jnz do_get_todos
    
    mov rdi, path_buf
    mov rsi, str_todos_slash
    call startswith
    test rax, rax
    jnz do_get_todo
    
    jmp err_404_not_found

rr_is_put:
    mov rdi, path_buf
    mov rsi, str_password
    call streq
    test rax, rax
    jnz do_password
    
    mov rdi, path_buf
    mov rsi, str_todos_slash
    call startswith
    test rax, rax
    jnz do_put_todo
    
    jmp err_404_not_found

rr_is_delete:
    mov rdi, path_buf
    mov rsi, str_todos_slash
    call startswith
    test rax, rax
    jnz do_delete_todo
    
    jmp err_404_not_found

handle_client:
    mov rax, 0
    mov rsi, recv_buf
    mov rdx, 8192
    syscall
    test rax, rax
    jle hc_ret
    mov byte [recv_buf + rax], 0
    call parse_request
    call route_request
hc_ret:
    ret

_start:
    mov r8, [rsp]
    cmp r8, 3
    jne start_usage
    
    mov r9, [rsp+16]
    mov rdi, r9
    mov rsi, str_port
    call streq
    test rax, rax
    jz start_usage
    
    mov rdi, [rsp+24]
    call atoi
    mov [server_port], ax
    
    mov rax, 41
    mov rdi, 2
    mov rsi, 1
    xor rdx, rdx
    syscall
    mov [server_fd], rax
    
    mov ax, [server_port]
    xchg al, ah
    mov [sockaddr_in+2], ax
    
    mov rax, 49
    mov rdi, [server_fd]
    mov rsi, sockaddr_in
    mov rdx, 16
    syscall
    
    mov rax, 50
    mov rdi, [server_fd]
    mov rsi, 128
    syscall

start_accept_loop:
    mov rax, 43
    mov rdi, [server_fd]
    xor rsi, rsi
    xor rdx, rdx
    syscall
    test rax, rax
    js start_accept_loop
    mov [client_fd], rax
    
    mov rdi, rax
    call handle_client
    
    mov rax, 3
    mov rdi, [client_fd]
    syscall
    jmp start_accept_loop

start_usage:
    mov rax, 1
    mov rdi, 2
    mov rsi, usage_str
    mov rdx, 28
    syscall
    mov rax, 60
    xor rdi, rdi
    syscall

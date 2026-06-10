global _start

section .bss
sock_fd:        resq 1
client_fd:      resq 1
server_port:    resq 1
req_len:        resq 1
body_len:       resq 1
body_ptr:       resq 1
method:         resq 1
user_count:     resq 1
todo_count:     resq 1
session_count:  resq 1

req_buffer:     resb 8192
res_buffer:     resb 8192
path:           resb 256

user_array:     resb 64 * 144
todo_array:     resb 256 * 384
session_array:  resb 64 * 80

temp_buf1:      resb 256
temp_buf2:      resb 256
temp_buf3:      resb 64
temp_buf4:      resb 512
temp_buf5:      resb 256

section .data
port_str:       db "--port", 0
crlfcrlf:       db 0x0D, 0x0A, 0x0D, 0x0A, 0
content_length_header: db "Content-Length: ", 0
cookie_header:  db "Cookie: ", 0
session_id_str: db "session_id=", 0
key_username:   db "username", 0
key_password:   db "password", 0
key_title:      db "title", 0
key_desc:       db "description", 0
key_completed:  db "completed", 0
key_old_pass:   db "old_password", 0
key_new_pass:   db "new_password", 0

path_register:  db "/register", 0
path_login:     db "/login", 0
path_logout:    db "/logout", 0
path_me:        db "/me", 0
path_password:  db "/password", 0
path_todos:     db "/todos", 0
todos_prefix:   db "/todos/", 0

str_ok:         db "OK", 0
str_created:    db "Created", 0
str_no_content: db "No Content", 0
str_bad_req:    db "Bad Request", 0
str_unauth:     db "Unauthorized", 0
str_forbidden:  db "Forbidden", 0
str_not_found:  db "Not Found", 0
str_conflict:   db "Conflict", 0
str_server_err: db "Internal Server Error", 0

str_user_json_start: db '{"id":', 0
str_user_json_mid:   db ',"username":"', 0
str_user_json_end:   db '"}', 0

str_todo_start:      db '{"id":', 0
str_todo_title:      db ',"title":"', 0
str_todo_desc:       db ',"description":"', 0
str_todo_done:       db ',"completed":', 0
str_true:            db 'true', 0
str_false:           db 'false', 0
str_todo_created:    db ',"created_at":"', 0
str_todo_updated:    db ',"updated_at":"', 0
str_todo_end:        db '"}', 0

str_err_start:       db '{"error":"', 0
str_err_end:         db '"}', 0

str_set_cookie_start: db "Set-Cookie: session_id=", 0
str_set_cookie_end:   db "; Path=/; HttpOnly\r\n", 0

content_type_json: db "Content-Type: application/json\r\n", 0
content_length_prefix: db "Content-Length: ", 0

month_days: db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

USER_SIZE equ 144
USER_ID_OFF equ 0
USER_NAME_OFF equ 8
USER_PASS_OFF equ 72

TODO_SIZE equ 384
TODO_ID_OFF equ 0
TODO_USER_ID_OFF equ 8
TODO_TITLE_OFF equ 16
TODO_DESC_OFF equ 144
TODO_DONE_OFF equ 272
TODO_CREATED_OFF equ 280
TODO_UPDATED_OFF equ 300

SESSION_SIZE equ 80
SESSION_TOKEN_OFF equ 0
SESSION_USER_ID_OFF equ 32
SESSION_VALID_OFF equ 40

MAX_USERS equ 64
MAX_TODOS equ 256
MAX_SESSIONS equ 64

section .text
_start:
    mov rdi, [rsp]
    lea rsi, [rsp+8]
    call parse_args
    
    mov rax, 41
    mov rdi, 2
    mov rsi, 1
    xor rdx, rdx
    syscall
    mov [sock_fd], rax
    
    mov ax, [server_port]
    xchg al, ah
    mov [sockaddr + 2], ax
    
    mov rdi, [sock_fd]
    mov rax, 49
    lea rsi, [sockaddr]
    mov rdx, 16
    syscall
    
    mov rdi, [sock_fd]
    mov rax, 50
    mov rsi, 128
    syscall

accept_loop:
    mov rax, 43
    mov rdi, [sock_fd]
    xor rsi, rsi
    xor rdx, rdx
    syscall
    mov [client_fd], rax
    call handle_client
    mov rdi, [client_fd]
    mov rax, 3
    syscall
    jmp accept_loop

parse_args:
    mov rcx, 1
.pa_loop:
    cmp rcx, rdi
    jge .default_port
    mov r8, [rsi + rcx*8]
    lea r9, [port_str]
    call strcmp
    test rax, rax
    jnz .next_arg
    inc rcx
    cmp rcx, rdi
    jge .default_port
    mov r8, [rsi + rcx*8]
    call atoi
    mov [server_port], rax
    ret
.next_arg:
    inc rcx
    jmp .pa_loop
.default_port:
    mov qword [server_port], 8080
    ret

strcmp:
    xor rax, rax
.sc_loop:
    mov cl, [rdi]
    mov dl, [rsi]
    cmp cl, dl
    jne .sc_ne
    test cl, cl
    jz .sc_eq
    inc rdi
    inc rsi
    jmp .sc_loop
.sc_eq:
    xor rax, rax
    ret
.sc_ne:
    mov rax, 1
    ret

atoi:
    xor rax, rax
    xor rcx, rcx
.at_loop:
    mov cl, [rdi]
    test cl, cl
    jz .at_done
    cmp cl, '0'
    jl .at_done
    cmp cl, '9'
    jg .at_done
    sub cl, '0'
    mov r8, rax
    imul rax, 10
    add rax, r8
    inc rdi
    jmp .at_loop
.at_done:
    ret

find_substring:
    push rdi
    push rsi
    push rdx
    mov rdx, rdi
    xor r8, r8
.fs_loop:
    mov al, [rdi]
    test al, al
    jz .fs_nf
    mov r9, rsi
.fs_inner:
    mov cl, [r9]
    test cl, cl
    jz .fs_f
    mov dl, [rdi]
    cmp cl, dl
    jne .fs_nc
    inc rdi
    inc r9
    jmp .fs_inner
.fs_nc:
    inc r8
    inc rdx
    mov rdi, rdx
    mov rsi, [rsp+16]
    jmp .fs_loop
.fs_f:
    mov rax, r8
    pop rdx
    pop rsi
    pop rdi
    ret
.fs_nf:
    mov rax, -1
    pop rdx
    pop rsi
    pop rdi
    ret

strcmp_prefix:
    xor rax, rax
.sp_loop:
    mov cl, [rsi]
    test cl, cl
    jz .sp_eq
    mov dl, [rdi]
    cmp cl, dl
    jne .sp_ne
    inc rdi
    inc rsi
    jmp .sp_loop
.sp_eq:
    xor rax, rax
    ret
.sp_ne:
    mov rax, 1
    ret

get_json_string:
    push rdi
    push rsi
    push rdx
    push rcx
    mov r8, rdi
    mov r9, rsi
.gjs_search:
    mov al, [r8]
    test al, al
    jz .gjs_nf
    cmp al, '"'
    jne .gjs_nc
    mov r10, r8
    inc r10
    mov r11, r9
.gjs_ck:
    mov cl, [r11]
    test cl, cl
    jz .gjs_km
    mov dl, [r10]
    cmp cl, dl
    jne .gjs_nc
    inc r10
    inc r11
    jmp .gjs_ck
.gjs_km:
    cmp byte [r10], '"'
    jne .gjs_nc
    cmp byte [r10+1], ':'
    jne .gjs_nc
    cmp byte [r10+2], '"'
    jne .gjs_nc
    add r10, 3
    mov r8, r10
    mov r9, [rsp+16]
    xor r11, r11
.gjs_cv:
    mov cl, [r8]
    cmp cl, '"'
    je .gjs_vd
    cmp cl, 0
    je .gjs_vd
    mov rdi, [rsp+8]
    mov [rdi + r11], cl
    inc r11
    inc r8
    cmp r11, r9
    jl .gjs_cv
.gjs_vd:
    mov rdi, [rsp+8]
    mov byte [rdi + r11], 0
    mov rax, r11
    jmp .gjs_clean
.gjs_nc:
    inc r8
    jmp .gjs_search
.gjs_nf:
    mov rax, -1
.gjs_clean:
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

get_json_bool:
    push rdi
    push rsi
    mov r8, rdi
    mov r9, rsi
.gjb_search:
    mov al, [r8]
    test al, al
    jz .gjb_nf
    cmp al, '"'
    jne .gjb_nc
    mov r10, r8
    inc r10
    mov r11, r9
.gjb_ck:
    mov cl, [r11]
    test cl, cl
    jz .gjb_km
    mov dl, [r10]
    cmp cl, dl
    jne .gjb_nc
    inc r10
    inc r11
    jmp .gjb_ck
.gjb_km:
    cmp byte [r10], '"'
    jne .gjb_nc
    cmp byte [r10+1], ':'
    jne .gjb_nc
    add r10, 2
.gjb_sw:
    cmp byte [r10], ' '
    je .gjb_ws
    cmp byte [r10], 0x09
    je .gjb_ws
    jmp .gjb_cv
.gjb_ws:
    inc r10
    jmp .gjb_sw
.gjb_cv:
    cmp qword [r10], 'eurt'
    je .gjb_true
    cmp dword [r10], 'slaf'
    jne .gjb_nf
    cmp byte [r10+4], 'e'
    jne .gjb_nf
    mov rax, 0
    jmp .gjb_clean
.gjb_true:
    mov rax, 1
    jmp .gjb_clean
.gjb_nc:
    inc r8
    jmp .gjb_search
.gjb_nf:
    mov rax, -1
.gjb_clean:
    pop rsi
    pop rdi
    ret

strlen:
    xor rax, rax
.sl_loop:
    cmp byte [rdi], 0
    je .sl_done
    inc rax
    inc rdi
    jmp .sl_loop
.sl_done:
    ret

memcpy:
    test rdx, rdx
    jz .mc_done
.mc_loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rdx
    jnz .mc_loop
.mc_done:
    ret

print_num:
    push rax
    push rbx
    push rcx
    push rdx
    lea rcx, [rsp-32]
    mov r8, rcx
    add r8, 31
    mov byte [r8], 0
    dec r8
    xor r9, r9
.pn_loop:
    mov rbx, 10
    xor rdx, rdx
    div rbx
    add dl, '0'
    mov [r8], dl
    dec r8
    inc r9
    test rax, rax
    jnz .pn_loop
    inc r8
    mov rcx, r9
    mov rsi, r8
    rep movsb
    mov rax, r9
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

strcpy:
.sc_loop:
    mov al, [r8]
    test al, al
    jz .sc_done
    mov [rsi], al
    inc r8
    inc rsi
    jmp .sc_loop
.sc_done:
    ret

format_time:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov rax, r12
    mov rbx, 86400
    xor rdx, rdx
    div rbx
    mov r14, rax
    mov r15, rdx
    mov rax, r15
    mov rbx, 3600
    xor rdx, rdx
    div rbx
    mov r8, rax
    mov rax, rdx
    mov rbx, 60
    xor rdx, rdx
    div rbx
    mov r9, rax
    mov r10, rdx
    mov rbx, 1970
.ft_yloop:
    mov rax, rbx
    mov rcx, 4
    xor rdx, rdx
    div rcx
    mov r11, 365
    test rdx, rdx
    jnz .ft_nl
    mov rax, rbx
    mov rcx, 100
    xor rdx, rdx
    div rcx
    test rdx, rdx
    jnz .ft_l
    mov rax, rbx
    mov rcx, 400
    xor rdx, rdx
    div rcx
    test rdx, rdx
    jnz .ft_nl
.ft_l:
    mov r11, 366
.ft_nl:
    cmp r14, r11
    jl .ft_yd
    sub r14, r11
    inc rbx
    jmp .ft_yloop
.ft_yd:
    mov rbp, 1
    lea rdi, [month_days]
.ft_mloop:
    movzx rcx, byte [rdi + rbp - 1]
    cmp rbp, 2
    jne .ft_cm
    mov rax, rbx
    mov rcx, 4
    xor rdx, rdx
    div rcx
    test rdx, rdx
    jnz .ft_nlf
    mov rax, rbx
    mov rcx, 100
    xor rdx, rdx
    div rcx
    test rdx, rdx
    jnz .ft_lf
    mov rax, rbx
    mov rcx, 400
    xor rdx, rdx
    div rcx
    test rdx, rdx
    jz .ft_lf
.ft_nlf:
    movzx rcx, byte [rdi + rbp - 1]
    jmp .ft_cm
.ft_lf:
    mov rcx, 29
.ft_cm:
    cmp r14, rcx
    jl .ft_md
    sub r14, rcx
    inc rbp
    jmp .ft_mloop
.ft_md:
    inc r14
    mov rdi, r13
    mov rax, rbx
    call print_num4
    add rdi, 4
    mov byte [rdi], '-'
    inc rdi
    mov rax, rbp
    call print_num2
    add rdi, 2
    mov byte [rdi], '-'
    inc rdi
    mov rax, r14
    call print_num2
    add rdi, 2
    mov byte [rdi], 'T'
    inc rdi
    mov rax, r8
    call print_num2
    add rdi, 2
    mov byte [rdi], ':'
    inc rdi
    mov rax, r9
    call print_num2
    add rdi, 2
    mov byte [rdi], ':'
    inc rdi
    mov rax, r10
    call print_num2
    add rdi, 2
    mov byte [rdi], 'Z'
    inc rdi
    mov byte [rdi], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

print_num4:
    mov rcx, 1000
    xor rdx, rdx
    div rcx
    add al, '0'
    mov [rdi], al
    mov rax, rdx
    mov rcx, 100
    xor rdx, rdx
    div rcx
    add al, '0'
    mov [rdi+1], al
    mov rax, rdx
    mov rcx, 10
    xor rdx, rdx
    div rcx
    add al, '0'
    mov [rdi+2], al
    add dl, '0'
    mov [rdi+3], dl
    ret

print_num2:
    mov rcx, 10
    xor rdx, rdx
    div rcx
    add al, '0'
    mov [rdi], al
    add dl, '0'
    mov [rdi+1], dl
    ret

validate_username:
    push rbx
    push rcx
    push rdi
    xor rbx, rbx
.vu_loop:
    mov cl, [rdi]
    test cl, cl
    jz .vu_done
    cmp cl, 'a'
    jl .vu_inv
    cmp cl, 'z'
    jle .vu_vc
    cmp cl, 'A'
    jl .vu_inv
    cmp cl, 'Z'
    jle .vu_vc
    cmp cl, '0'
    jl .vu_inv
    cmp cl, '9'
    jle .vu_vc
    cmp cl, '_'
    je .vu_vc
    jmp .vu_inv
.vu_vc:
    inc rbx
    inc rdi
    jmp .vu_loop
.vu_done:
    cmp rbx, 3
    jl .vu_inv
    cmp rbx, 50
    jg .vu_inv
    mov rax, 1
    jmp .vu_clean
.vu_inv:
    xor rax, rax
.vu_clean:
    pop rdi
    pop rcx
    pop rbx
    ret

find_user_by_name:
    push rbx
    push rcx
    push rdi
    xor rbx, rbx
.fub_loop:
    cmp rbx, [user_count]
    jge .fub_nf
    mov rax, rbx
    imul rax, USER_SIZE
    lea rcx, [user_array + rax]
    lea rsi, [rcx + USER_NAME_OFF]
    mov rdi, [rsp]
    call strcmp
    test rax, rax
    jz .fub_f
    inc rbx
    jmp .fub_loop
.fub_f:
    mov rax, [rcx + USER_ID_OFF]
    jmp .fub_clean
.fub_nf:
    xor rax, rax
.fub_clean:
    pop rdi
    pop rcx
    pop rbx
    ret

parse_method:
    cmp qword [rdi], ' TEG'
    je .pm_get
    cmp dword [rdi], 'TSOP'
    je .pm_post
    cmp qword [rdi], ' TUP'
    je .pm_put
    cmp dword [rdi], 'ELED'
    je .pm_del
    mov rax, 0
    ret
.pm_get:
    mov rax, 1
    ret
.pm_post:
    mov rax, 2
    ret
.pm_put:
    mov rax, 3
    ret
.pm_del:
    mov rax, 4
    ret

parse_path:
    mov r8, rdi
.pp_fs1:
    cmp byte [r8], ' '
    je .pp_f1
    cmp byte [r8], 0
    je .pp_nf
    inc r8
    jmp .pp_fs1
.pp_f1:
    inc r8
    mov r9, r8
    xor r10, r10
.pp_cp:
    cmp byte [r9], ' '
    je .pp_dc
    cmp byte [r9], 0
    je .pp_dc
    cmp byte [r9], 0x0d
    je .pp_dc
    cmp byte [r9], 0x0a
    je .pp_dc
    mov al, [r9]
    mov [rsi + r10], al
    inc r10
    inc r9
    cmp r10, rcx
    jl .pp_cp
.pp_dc:
    mov byte [rsi + r10], 0
    mov rax, r10
    ret
.pp_nf:
    mov rax, 0
    ret

build_user_json:
    lea r8, [str_user_json_start]
    call strcpy
    mov rax, [rdi + USER_ID_OFF]
    call print_num
    add rsi, rax
    lea r8, [str_user_json_mid]
    call strcpy
    lea r8, [rdi + USER_NAME_OFF]
    call strcpy
    lea r8, [str_user_json_end]
    call strcpy
    mov rax, rsi
    sub rax, rdx
    mov rcx, rax
    ret

build_error_json:
    lea r8, [str_err_start]
    call strcpy
    lea r8, [rdi]
    call strcpy
    lea r8, [str_err_end]
    call strcpy
    mov rax, rsi
    sub rax, rdx
    mov rcx, rax
    ret

build_empty_json:
    mov word [rsi], 0x7D7B
    add rsi, 2
    mov byte [rsi], 0
    mov rax, 2
    mov rcx, 2
    ret

build_todo_json:
    lea r8, [str_todo_start]
    call strcpy
    mov rax, [rdi + TODO_ID_OFF]
    call print_num
    add rsi, rax
    lea r8, [str_todo_title]
    call strcpy
    lea r8, [rdi + TODO_TITLE_OFF]
    call strcpy
    lea r8, [str_todo_desc]
    call strcpy
    lea r8, [rdi + TODO_DESC_OFF]
    call strcpy
    lea r8, [str_todo_done]
    call strcpy
    mov rax, [rdi + TODO_DONE_OFF]
    cmp rax, 0
    je .btj_f
    lea r8, [str_true]
    call strcpy
    jmp .btj_ad
.btj_f:
    lea r8, [str_false]
    call strcpy
.btj_ad:
    lea r8, [str_todo_created]
    call strcpy
    lea r8, [rdi + TODO_CREATED_OFF]
    call strcpy
    lea r8, [str_todo_updated]
    call strcpy
    lea r8, [rdi + TODO_UPDATED_OFF]
    call strcpy
    lea r8, [str_todo_end]
    call strcpy
    mov rax, rsi
    sub rax, rdx
    mov rcx, rax
    ret

build_todo_list_json:
    push rsi
    mov byte [rsi], '['
    inc rsi
    xor rbx, rbx
    xor r9, r9
.btl_loop:
    cmp rbx, [todo_count]
    jge .btl_done
    mov rax, rbx
    imul rax, TODO_SIZE
    lea rcx, [todo_array + rax]
    cmp qword [rcx + TODO_USER_ID_OFF], rdi
    jne .btl_next
    cmp r9, 0
    je .btl_nc
    mov byte [rsi], ','
    inc rsi
.btl_nc:
    mov rdx, rsi
    push rdi
    mov rdi, rcx
    call build_todo_json
    pop rdi
    mov rsi, rdx
    add rsi, rcx
    inc r9
.btl_next:
    inc rbx
    jmp .btl_loop
.btl_done:
    mov byte [rsi], ']'
    inc rsi
    mov byte [rsi], 0
    pop rdx
    mov rax, rsi
    sub rax, rdx
    mov rcx, rax
    ret

build_response:
    lea r10, [res_buffer]
    mov qword [r10], 0x202E312F50545448
    add r10, 9
    mov rax, rdi
    mov rbx, 100
    xor rdx, rdx
    div rbx
    add al, '0'
    mov [r10], al
    inc r10
    mov rax, rdx
    mov rbx, 10
    xor rdx, rdx
    div rbx
    add al, '0'
    mov [r10], al
    inc r10
    add dl, '0'
    mov [r10], dl
    inc r10
    mov byte [r10], ' '
    inc r10
.br_cs:
    mov al, [rsi]
    test al, al
    jz .br_sd
    mov [r10], al
    inc r10
    inc rsi
    jmp .br_cs
.br_sd:
    mov word [r10], 0x0A0D
    add r10, 2
    lea r11, [content_type_json]
.br_cct:
    mov al, [r11]
    test al, al
    jz .br_cctd
    mov [r10], al
    inc r10
    inc r11
    jmp .br_cct
.br_cctd:
    test r8, r8
    jz .br_ne
    mov r11, r8
    mov r12, r9
.br_ce:
    test r12, r12
    jz .br_ced
    mov al, [r11]
    mov [r10], al
    inc r10
    inc r11
    dec r12
    jmp .br_ce
.br_ced:
.br_ne:
    lea r11, [content_length_prefix]
.br_ccl:
    mov al, [r11]
    test al, al
    jz .br_cpdd
    mov [r10], al
    inc r10
    inc r11
    jmp .br_ccl
.br_cpdd:
    lea r11, [rsp-32]
    mov r12, r11
    add r12, 31
    mov byte [r12], 0
    dec r12
.br_itoa:
    mov rbx, 10
    xor rdx, rdx
    div rbx
    add dl, '0'
    mov [r12], dl
    dec r12
    test rax, rax
    jnz .br_itoa
    inc r12
.br_cnum:
    mov al, [r12]
    test al, al
    jz .br_nd
    mov [r10], al
    inc r10
    inc r12
    jmp .br_cnum
.br_nd:
    mov word [r10], 0x0A0D
    add r10, 2
    mov word [r10], 0x0A0D
    add r10, 2
    test rcx, rcx
    jz .br_nb
    mov r11, rdx
.br_cb:
    test rcx, rcx
    jz .br_bd
    mov al, [r11]
    mov [r10], al
    inc r10
    inc r11
    dec rcx
    jmp .br_cb
.br_bd:
.br_nb:
    lea r11, [res_buffer]
    sub r10, r11
    mov rax, r10
    ret

send_success:
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    call build_response
    mov [res_buffer + 8000], rax
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    mov rdi, [client_fd]
    mov rax, 1
    lea rsi, [res_buffer]
    mov rdx, [res_buffer + 8000]
    syscall
    ret

send_error_resp:
    lea r8, [res_buffer + 4000]
    mov rdx, r8
    call build_error_json
    xor r8, r8
    xor r9, r9
    push rdi
    push rsi
    call send_success
    ret

generate_token:
    push rdi
    push rdx
    mov rax, 318
    mov rdi, rsi
    mov rdx, 16
    mov r10, 0
    syscall
    mov rcx, 16
    mov r8, rsi
    mov r9, rsi
    add r9, 32
    mov byte [r9], 0
    dec r9
.gt_loop:
    test rcx, rcx
    jz .gt_done
    dec rcx
    movzx rax, byte [r8 + rcx]
    mov rdx, rax
    shr rdx, 4
    call nibble_to_hex
    mov [r9], al
    dec r9
    mov rdx, rax
    and rdx, 0x0F
    call nibble_to_hex
    mov [r9], al
    dec r9
    jmp .gt_loop
.gt_done:
    pop rdx
    pop rdi
    ret

nibble_to_hex:
    cmp rdx, 9
    jle .nth_n
    add rdx, 'a' - 10
    mov al, dl
    ret
.nth_n:
    add rdx, '0'
    mov al, dl
    ret

find_session:
    push rbx
    push rcx
    push rdi
    xor rbx, rbx
.fs_loop:
    cmp rbx, [session_count]
    jge .fs_nf
    mov rax, rbx
    imul rax, SESSION_SIZE
    lea rcx, [session_array + rax]
    cmp qword [rcx + SESSION_VALID_OFF], 1
    jne .fs_ns
    mov rsi, [rsp]
    lea rdi, [rcx + SESSION_TOKEN_OFF]
    call strcmp
    test rax, rax
    jz .fs_f
.fs_ns:
    inc rbx
    jmp .fs_loop
.fs_f:
    mov rax, [rcx + SESSION_USER_ID_OFF]
    jmp .fs_clean
.fs_nf:
    xor rax, rax
.fs_clean:
    pop rdi
    pop rcx
    pop rbx
    ret

extract_session_id:
    push rdi
    push rsi
    lea r8, [cookie_header]
    mov rdi, [rsp+16]
    mov rsi, r8
    call find_substring
    cmp rax, -1
    je .esi_nc
    add rdi, rax
    add rdi, 8
    lea r8, [session_id_str]
    mov rsi, r8
    call find_substring
    cmp rax, -1
    je .esi_nc
    add rdi, rax
    add rdi, 11
    mov r8, rdi
    mov r9, [rsp+8]
    xor r10, r10
.esi_ct:
    mov cl, [r8]
    cmp cl, ';'
    je .esi_dt
    cmp cl, 0x0d
    je .esi_dt
    cmp cl, 0x0a
    je .esi_dt
    cmp cl, ' '
    je .esi_dt
    cmp cl, 0
    je .esi_dt
    mov [r9 + r10], cl
    inc r10
    inc r8
    cmp r10, 32
    jl .esi_ct
.esi_dt:
    mov byte [r9 + r10], 0
    mov rdi, r9
    call find_session
    test rax, rax
    jz .esi_is
    mov rax, 1
    jmp .esi_clean
.esi_nc:
.esi_is:
    xor rax, rax
.esi_clean:
    pop rsi
    pop rdi
    ret

parse_todo_id:
    lea rsi, [todos_prefix]
    call strcmp_prefix
    test rax, rax
    jnz .pti_nt
    add rdi, 7
    call atoi
    ret
.pti_nt:
    mov rax, -1
    ret

err_400_br:
    mov rdi, 400
    lea rsi, [str_bad_req]
    lea rdx, [str_bad_req]
    call send_error_resp
    ret

handle_client:
    mov rdi, [client_fd]
    mov rax, 0
    lea rsi, [req_buffer]
    mov rdx, 8192
    syscall
    mov [req_len], rax
    lea rdi, [req_buffer]
    lea rsi, [crlfcrlf]
    call find_substring
    cmp rax, -1
    je err_400_br
    lea rdi, [req_buffer]
    lea rsi, [content_length_header]
    call find_substring
    cmp rax, -1
    je .hc_nb
    add rdi, rax
    add rdi, 16
    call atoi
    mov [body_len], rax
.hc_nb:
    lea rdi, [req_buffer]
    lea rsi, [crlfcrlf]
    call find_substring
    add rax, 4
    lea rbx, [req_buffer + rax]
    mov [body_ptr], rbx
    lea rdi, [req_buffer]
    call parse_method
    mov [method], rax
    lea rdi, [req_buffer]
    lea rsi, [path]
    mov rcx, 256
    call parse_path

    lea rdi, [path]
    lea rsi, [path_register]
    call strcmp
    test rax, rax
    jnz .hc_nreg
    cmp qword [method], 2
    jne err_400_br
    call handle_register
    jmp .hc_done

.hc_nreg:
    lea rdi, [path]
    lea rsi, [path_login]
    call strcmp
    test rax, rax
    jnz .hc_nlog
    cmp qword [method], 2
    jne err_400_br
    call handle_login
    jmp .hc_done

.hc_nlog:
    lea rdi, [path]
    lea rsi, [path_logout]
    call strcmp
    test rax, rax
    jnz .hc_nlo
    cmp qword [method], 2
    jne err_400_br
    call handle_logout
    jmp .hc_done

.hc_nlo:
    lea rdi, [path]
    lea rsi, [path_me]
    call strcmp
    test rax, rax
    jnz .hc_nme
    cmp qword [method], 1
    jne err_400_br
    call handle_me
    jmp .hc_done

.hc_nme:
    lea rdi, [path]
    lea rsi, [path_password]
    call strcmp
    test rax, rax
    jnz .hc_np
    cmp qword [method], 3
    jne err_400_br
    call handle_password
    jmp .hc_done

.hc_np:
    lea rdi, [path]
    lea rsi, [path_todos]
    call strcmp
    test rax, rax
    jz .hc_todos_root
    lea rdi, [path]
    call parse_todo_id
    cmp rax, -1
    je err_400_br
    mov [temp_buf1], rax
    cmp qword [method], 1
    je .hc_todo_get
    cmp qword [method], 3
    je .hc_todo_put
    cmp qword [method], 4
    je .hc_todo_del
    jmp err_400_br

.hc_todos_root:
    cmp qword [method], 1
    je .hc_todos_get
    cmp qword [method], 2
    je .hc_todos_post
    jmp err_400_br

.hc_todos_get:
    call handle_todos_get
    jmp .hc_done

.hc_todos_post:
    call handle_todos_post
    jmp .hc_done

.hc_todo_get:
    call handle_todo_get
    jmp .hc_done

.hc_todo_put:
    call handle_todo_put
    jmp .hc_done

.hc_todo_del:
    call handle_todo_del
    jmp .hc_done

.hc_done:
    ret

handle_register:
    mov rdi, [body_ptr]
    lea rsi, [key_username]
    lea rdx, [temp_buf1]
    mov rcx, 64
    call get_json_string
    cmp rax, -1
    je .hr_inv_u
    mov r14, rax
    lea rdi, [temp_buf1]
    call validate_username
    test rax, rax
    jz .hr_inv_u
    mov rdi, [body_ptr]
    lea rsi, [key_password]
    lea rdx, [temp_buf2]
    mov rcx, 64
    call get_json_string
    cmp rax, -1
    je .hr_inv_p
    mov r15, rax
    cmp r15, 8
    jl .hr_ps
    lea rdi, [temp_buf1]
    call find_user_by_name
    test rax, rax
    jnz .hr_uex
    mov rbx, [user_count]
    cmp rbx, MAX_USERS
    jge .hr_se
    mov rax, rbx
    imul rax, USER_SIZE
    lea rcx, [user_array + rax]
    mov rax, rbx
    inc rax
    mov [rcx + USER_ID_OFF], rax
    lea rsi, [temp_buf1]
    lea rdi, [rcx + USER_NAME_OFF]
    mov rdx, r14
    call memcpy
    lea rdi, [temp_buf2]
    call strlen
    mov rdx, rax
    lea rsi, [temp_buf2]
    lea rdi, [rcx + USER_PASS_OFF]
    call memcpy
    inc qword [user_count]
    mov rdx, temp_buf4
    mov rdi, rcx
    call build_user_json
    mov rdx, temp_buf4
    mov rdi, 201
    lea rsi, [str_created]
    xor r8, r8
    xor r9, r9
    call send_success
    ret
.hr_inv_u:
    mov rdi, 400
    lea rsi, [str_bad_req]
    lea rdx, [str_inv_user]
    call send_error_resp
    ret
.hr_inv_p:
.hr_ps:
    mov rdi, 400
    lea rsi, [str_bad_req]
    lea rdx, [str_ps_short]
    call send_error_resp
    ret
.hr_uex:
    mov rdi, 409
    lea rsi, [str_conflict]
    lea rdx, [str_u_exists]
    call send_error_resp
    ret
.hr_se:
    mov rdi, 500
    lea rsi, [str_server_err]
    lea rdx, [str_server_err]
    call send_error_resp
    ret

str_inv_user: db "Invalid username", 0
str_ps_short: db "Password too short", 0
str_u_exists: db "Username already exists", 0

handle_login:
    mov rdi, [body_ptr]
    lea rsi, [key_username]
    lea rdx, [temp_buf1]
    mov rcx, 64
    call get_json_string
    cmp rax, -1
    je .hl_ic
    lea rdi, [temp_buf1]
    call find_user_by_name
    test rax, rax
    jz .hl_ic
    mov r8, rax
    dec r8
    mov rax, r8
    imul rax, USER_SIZE
    lea rcx, [user_array + rax]
    mov rdi, [body_ptr]
    lea rsi, [key_password]
    lea rdx, [temp_buf2]
    mov rcx, 64
    call get_json_string
    cmp rax, -1
    je .hl_ic
    lea rdi, [temp_buf2]
    lea rsi, [rcx + USER_PASS_OFF]
    call strcmp
    test rax, rax
    jnz .hl_ic
    lea rdi, [temp_buf3]
    call generate_token
    xor rbx, rbx
.hl_fss:
    cmp rbx, MAX_SESSIONS
    jge .hl_se
    mov rax, rbx
    imul rax, SESSION_SIZE
    lea r9, [session_array + rax]
    cmp qword [r9 + SESSION_VALID_OFF], 0
    je .hl_fs
    inc rbx
    jmp .hl_fss
.hl_fs:
    lea rsi, [temp_buf3]
    lea rdi, [r9 + SESSION_TOKEN_OFF]
    mov rdx, 32
    call memcpy
    mov [r9 + SESSION_USER_ID_OFF], r8
    mov qword [r9 + SESSION_VALID_OFF], 1
    inc qword [session_count]
    lea r8, [temp_buf5]
    mov rsi, r8
    lea r10, [str_set_cookie_start]
    call strcpy
    lea r10, [temp_buf3]
    call strcpy
    lea r10, [str_set_cookie_end]
    call strcpy
    mov rdi, r8
    call strlen
    mov r9, rax
    mov r8, r8
    mov rdx, temp_buf4
    mov rdi, rcx
    call build_user_json
    mov rdx, temp_buf4
    mov rdi, 200
    lea rsi, [str_ok]
    call send_success
    ret
.hl_ic:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_inv_creds]
    call send_error_resp
    ret
.hl_se:
    mov rdi, 500
    lea rsi, [str_server_err]
    lea rdx, [str_server_err]
    call send_error_resp
    ret

str_inv_creds: db "Invalid credentials", 0

handle_logout:
    lea rdi, [req_buffer]
    lea rsi, [temp_buf1]
    call extract_session_id
    test rax, rax
    jz .ho_unauth
    xor rbx, rbx
.ho_fs:
    cmp rbx, [session_count]
    jge .ho_done
    mov rax, rbx
    imul rax, SESSION_SIZE
    lea rcx, [session_array + rax]
    lea rdi, [temp_buf1]
    lea rsi, [rcx + SESSION_TOKEN_OFF]
    call strcmp
    test rax, rax
    jz .ho_f
    inc rbx
    jmp .ho_fs
.ho_f:
    mov qword [rcx + SESSION_VALID_OFF], 0
.ho_done:
    mov rdx, temp_buf4
    mov rsi, rdx
    call build_empty_json
    mov rdx, temp_buf4
    mov rdi, 200
    lea rsi, [str_ok]
    xor r8, r8
    xor r9, r9
    call send_success
    ret
.ho_unauth:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_auth_req]
    call send_error_resp
    ret

str_auth_req: db "Authentication required", 0

handle_me:
    lea rdi, [req_buffer]
    lea rsi, [temp_buf1]
    call extract_session_id
    test rax, rax
    jz .hme_unauth
    mov r8, rax
    dec r8
    mov rax, r8
    imul rax, USER_SIZE
    lea rcx, [user_array + rax]
    mov rdx, temp_buf4
    mov rdi, rcx
    call build_user_json
    mov rdx, temp_buf4
    mov rdi, 200
    lea rsi, [str_ok]
    xor r8, r8
    xor r9, r9
    call send_success
    ret
.hme_unauth:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_auth_req]
    call send_error_resp
    ret

handle_password:
    lea rdi, [req_buffer]
    lea rsi, [temp_buf1]
    call extract_session_id
    test rax, rax
    jz .hp_unauth
    mov r8, rax
    dec r8
    mov rax, r8
    imul rax, USER_SIZE
    lea rcx, [user_array + rax]
    mov rdi, [body_ptr]
    lea rsi, [key_old_pass]
    lea rdx, [temp_buf2]
    mov rcx, 64
    call get_json_string
    cmp rax, -1
    je .hp_ic
    lea rdi, [temp_buf2]
    lea rsi, [rcx + USER_PASS_OFF]
    call strcmp
    test rax, rax
    jnz .hp_ic
    mov rdi, [body_ptr]
    lea rsi, [key_new_pass]
    lea rdx, [temp_buf3]
    mov rcx, 64
    call get_json_string
    cmp rax, -1
    je .hp_ps
    mov r14, rax
    cmp r14, 8
    jl .hp_ps
    lea rdi, [temp_buf3]
    call strlen
    mov rdx, rax
    lea rsi, [temp_buf3]
    lea rdi, [rcx + USER_PASS_OFF]
    call memcpy
    mov rdx, temp_buf4
    mov rsi, rdx
    call build_empty_json
    mov rdx, temp_buf4
    mov rdi, 200
    lea rsi, [str_ok]
    xor r8, r8
    xor r9, r9
    call send_success
    ret
.hp_ic:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_inv_creds]
    call send_error_resp
    ret
.hp_ps:
    mov rdi, 400
    lea rsi, [str_bad_req]
    lea rdx, [str_ps_short]
    call send_error_resp
    ret
.hp_unauth:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_auth_req]
    call send_error_resp
    ret

get_current_time_str:
    mov rax, 201
    xor rdi, rdi
    xor rsi, rsi
    syscall
    mov rdi, rax
    mov rsi, rdx
    call format_time
    ret

handle_todos_get:
    lea rdi, [req_buffer]
    lea rsi, [temp_buf1]
    call extract_session_id
    test rax, rax
    jz .htg_unauth
    mov rdi, rax
    lea rsi, [temp_buf4]
    push rdi
    call build_todo_list_json
    pop rdi
    mov rdx, temp_buf4
    mov rdi, 200
    lea rsi, [str_ok]
    xor r8, r8
    xor r9, r9
    call send_success
    ret
.htg_unauth:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_auth_req]
    call send_error_resp
    ret

handle_todos_post:
    lea rdi, [req_buffer]
    lea rsi, [temp_buf1]
    call extract_session_id
    test rax, rax
    jz .htp_unauth
    mov r8, rax
    mov rdi, [body_ptr]
    lea rsi, [key_title]
    lea rdx, [temp_buf2]
    mov rcx, 128
    call get_json_string
    cmp rax, -1
    je .htp_tr
    mov r14, rax
    cmp r14, 0
    je .htp_tr
    mov rbx, [todo_count]
    cmp rbx, MAX_TODOS
    jge .htp_se
    mov rax, rbx
    imul rax, TODO_SIZE
    lea rcx, [todo_array + rax]
    mov rax, rbx
    inc rax
    mov [rcx + TODO_ID_OFF], rax
    mov [rcx + TODO_USER_ID_OFF], r8
    lea rsi, [temp_buf2]
    lea rdi, [rcx + TODO_TITLE_OFF]
    mov rdx, r14
    call memcpy
    mov qword [rcx + TODO_DONE_OFF], 0
    mov rdi, [body_ptr]
    lea rsi, [key_desc]
    lea rdx, [temp_buf3]
    mov rcx, 256
    call get_json_string
    cmp rax, -1
    jne .htp_hd
    mov rax, 0
.htp_hd:
    mov r15, rax
    mov rdx, r15
    lea rsi, [temp_buf3]
    lea rdi, [rcx + TODO_DESC_OFF]
    call memcpy
    call get_current_time_str
    lea rsi, [temp_buf4]
    lea rdi, [rcx + TODO_CREATED_OFF]
    mov rdx, 20
    call memcpy
    lea rdi, [rcx + TODO_UPDATED_OFF]
    mov rdx, 20
    call memcpy
    inc qword [todo_count]
    mov rdx, temp_buf5
    mov rdi, rcx
    call build_todo_json
    mov rdx, temp_buf5
    mov rdi, 201
    lea rsi, [str_created]
    xor r8, r8
    xor r9, r9
    call send_success
    ret
.htp_tr:
    mov rdi, 400
    lea rsi, [str_bad_req]
    lea rdx, [str_title_req]
    call send_error_resp
    ret
.htp_se:
    mov rdi, 500
    lea rsi, [str_server_err]
    lea rdx, [str_server_err]
    call send_error_resp
    ret
.htp_unauth:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_auth_req]
    call send_error_resp
    ret

str_title_req: db "Title is required", 0

handle_todo_get:
    lea rdi, [req_buffer]
    lea rsi, [temp_buf1]
    call extract_session_id
    test rax, rax
    jz .htg2_unauth
    mov r8, rax
    mov rax, [temp_buf1]
    cmp rax, 1
    jl .htg2_nf
    dec rax
    cmp rax, [todo_count]
    jge .htg2_nf
    mov rbx, rax
    imul rbx, TODO_SIZE
    lea rcx, [todo_array + rbx]
    cmp qword [rcx + TODO_USER_ID_OFF], r8
    jne .htg2_nf
    mov rdx, temp_buf4
    mov rdi, rcx
    call build_todo_json
    mov rdx, temp_buf4
    mov rdi, 200
    lea rsi, [str_ok]
    xor r8, r8
    xor r9, r9
    call send_success
    ret
.htg2_nf:
    mov rdi, 404
    lea rsi, [str_not_found]
    lea rdx, [str_todo_nf]
    call send_error_resp
    ret
.htg2_unauth:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_auth_req]
    call send_error_resp
    ret

str_todo_nf: db "Todo not found", 0

handle_todo_put:
    lea rdi, [req_buffer]
    lea rsi, [temp_buf1]
    call extract_session_id
    test rax, rax
    jz .htpu_unauth
    mov r8, rax
    mov rax, [temp_buf1]
    cmp rax, 1
    jl .htpu_nf
    dec rax
    cmp rax, [todo_count]
    jge .htpu_nf
    mov rbx, rax
    imul rbx, TODO_SIZE
    lea rcx, [todo_array + rbx]
    cmp qword [rcx + TODO_USER_ID_OFF], r8
    jne .htpu_nf
    mov rdi, [body_ptr]
    lea rsi, [key_title]
    lea rdx, [temp_buf2]
    mov r9d, 128
    call get_json_string
    cmp rax, -1
    jne .htpu_ht
    cmp rax, 0
    je .htpu_ter
    jmp .htpu_st
.htpu_ht:
    mov r14, rax
    mov rdx, r14
    lea rsi, [temp_buf2]
    lea rdi, [rcx + TODO_TITLE_OFF]
    call memcpy
.htpu_st:
    mov rdi, [body_ptr]
    lea rsi, [key_desc]
    lea rdx, [temp_buf2]
    mov r9d, 256
    call get_json_string
    cmp rax, -1
    jne .htpu_hd
    jmp .htpu_sd
.htpu_hd:
    mov r14, rax
    mov rdx, r14
    lea rsi, [temp_buf2]
    lea rdi, [rcx + TODO_DESC_OFF]
    call memcpy
.htpu_sd:
    mov rdi, [body_ptr]
    lea rsi, [key_completed]
    call get_json_bool
    cmp rax, -1
    je .htpu_sc
    mov [rcx + TODO_DONE_OFF], rax
.htpu_sc:
    call get_current_time_str
    lea rsi, [temp_buf4]
    lea rdi, [rcx + TODO_UPDATED_OFF]
    mov rdx, 20
    call memcpy
    mov rdx, temp_buf5
    mov rdi, rcx
    call build_todo_json
    mov rdx, temp_buf5
    mov rdi, 200
    lea rsi, [str_ok]
    xor r8, r8
    xor r9, r9
    call send_success
    ret
.htpu_ter:
    mov rdi, 400
    lea rsi, [str_bad_req]
    lea rdx, [str_title_req]
    call send_error_resp
    ret
.htpu_nf:
    mov rdi, 404
    lea rsi, [str_not_found]
    lea rdx, [str_todo_nf]
    call send_error_resp
    ret
.htpu_unauth:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_auth_req]
    call send_error_resp
    ret

handle_todo_del:
    lea rdi, [req_buffer]
    lea rsi, [temp_buf1]
    call extract_session_id
    test rax, rax
    jz .htd_unauth
    mov r8, rax
    mov rax, [temp_buf1]
    cmp rax, 1
    jl .htd_nf
    dec rax
    cmp rax, [todo_count]
    jge .htd_nf
    mov rbx, rax
    imul rbx, TODO_SIZE
    lea rcx, [todo_array + rbx]
    cmp qword [rcx + TODO_USER_ID_OFF], r8
    jne .htd_nf
    mov qword [rcx + TODO_USER_ID_OFF], 0
    mov rdi, 204
    lea rsi, [str_no_content]
    xor rdx, rdx
    xor rcx, rcx
    xor r8, r8
    xor r9, r9
    call send_success
    ret
.htd_nf:
    mov rdi, 404
    lea rsi, [str_not_found]
    lea rdx, [str_todo_nf]
    call send_error_resp
    ret
.htd_unauth:
    mov rdi, 401
    lea rsi, [str_unauth]
    lea rdx, [str_auth_req]
    call send_error_resp
    ret

section .data
sockaddr:
    dw 2
    dw 0
    dd 0
    times 8 db 0
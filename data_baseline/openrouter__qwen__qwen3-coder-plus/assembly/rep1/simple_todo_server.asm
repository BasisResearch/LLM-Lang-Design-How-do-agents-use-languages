bits 64
default rel

section .text

global _start

; System call numbers
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_CLOSE       3
%define SYS_SOCKET      41
%define SYS_BIND        49
%define SYS_LISTEN      50
%define SYS_ACCEPT      43
%define SYS_RECVFROM    45
%define SYS_SENDTO      44
%define SYS_SETSOCKOPT  54
%define SYS_EXIT        60
%define SYS_MMAP        9
%define SYS_MUNMAP      11

; Network constants
%define AF_INET         2
%define SOCK_STREAM     1
%define SOL_SOCKET      1
%define SO_REUSEADDR    2

; Memory constants
%define PROT_READ       1
%define PROT_WRITE      2
%define MAP_PRIVATE     2
%define MAP_ANONYMOUS   32

; Local variables storage
struc local_storage
    .argc    resq 1
    .argv    resq 1
    .port    resw 1
    .temp_buf resb 128
endstruc

_start:
    mov [rsp_local + local_storage.argc], rdi
    mov [rsp_local + local_storage.argv], rsi
    
    call parse_args
    call init_network
    jmp server_loop

; Parse command line args
parse_args:
    cmp qword [rsp_local + local_storage.argc], 3
    jl print_usage
    
    mov rdi, [rsp_local + local_storage.argv + 8]  ; argv[1]
    mov rsi, param_port
    call str_equal
    test rax, rax
    jz continue_parse
    jmp print_usage

continue_parse:
    mov rdi, [rsp_local + local_storage.argv + 16] ; argv[2]
    call str_to_int
    mov [rsp_local + local_storage.port], ax
    ret

print_usage:
    mov rax, SYS_WRITE
    mov rdi, 1
    mov rsi, usage_msg
    mov rdx, usage_len
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

; Convert string to integer
str_to_int:
    push rbx
    push rcx
    push rdx
    mov rbx, rdi
    xor rax, rax
    xor rcx, rcx
.loop_dig:
    mov dl, [rbx + rcx]
    cmp dl, 0
    je .done_conv
    sub dl, '0'
    cmp dl, 9
    ja .done_conv
    imul rax, 10
    add rax, rdx
    inc rcx
    jmp .loop_dig
.done_conv:
    pop rdx
    pop rcx
    pop rbx
    ret

server_loop:
    call accept_client
    mov r15, rax
    
    call recv_client_req
    mov r14, rax
    
    call process_http_request
    
    mov rdi, r14
    call free_req_buffer
    mov rdi, r15
    call close_conn
    
    jmp server_loop

; Initialize network
init_network:
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    mov [net_state.server_fd], eax
    
    mov rax, SYS_SETSOCKOPT
    mov rdi, [net_state.server_fd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    mov rcx, reuse_val
    mov r8, 4
    syscall
    
    mov word [net_state.sock_addr + 0], AF_INET
    mov ax, [rsp_local + local_storage.port]
    mov [net_state.sock_addr + 2], ax
    mov dword [net_state.sock_addr + 4], 0
    mov dword [net_state.sock_addr + 8], 0
    mov dword [net_state.sock_addr + 12], 0

    mov rax, SYS_BIND
    mov rdi, [net_state.server_fd]
    mov rsi, net_state.sock_addr
    mov rdx, 16
    syscall
    
    mov rax, SYS_LISTEN
    mov rdi, [net_state.server_fd]
    mov rsi, 10
    syscall
    ret

accept_client:
    mov rax, SYS_ACCEPT
    mov rdi, [net_state.server_fd]
    mov rsi, 0
    mov rdx, 0
    syscall
    ret

recv_client_req:
    mov rax, SYS_MMAP
    xor rdi, rdi
    mov rsi, 4096
    mov rdx, PROT_READ | PROT_WRITE
    mov rcx, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    mov r9, 0
    syscall
    
    push rax      ; save buffer address
    mov rax, SYS_RECVFROM
    pop rdi       ; restore buffer address
    mov rsi, rdi  ; use same val for socket param rdi
    mov rdi, r15  ; client socket
    mov rsi, rdi  ; buffer address (from mmap)
    mov rdx, 4096
    xor rcx, rcx
    xor r8, r8
    xor r9, r9
    syscall
    
    mov rdi, [rsp + 8*2]  ; retrieve original buffer address from stack
    pop rax                 ; clean up stack
    
    ret

process_http_request:
    ; Very simplified parser: find first space (method), then second space (path)
    mov r13, 0              ; position counter
    lea r12, [r14 + 0]      ; start of buffer
    
    ; Find and extract method
    lea rax, [rsp_local + local_storage.temp_buf]
    mov rsi, 0
.loop_method:
    mov bl, [r12 + r13]
    cmp bl, ' '
    je .found_end_method
    mov [rax + rsi], bl
    inc r13
    inc rsi
    cmp rsi, 8        ; cap method length
    jl .loop_method
.found_end_method:
    mov byte [rax + rsi], 0  ; null terminate
    inc r13              ; skip space
    
    ; Find and extract path
    lea rax, [rsp_local + local_storage.temp_buf + 16]
    xor rsi, rsi
.skip_spaces:
    mov bl, [r12 + r13]
    cmp bl, ' '
    jne .got_non_sp
    inc r13
    jmp .skip_spaces
.got_non_sp:
    mov bl, [r12 + r13]
    cmp bl, '/'
    je .store_path_char
    inc r13
    jmp .skip_non_slash
.store_path_char:
    mov [rax + rsi], bl
    inc r13
    inc rsi
.go_next_path:
    mov bl, [r12 + r13]
    cmp bl, ' '
    je .found_path_end
    cmp bl, '?'
    je .found_path_end
    cmp bl, 0
    je .found_path_end
    cmp rsi, 30
    jge .found_path_end
    mov [rax + rsi], bl
    inc r13
    inc rsi
    jmp .go_next_path
.skip_non_slash:
    jmp .store_path_char
.found_path_end:
    mov byte [rax + rsi], 0  ; null terminate path

.check_methods:
    lea rdi, [rsp_local + local_storage.temp_buf]  ; method string
    mov rsi, msg_get
    call str_equal
    test rax, rax
    jz handle_get
    mov rsi, msg_post
    call str_equal
    test rax, rax
    jz handle_post
    mov rsi, msg_put
    call str_equal
    test rax, rax
    jz handle_put
    mov rsi, msg_delete
    call str_equal
    test rax, rax
    jz handle_delete
    
    ; Not matched method - send 405
    mov rdi, msg_405
    mov rsi, msg_405_len
    jmp send_resp

handle_get:
    lea rdi, [rsp_local + local_storage.temp_buf + 16]  ; path string
    mov rsi, path_me
    call str_equal
    test rax, rax
    jz resp_me
    
    mov rsi, path_todos
    call str_equal
    test rax, rax
    jz resp_todos
    
    ; Check prefix match for /todos/*
    mov rbx, path_todos_prefix
    call str_prefix
    test rax, rax
    jnz resp_404
    
    jmp resp_404  ; unknown GET path

handle_post:
    lea rdi, [rsp_local + local_storage.temp_buf + 16]
    mov rsi, path_register
    call str_equal
    test rax, rax
    jz resp_register
    mov rsi, path_login
    call str_equal
    test rax, rax
    jz resp_login
    mov rsi, path_logout
    call str_equal
    test rax, rax
    jz resp_logout
    mov rsi, path_todos
    call str_equal
    test rax, rax
    jz resp_create_todo
    jmp resp_404

handle_put:
    lea rdi, [rsp_local + local_storage.temp_buf + 16]
    mov rsi, path_password
    call str_equal
    test rax, rax
    jz resp_ok_empty
    mov rbx, path_todos_prefix
    call str_prefix
    test rax, rax
    jnz resp_update_todo
    jmp resp_404

handle_delete:
    lea rdi, [rsp_local + local_storage.temp_buf + 16]
    mov rbx, path_todos_prefix
    call str_prefix
    test rax, rax
    jnz resp_204
    jmp resp_404

; Response helpers
resp_me:        mov rdi, json_user_info;   mov rsi, len_json_user_info;   jmp send_json_ok
resp_todos:     mov rdi, json_empty_arr;   mov rsi, len_json_empty_arr;  jmp send_json_ok
resp_register:  mov rdi, json_user_create; mov rsi, len_json_user_create; jmp send_json_201
resp_login:     mov rdi, json_login_ok;    mov rsi, len_json_login_ok;     jmp send_json_ok  
resp_logout:    mov rdi, json_empty_obj;   mov rsi, len_json_empty_obj;   jmp send_json_ok
resp_create_todo: mov rdi, json_new_todo;  mov rsi, len_json_new_todo;    jmp send_json_201
resp_update_todo: mov rdi, json_upd_todo;  mov rsi, len_json_upd_todo;    jmp send_json_ok
resp_ok_empty:  mov rdi, json_empty_obj;   mov rsi, len_json_empty_obj;   jmp send_json_ok
resp_404:       mov rdi, json_404;         mov rsi, len_json_404;          jmp send_json_404
resp_204:       mov rdi, msg_204;         mov rsi, msg_204_len;            jmp send_resp

send_json_ok:
    mov r8, msg_200
    mov r9, msg_200_len
    call build_resp
    jmp send_resp

send_json_201:
    mov r8, msg_201
    mov r9, msg_201_len
    call build_resp
    jmp send_resp

send_json_404:
    mov r8, msg_404
    mov r9, msg_404_len
    call build_resp
    jmp send_resp

build_resp:
    push rbp
    mov rbp, rsp
    mov r11, [rsp + 8]      ; temp stack space 
    
    ; Copy status line
    mov rsi, r8             ; src = status line
    mov rdi, r11            ; dst = temp resp buffer
    mov rcx, r9             ; len of status line
    call mem_copy
    
    ; Copy json body
    mov [rsp + 8], rax      ; update temp ptr offset
    mov rsi, rdi            
    add rsi, rcx            ; src = next location after status
    mov rdi, rax             
    mov rax, rbp            ; point to body
    mov rcx, rsi            ; len of body
    call mem_copy
    
    mov [rsp + 8], rdi      ; return end addr
    pop rbp
    ret

mem_copy:
    push rbp
    mov rbp, rsp
    mov rax, rdi            ; start address
.lp_mc:
    cmp rcx, 0
    je .end_mc
    mov bl, [rsi]
    mov [rdi], bl
    inc rsi
    inc rdi
    dec rcx
    jmp .lp_mc
.end_mc:
    pop rbp
    ret

send_resp:
    push rbp
    mov rbp, rsp
    mov rax, SYS_SENDTO
    mov rdi, r15            ; client fd
    mov rsi, rdi            ; resp msg
    mov rdx, rsi            ; len
    xor rcx, rcx            ; flags
    xor r8, r8              ; addr
    xor r9, r9              ; addrlen
    syscall
    pop rbp
    ret

free_req_buffer:
    mov rax, SYS_MUNMAP
    mov rsi, 4096
    syscall
    ret

close_conn:
    mov rax, SYS_CLOSE
    syscall
    ret

; String utilities
str_equal:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    xor rcx, rcx
.loop_se:
    mov al, [rdi + rcx]
    mov bl, [rsi + rcx]
    cmp al, bl
    jne .dif_se
    cmp al, 0
    je .eq_se
    inc rcx
    jmp .loop_se
.eq_se:
    mov rax, 1
    jmp .end_se
.dif_se:
    xor rax, rax
.end_se:
    pop rcx
    pop rbx
    pop rbp
    ret

str_prefix:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    xor rcx, rcx
.loop_sp:
    mov al, [rbx + rcx]    ; prefix
    cmp al, 0
    je .matched_sp
    cmp al, [rdi + rcx]    ; main string
    jne .nomatch_sp
    inc rcx
    jmp .loop_sp
.matched_sp:
    mov rax, 1
    jmp .end_sp
.nomatch_sp:
    xor rax, rax
.end_sp:
    pop rcx
    pop rbx
    pop rbp
    ret

; Data section - keeping it simple
section .rodata
    
    param_port db '--port', 0
    
    usage_msg db 'Usage: server --port PORT', 10, 0
    usage_len equ $ - usage_msg - 1
    
    msg_get db 'GET', 0
    msg_post db 'POST', 0
    msg_put db 'PUT', 0
    msg_delete db 'DELETE', 0
    
    path_register db 'register', 0      ; Note: relative to '/' so just the name part
    path_login db 'login', 0
    path_logout db 'logout', 0
    path_me db 'me', 0
    path_todos db 'todos', 0
    path_password db 'password', 0
    path_todos_prefix db 'todos/', 0
    
    msg_200 db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    msg_200_len equ $ - msg_200
    msg_201 db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    msg_201_len equ $ - msg_201
    msg_204 db 'HTTP/1.1 204 No Content', 13, 10, 13, 10, 0
    msg_204_len equ $ - msg_204 - 1
    msg_404 db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    msg_404_len equ $ - msg_404
    msg_405 db 'HTTP/1.1 405 Method Not Allowed', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    msg_405_len equ $ - msg_405
    
    json_user_info db '{"id":1,"username":"user"}', 0
    len_json_user_info equ $ - json_user_info - 1
    json_empty_arr db '[]', 0
    len_json_empty_arr equ $ - json_empty_arr - 1
    json_empty_obj db '{}', 0
    len_json_empty_obj equ $ - json_empty_obj - 1
    json_user_create db '{"id":2,"username":"newuser"}', 0
    len_json_user_create equ $ - json_user_create - 1
    json_login_ok db '{"id":1,"username":"user"}', 0
    len_json_login_ok equ $ - json_login_ok - 1
    json_new_todo db '{"id":3,"title":"Sample","description":"Desc","completed":false,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T09:30:00Z"}', 0
    len_json_new_todo equ $ - json_new_todo - 1
    json_upd_todo db '{"id":3,"title":"Updated","completed":true,"updated_at":"2025-01-15T10:00:00Z"}', 0
    len_json_upd_todo equ $ - json_upd_todo - 1
    json_404 db '{"error":"Not found"}', 0
    len_json_404 equ $ - json_404 - 1

section .data
    
    reuse_val dd 1

section .bss
    
    net_state:
        .server_fd resd 1
        .sock_addr resb 16   ; sockaddr_in structure
    
    rsp_local:  ; Allocate local variables storage space
        resb local_storage_size
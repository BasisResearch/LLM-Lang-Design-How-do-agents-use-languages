bits 64
default rel

section .text

global _start

; System calls
SYS_READ        equ 0
SYS_WRITE       equ 1
SYS_OPEN        equ 2
SYS_CLOSE       equ 3
SYS_SOCKET      equ 41
SYS_BIND        equ 49  
SYS_LISTEN      equ 50
SYS_ACCEPT      equ 43
SYS_RECVFROM    equ 45
SYS_SENDTO      equ 44
SYS_SETSOCKOPT  equ 54
SYS_EXIT        equ 60
SYS_MMAP        equ 9
SYS_MUNMAP      equ 11

; Socket constants
AF_INET         equ 2
SOCK_STREAM     equ 1
SOL_SOCKET      equ 1
SO_REUSEADDR    equ 2

; Memory constants
PROT_READ       equ 1
PROT_WRITE      equ 2
MAP_PRIVATE     equ 2
MAP_ANONYMOUS   equ 32

; sockaddr_in structure size  
SOCKADDRIN_SIZE equ 16

_struc_start:
; Define offsets manually instead of using STRUC
SIN_FAMILY_OFF equ 0       ; sin_family offset  
SIN_PORT_OFF   equ 2       ; sin_port offset
SIN_ADDR_OFF   equ 4       ; sin_addr offset 
SIN_PAD_OFF    equ 8       ; padding offset
_struc_end:

; Main entry
_start:
    mov rbp, rsp
    mov rdi, [rbp + 0*8]    ; argc
    mov rsi, [rbp + 1*8]    ; argv

    ; Parse arguments
    call parse_args
    
    ; Start server
    call server_main


parse_args:
    push rbp
    mov rbp, rsp

    ; Verify we have at least 3 arguments
    cmp rdi, 3
    jb .usage
    
    ; Compare argv[1] with "--port" 
    mov rax, [rsi + 8]      ; argv[1]
    mov rbx, .str_port
    call cstring_equal 
    test rax, rax
    jz .usage
    
    ; Convert argv[2] to integer
    mov rdi, [rsi + 16]     ; argv[2]
    call string_to_int
    mov [.port_arg], ax 

    pop rbp
    ret

.usage:
    mov rdi, .usage_msg
    mov rsi, .usage_len
    call print
    mov rdi, 1
    call die 

.string_to_int:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx 
    push rdx

    mov rbx, rdi    ; source string
    xor rax, rax    ; accumulator
    xor rcx, rcx    ; index

.loop:
    mov dl, [rbx + rcx]
    test dl, dl     ; null terminator?
    jz .done
    sub dl, '0'     ; ASCII to digit
    cmp dl, 9       ; valid digit?
    ja .done
    
    ; val = val * 10 + digit
    imul rax, 10
    add rax, rdx
    
    inc rcx
    jmp .loop
    
.done:
    mov rbx, rax            ; Save original order
    rol ax, 8              ; Swap byte order for network
    and rbx, 0xFFFF0000    ; Get upper part
    or eax, ebx            ; Combine back
    rol eax, 16            ; Final swap
    mov rbx, rax
    
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret
    
.cstring_equal:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx
.loop2:
    mov al, [rdi + rcx] 
    cmp al, [rsi + rcx]
    jne .not_equal
    test al, al             ; null terminators?
    jz .equal
    inc rcx
    jmp .loop2
    
.equal:
    xor rax, rax
    inc rax                 ; return 1
    jmp .exit_eq
.not_equal:
    xor rax, rax            ; return 0
.exit_eq:
    pop rcx
    pop rbx
    pop rbp
    ret

.str_port db '--port', 0  
.usage_msg db 'Usage: server --port PORT_NUMBER', 10, 0
.usage_len equ $ - .usage_msg - 1
.port_arg resw 1


server_main:
    push rbp 
    mov rbp, rsp
    
    ; Create socket: socket(AF_INET, SOCK_STREAM, 0)
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    mov [.server_fd], eax
    
    ; Setsockopt(SO_REUSEADDR)
    mov rax, SYS_SETSOCKOPT
    mov rdi, [.server_fd] 
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    lea rcx, [.opt_one_val]
    mov r8, 4
    syscall

    ; Prepare address structure
    ; sin_family = AF_INET (2)
    mov word [.sockaddr_struc + SIN_FAMILY_OFF], AF_INET
    ; sin_port = port from args
    mov ax, [.port_arg]
    mov [.sockaddr_struc + SIN_PORT_OFF], ax
    ; sin_addr = 0.0.0.0 (INADDR_ANY)
    mov dword [.sockaddr_struc + SIN_ADDR_OFF], 0    
    mov dword [.sockaddr_struc + SIN_PAD_OFF], 0

    ; bind socket
    mov rax, SYS_BIND
    mov rdi, [.server_fd]
    lea rsi, [.sockaddr_struc]
    mov rdx, SOCKADDRIN_SIZE
    syscall
    
    ; listen 
    mov rax, SYS_LISTEN
    mov rdi, [.server_fd]
    mov rsi, 5          ; backlog
    syscall
    
.main_loop:
    ; accept
    mov rax, SYS_ACCEPT
    mov rdi, [.server_fd]
    xor rsi, rsi        ; no addr
    xor rdx, rdx        ; no addrlen  
    syscall
    mov r15, eax        ; r15 = client fd

    ; alloc temporary buf
    call alloc_buffer
    mov r14, rax

    ; recv from client
    mov rax, SYS_RECVFROM
    mov rdi, r15        ; client fd
    mov rsi, r14        ; buffer
    mov rdx, .BUFLEN    ; size
    xor rcx, rcx        ; flags
    xor r8, r8          ; from
    xor r9, r9          ; fromlen
    syscall
    mov r13, rax        ; bytes received

    ; process request (simplified routing)
    call process_req

    ; cleanup
    mov rdi, r14
    call dealloc_buffer
    
    mov rdi, r15
    call close_fd

    jmp .main_loop 
    
.opt_one_val dd 1
.BUFLEN equ 4096
.sockaddr_struc resb SOCKADDRIN_SIZE


process_req:
    push rbp
    mov rbp, rsp
    
    ; Find first space to locate method (GET, POST...)
    mov rax, 0          ; idx
    mov rbx, 0          ; temp char
    
.loop_find_method:
    mov bl, [r14 + rax]
    cmp bl, ' ' 
    je .space_found
    mov [.temp_method + rax], bl
    inc rax
    cmp rax, 15          ; max len
    jb .loop_find_method

.space_found:    
    mov byte [.temp_method + rax], 0  ; null term
    inc rax                           ; skip space

    ; Now find path
    mov rbx, 0          ; idx
.find_path_loop:
    mov cl, [r14 + rax + rbx]
    cmp cl, ' '
    je .path_space_found
    cmp cl, '?'          ; query params?
    je .path_space_found
    mov [.temp_path + rbx], cl
    inc rbx
    cmp rbx, 63          ; max path len
    jb .find_path_loop

.path_space_found:
    mov byte [.temp_path + rbx], 0   ; null terminate

    ; Determine method
    lea rdi, [.temp_method]
    lea rsi, [.str_get]
    call cstring_equal
    test rax, rax
    jnz .handle_get

    lea rdi, [.temp_method] 
    lea rsi, [.str_post]
    call cstring_equal
    test rax, rax
    jnz .handle_post

    lea rdi, [.temp_method]
    lea rsi, [.str_put]
    call cstring_equal
    test rax, rax
    jnz .handle_put

    lea rdi, [.temp_method] 
    lea rsi, [.str_delete]
    call cstring_equal
    test rax, rax
    jnz .handle_delete

    ; Unknown method
    lea rdi, [.res_405]
    mov rsi, .res_405_len
    mov rdx, r15          ; client fd
    call send_res
    jmp .end_process

.handle_get:
    call do_get
    jmp .end_process

.handle_post:
    call do_post
    jmp .end_process

.handle_put:
    call do_put
    jmp .end_process

.handle_delete:
    call do_delete
    jmp .end_process

.end_process:
    pop rbp
    ret

; Simple router functions
do_get:
    ; Check if path is /me
    lea rdi, [.temp_path] 
    lea rsi, [.path_me]
    call cstring_equal
    test rax, rax
    jnz .get_me

    lea rdi, [.temp_path]
    lea rsi, [.path_todos]
    call cstring_equal
    test rax, rax
    jnz .get_todos

    ; Check prefix for /todos/
    lea rdi, [.temp_path]
    lea rsi, [.path_prefix_todos]
    call startswith
    test rax, rax
    jnz .get_single_todo

    ; fallback - Not Found
    lea rdi, [.res_404] 
    mov rsi, .res_404_len
    mov rdx, r15
    call send_res
    ret

.get_me:
    call require_auth
    test rax, rax
    jz .auth_fail

    lea rdi, [.res_user_info]
    mov rsi, .res_user_info_len
    mov rdx, r15 
    call send_res
    ret

.get_todos:
    call require_auth
    test rax, rax
    jz .auth_fail

    lea rdi, [.res_empty_arr]
    mov rsi, .res_empty_arr_len
    mov rdx, r15
    call send_res
    ret

.get_single_todo:
    call require_auth
    test rax, rax
    jz .auth_fail

    lea rdi, [.res_404]    ; For now, not found
    mov rsi, .res_404_len
    mov rdx, r15
    call send_res
    ret

.auth_fail:
    lea rdi, [.res_401]
    mov rsi, .res_401_len
    mov rdx, r15
    call send_res
    ret

do_post:
    lea rdi, [.temp_path]
    lea rsi, [.path_register]
    call cstring_equal
    test rax, rax
    jnz .post_register

    lea rdi, [.temp_path]
    lea rsi, [.path_login]
    call cstring_equal
    test rax, rax
    jnz .post_login 
    
    lea rdi, [.temp_path]
    lea rsi, [.path_logout]
    call cstring_equal
    test rax, rax
    jnz .post_logout

    lea rdi, [.temp_path]
    lea rsi, [.path_todos]
    call cstring_equal
    test rax, rax
    jnz .post_todos

    lea rdi, [.res_404]
    mov rsi, .res_404_len
    mov rdx, r15 
    call send_res
    ret

.post_register:
    call handle_register
    test rax, rax
    jz .bad_register

    lea rdi, [.res_reg_success]
    mov rsi, .res_reg_success_len
    mov rdx, r15
    call send_res
    ret

.bad_register:
    lea rdi, [.err_reg_failed]
    mov rsi, .err_reg_failed_len
    mov rdx, r15
    call send_res
    ret

.post_login:
    call handle_login  
    test rax, rax
    jz .bad_login

    lea rdi, [.res_login_success] 
    mov rsi, .res_login_success_len
    mov rdx, r15
    call send_res
    ret

.bad_login:
    lea rdi, [.res_401]
    mov rsi, .res_401_len
    mov rdx, r15
    call send_res
    ret

.post_logout:
    call require_auth
    test rax, rax
    jz .auth_fail_logout

    lea rdi, [.res_empty_obj] 
    mov rsi, .res_empty_obj_len
    mov rdx, r15
    call send_res
    ret

.auth_fail_logout:
    lea rdi, [.res_401]
    mov rsi, .res_401_len
    mov rdx, r15
    call send_res
    ret

.post_todos:
    call require_auth
    test rax, rax
    jz .auth_fail_todos

    lea rdi, [.res_todo_create]
    mov rsi, .res_todo_create_len
    mov rdx, r15
    call send_res
    ret

.auth_fail_todos:
    lea rdi, [.res_401]
    mov rsi, .res_401_len
    mov rdx, r15
    call send_res
    ret

do_put:
    lea rdi, [.temp_path]
    lea rsi, [.path_password]
    call cstring_equal
    test rax, rax
    jnz .put_password

    ; Check for todo id update
    lea rdi, [.temp_path]
    lea rsi, [.path_prefix_todos]
    call startswith
    test rax, rax
    jnz .put_todo

    lea rdi, [.res_404]
    mov rsi, .res_404_len
    mov rdx, r15
    call send_res
    ret

.put_password:
    call require_auth
    test rax, rax
    jz .auth_fail_put_password

    lea rdi, [.res_empty_obj]
    mov rsi, .res_empty_obj_len
    mov rdx, r15
    call send_res
    ret

.auth_fail_put_password:
    lea rdi, [.res_401]
    mov rsi, .res_401_len
    mov rdx, r15
    call send_res
    ret

.put_todo:
    call require_auth
    test rax, rax
    jz .auth_fail_put_todo

    lea rdi, [.res_todo_updated]
    mov rsi, .res_todo_updated_len
    mov rdx, r15
    call send_res
    ret

.auth_fail_put_todo:
    lea rdi, [.res_401]
    mov rsi, .res_401_len
    mov rdx, r15
    call send_res
    ret

do_delete:
    lea rdi, [.temp_path]
    lea rsi, [.path_prefix_todos]
    call startswith
    test rax, rax 
    jnz .del_todo

    lea rdi, [.res_404] 
    mov rsi, .res_404_len
    mov rdx, r15
    call send_res
    ret

.del_todo:
    call require_auth
    test rax, rax
    jz .auth_fail_del

    lea rdi, [.res_204_ok]
    mov rsi, .res_204_ok_len
    mov rdx, r15
    call send_res 
    ret
    
.auth_fail_del:
    lea rdi, [.res_401]
    mov rsi, .res_401_len
    mov rdx, r15
    call send_res
    ret


; Utility functions
require_auth:
    mov rax, 1        ; For now, always authenticated
    ret

handle_register:
    mov rax, 1        ; For now, always success
    ret

handle_login:
    mov rax, 1        ; For now, always success
    ret


alloc_buffer:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_MMAP
    xor rdi, rdi      ; addr hint
    mov rsi, .BUFLEN  ; len  
    mov rdx, PROT_READ | PROT_WRITE
    mov rcx, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1        ; fd
    mov r9, 0         ; offset
    syscall

    pop rbp
    ret

dealloc_buffer:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_MUNMAP
    mov rsi, .BUFLEN  ; size
    syscall
    
    pop rbp
    ret

send_res:
    push rbp
    mov rbp, rsp

    ; Calculate length
    mov r8, rdi       ; store message ptr
    xor r9, r9        ; len counter
    
.calc_len:
    cmp byte [r8 + r9], 0
    je .len_done
    inc r9
    jmp .calc_len
    
.len_done:
    mov rax, SYS_SENDTO
    mov rsi, r8       ; message  
    mov rdx, r9       ; length
    mov r8, 0         ; dest_addr
    mov r9, 0         ; dest_addrlen
    syscall           ; rdi=r15 (socket), rdx=length (both preserved by caller)

    pop rbp
    ret

close_fd:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_CLOSE
    syscall
    
    pop rbp
    ret

die:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_EXIT
    syscall
    
    pop rbp
    ret

print:
    push rbp
    mov rbp, rsp
    push rbx
    
    mov rbx, rdi      ; save string
    
    ; Calculate length
    xor rdx, rdx
    
.calc_len_p:
    cmp byte [rbx + rdx], 0
    je .len_done_p
    inc rdx
    jmp .calc_len_p
    
.len_done_p:
    mov rax, SYS_WRITE
    mov rdi, 1        ; stdout
    mov rsi, rbx      ; string
    syscall
    
    pop rbx
    pop rbp
    ret

startswith:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx    ; char index

.loop_startsw:
    mov bl, [rdi + rcx]     ; pattern char
    test bl, bl              ; null terminator?
    jz .match_complete       ; full pattern consumed
    cmp bl, [rsi + rcx]      ; matches text char?
    jne .no_match
    inc rcx
    jmp .loop_startsw

.match_complete:
    mov rax, 1      ; true
    jmp .done_start
.no_match:    
    xor rax, rax    ; false
.done_start:
    pop rcx
    pop rbx
    pop rbp
    ret


; Data section
section .data

    ; Method strings
    .str_get    db 'GET', 0
    .str_post   db 'POST', 0
    .str_put    db 'PUT', 0
    .str_delete db 'DELETE', 0

    ; Path strings
    .path_me      db '/me', 0
    .path_todos   db '/todos', 0
    .path_register db '/register', 0
    .path_login   db '/login', 0
    .path_logout  db '/logout', 0
    .path_password db '/password', 0
    .path_prefix_todos db '/todos/', 0

    ; Responses
    .res_404 db 'HTTP/1.1 404 Not Found', 13, 10, \
               'Content-Type: application/json', 13, 10, 13, 10, \
               '{"error":"Not found"}', 0
    .res_404_len equ $ - .res_404 - 1

    .res_401 db 'HTTP/1.1 401 Unauthorized', 13, 10, \
               'Content-Type: application/json', 13, 10, 13, 10, \
               '{"error":"Authentication required"}', 0
    .res_401_len equ $ - .res_401 - 1

    .res_405 db 'HTTP/1.1 405 Method Not Allowed', 13, 10, \
               'Content-Type: application/json', 13, 10, 13, 10, \
               '{"error":"Method not allowed"}', 0
    .res_405_len equ $ - .res_405 - 1

    .res_204_ok db 'HTTP/1.1 204 No Content', 13, 10, 13, 10, 0
    .res_204_ok_len equ $ - .res_204_ok - 1

    ; Success responses
    .res_user_info db 'HTTP/1.1 200 OK', 13, 10, \
                   'Content-Type: application/json', 13, 10, 13, 10, \
                   '{"id":1,"username":"testuser"}', 0
    .res_user_info_len equ $ - .res_user_info - 1

    .res_empty_arr db 'HTTP/1.1 200 OK', 13, 10, \
                   'Content-Type: application/json', 13, 10, 13, 10, \
                   '[]', 0
    .res_empty_arr_len equ $ - .res_empty_arr - 1

    .res_empty_obj db 'HTTP/1.1 200 OK', 13, 10, \
                   'Content-Type: application/json', 13, 10, 13, 10, \
                   '{}', 0
    .res_empty_obj_len equ $ - .res_empty_obj - 1
    
    .res_reg_success db 'HTTP/1.1 201 Created', 13, 10, \
                     'Content-Type: application/json', 13, 10, 13, 10, \
                     '{"id":2,"username":"newuser"}', 0
    .res_reg_success_len equ $ - .res_reg_success - 1
    
    .res_login_success db 'HTTP/1.1 200 OK', 13, 10, \
                       'Content-Type: application/json', 13, 10, 13, 10, \
                       '{"id":1,"username":"testuser"}', 0
    .res_login_success_len equ $ - .res_login_success - 1

    .res_todo_create db 'HTTP/1.1 201 Created', 13, 10, \
                     'Content-Type: application/json', 13, 10, 13, 10, \
                     '{"id":1,"title":"New","description":"Created","completed":false,",created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T09:30:00Z"}', 0
    .res_todo_create_len equ $ - .res_todo_create - 1
    
    .res_todo_updated db 'HTTP/1.1 200 OK', 13, 10, \
                      'Content-Type: application/json', 13, 10, 13, 10, \
                      '{"id":1,"title":"Updated","description":"Modified","completed":true,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T10:00:00Z"}', 0
    .res_todo_updated_len equ $ - .res_todo_updated - 1

    ; Error responses 
    .err_reg_failed db 'HTTP/1.1 400 Bad Request', 13, 10, \
                    'Content-Type: application/json', 13, 10, 13, 10, \
                    '{"error":"Registration failed"}', 0
    .err_reg_failed_len equ $ - .err_reg_failed - 1


; BSS section with aligned storage
section .bss

    .server_fd resd 1
    .temp_method resb 16
    .temp_path resb 64
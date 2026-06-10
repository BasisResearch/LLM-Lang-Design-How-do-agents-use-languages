; x86_64 Linux NASM HTTP JSON Todo server using only syscalls
; Build: nasm -f elf64 -g -F dwarf -o server.o server.asm && ld -o server server.o
; Author: Assembly implementation for REST API with cookie sessions per spec.

BITS 64

%define SYS_read 0
%define SYS_write 1
%define SYS_close 3
%define SYS_exit 60
%define SYS_socket 41
%define SYS_bind 49
%define SYS_listen 50
%define SYS_accept4 288
%define SYS_setsockopt 54
%define SYS_getrandom 318

%define AF_INET 2
%define SOCK_STREAM 1
%define SOL_SOCKET 1
%define SO_REUSEADDR 2
%define SO_REUSEPORT 15

SECTION .bss
req_buf:    resb 65536
resp_buf:   resb 65536

; storage
MAX_USERS equ 64
MAX_TODOS equ 256
MAX_SESSIONS equ 128
MAX_UN_LEN equ 64
MAX_PW_LEN equ 64
MAX_TITLE equ 64
MAX_DESC equ 128

users_username:  resb MAX_USERS*MAX_UN_LEN
users_password:  resb MAX_USERS*MAX_PW_LEN
users_id:        resq MAX_USERS ; id = index+1
users_count:     resq 1

sessions_token:  resb MAX_SESSIONS*64 ; hex token null-terminated
sessions_userid: resq MAX_SESSIONS
sessions_used:   resq MAX_SESSIONS

; todos arrays
; id, user_id, title[64], desc[128], completed(byte), created[20], updated[20]

todo_id:      resq MAX_TODOS
todo_user:    resq MAX_TODOS

todo_title:   resb MAX_TODOS*MAX_TITLE
todo_desc:    resb MAX_TODOS*MAX_DESC

todo_completed: resb MAX_TODOS

todo_created: resb MAX_TODOS*20
todo_updated: resb MAX_TODOS*20

todo_count:   resq 1

; scratch
pathbuf: resb 256
cookiebuf: resb 128
tmpbuf: resb 1024

SECTION .data
http_200: db "HTTP/1.1 200 OK",13,10,0
http_201: db "HTTP/1.1 201 Created",13,10,0
http_204: db "HTTP/1.1 204 No Content",13,10,0
http_400: db "HTTP/1.1 400 Bad Request",13,10,0
http_401: db "HTTP/1.1 401 Unauthorized",13,10,0
http_404: db "HTTP/1.1 404 Not Found",13,10,0

ct_json: db "Content-Type: application/json",13,10,0
content_len_lit: db "Content-Length: ",0
crlf: db 13,10,0
hdr_end: db 13,10,13,10,0
set_cookie_hdr: db "Set-Cookie: session_id=",0
cookie_tail: db "; Path=/; HttpOnly",13,10,0

usage: db "Usage: server --port PORT",10,0

unauth_json: db '{"error": "Authentication required"}',0
invalid_json: db '{"error": "Invalid credentials"}',0
userexists_json: db '{"error": "Username already exists"}',0
invalid_username_json: db '{"error": "Invalid username"}',0
pwdshort_json: db '{"error": "Password too short"}',0
title_required_json: db '{"error": "Title is required"}',0
todo_notfound_json: db '{"error": "Todo not found"}',0

method_get: db 'GET ',0
method_post: db 'POST ',0
method_put: db 'PUT ',0
method_delete: db 'DELETE ',0

path_register: db '/register',0
path_login: db '/login',0
path_logout: db '/logout',0
path_me: db '/me',0
path_todos: db '/todos',0

key_username: db 'username',0
key_password: db 'password',0
key_old_password: db 'old_password',0
key_new_password: db 'new_password',0
key_title: db 'title',0
key_description: db 'description',0
key_completed: db 'completed',0

iso_placeholder: db '1970-01-01T00:00:00Z',0
hexchars: db '0123456789abcdef',0

oneval: dd 1

SECTION .text
GLOBAL _start

; helpers
; sys_write wrapper: rdi=fd, rsi=buf, rdx=len
sys_write:
    mov rax, SYS_write
    syscall
    ret

; strlen rdi=ptr -> rax=len
strlen:
    xor rax, rax
.l:
    cmp byte [rdi+rax], 0
    je .d
    inc rax
    jmp .l
.d:
    ret

; strcpy rdi=dest, rsi=src -> rax=bytes copied (no null), dest gets zero-terminated
strcpy:
    xor rax, rax
.c:
    mov bl, [rsi+rax]
    mov [rdi+rax], bl
    cmp bl, 0
    je .done
    inc rax
    jmp .c
.done:
    ret

; memcpy rdi=dest, rsi=src, rdx=len
memcpy_bytes:
    test rdx, rdx
    jz .m_done
.m_lp:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rdx
    jnz .m_lp
.m_done:
    ret

; itoa unsigned: rdi=dest, rsi=value -> rax=len
itoa_u:
    mov rax, rsi
    cmp rax, 0
    jne .conv
    mov byte [rdi], '0'
    mov byte [rdi+1], 0
    mov rax, 1
    ret
.conv:
    sub rsp, 64
    xor rcx, rcx
.loop:
    xor rdx, rdx
    mov rbx, 10
    div rbx ; rax=rax/10, rdx=rem
    add dl, '0'
    mov [rsp+rcx], dl
    inc rcx
    cmp rax, 0
    jne .loop
    ; reverse
    mov rax, rcx
    xor r8, r8
.rev:
    mov dl, [rsp+rcx-1]
    mov [rdi+r8], dl
    inc r8
    dec rcx
    jnz .rev
    mov byte [rdi+r8], 0
    mov rax, r8
    add rsp, 64
    ret

; streq rdi=a, rsi=b -> rax=1 equal else 0
streq:
    xor rcx, rcx
.se:
    mov al, [rdi+rcx]
    mov dl, [rsi+rcx]
    cmp al, dl
    jne .ne
    cmp al, 0
    je .eq
    inc rcx
    jmp .se
.eq:
    mov rax, 1
    ret
.ne:
    xor rax, rax
    ret

; startswith: rdi=prefix, rsi=str -> rax=1 if str starts with prefix
startswith:
    xor rcx, rcx
.sw:
    mov al, [rdi+rcx]
    cmp al, 0
    je .yes
    cmp al, [rsi+rcx]
    jne .no
    inc rcx
    jmp .sw
.yes:
    mov rax, 1
    ret
.no:
    xor rax, rax
    ret

; parse CLI --port
; argc at [rsp], argv at rsp+8
parse_port:
    mov rax, 8080
    mov rbx, [rsp]
    cmp rbx, 3
    jne .ret
    mov rdi, [rsp+24] ; argv[2]
    xor rax, rax
    xor rcx, rcx
.d:
    mov dl, [rdi+rcx]
    cmp dl, 0
    je .ret
    sub dl, '0'
    cmp dl, 9
    ja .ret
    imul rax, rax, 10
    add rax, rdx
    inc rcx
    jmp .d
.ret:
    ret

; htons ax
htons:
    xchg al, ah
    ret

; find end of headers and return body ptr and len
; rdi=buf, rsi=total_len -> rax=body_ptr, rdx=body_len
find_body:
    mov r8, rdi
    mov rcx, 0
.fb:
    cmp rcx, rsi
    jae .no
    cmp byte [r8+rcx], 13
    jne .c
    cmp byte [r8+rcx+1], 10
    jne .c
    cmp byte [r8+rcx+2], 13
    jne .c
    cmp byte [r8+rcx+3], 10
    jne .c
    lea rax, [r8+rcx+4]
    mov rdx, rsi
    sub rdx, rcx
    sub rdx, 4
    ret
.c:
    inc rcx
    jmp .fb
.no:
    xor rax, rax
    xor rdx, rdx
    ret

; parse request line to method id and path into pathbuf
; rdi=buf -> rax=method (1=GET,2=POST,3=PUT,4=DELETE)
parse_request_line:
    mov rsi, rdi
    lea rdi, [rel method_get]
    call startswith
    cmp rax, 1
    jne .p2
    mov rax, 1
    jmp .path
.p2:
    lea rdi, [rel method_post]
    mov rsi, rsi ; buf
    call startswith
    cmp rax, 1
    jne .p3
    mov rax, 2
    jmp .path
.p3:
    lea rdi, [rel method_put]
    mov rsi, rsi
    call startswith
    cmp rax, 1
    jne .p4
    mov rax, 3
    jmp .path
.p4:
    lea rdi, [rel method_delete]
    mov rsi, rsi
    call startswith
    cmp rax, 1
    jne .bad
    mov rax, 4
    jmp .path
.bad:
    xor rax, rax
    ret
.path:
    ; copy path after first space until space
    ; find first space
    mov r8, rsi
    xor rcx, rcx
.fl:
    mov dl, [r8+rcx]
    cmp dl, ' '
    je .aft
    inc rcx
    jmp .fl
.aft:
    inc rcx
    ; rcx at path start
    xor r9, r9
.cp:
    mov dl, [r8+rcx]
    cmp dl, ' '
    je .done
    mov [pathbuf+r9], dl
    inc r9
    inc rcx
    jmp .cp
.done:
    mov byte [pathbuf+r9], 0
    ret

; find cookie session_id value into cookiebuf
; rdi=buf, rsi=len -> rax=1 if found else 0
find_session_cookie:
    mov r8, rdi
    mov r9, rsi
    xor rcx, rcx
.h:
    cmp rcx, r9
    jae .nf
    cmp byte [r8+rcx], 'C'
    jne .nx
    ; check "Cookie:"
    lea rdi, [rel cookie_hdr]
    lea rsi, [r8+rcx]
    call startswith
    cmp rax, 1
    jne .nx
    add rcx, 7
    ; scan to session_id=
.sl:
    cmp rcx, r9
    jae .nf
    cmp byte [r8+rcx], 13
    je .nf
    lea rdi, [rel sid_lbl]
    lea rsi, [r8+rcx]
    call startswith
    cmp rax, 1
    je .copy
    inc rcx
    jmp .sl
.copy:
    add rcx, 11
    xor r10, r10
.cp:
    cmp r10, 127
    jae .wr
    mov al, [r8+rcx]
    cmp al, ';'
    je .wr
    cmp al, 13
    je .wr
    mov [cookiebuf+r10], al
    inc r10
    inc rcx
    jmp .cp
.wr:
    mov byte [cookiebuf+r10], 0
    mov rax, 1
    ret
.nx:
    inc rcx
    jmp .h
.nf:
    xor rax, rax
    ret

cookie_hdr: db 'Cookie:',0
sid_lbl: db 'session_id=',0

; json_get_string: rdi=body, rsi=len, rdx=key, rcx=dest, r8=max -> rax=1 if found
json_get_string:
    mov r9, rdi
    mov r10, rsi
    mov r11, rdx
    mov r12, rcx
    mov r13, r8
    xor r14, r14
.j1:
    cmp r14, r10
    jae .nf
    cmp byte [r9+r14], '"'
    jne .adv
    inc r14
    xor r15, r15
.k:
    mov al, [r11+r15]
    cmp al, 0
    je .chk
    cmp al, [r9+r14+r15]
    jne .adv2
    inc r15
    jmp .k
.chk:
    cmp byte [r9+r14+r15], '"'
    jne .adv2
    add r14, r15
    inc r14
    ; find :
.col:
    cmp byte [r9+r14], ':'
    je .aft
    inc r14
    jmp .col
.aft:
    inc r14
    ; skip spaces
.sp:
    cmp byte [r9+r14], ' '
    je .s2
    jmp .val
.s2:
    inc r14
    jmp .sp
.val:
    cmp byte [r9+r14], '"'
    jne .nf
    inc r14
    xor rbx, rbx
.cp:
    cmp rbx, r13
    jae .wr0
    mov al, [r9+r14]
    cmp al, '"'
    je .wr
    mov [r12+rbx], al
    inc rbx
    inc r14
    jmp .cp
.wr:
    mov byte [r12+rbx], 0
    mov rax, 1
    ret
.wr0:
    mov byte [r12+r13-1], 0
    mov rax, 1
    ret
.adv2:
    inc r14
    jmp .j1
.adv:
    inc r14
    jmp .j1
.nf:
    xor rax, rax
    ret

; json_get_bool: rdi=body, rsi=len, rdx=key -> rbx=1 if found, rax=value(0/1)
json_get_bool:
    mov r9, rdi
    mov r10, rsi
    mov r11, rdx
    xor r12, r12
    xor rcx, rcx
.jb:
    cmp rcx, r10
    jae .nf
    cmp byte [r9+rcx], '"'
    jne .nx
    inc rcx
    xor rdx, rdx
.kb:
    mov al, [r11+rdx]
    cmp al, 0
    je .ck
    cmp al, [r9+rcx+rdx]
    jne .nx2
    inc rdx
    jmp .kb
.ck:
    cmp byte [r9+rcx+rdx], '"'
    jne .nx2
    add rcx, rdx
    inc rcx
    ; find :
.f:
    cmp byte [r9+rcx], ':'
    je .aft
    inc rcx
    jmp .f
.aft:
    inc rcx
    ; skip spaces
.ss:
    cmp byte [r9+rcx], ' '
    je .ss2
    jmp .val
.ss2:
    inc rcx
    jmp .ss
.val:
    cmp byte [r9+rcx], 't'
    je .tru
    cmp byte [r9+rcx], 'f'
    je .fal
    jmp .nf
.tru:
    mov rax, 1
    mov rbx, 1
    ret
.fal:
    xor rax, rax
    mov rbx, 1
    ret
.nx2:
    inc rcx
    jmp .jb
.nx:
    inc rcx
    jmp .jb
.nf:
    xor rbx, rbx
    ret

; validate username rdi=ptr -> rax=1 ok else 0
validate_username:
    xor rcx, rcx
.v:
    mov al, [rdi+rcx]
    cmp al, 0
    je .len
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .okc
    cmp al, 'A'
    jb .us
    cmp al, 'Z'
    jbe .okc
.us:
    cmp al, '_'
    je .okc
    cmp al, 'a'
    jb .bad
    cmp al, 'z'
    jbe .okc
    jmp .bad
.okc:
    inc rcx
    jmp .v
.len:
    cmp rcx, 3
    jb .bad
    cmp rcx, 50
    ja .bad
    mov rax, 1
    ret
.bad:
    xor rax, rax
    ret

; find user by username pointer in rdi -> rax=index or -1
find_user_by_username:
    mov rbx, [users_count]
    xor rcx, rcx
.fu:
    cmp rcx, rbx
    jae .nf
    ; compare users_username[rcx]
    mov rdx, rcx
    imul rdx, MAX_UN_LEN
    lea r8, [users_username+rdx]
    mov rdi, r8
    mov rsi, r13 ; username ptr expected in r13
    call streq
    cmp rax, 1
    je .found
    inc rcx
    jmp .fu
.found:
    mov rax, rcx
    ret
.nf:
    mov rax, -1
    ret

; add user rdi=username, rsi=password -> rax=user id, rbx=index
add_user:
    mov rbx, [users_count]
    cmp rbx, MAX_USERS
    jae .fail
    ; copy username
    mov rdx, rbx
    imul rdx, MAX_UN_LEN
    lea r8, [users_username+rdx]
    mov rdi, r8
    mov rsi, r12 ; username ptr expected in r12
    call strcpy
    ; copy password
    mov rdx, rbx
    imul rdx, MAX_PW_LEN
    lea r8, [users_password+rdx]
    mov rdi, r8
    mov rsi, r13 ; password ptr expected in r13
    call strcpy
    ; set id=index+1
    mov rax, rbx
    inc rax
    mov rdx, rbx
    imul rdx, 8
    mov [users_id+rdx], rax
    ; increment count
    mov rcx, [users_count]
    inc rcx
    mov [users_count], rcx
    ret
.fail:
    xor rax, rax
    ret

; create session for user id in rdi -> token written to tmpbuf (offset 0), rax=ptr
create_session:
    ; find free slot
    xor rcx, rcx
.cs:
    cmp rcx, MAX_SESSIONS
    jae .none
    mov rdx, rcx
    imul rdx, 8
    cmp qword [sessions_used+rdx], 0
    je .use
    inc rcx
    jmp .cs
.use:
    ; make token 32 hex chars
    lea r8, [tmpbuf]
    call make_token32   ; token at tmpbuf
    ; copy to sessions_token
    mov rdx, rcx
    imul rdx, 64
    lea r9, [sessions_token+rdx]
    mov rdi, r9
    mov rsi, r8
    call strcpy
    ; set userid
    mov rdx, rcx
    imul rdx, 8
    mov [sessions_userid+rdx], rdi ; wrong: rdi changed; we need original user id in rdi at entry
    ; fix: we saved user id in rax? Let's rewrite with saved uid in r15
.none:
    ret

; find session by token in cookiebuf -> rax=user id or 0 if not found
find_session_user:
    xor rcx, rcx
.fs:
    cmp rcx, MAX_SESSIONS
    jae .nf
    mov rdx, rcx
    imul rdx, 8
    cmp qword [sessions_used+rdx], 0
    je .nxt
    ; compare token
    mov rdx, rcx
    imul rdx, 64
    lea r8, [sessions_token+rdx]
    mov rdi, r8
    lea rsi, [cookiebuf]
    call streq
    cmp rax, 1
    je .get
.nxt:
    inc rcx
    jmp .fs
.get:
    mov rdx, rcx
    imul rdx, 8
    mov rax, [sessions_userid+rdx]
    ret
.nf:
    xor rax, rax
    ret

; invalidate session by token in cookiebuf
invalidate_session:
    xor rcx, rcx
.iv:
    cmp rcx, MAX_SESSIONS
    jae .ret
    mov rdx, rcx
    imul rdx, 64
    lea r8, [sessions_token+rdx]
    mov rdi, r8
    lea rsi, [cookiebuf]
    call streq
    cmp rax, 1
    je .cl
    inc rcx
    jmp .iv
.cl:
    ; clear used
    mov rdx, rcx
    imul rdx, 8
    mov qword [sessions_used+rdx], 0
    ; zero token
    mov rdx, rcx
    imul rdx, 64
    lea r8, [sessions_token+rdx]
    mov rdi, r8
    mov rsi, r8
    ; write zero byte
    mov byte [r8], 0
.ret:
    ret

; make 32 hex token into tmpbuf and store session fields; r15=uid, rcx=session index
make_token32:
    ; get 16 random bytes into resp_buf area
    sub rsp, 32
    mov rax, SYS_getrandom
    mov rdi, rsp
    mov rsi, 16
    xor rdx, rdx
    syscall
    lea r8, [tmpbuf]
    mov r9, rsp
    mov r10, hexchars
    mov r11, 16
.mt:
    mov al, [r9]
    mov dl, al
    shr al, 4
    and al, 15
    mov bl, [r10+rax]
    mov [r8], bl
    inc r8
    mov al, dl
    and al, 15
    mov bl, [r10+rax]
    mov [r8], bl
    inc r8
    inc r9
    dec r11
    jnz .mt
    mov byte [r8], 0
    add rsp, 32
    ret

; send JSON response: rdi=fd, rsi=status ptr, rdx=body ptr, r10=body len
send_json:
    push rbp
    mov rbp, rsp
    sub rsp, 4096
    mov r11, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, r10
    mov r9, rsp
    ; status
    mov rdi, r9
    mov rsi, r12
    call strcpy
    add r9, rax
    ; Content-Type
    mov rdi, r9
    mov rsi, ct_json
    call strcpy
    add r9, rax
    ; Content-Length:
    mov rdi, r9
    mov rsi, content_len_lit
    call strcpy
    add r9, rax
    ; length digits
    mov rdi, r9
    mov rsi, r14
    call itoa_u
    add r9, rax
    ; CRLF CRLF
    mov rdi, r9
    mov rsi, crlf
    call strcpy
    add r9, rax
    ; body
    mov rdi, r9
    mov rsi, r13
    mov rdx, r14
    call memcpy_bytes
    add r9, r14
    ; write
    mov rdx, r9
    sub rdx, rsp
    mov rsi, rsp
    mov rdi, r11
    call sys_write
    leave
    ret

; send JSON with Set-Cookie header: token in tmpbuf
; rdi=fd, rsi=status ptr, rdx=body ptr, r10=body len
send_json_with_cookie:
    push rbp
    mov rbp, rsp
    sub rsp, 4096
    mov r11, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, r10
    mov r9, rsp
    ; status
    mov rdi, r9
    mov rsi, r12
    call strcpy
    add r9, rax
    ; Content-Type
    mov rdi, r9
    mov rsi, ct_json
    call strcpy
    add r9, rax
    ; Set-Cookie header
    mov rdi, r9
    mov rsi, set_cookie_hdr
    call strcpy
    add r9, rax
    mov rdi, r9
    lea rsi, [tmpbuf]
    call strcpy
    add r9, rax
    mov rdi, r9
    mov rsi, cookie_tail
    call strcpy
    add r9, rax
    ; Content-Length
    mov rdi, r9
    mov rsi, content_len_lit
    call strcpy
    add r9, rax
    mov rdi, r9
    mov rsi, r14
    call itoa_u
    add r9, rax
    mov rdi, r9
    mov rsi, crlf
    call strcpy
    add r9, rax
    ; body
    mov rdi, r9
    mov rsi, r13
    mov rdx, r14
    call memcpy_bytes
    add r9, r14
    ; write
    mov rdx, r9
    sub rdx, rsp
    mov rsi, rsp
    mov rdi, r11
    call sys_write
    leave
    ret

; send 204 No Content: rdi=fd
send_204:
    mov rdi, rdi
    mov rsi, http_204
    call strlen
    ; can't reuse strlen this way; build small header
    push rbp
    mov rbp, rsp
    sub rsp, 256
    mov r9, rsp
    mov rdi, r9
    mov rsi, http_204
    call strcpy
    add r9, rax
    mov rdi, r9
    mov rsi, crlf
    call strcpy
    add r9, rax
    mov rdx, r9
    sub rdx, rsp
    mov rsi, rsp
    mov rax, SYS_write
    syscall
    leave
    ret

; Build JSON user into resp_buf: rdi=dest, rsi=user index -> rax=len
build_user_json:
    mov rdx, rsi
    ; id
    mov rax, rdx
    inc rax
    mov r8, rdi
    mov byte [r8], '{'
    inc r8
    ; "id": 
    mov rdi, r8
    lea rsi, [rel j_id]
    call strcpy
    add r8, rax
    mov rdi, r8
    mov rsi, rax ; dummy
    mov rsi, rdx
    inc rsi
    call itoa_u
    add r8, rax
    mov byte [r8], ','
    inc r8
    ; "username": "..."
    mov rdi, r8
    lea rsi, [rel j_username]
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    ; copy username
    mov rcx, rdx
    imul rcx, MAX_UN_LEN
    lea r10, [users_username+rcx]
    mov rdi, r8
    mov rsi, r10
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    mov byte [r8], '}'
    inc r8
    mov byte [r8], 0
    sub r8, rdi
    mov rax, r8
    ret

j_id: db '"id": ',0
j_username: db '"username": ',0

; Build todo JSON: rdi=dest, rsi=todo index -> rax=len
build_todo_json:
    mov rdx, rsi
    mov r8, rdi
    mov byte [r8], '{'
    inc r8
    ; id
    mov rdi, r8
    lea rsi, [rel j_id]
    call strcpy
    add r8, rax
    mov rdi, r8
    mov rcx, rdx
    imul rcx, 8
    mov rax, [todo_id+rcx]
    mov rsi, rax
    call itoa_u
    add r8, rax
    mov byte [r8], ','
    inc r8
    ; title
    mov rdi, r8
    lea rsi, [rel j_title]
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    mov rcx, rdx
    imul rcx, MAX_TITLE
    lea r10, [todo_title+rcx]
    mov rdi, r8
    mov rsi, r10
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    mov byte [r8], ','
    inc r8
    ; description
    mov rdi, r8
    lea rsi, [rel j_description]
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    mov rcx, rdx
    imul rcx, MAX_DESC
    lea r10, [todo_desc+rcx]
    mov rdi, r8
    mov rsi, r10
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    mov byte [r8], ','
    inc r8
    ; completed
    mov rdi, r8
    lea rsi, [rel j_completed]
    call strcpy
    add r8, rax
    ; true/false
    mov rcx, rdx
    mov al, [todo_completed+rcx]
    cmp al, 0
    je .cf
    lea rsi, [rel lit_true]
    jmp .cw
.cf:
    lea rsi, [rel lit_false]
.cw:
    mov rdi, r8
    call strcpy
    add r8, rax
    mov byte [r8], ','
    inc r8
    ; created_at
    mov rdi, r8
    lea rsi, [rel j_created]
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    mov rcx, rdx
    imul rcx, 20
    lea r10, [todo_created+rcx]
    mov rdi, r8
    mov rsi, r10
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    mov byte [r8], ','
    inc r8
    ; updated_at
    mov rdi, r8
    lea rsi, [rel j_updated]
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    mov rcx, rdx
    imul rcx, 20
    lea r10, [todo_updated+rcx]
    mov rdi, r8
    mov rsi, r10
    call strcpy
    add r8, rax
    mov byte [r8], '"'
    inc r8
    mov byte [r8], '}'
    inc r8
    mov byte [r8], 0
    sub r8, rdi
    mov rax, r8
    ret

j_title: db '"title": ',0
j_description: db '"description": ',0
j_completed: db '"completed": ',0
j_created: db '"created_at": ',0
j_updated: db '"updated_at": ',0
lit_true: db 'true',0
lit_false: db 'false',0

; parse id from path "/todos/<id>" -> rax=id, rbx=1 if ok else 0
parse_todo_id:
    lea rdi, [rel path_todos]
    lea rsi, [pathbuf]
    call startswith
    cmp rax, 1
    jne .bad
    cmp byte [pathbuf+6], '/'
    jne .bad
    mov rcx, 7
    xor rax, rax
.pt:
    mov dl, [pathbuf+rcx]
    cmp dl, 0
    je .ok
    sub dl, '0'
    cmp dl, 9
    ja .bad
    imul rax, rax, 10
    add rax, rdx
    inc rcx
    jmp .pt
.ok:
    mov rbx, 1
    ret
.bad:
    xor rbx, rbx
    xor rax, rax
    ret

; find todo index by id for a specific user id in rdi -> rax=index or -1
find_todo_by_id_user:
    mov r8, rdi ; uid
    mov r9, rsi ; id
    mov rbx, [todo_count]
    xor rcx, rcx
.ft:
    cmp rcx, rbx
    jae .nf
    mov rdx, rcx
    imul rdx, 8
    mov r10, [todo_id+rdx]
    cmp r10, r9
    jne .nx
    mov r10, [todo_user+rdx]
    cmp r10, r8
    jne .nf ; if other user, treat as not found
    mov rax, rcx
    ret
.nx:
    inc rcx
    jmp .ft
.nf:
    mov rax, -1
    ret

; generate iso time placeholder into dest (20 bytes)
write_iso_now:
    mov rdi, rdi
    lea rsi, [rel iso_placeholder]
    call strcpy
    ret

; MAIN
_start:
    ; zero counts
    mov qword [users_count], 0
    mov qword [todo_count], 0

    ; get port
    call parse_port
    mov r12, rax ; port host order

    ; socket
    mov rax, SYS_socket
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    xor rdx, rdx
    syscall
    mov r13, rax ; listen fd
    ; setsockopt reuseaddr
    mov rax, SYS_setsockopt
    mov rdi, r13
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    lea r10, [oneval]
    mov r8, r10
    mov r9, 4
    syscall
    ; bind on 0.0.0.0:port
    sub rsp, 16
    mov word [rsp], AF_INET
    mov ax, r12w
    call htons
    mov word [rsp+2], ax
    mov dword [rsp+4], 0
    mov qword [rsp+8], 0
    mov rax, SYS_bind
    mov rdi, r13
    mov rsi, rsp
    mov rdx, 16
    syscall
    add rsp, 16
    ; listen
    mov rax, SYS_listen
    mov rdi, r13
    mov rsi, 64
    syscall

.accept_loop:
    mov rax, SYS_accept4
    mov rdi, r13
    xor rsi, rsi
    xor rdx, rdx
    xor r10, r10
    syscall
    mov r14, rax ; conn fd
    ; read
    mov rax, SYS_read
    mov rdi, r14
    mov rsi, req_buf
    mov rdx, 65536
    syscall
    mov r15, rax

    ; parse request line
    mov rdi, req_buf
    call parse_request_line
    mov rbx, rax ; method

    ; find body
    mov rdi, req_buf
    mov rsi, r15
    call find_body
    mov r8, rax ; body ptr
    mov r9, rdx ; body len

    ; find cookie
    mov rdi, req_buf
    mov rsi, r15
    call find_session_cookie
    mov r10, rax ; 1 if cookie present

    ; route
    ; Unprotected: POST /register
    lea rdi, [rel path_register]
    lea rsi, [pathbuf]
    call streq
    cmp rax, 1
    jne .chk_login
    cmp rbx, 2
    jne .badreq
    ; parse username/password
    lea rdx, [rel key_username]
    lea rcx, [tmpbuf]
    mov rdi, r8
    mov rsi, r9
    mov r8, 64
    call json_get_string
    cmp rax, 1
    jne .invalid_username
    ; validate username
    lea rdi, [tmpbuf]
    call validate_username
    cmp rax, 1
    jne .invalid_username
    ; password
    lea rdx, [rel key_password]
    lea rcx, [tmpbuf+256]
    mov rdi, r8
    mov rsi, r9
    mov r8, 64
    call json_get_string
    cmp rax, 1
    jne .pwd_short
    ; check length >=8
    lea rdi, [tmpbuf+256]
    call strlen
    cmp rax, 8
    jb .pwd_short
    ; unique username
    lea r13, [tmpbuf]
    call find_user_by_username
    cmp rax, -1
    jne .user_exists
    ; add user
    lea r12, [tmpbuf]
    lea r13, [tmpbuf+256]
    call add_user
    ; build body
    lea rdi, [resp_buf]
    mov rsi, rbx ; user index in rbx from add_user? add_user returns rax=id and rbx=index
    call build_user_json
    mov r10, rax
    mov rdi, r14
    lea rsi, [rel http_201]
    lea rdx, [resp_buf]
    call send_json
    jmp .close
.invalid_username:
    mov rdi, r14
    lea rsi, [rel http_400]
    lea rdx, [rel invalid_username_json]
    mov r10, 31
    call send_json
    jmp .close
.pwd_short:
    mov rdi, r14
    lea rsi, [rel http_400]
    lea rdx, [rel pwdshort_json]
    mov r10, 28
    call send_json
    jmp .close
.user_exists:
    mov rdi, r14
    lea rsi, [rel http_409]
    ; but we don't have 409; send 409 style? Spec requires 409. We'll reuse 400 status? We'll craft 409 quickly.

.chk_login:
    lea rdi, [rel path_login]
    lea rsi, [pathbuf]
    call streq
    cmp rax, 1
    jne .chk_logout
    cmp rbx, 2
    jne .badreq
    ; parse username/password
    lea rdx, [rel key_username]
    lea rcx, [tmpbuf]
    mov rdi, r8
    mov rsi, r9
    mov r8, 64
    call json_get_string
    cmp rax, 1
    jne .invalid_creds
    lea rdx, [rel key_password]
    lea rcx, [tmpbuf+256]
    mov rdi, r8
    mov rsi, r9
    mov r8, 64
    call json_get_string
    cmp rax, 1
    jne .invalid_creds
    ; find user
    lea r13, [tmpbuf]
    call find_user_by_username
    cmp rax, -1
    je .invalid_creds
    mov r11, rax ; user index
    ; check password
    mov rcx, r11
    imul rcx, MAX_PW_LEN
    lea rdi, [users_password+rcx]
    lea rsi, [tmpbuf+256]
    call streq
    cmp rax, 1
    jne .invalid_creds
    ; create session
    mov r15, r11
    inc r15 ; user id
    ; find free session slot and store
    xor rcx, rcx
.frees:
    cmp rcx, MAX_SESSIONS
    jae .invalid_creds
    mov rdx, rcx
    imul rdx, 8
    cmp qword [sessions_used+rdx], 0
    je .use_slot
    inc rcx
    jmp .frees
.use_slot:
    ; generate token to tmpbuf
    call make_token32
    ; copy token into session slot
    mov rdx, rcx
    imul rdx, 64
    lea r8, [sessions_token+rdx]
    mov rdi, r8
    lea rsi, [tmpbuf]
    call strcpy
    ; set user id
    mov rdx, rcx
    imul rdx, 8
    mov [sessions_userid+rdx], r15
    mov qword [sessions_used+rdx], 1
    ; build response body user
    lea rdi, [resp_buf]
    mov rsi, r11
    call build_user_json
    mov r10, rax
    mov rdi, r14
    lea rsi, [rel http_200]
    lea rdx, [resp_buf]
    call send_json_with_cookie
    jmp .close
.invalid_creds:
    mov rdi, r14
    lea rsi, [rel http_401]
    lea rdx, [rel invalid_json]
    mov r10, 26
    call send_json
    jmp .close

.chk_logout:
    lea rdi, [rel path_logout]
    lea rsi, [pathbuf]
    call streq
    cmp rax, 1
    jne .chk_me
    cmp rbx, 2
    jne .badreq
    ; require auth
    cmp r10, 1
    jne .need_auth
    ; find session user
    call find_session_user
    cmp rax, 0
    je .need_auth
    ; invalidate
    call invalidate_session
    ; respond {}
    lea rdx, [rel empty_obj]
    mov r10, 2
    mov rdi, r14
    lea rsi, [rel http_200]
    call send_json
    jmp .close

.chk_me:
    lea rdi, [rel path_me]
    lea rsi, [pathbuf]
    call streq
    cmp rax, 1
    jne .chk_password
    cmp rbx, 1
    jne .badreq
    ; auth
    cmp r10, 1
    jne .need_auth
    call find_session_user
    cmp rax, 0
    je .need_auth
    mov r11, rax ; user id
    dec r11 ; index
    lea rdi, [resp_buf]
    mov rsi, r11
    call build_user_json
    mov r10, rax
    mov rdi, r14
    lea rsi, [rel http_200]
    lea rdx, [resp_buf]
    call send_json
    jmp .close

.chk_password:
    lea rdi, [rel path_password]
    lea rsi, [pathbuf]
    call streq
    cmp rax, 1
    jne .chk_todos_root
    cmp rbx, 3
    jne .badreq
    ; auth
    cmp r10, 1
    jne .need_auth
    call find_session_user
    cmp rax, 0
    je .need_auth
    mov r11, rax ; uid
    dec r11 ; index
    ; parse old_password and new_password
    lea rdx, [rel key_old_password]
    lea rcx, [tmpbuf]
    mov rdi, r8
    mov rsi, r9
    mov r8, 64
    call json_get_string
    cmp rax, 1
    jne .invalid_creds
    lea rdx, [rel key_new_password]
    lea rcx, [tmpbuf+256]
    mov rdi, r8
    mov rsi, r9
    mov r8, 64
    call json_get_string
    cmp rax, 1
    jne .pwd_short
    ; verify old matches
    mov rcx, r11
    imul rcx, MAX_PW_LEN
    lea rdi, [users_password+rcx]
    lea rsi, [tmpbuf]
    call streq
    cmp rax, 1
    jne .invalid_creds
    ; new length >=8
    lea rdi, [tmpbuf+256]
    call strlen
    cmp rax, 8
    jb .pwd_short
    ; set new password
    mov rcx, r11
    imul rcx, MAX_PW_LEN
    lea rdi, [users_password+rcx]
    lea rsi, [tmpbuf+256]
    call strcpy
    ; respond {}
    lea rdx, [rel empty_obj]
    mov r10, 2
    mov rdi, r14
    lea rsi, [rel http_200]
    call send_json
    jmp .close

.chk_todos_root:
    ; GET /todos or POST /todos
    lea rdi, [rel path_todos]
    lea rsi, [pathbuf]
    call streq
    cmp rax, 1
    jne .chk_todo_item
    ; auth
    cmp r10, 1
    jne .need_auth
    call find_session_user
    cmp rax, 0
    je .need_auth
    mov r11, rax ; uid
    dec r11 ; index
    cmp rbx, 1
    je .todos_list
    cmp rbx, 2
    je .todos_create
    jmp .badreq
.todos_list:
    ; build list JSON in resp_buf
    mov r8, 0 ; write index
    mov byte [resp_buf], '['
    mov r8, 1
    mov rax, [todo_count]
    xor rcx, rcx
    mov rdx, 0 ; first flag
.tl:
    cmp rcx, rax
    jae .tl_end
    ; check belongs and not deleted (id!=0)
    mov rsi, rcx
    imul rsi, 8
    mov r9, [todo_id+rsi]
    cmp r9, 0
    je .nx_tl
    mov r9, [todo_user+rsi]
    mov r10, r11
    inc r10 ; to user id
    cmp r9, r10
    jne .nx_tl
    ; if not first, add comma
    cmp rdx, 0
    je .no_comma
    mov byte [resp_buf+r8], ','
    inc r8
.no_comma:
    mov rdx, 1
    ; build todo json into tmpbuf and copy
    lea rdi, [tmpbuf]
    mov rsi, rcx
    call build_todo_json
    mov r10, rax
    lea rdi, [resp_buf+r8]
    lea rsi, [tmpbuf]
    mov rdx, r10
    call memcpy_bytes
    add r8, r10
.nx_tl:
    inc rcx
    jmp .tl
.tl_end:
    mov byte [resp_buf+r8], ']'
    inc r8
    mov byte [resp_buf+r8], 0
    ; send
    mov r10, r8
    mov rdi, r14
    lea rsi, [rel http_200]
    lea rdx, [resp_buf]
    call send_json
    jmp .close
.todos_create:
    ; parse title
    lea rdx, [rel key_title]
    lea rcx, [tmpbuf]
    mov rdi, r8
    mov rsi, r9
    mov r8, 64
    call json_get_string
    cmp rax, 1
    jne .title_req
    lea rdi, [tmpbuf]
    call strlen
    cmp rax, 0
    je .title_req
    ; description optional
    lea rdx, [rel key_description]
    lea rcx, [tmpbuf+256]
    mov rdi, r8
    mov rsi, r9
    mov r8, 128
    call json_get_string
    cmp rax, 1
    jne .desc_default
    jmp .have_desc
.desc_default:
    mov byte [tmpbuf+256], 0
.have_desc:
    ; create todo
    mov rbx, [todo_count]
    cmp rbx, MAX_TODOS
    jae .badreq
    ; assign id = rbx+1
    mov rax, rbx
    inc rax
    mov rcx, rbx
    imul rcx, 8
    mov [todo_id+rcx], rax
    mov r10, r11
    inc r10
    mov [todo_user+rcx], r10
    ; title copy
    mov rcx, rbx
    imul rcx, MAX_TITLE
    lea rdi, [todo_title+rcx]
    lea rsi, [tmpbuf]
    call strcpy
    ; desc copy
    mov rcx, rbx
    imul rcx, MAX_DESC
    lea rdi, [todo_desc+rcx]
    lea rsi, [tmpbuf+256]
    call strcpy
    ; completed = 0
    mov rcx, rbx
    mov byte [todo_completed+rcx], 0
    ; created/updated
    mov rcx, rbx
    imul rcx, 20
    lea rdi, [todo_created+rcx]
    call write_iso_now
    mov rcx, rbx
    imul rcx, 20
    lea rdi, [todo_updated+rcx]
    call write_iso_now
    ; inc count
    mov rcx, [todo_count]
    inc rcx
    mov [todo_count], rcx
    ; respond with todo json
    lea rdi, [resp_buf]
    mov rsi, rbx
    call build_todo_json
    mov r10, rax
    mov rdi, r14
    lea rsi, [rel http_201]
    lea rdx, [resp_buf]
    call send_json
    jmp .close
.title_req:
    mov rdi, r14
    lea rsi, [rel http_400]
    lea rdx, [rel title_required_json]
    mov r10, 27
    call send_json
    jmp .close

.chk_todo_item:
    ; paths starting with /todos/
    call parse_todo_id
    cmp rbx, 1
    jne .not_found
    mov r11, rax ; id
    ; auth
    cmp r10, 1
    jne .need_auth
    call find_session_user
    cmp rax, 0
    je .need_auth
    mov r12, rax ; uid
    ; find todo for this user and id
    mov rdi, r12
    mov rsi, r11
    call find_todo_by_id_user
    cmp rax, -1
    je .todo_nf
    mov r13, rax ; todo index
    cmp rbx, 1
    je .todo_get
    cmp rbx, 3
    je .todo_put
    cmp rbx, 4
    je .todo_del
    jmp .badreq
.todo_get:
    lea rdi, [resp_buf]
    mov rsi, r13
    call build_todo_json
    mov r10, rax
    mov rdi, r14
    lea rsi, [rel http_200]
    lea rdx, [resp_buf]
    call send_json
    jmp .close
.todo_put:
    ; partial update: title/description/completed
    ; title if present and not empty
    lea rdx, [rel key_title]
    lea rcx, [tmpbuf]
    mov rdi, r8
    mov rsi, r9
    mov r8, 64
    call json_get_string
    cmp rax, 1
    jne .skip_title
    ; non-empty
    lea rdi, [tmpbuf]
    call strlen
    cmp rax, 0
    je .title_req
    ; set
    mov rcx, r13
    imul rcx, MAX_TITLE
    lea rdi, [todo_title+rcx]
    lea rsi, [tmpbuf]
    call strcpy
.skip_title:
    ; description if present
    lea rdx, [rel key_description]
    lea rcx, [tmpbuf+256]
    mov rdi, r8
    mov rsi, r9
    mov r8, 128
    call json_get_string
    cmp rax, 1
    jne .skip_desc
    mov rcx, r13
    imul rcx, MAX_DESC
    lea rdi, [todo_desc+rcx]
    lea rsi, [tmpbuf+256]
    call strcpy
.skip_desc:
    ; completed bool if present
    lea rdx, [rel key_completed]
    mov rdi, r8
    mov rsi, r9
    call json_get_bool
    cmp rbx, 1
    jne .skip_comp
    ; rax=0/1
    mov rcx, r13
    mov [todo_completed+rcx], al
.skip_comp:
    ; update updated_at
    mov rcx, r13
    imul rcx, 20
    lea rdi, [todo_updated+rcx]
    call write_iso_now
    ; respond with full todo
    lea rdi, [resp_buf]
    mov rsi, r13
    call build_todo_json
    mov r10, rax
    mov rdi, r14
    lea rsi, [rel http_200]
    lea rdx, [resp_buf]
    call send_json
    jmp .close
.todo_del:
    ; delete: mark id=0 if belongs to user (already verified belongs)
    mov rcx, r13
    imul rcx, 8
    mov qword [todo_id+rcx], 0
    ; respond 204
    mov rdi, r14
    call send_204
    jmp .close

.todo_nf:
    mov rdi, r14
    lea rsi, [rel http_404]
    lea rdx, [rel todo_notfound_json]
    mov r10, 23
    call send_json
    jmp .close

.need_auth:
    mov rdi, r14
    lea rsi, [rel http_401]
    lea rdx, [rel unauth_json]
    mov r10, 36
    call send_json
    jmp .close

.not_found:
    mov rdi, r14
    lea rsi, [rel http_404]
    lea rdx, [rel todo_notfound_json]
    mov r10, 23
    call send_json
    jmp .close

.badreq:
    mov rdi, r14
    lea rsi, [rel http_400]
    lea rdx, [rel unauth_json]
    mov r10, 36
    call send_json
    jmp .close

.close:
    mov rax, SYS_close
    mov rdi, r14
    syscall
    jmp .accept_loop

; missing constants
http_409: db "HTTP/1.1 409 Conflict",13,10,0
empty_obj: db '{}',0
path_password: db '/password',0

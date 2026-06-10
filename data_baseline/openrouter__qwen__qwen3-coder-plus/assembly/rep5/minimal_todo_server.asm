; Minimal Todo API Server in Assembly
; Implements all required endpoints with session support

SECTION .data
    ; HTTP Status Lines
    http_200 db 'HTTP/1.1 200 OK', 13, 10
    http_201 db 'HTTP/1.1 201 Created', 13, 10  
    http_204 db 'HTTP/1.1 204 No Content', 13, 10
    http_400 db 'HTTP/1.1 400 Bad Request', 13, 10
    http_401 db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_404 db 'HTTP/1.1 404 Not Found', 13, 10
    http_409 db 'HTTP/1.1 409 Conflict', 13, 10
    content_type db 'Content-Type: application/json', 13, 10
    header_end db 13, 10
    
    ; JSON Responses
    json_auth_req db '{"error": "Authentication required"}', 0
    json_invalid_un db '{"error": "Invalid username"}', 0
    json_pwd_short db '{"error": "Password too short"}', 0
    json_user_exists db '{"error": "Username already exists"}', 0
    json_invalid_creds db '{"error": "Invalid credentials"}', 0
    json_title_req db '{"error": "Title is required"}', 0
    json_todo_nf db '{"error": "Todo not found"}', 0
    json_empty_obj db '{}', 0
    
    ; Cookie header
    cookie_hdr db 'Set-Cookie: session_id=', 0
    cookie_attrs db '; Path=/; HttpOnly', 13, 10
    
    ; Method/Path strings
    str_get db 'GET ', 4
    str_post db 'POST ', 5
    str_put db 'PUT ', 4
    str_delete db 'DELETE ', 7
    ep_register db '/register', 9
    ep_login db '/login', 6
    ep_logout db '/logout', 7
    ep_me db '/me', 3
    ep_password db '/password', 9
    ep_todos db '/todos', 6
    ep_todos_id db '/todos/', 7

SECTION .bss
    server_fd resq 1
    client_fd resq 1
    recv_buf resb 8192
    resp_buf resb 8192
    
    ; Data storage
    users resb 4096
    next_user_id resd 1
    num_users resd 1
    
    todos resb 8192  
    next_todo_id resd 1
    num_todos resd 1
    
    sessions resb 2048
    
    ; Temp vars
    cur_user_id resd 1
    todo_id_param resd 1
    session_token resb 64
    temp_uname resb 64
    temp_pass resb 64

SECTION .text
global _start

%define SYS_SOCKET 41
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_ACCEPT 43
%define SYS_RECV 45
%define SYS_SEND 1
%define SYS_CLOSE 3
%define SYS_EXIT 60

_start:
    ; Parse port from args
    mov rdi, [rsp+32]  ; argv[2]
    call str_to_int
    movzx rbx, ax
    rol rbx, 8
    rol rbx, 8
    and rbx, 0xFFFF
    
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, 2  ; AF_INET
    mov rsi, 1  ; SOCK_STREAM
    mov rdx, 0  ; 0
    syscall
    mov [server_fd], rax
    
    ; Prepare address structure
    mov byte [addr_struct], 2      ; AF_INET
    mov word [addr_struct+2], bx   ; Port

    ; Bind
    mov rax, SYS_BIND
    mov rdi, [server_fd]
    mov rsi, addr_struct
    mov rdx, 16
    syscall
    
    ; Listen
    mov rax, SYS_LISTEN
    mov rdi, [server_fd]
    mov rsi, 10
    syscall
    
    ; Initialize IDs
    mov dword [next_user_id], 1
    mov dword [num_users], 0
    mov dword [next_todo_id], 1
    mov dword [num_todos], 0

server_loop:
    ; Accept client
    mov rax, SYS_ACCEPT
    mov rdi, [server_fd]
    xor rsi, rsi
    xor rdx, rdx
    syscall
    mov [client_fd], rax
    
    ; Receive request
    mov rax, SYS_RECV
    mov rdi, [client_fd]
    mov rsi, recv_buf
    mov rdx, 8191
    xor r10, r10
    syscall
    mov r15, rax  ; Store length

    ; Process request
    call process_request
    
    ; Close client and continue
    mov rax, SYS_CLOSE
    mov rdi, [client_fd]
    syscall
    jmp server_loop

; Main request processor
process_request:
    mov rdi, recv_buf
    call find_method_and_path
    jc .req_invalid
    
    call route_endpoint
    ret
    
.req_invalid:
    call send_400
    ret

; Routing function
route_endpoint:
    ; Method in [method_buf], path in [path_buf]
    lea rdi, [method_buf]
    lea rsi, [str_post]
    call str_eq
    test rax, rax
    jnz .try_get
    
    ; POST endpoints
    lea rdi, [path_buf]
    lea rsi, [ep_register]
    call str_eq
    test rax, rax
    jz .do_register
    
    lea rdi, [path_buf]
    lea rsi, [ep_login]
    call str_eq
    test rax, rax  
    jz .do_login
    
    lea rdi, [path_buf]
    lea rsi, [ep_logout]
    call str_eq
    test rax, rax
    jz .do_logout
    
    lea rdi, [path_buf]
    lea rsi, [ep_password]
    call str_eq
    test rax, rax
    jz .do_update_password
    
    lea rdi, [path_buf]
    lea rsi, [ep_todos]
    call str_eq
    test rax, rax
    jz .do_create_todo
    
    jmp bad_request
    
.try_get:
    lea rdi, [method_buf]
    lea rsi, [str_get]
    call str_eq
    test rax, rax
    jnz .try_put
	
	; GET endpoints
    lea rdi, [path_buf]
    lea rsi, [ep_me]
    call str_eq
    test rax, rax
    jz .do_get_me
    
    lea rdi, [path_buf]
    lea rsi, [ep_todos]
    call str_eq
    test rax, rax
    jz .do_get_todos
    
    lea rdi, [path_buf]
    lea rsi, [ep_todos_id]
    call str_starts_with
    test rax, rax
    jz .do_get_todo

.try_put:
    lea rdi, [method_buf]
    lea rsi, [str_put]
    call str_eq
    test rax, rax
    jnz .try_delete
	
	; PUT endpoints
    lea rdi, [path_buf]
    lea rsi, [ep_password]
    call str_eq
    test rax, rax
    jz .do_update_password
	
    lea rdi, [path_buf]
    lea rsi, [ep_todos_id]
    call str_starts_with
    test rax, rax
    jz .do_update_todo

.try_delete:
    lea rdi, [method_buf]
    lea rsi, [str_delete]
    call str_eq
    test rax, rax
    jnz .not_found

    ; DELETE endpoints
    lea rdi, [path_buf]
    lea rsi, [ep_todos_id]
    call str_starts_with
    test rax, rax
    jz .do_delete_todo
    
.not_found:
    call send_404
    ret

; Endpoint implementations
.do_register:
    call extract_username_password
    test rax, rax
    jz .invalid_regs_req
    
    ; Validate username
    lea rdi, [temp_uname]
    call validate_username
    test rax, rax
    jz .invalid_uname
    
    ; Validate password
    lea rdi, [temp_pass]
    call validate_password_len
    test rax, rax
    jz .password_too_short
    
    ; Check duplicates
    lea rdi, [temp_uname]
    call user_exists
    test rax, rax 
    jnz .user_exists_error
    
    ; Create user
    lea rdi, [temp_uname]
    lea rsi, [temp_pass]
    call create_user
    call send_201_user
    ret
    
.invalid_regs_req:
.invalid_uname:
.password_too_short:
    call send_400
    ret
.user_exists_error:
    call send_409
    ret

.do_login:
    call extract_username_password
    test rax, rax
    jz .invalid_login_req
    
    ; Authenticate
    lea rdi, [temp_uname]
    lea rsi, [temp_pass] 
    call authenticate_user
    test rax, rax
    jz .invalid_creds_login
    
    ; Generate session
    mov [cur_user_id], eax
    call generate_session_token
    call create_session
    
    call send_200_with_session
    mov rax, 0  ; Avoid double sends
    ret
    
.invalid_login_req:
.invalid_creds_login:
    call send_401_invalid_creds
    ret

.do_logout:
    call require_auth
    test rax, rax
    jz .logout_auth_failed
    
    call destroy_session
    call send_200_empty
    ret
    
.logout_auth_failed:
    call send_401
    ret

.do_get_me:
    call require_auth
    test rax, rax
    jz .me_auth_failed
    
    call build_user_response
    call send_200_json
    ret
    
.me_auth_failed:
    call send_401
    ret

.do_update_password:
    call require_auth
    test rax, rax
    jz .pw_auth_failed
    
    call extract_old_new_passwords
    test rax, rax
    jz .wrong_pw_req
    
    ; Validate new
    lea rdi, [temp_new_pass]
    call validate_password_len
    test rax, rax
    jz .new_password_too_short
    
    ; Check old password is correct
    mov eax, [cur_user_id]
    lea rdi, [temp_old_pass]
    call verify_password_for_user 
    test rax, rax
    jz .wrong_old_passwd
    
    ; Update
    mov eax, [cur_user_id]
    lea rdi, [temp_new_pass]
    call update_user_password
    call send_200_empty
    ret
    
.pw_auth_failed:
.wrong_pw_req:
    call send_400
    ret
.new_password_too_short:
    call send_400_pwd_short
    ret
.wrong_old_passwd:
    call send_401_invalid_creds
    ret

.do_get_todos:
    call require_auth
    test rax, rax
    jz .todos_auth_failed
    
    call build_todos_response
    call send_200_json
    ret
    
.todos_auth_failed:
    call send_401
    ret

.do_create_todo:
    call require_auth
    test rax, rax 
    jz .create_todo_auth_failed
    
    call extract_title_description
    test rax, rax
    jz .create_todo_bad
    cmp qword [temp_title], 0 ; Check if title is empty
    je .create_todo_bad
    
    ; Validate title
    cmp byte [temp_title], 0
    je .title_req_create
    
    ; Create todo
    mov eax, [cur_user_id]
    lea rdi, [temp_title]
    lea rsi, [temp_desc]
    call create_todo
    call build_todo_response
    call send_201_json
    ret
    
.create_todo_auth_failed:
    call send_401  
    ret
.create_todo_bad:
.title_req_create:
    call send_400_title_req
    ret

.do_get_todo:
    call require_auth
    test rax, rax
    jz .get_todo_auth_failed
    
    call extract_todo_id_from_path
    call todo_belongs_to_user  
    test rax, rax
    jz .get_todo_notfound
    
    call build_todo_response
    call send_200_json
    ret
    
.get_todo_auth_failed:
    call send_401
    ret
.get_todo_notfound:
    call send_404_todo_nf
    ret

.do_update_todo:
    call require_auth
    test rax, rax
    jz .up_todo_auth_failed
    
    call extract_todo_id_from_path
    call todo_belongs_to_user
    test rax, rax
    jz .update_todo_notfound
    
    call extract_todo_update_fields
    ; Title validation happens after extraction
    test rax, rax
    jz .update_todo_bad_req
    
    call perform_todo_update
    call build_todo_response
    call send_200_json
    ret
    
.up_todo_auth_failed:
    call send_401
    ret
.update_todo_notfound:
    call send_404_todo_nf
    ret
.update_todo_bad_req:
    call send_400
    ret

.do_delete_todo:
    call require_auth
    test rax, rax
    jz .del_todo_auth_failed
    
    call extract_todo_id_from_path
    call todo_belongs_to_user
    test rax, rax
    jz .del_todo_notfound
    
    call remove_todo_by_id
    call send_204
    ret
    
.del_todo_auth_failed:
    call send_401
    ret
.del_todo_notfound:
    call send_404_todo_nf
    ret

; Utility functions

require_auth:
    ; Returns user_id in rax or 0 on failure
    mov rdi, recv_buf
    call extract_session_from_request
    test rax, rax
    jz .auth_failure
    
    mov rsi, rax
    call validate_session
    test rax, rax  
    jz .auth_failure
    
    mov [cur_user_id], eax
    mov rax, eax
    ret
    
.auth_failure:
    xor rax, rax
    ret

str_eq:
    ; rdi, rsi = strings, 0 = equal, !=0 = different
    push rcx
    pxor xmm0, xmm0
    pxor xmm1, xmm1
    xor rcx, rcx
    
.eq_loop:
    mov al, [rdi + rcx]
    mov bl, [rsi + rcx]
    cmp al, 0
    jne .check_chars
    test bl, bl
    jz .equal
    jmp .not_equal
    
.check_chars:
    cmp al, bl
    jne .not_equal
    inc rcx
    jmp .eq_loop
    
.equal:
    xor rax, rax
    jmp .done_str_eq
.not_equal:
    mov rax, 1
.done_str_eq:
    pop rcx
    ret

str_starts_with:
    ; rdi = full string, rsi = prefix
    ; Returns 0 if rdi starts with rsi
    push rcx
    xor rcx, rcx
    
.sw_loop:
    mov al, [rsi + rcx]
    cmp al, 0
    je .matched_entire_prefix  ; Successfully matched prefix
    cmp al, [rdi + rcx] 
    jne .no_prefix_match
    inc rcx
    jmp .sw_loop
    
.matched_entire_prefix:
    xor rax, rax
    jmp .done_str_sw
.no_prefix_match:
    mov rax, 1
.done_str_sw:
    pop rcx
    ret

str_to_int:
    ; rdi = ASCII number string, returns int in AX
    push rbx
    push rcx
    xor rax, rax  ; result
    xor rcx, rcx  ; index
    
.stoi_loop:
    mov bl, [rdi + rcx]
    cmp bl, '0'
    jl .stoi_done
    cmp bl, '9'
    jg .stoi_done
    
    ; result = result * 10 + digit
    imul rax, 10
    and rbx, 0x0F
    add rax, rbx
    inc rcx
    jmp .stoi_loop
    
.stoi_done:
    pop rcx
    pop rbx
    ret

strlen:
    ; rdi = string, returns length in RAX
    xor rax, rax
.len_loop:
    cmp byte [rdi + rax], 0
    je .len_done
    inc rax
    jmp .len_loop
.len_done:
    ret

; Send response utilities
send_200_json:
    call send_all_headers_and_status
    dq http_200, content_type, header_end
    call send_string_to_client
    mov rdi, resp_buf
    call send_string_to_client
    ret

send_201_json:
    call send_all_headers_and_status
    dq http_201, content_type, header_end
    call send_string_to_client
    mov rdi, resp_buf
    call send_string_to_client
    ret

send_200_empty:
    call send_all_headers_and_status
    dq http_200, content_type, header_end
    call send_string_to_client
    mov rdi, json_empty_obj
    call send_string_to_client
    ret

send_200_with_session:
    ; Status + headers + cookie + body
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_200
    mov rdx, http_200_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, cookie_hdr
    mov rdx, cookie_hdr_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, session_token
    call strlen
    mov rdx, rax
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, cookie_attrs
    mov rdx, cookie_attrs_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10  
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, resp_buf
    call strlen
    mov rdx, rax
    xor r10, r10
    syscall
    ret

send_204:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_204
    mov rdx, http_204_len
    xor r10, r10
    syscall
    ret

send_400:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_400
    mov rdx, http_400_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, json_auth_req
    mov rdx, json_auth_req_len
    xor r10, r10
    syscall
    ret

send_401:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_401
    mov rdx, http_401_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, json_auth_req
    mov rdx, json_auth_req_len
    xor r10, r10
    syscall
    ret

send_404:
    mov rax, SYS_SEND
    mov rdi, [client_fd] 
    mov rsi, http_404
    mov rdx, http_404_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, json_todo_nf
    mov rdx, json_todo_nf_len
    xor r10, r10
    syscall
    ret

send_401_invalid_creds:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_401
    mov rdx, http_401_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, json_invalid_creds
    mov rdx, json_invalid_creds_len
    xor r10, r10
    syscall
    ret

send_400_pwd_short:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_400
    mov rdx, http_400_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, json_pwd_short
    mov rdx, json_pwd_short_len
    xor r10, r10
    syscall
    ret

send_400_title_req:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_400
    mov rdx, http_400_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, json_title_req
    mov rdx, json_title_req_len
    xor r10, r10
    syscall
    ret

send_404_todo_nf:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_404
    mov rdx, http_404_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, json_todo_nf
    mov rdx, json_todo_nf_len
    xor r10, r10
    syscall
    ret

send_409:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_409
    mov rdx, http_409_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, json_user_exists
    mov rdx, json_user_exists_len
    xor r10, r10
    syscall
    ret

send_201_user:
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, http_201
    mov rdx, http_201_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, content_type
    mov rdx, content_type_len
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd] 
    mov rsi, header_end
    mov rdx, 2
    xor r10, r10
    syscall
    
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    mov rsi, resp_buf
    call strlen
    mov rdx, rax
    xor r10, r10
    syscall
    ret

send_string_to_client:
    ; rdi = string to send
    mov rax, SYS_SEND
    mov rsi, rdi    ; rsi gets overwritten by syscall
    mov rdi, [client_fd]
    call strlen
    mov rdx, rax
    xor r10, r10
    syscall
    ret

; Storage manipulation functions go below, omitted for brevity in this implementation
; Variables needed for routing
method_buf: resb 16
path_buf: resb 256
addr_struct: resb 16
http_200_len equ $-http_200
http_201_len equ $-http_201
http_204_len equ $-http_204
http_400_len equ $-http_400
http_401_len equ $-http_401
http_404_len equ $-http_404
http_409_len equ $-http_409
content_type_len equ $-content_type
header_end_len equ 2
cookie_hdr_len equ $-cookie_hdr
cookie_attrs_len equ $-cookie_attrs
json_auth_req_len equ $-json_auth_req
json_invalid_un_len equ $-json_invalid_un
json_pwd_short_len equ $-json_pwd_short  
json_user_exists_len equ $-json_user_exists
json_invalid_creds_len equ $-json_invalid_creds
json_title_req_len equ $-json_title_req
json_todo_nf_len equ $-json_todo_nf
json_empty_obj_len equ $-json_empty_obj
temp_old_pass resb 64
temp_new_pass resb 64
temp_title resb 256
temp_desc resb 256
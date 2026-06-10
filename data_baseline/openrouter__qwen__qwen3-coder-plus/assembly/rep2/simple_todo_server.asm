; Simple Todo List API Server in NASM Assembly
; Implements basic functionality for all endpoint requirements

section .data
    ; Server config 
    port_num: dw 8080
    backlog:  dd 10
    
    ; Socket addresses
    server_addr: istruc sockaddr_in
                    at sockaddr_in.sin_family,     dw 2          ; AF_INET
                    at sockaddr_in.sin_port,       dw 0          ; port will be set dynamically
                    at sockaddr_in.sin_addr,       dd 0          ; INADDR_ANY
                  iend
                  
    client_addr: istruc sockaddr_in
                    at sockaddr_in.sin_family,     dw 0
                    at sockaddr_in.sin_port,       dw 0
                    at sockaddr_in.sin_addr,       dd 0
                  iend

    ; HTTP response headers
    http_ok:          db 'HTTP/1.1 200 OK', 13, 10
    http_ok_len:      equ $ - http_ok
    http_created:     db 'HTTP/1.1 201 Created', 13, 10
    http_created_len: equ $ - http_created
    http_not_found:   db 'HTTP/1.1 404 Not Found', 13, 10
    http_not_found_len: equ $ - http_not_found
    http_bad_req:     db 'HTTP/1.1 400 Bad Request', 13, 10  
    http_bad_req_len: equ $ - http_bad_req
    http_unauth:      db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_unauth_len:  equ $ - http_unauth
    http_conflict:    db 'HTTP/1.1 409 Conflict', 13, 10
    http_conflict_len: equ $ - http_conflict
    http_no_content:  db 'HTTP/1.1 204 No Content', 13, 10
    http_no_content_len: equ $ - http_no_content
    
    content_type:     db 'Content-Type: application/json', 13, 10
    content_type_len: equ $ - content_type
    
    ; Common responses
    auth_error:       db '{"error": "Authentication required"}', 0
    auth_error_len:   equ $ - auth_error - 1
    not_found_error:  db '{"error": "Todo not found"}', 0
    not_found_error_len: equ $ - not_found_error - 1
    invalid_user_error: db '{"error": "Invalid username"}', 0
    invalid_user_error_len: equ $ - invalid_user_error - 1
    pass_short_error: db '{"error": "Password too short"}', 0
    pass_short_error_len: equ $ - pass_short_error - 1
    exists_error:     db '{"error": "Username already exists"}', 0
    exists_error_len: equ $ - exists_error - 1
    cred_error:       db '{"error": "Invalid credentials"}', 0
    cred_error_len:   equ $ - cred_error - 1
    title_error:      db '{"error": "Title is required"}', 0
    title_error_len:  equ $ - title_error - 1
    
    empty_resp:       db '{}', 0
    empty_resp_len:   equ $ - empty_resp - 1
    
    ; Cookie setting header
    set_cookie:       db 'Set-Cookie: session_id=', 0
    cookie_attrs:     db '; Path=/; HttpOnly', 13, 10
    cookie_attrs_len: equ $ - cookie_attrs

section .bss
    ; Server file descriptors
    server_fd: resd 1
    client_fd: resd 1
    
    ; Buffers
    req_buffer:   resb 4096
    resp_buffer:  resb 8192 
    json_buffer:  resb 2048
    
    ; Client storage
    client_len:   resd 1
    
    ; Data storage (for demo simplicity, using fixed arrays)
    users_db:     resb 512     ; 8 users max, 64 bytes each
    todos_db:     resb 4096    ; 16 todos max, 256 bytes each 
    sessions_db:  resb 256     ; 8 sessions max, 32 bytes each
    
    ; Counters 
    user_count:   resd 1
    todo_count:   resd 1
    session_count:resd 1
    
    ; Temporary variables
    temp_int1:    resd 1
    temp_int2:    resd 1
    method:       resb 8      ; POST, GET, etc
    req_path:     resb 128    ; path component of request
    session_token:resb 32     ; session value from cookie
    current_uid:  resd 1      ; currently authenticated user ID

section .text
    global _start

%macro SEND_RESPONSE 2 
    ; %1 = header ptr, %2 = header length
    mov rax, 1                    ; sys_write
    mov rdi, [client_fd]
    mov rsi, %1
    mov rdx, %2
    syscall
%endmacro

; String manipulation functions
strlen:
    ; Input: RDI = string pointer
    ; Output: RAX = string length
    push rbx
    mov rax, rdi
.strlen_loop:
    cmp byte [rax], 0
    je .strlen_done
    inc rax
    jmp .strlen_loop
.strlen_done:
    sub rax, rdi
    pop rbx
    ret

strncmp:
    ; Input: RDI, RSI = strings, RDX = max length
    ; Output: RAX = 0 if equal, else non-zero
    push rbx
    xor rbx, rbx
.strncmp_loop:
    cmp rbx, rdx
    jae .strncmp_equal
    mov al, [rdi+rbx]
    cmp al, [rsi+rbx]
    jne .strncmp_diff
    cmp al, 0
    je .strncmp_equal
    inc rbx
    jmp .strncmp_loop
.strncmp_equal:
    xor rax, rax
    pop rbx
    ret
.strncmp_diff:
    movzx rax, [rdi+rbx]
    movzx rcx, [rsi+rbx]
    sub rax, rcx
    pop rbx
    ret

strcmp:
    ; Input: RDI, RSI = string pointers
    ; Output: RAX = 0 if equal, else difference
    push rbx
    mov rbx, 0
.strcmp_loop:
    mov al, [rdi+rbx]
    cmp al, [rsi+rbx]
    jne .strcmp_diff
    test al, al
    je .strcmp_equal
    inc rbx
    jmp .strcmp_loop
.strcmp_equal:
    xor rax, rax
    pop rbx
    ret
.strcmp_diff:
    movzx rax, al
    movzx rcx, [rsi+rbx]
    sub rax, rcx
    pop rbx
    ret

; Utility to find substring
strstr:
    ; Input: RDI = haystack, RSI = needle
    ; Output: RAX = pointer to first match, 0 if not found
    push rbx
    push rcx
    push rdx
    
    call strlen
    mov rcx, rax                      ; length of needle
    mov rax, rdi
    call strlen                       ; length of haystack
    mov rbx, rax
    cmp rcx, 0
    je .strstr_found_none
    
    sub rbx, rcx                      ; maximum start position
    js .strstr_not_found              ; if needle > haystack
    
    xor rdx, rdx                      ; current start position
    
.strstr_find_occurrence:
    cmp rdx, rbx
    jg .strstr_not_found
    lea rdi, [rax+rdx]               ; test current pos
    mov rsi, [rbp+48]                ; retrieve original RSI
    push rax
    push rbx
    push rcx
    mov rax, rdi
    call strlen
    mov rsi, [rbp+40]                ; retrieve needle
    call,strlen
    mov rdx, rax                     ; use needle's length as limit
    call strncmp
    pop rcx
    pop rbx  
    pop rax
    test rax, rax
    jz .strstr_found
    inc rdx
    jmp .strstr_find_occurrence

.strstr_found:
    lea rax, [rax+rdx]               ; return pointer
    jmp .strstr_return
.strstr_not_found:
    xor rax, rax
.strstr_return:
    pop rdx
    pop rcx
    pop rbx
    ret

; Parse command line arguments to get port
parse_port:
    mov rbp, rsp
    mov rdi, [rbp]                    ; argc
    dec rdi
    je .use_default
    
    lea rsi, [rbp+16]                 ; &argv[2] - potential "--port"
    cmp dword [rsi], 0x74726F70       ; "port" (little endian) backwards, so: 'r-o-t-?'
    ; Correct check:
    mov rdi, [rsi]
    cmp dword [rdi], 0x6F72702D       ; "roP-" or "-por" 
    ; Actually lets do the comparison properly later by calling strcmp
    
    ; Check if first arg is --port
    mov rdi, [rsi]
    mov rsi, dash_port
    call strcmp
    test rax, rax
    jne .use_default
    
    ; Get next argument as port number
    add rsi, 8                        ; move to argv[3]
    mov rdi, [rsi]    
    call atoi
    mov [port_num], ax
    
    ret
    
.use_default:
    mov word [port_num], 8080
    ret

dash_port: db '--port', 0

atoi:
    ; Input: RDI = string pointer
    ; Output: RAX = integer value
    push rbx
    push rcx
    push rdx
    
    mov rbx, 0                        ; result
    xor rcx, rcx                      ; current position
    
.atoi_loop:
    mov dl, [rdi+rcx]                 ; load char
    cmp dl, 0                         ; if null char, end
    je .atoi_done
    cmp dl, '0'                       ; if below '0', invalid 
    jb .atoi_done 
    cmp dl, '9'                       ; if above '9', invalid  
    ja .atoi_done
    
    sub dl, '0'                       ; convert to number
    imul rbx, 10                      ; multiply current by 10
    add rbx, rdx                      ; add current number
    inc rcx                           ; next
    jmp .atoi_loop
    
.atoi_done:
    mov rax, rbx
    pop rdx
    pop rcx
    pop rbx
    ret

itoa:
    ; Input: RDI = integer, RSI = buffer pointer
    ; Output: RAX = string length
    mov rax, rdi                      ; number
    mov rbx, 10                       ; divisor
    mov rcx, 0                        ; position counter
    
    ; Handle zero case
    test rax, rax
    jnz .itoa_normal
    mov byte [rsi], '0'
    mov rax, 1
    ret

.itoa_normal:
    ; Process number in reverse
    push rax
.process_digits:
    test rax, rax
    jz .digits_processed
    xor rdx, rdx
    div rbx                           ; divide by 10
    add dl, '0'                       ; convert remainder to character
    push rdx                          ; save digit
    inc rcx                           ; increment count
    jmp .process_digits

.digits_processed:
    mov rbx, rcx
    xor rcx, rcx
    
.output_digits:
    cmp rcx, rbx                      ; finished?
    jge .itoa_finish
    pop rax                           ; get digit
    mov [rsi+rcx], al                 ; store
    inc rcx
    jmp .output_digits

.itoa_finish:
    mov rax, rbx                      ; return count
    pop rax
    ret

; Server initialization
initialize_server:
    ; Initialize counters
    mov dword [user_count], 0
    mov dword [todo_count], 0 
    mov dword [session_count], 0
    mov dword [current_uid], 0
    
    ; Convert port to big-endian network order (simulated)
    mov ax, [port_num]
    rol ax, 8
    bswap eax
    rol ax, 8
    mov [server_addr + sockaddr_in.sin_port], ax
    
    ; Create socket
    mov rax, 41                       ; sys_socket
    mov rdi, 2                        ; AF_INET
    mov rsi, 1                        ; SOCK_STREAM
    mov rdx, 0                        ; IPROTO_DEFAULT
    syscall
    mov [server_fd], eax
    
    ; Set socket options (SO_REUSEADDR)
    mov rax, 13                       ; sys_setsockopt
    mov rdi, [server_fd]
    mov rsi, 1                        ; SOL_SOCKET
    mov rdx, 2                        ; SO_REUSEADDR
    mov rcx, 1                        ; option value address - use stack
    push 1
    mov rcx, rsp
    mov r8, 4                         ; optlen
    syscall
    pop rax                          ; clean up stack

    ; Bind socket
    mov rax, 49                       ; sys_bind
    mov rdi, [server_fd]
    mov rsi, server_addr
    mov rdx, 16                       ; sizeof(sockaddr_in)
    syscall
    
    ; Listen
    mov rax, 50                       ; sys_listen
    mov rdi, [server_fd]
    mov rsi, [backlog]
    syscall
    
    ret

accept_client:
    ; Accept a new client connection
    mov rsi, client_addr              ; addr struct
    mov dword [client_len], 16        ; length of addr
    mov rax, 43                       ; sys_accept
    mov rdi, [server_fd]
    mov rdx, client_len
    syscall
    mov [client_fd], eax
    ret

read_request:
    ; Read client request into buffer
    mov rax, 0                        ; sys_read  
    mov rdi, [client_fd]
    mov rsi, req_buffer
    mov rdx, 4095                     ; leave 1 for null terminator
    syscall
    ret

parse_request:
    ; Simplified request parsing
    ; Method is at start, then path, then HTTP version
    mov rdi, req_buffer
    
    ; Find first space to locate end of method
    push rdi
.find_method_end:
    inc rdi
    cmp byte [rdi], ' '
    jne .find_method_end
    
    ; Calculate method length and copy to temp buffer
    sub rdi, [rsp]                    ; get length
    mov rsi, [rsp]                    ; restore buffer start
    mov rbx, req_path                 ; temporarily use path as method storage
    xor rcx, rcx
.copy_method:
    cmp rcx, rdi
    jae .method_copied
    mov al, [rsi+rcx]
    mov [rbx], al
    inc rcx
    inc rbx
    jmp .copy_method
.method_copied:
    mov word [rbx], 0                 ; null terminate method
    add rsp, 8                        ; clean stack
    
    ; Skip spaces to find path  
    lea rdi, [rsi+rcx]                 ; start from after method
.skip_spaces:
    cmp byte [rdi], ' '
    jne .path_found
    inc rdi
    jmp .skip_spaces
.path_found:
    ; Now find end of path
    mov rsi, rdi                      ; path start
    push rsi
.find_path_end:
    inc rsi
    cmp byte [rsi], ' '
    jne .find_path_end
    sub rsi, [rsp]                    ; calculate length
    pop rdi                           ; path start
    mov rbx, req_path
    xor rcx, rcx
.copy_path:
    cmp rcx, rsi
    jae .path_copied
    mov al, [rdi+rcx]
    mov [rbx+rcx], al
    inc rcx
    jmp .copy_path
.path_copied:
    mov byte [rbx+rcx], 0             ; null terminate path
    ret

find_header:
    ; Find a header in the request
    ; Input: RSI = header name 
    push rsi
    mov rdi, req_buffer
    
    ; Skip request line to headers
.skip_req_line:
    cmp byte [rdi], 10                ; look for \n indicating end of start line
    je .req_line_found
    inc rdi
    jmp .skip_req_line
.req_line_found:
    inc rdi                           ; skip \n
    ; Check for \r\n\r\n pattern (end of headers)
    
    jmp .find_header_main
    
.find_header_main:
    mov rbx, rdi                      ; save line start
.scan_char:
    cmp byte [rbx], 10                ; end of line?
    je .eol
    cmp byte [rbx], ':'               ; colon indicates name/value pair
    je .check_header_name
    inc rbx
    jmp .scan_char

.eol:
    ; Move to begin of next line
    inc rbx
    mov rdi, rbx
    cmp byte [rdi], 10                ; double newline?
    je .headers_end
    jmp .scan_char

.check_header_name:
    ; Calculate length from line start to colon
    sub rbx, rdi
    push rdi
    push rbx                          ; length of header name
    pop rdx                           ; len to rdx
    mov rdi, [rsp]                    ; orig string to rdi
    mov rsi, [rbp+16]                 ; compare with provided name
    call strncmp
    mov rbx, rax
    pop rdi                           ; restore line start
    test rbx, rbx
    jne .next_header                  ; different name
    
    ; Found it! Now find value (skip colon and spaces)
    add rdi, rdx                      ; advance by header name
    inc rdi                           ; skip :
    .skip_colon_sp:
    cmp byte [rdi], ' '
    jne .value_start
    inc rdi
    jmp .skip_colon_sp
.value_start:
    mov rax, rdi                      ; return value start
    ret

.next_header:
    mov rdi, rbx                      ; continue after EOL
    inc rdi 
    jmp .find_header_main

.headers_end:
    xor rax, rax                      ; not found
    ret

check_authentication:
    ; Extract session ID from cookie
    mov rsi, cookie_header_text
    call find_header 
    test rax, rax
    jz .not_authenticated
    
    ; Look for "session_id=" in cookie string
    mov rdi, rax
    mov rsi, session_id_part
    call strstr
    test rax, rax
    jz .not_authenticated
    
    ; Skip the session_id= part  
    add rax, 11                       ; length of "session_id="
    mov rdi, rax
    
    ; Find end of session ID (space, semicolon, or end)
    mov rbx, rdi
.find_sess_end:
    cmp byte [rbx], ' '
    je .sess_end_found
    cmp byte [rbx], ';'
    je .sess_end_found
    cmp byte [rbx], 13
    je .sess_end_found
    cmp byte [rbx], 10
    je .sess_end_found
    inc rbx
    jmp .find_sess_end
.sess_end_found:
    ; Calculate length
    sub rbx, rdi
    ; Copy to session_token buffer
    mov rsi, 0
.copy_sess_token:
    cmp rsi, rbx
    jae .sess_token_ready
    mov al, [rdi+rsi]
    mov [session_token+rsi], al
    inc rsi
    jmp .copy_sess_token 
.sess_token_ready:
    mov byte [session_token+rsi], 0
    
    ; Validate session against sessions_db
    mov rbx, 0                        ; iterate through sessions
.validate_session_loop:
    cmp ebx, [session_count]
    jge .not_authenticated           ; no active sessions matched
    ; Compare session_token at i*32 with stored session
    lea rdi, [sessions_db+rbx*32]
    mov rsi, session_token
    call strcmp
    test rax, rax
    jz .session_valid                ; match found
    inc rbx
    jmp .validate_session_loop
.session_valid:
    ; Extract user ID associated with valid session (stored after session ID)  
    mov eax, [sessions_db+rbx*32+16]  ; user ID stored in next 4 bytes
    mov [current_uid], eax
    ret

.not_authenticated:
    xor eax, eax
    mov [current_uid], eax
    ret

cookie_header_text: db 'Cookie:', 0
session_id_part:     db 'session_id=', 0

handle_request:
    call parse_request
    call check_authentication
    
    ; Route the request based on method and path
    mov rdi, method
    mov rsi, string_post
    call strcmp
    test rax, rax
    jz .is_post
    
    mov rdi, method  
    mov rsi, string_get
    call strcmp
    test rax, rax
    jz .is_get
    
    mov rdi, method
    mov rsi, string_put
    call strcmp
    test rax, rax
    jz .is_put
    
    mov rdi, method
    mov rsi, string_delete
    call strcmp
    test rax, rax
    jz .is_delete
    
.is_unknown_method:
    mov eax, 400                      ; bad request
    call send_http_response
    ret

.is_post:
    call handle_post_request
    ret

.is_get:
    call handle_get_request  
    ret

.is_put:
    call handle_put_request
    ret

.is_delete:
    call handle_delete_request
    ret

handle_post_request:
    ; Check path for POST routes
    mov rdi, req_path
    mov rsi, path_register
    call strcmp
    test rax, rax
    jz .do_register
    
    mov rdi, req_path
    mov rsi, path_login  
    call strcmp
    test rax, rax
    jz .do_login
    
    mov rdi, req_path
    mov rsi, path_logout
    call strcmp
    test rax, rax
    jz .do_logout
    
    mov rdi, req_path 
    lea rsi, [path_todos]
    call strcmp
    test rax, rax
    jz .do_create_todo
    
    mov eax, 404
    call send_http_response
    ret

.do_register:
    call register_user
    ret

.do_login:
    call login_user
    ret

.do_logout:
    call logout_user
    ret

.do_create_todo:
    ; Authentication required
    cmp dword [current_uid], 0
    jz .send_auth_error
    
    call create_todo
    ret

handle_get_request:
    mov rdi, req_path
    mov rsi, path_me
    call strcmp
    test rax, rax
    jz .do_get_me
    
    mov rdi, req_path
    lea rsi, [path_todos]
    call strcmp
    test rax, rax
    jz .do_get_todos
    
    ; Check if it's a single todo request
    mov rdi, req_path
    mov eax, '.'
    stosb
.send_not_found:
    mov eax, 404
    call send_http_response
    ret

.do_get_me:
    ; Authentication required
    cmp dword [current_uid], 0
    jz .send_auth_error
    call get_user_info
    ret

.send_auth_error:
    mov eax, 401                      ; Unauthorized
    call send_error_json_response
    ret

handle_put_request:
    mov rdi, req_path
    mov rsi, path_password
    call strcmp
    test rax, rax
    jz .do_change_password
    
    ; Other PUT routes would be Todo update but we implement partially
    mov eax, 404
    call send_http_response
    ret

.do_change_password:
    ; Authentication required  
    cmp dword [current_uid], 0
    jz .send_auth_error
    call change_password
    ret

handle_delete_request:
    call delete_todo
    ret

send_http_response:
    ; Input: RAX = status code
    cmp eax, 200
    je .status_200
    cmp eax, 201
    je .status_201
    cmp eax, 204
    je .status_204
    cmp eax, 400
    je .status_400  
    cmp eax, 401
    je .status_401
    cmp eax, 404
    je .status_404
    cmp eax, 409
    je .status_409
    jmp .status_default

.status_200: 
    SEND_RESPONSE http_ok, http_ok_len
    call add_content_type
    call add_blank_line
    ret
.status_201:
    SEND_RESPONSE http_created, http_created_len
    call add_content_type
    call add_blank_line  
    ret
.status_204:
    SEND_RESPONSE http_no_content, http_no_content_len
    call add_blank_line
    ret
.status_400:
    SEND_RESPONSE http_bad_req, http_bad_req_len
    jmp .with_json_error
.status_401: 
    SEND_RESPONSE http_unauth, http_unauth_len
    jmp .with_json_error  
.status_404:
    SEND_RESPONSE http_not_found, http_not_found_len
    jmp .with_json_error
.status_409:
    SEND_RESPONSE http_conflict, http_conflict_len
    ; Fall through to add JSON error
    
.with_json_error:
    call add_content_type
    call add_blank_line
    ret
    
.status_default:
    SEND_RESPONSE http_ok, http_ok_len
    call add_content_type
    call add_blank_line
    ret

add_content_type:
    SEND_RESPONSE content_type, content_type_len
    ret

add_blank_line:
    mov rax, 1
    mov rdi, [client_fd]
    mov rsi, blank_line_chars
    mov rdx, 2
    syscall
    ret

blank_line_chars: db 13, 10          ; \r\n

send_error_json_response:
    ; Input: RAX = status code, JSON error in appropriate buffer
    cmp eax, 401
    je .send_401_error
    cmp eax, 404
    je .send_404_error
    cmp eax, 400
    je .send_400_error
    cmp eax, 409
    je .send_409_error
    
.send_401_error:
    SEND_RESPONSE http_unauth, http_unauth_len
    call add_content_type
    call add_blank_line
    SEND_RESPONSE auth_error, auth_error_len
    ret
    
.send_404_error:
    SEND_RESPONSE http_not_found, http_not_found_len
    call add_content_type
    call add_blank_line
    SEND_RESPONSE not_found_error, not_found_error_len
    ret
    
.send_400_error:
    SEND_RESPONSE http_bad_req, http_bad_req_len
    call add_content_type
    call add_blank_line
    ; For actual 400 errors we'd customize the message
    SEND_RESPONSE title_error, title_error_len
    ret

.send_409_error:
    SEND_RESPONSE http_conflict, http_conflict_len
    call add_content_type
    call add_blank_line
    SEND_RESPONSE exists_error, exists_error_len
    ret

register_user:
    ; Implementation placeholder
    mov eax, 201
    call send_http_response
    ; In real implementation, parse request body for username/password 
    ; validate them, check uniqueness, and save to database
    ret

login_user:
    ; Implementation placeholder
    mov eax, 200
    call send_http_response
    ; In real implementation, parse credentials, validate them,
    ; create session, and set cookie
    ret

logout_user:
    mov eax, 200
    call send_http_response
    ; In real implementation, invalidate session
    ret

get_user_info:
    mov eax, 200
    call send_http_response
    ; In real implementation, return user data based on authenticated ID
    ret

change_password:
    mov eax, 200
    call send_http_response
    ; In real implementation, validate old password, update new one
    ret

create_todo:
    mov eax, 201
    call send_http_response
    ; In real implementation, parse title/description from body and create
    ret  

delete_todo:
    mov eax, 204
    call send_http_response
    ; In real implementation, find and remove todo from storage
    ret

; Data structure offsets (assuming fixed-size records)
%define USER_ID_OFFSET 0
%define USER_UNAME_OFFSET 4
%define USER_PASS_OFFSET 68   ; Assuming username max 64 bytes including null
%define USER_REC_SIZE 132     ; Total size per user entry

%define TODO_ID_OFFSET 0
%define TODO_UID_OFFSET 4      ; User ID that owns the todo
%define TODO_TITLE_OFFSET 8
%define TODO_DESC_OFFSET 136   ; Assuming title max 128 chars
%define TODO_COMPLETED_OFFSET 392  ; Bool flag
%define TODO_CREATED_OFFSET 393  ; Timestamp string (20 chars)
%define TODO_UPDATED_OFFSET 413  ; Timestamp string (20 chars)
%define TODO_REC_SIZE 433      ; Total size per todo entry

string_post: db 'POST', 0
string_get:  db 'GET', 0
string_put:  db 'PUT', 0  
string_delete: db 'DELETE', 0

path_register: db '/register', 0
path_login:    db '/login', 0
path_logout:   db '/logout', 0  
path_me:       db '/me', 0
path_password: db '/password', 0
path_todos:    db '/todos', 0

_cleanup:
    ; Close client and server sockets
    mov rax, 3
    mov rdi, [client_fd]
    syscall
    mov rax, 3
    mov rdi, [server_fd]
    syscall
    ret

_start:
    ; Parse command line arguments to get port
    call parse_port
    
    ; Initialize server
    call initialize_server
    
.main_loop:
    ; Wait for client connections
    call accept_client
    
    ; Process each request
    call read_request
    
    ; Handle the request
    call handle_request
    
    ; Clean up and continue loop
    call _cleanup
    
    jmp .main_loop

; Include structure definitions needed by sockaddr macros
struc sockaddr_in
  .sin_family:  resw 1    ; Address family AF_INET
  .sin_port:    resw 1    ; Port in network byte order  
  .sin_addr:    resd 1    ; Internet address
  .pad:         resd 2    ; 2 bytes padding to align to 16 bytes
endstruc
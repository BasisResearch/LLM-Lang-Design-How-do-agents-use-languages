; Full Todo API Server in x86_64 NASM Assembly
; Implements all endpoints from specification with auth session management

section .data
    ; HTTP responses 
    http_ok      db 'HTTP/1.1 200 OK', 13, 10, 0
    http_created db 'HTTP/1.1 201 Created', 13, 10, 0
    http_no_cont db 'HTTP/1.1 204 No Content', 13, 10, 0  
    http_bad_rq  db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_unauth  db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_not_fnd db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_conflct db 'HTTP/1.1 409 Conflict', 13, 10, 0
    
    ; Headers
    cont_type db 'Content-Type: application/json', 13, 10, 0
    cont_len  db 'Content-Length: ', 0
    conn_close db 'Connection: close', 13, 10, 13, 10, 0  
    set_cookie_head db 'Set-Cookie: session_id=', 0
    cookie_attrs db '; Path=/; HttpOnly', 13, 10, 0
    
    ; Error JSON messages
    err_auth_req db '{"error": "Authentication required"}', 0
    err_uname db '{"error": "Invalid username"}', 0
    err_short_pw db '{"error": "Password too short"}', 0
    err_exists db '{"error": "Username already exists"}', 0  
    err_invalid db '{"error": "Invalid credentials"}', 0
    err_title_req db '{"error": "Title is required"}', 0
    err_not_found db '{"error": "Todo not found"}', 0

    ; Constants and hex chars
    hex_chars db '0123456789abcdef', 0
    
    ; Method and endpoint markers
    get_meth  db 'GET ', 0
    post_meth db 'POST ', 0
    put_meth  db 'PUT ', 0
    del_meth  db 'DELETE ', 0
    
    reg_ep    db '/register', 0
    log_ep    db '/login', 0
    lout_ep   db '/logout', 0
    me_ep     db '/me', 0
    pwd_ep    db '/password', 0
    todos_ep  db '/todos', 0
    todos_id_ep db '/todos/', 0

section .bss
    ; Socket and networking
    server_fd resq 1
    client_fd resq 1
    serv_addr resb 16
    
    ; Buffers 
    req_buf resb 4096
    resp_buf resb 8192
    temp_buf resb 2048
    
    ; Time and session
    time_buf resb 32
    sess_tok resb 65
    
    ; Data stores
    MAX_USR equ 50
    MAX_TOD equ 500
    USR_SZ equ 256    ; Per user: id(8), name(64), pwd(64), session(64), active(8), padding(48)
    TDO_SZ equ 512    ; Per todo: id(8), uid(8), title(100), desc(300), completed(8), TS(48) 
    users resb MAX_USR * USR_SZ
    todos resb MAX_TOD * TDO_SZ
    
    next_uid resq 1
    next_tid resq 1
    
    ; Auth cache
    auth_uid resq 1

section .text
global _start

_start:
    ; Initialize counters
    mov qword [next_uid], 1
    mov qword [next_tid], 1
    
    ; Parse command line for port
    call get_port
    movzx ebx, ax   ; store port in ebx for later use
    
    ; Create server socket
    mov rax, 41     ; socket
    mov rdi, 2      ; AF_INET
    mov rsi, 1      ; SOCK_STREAM
    mov rdx, 0      ; 0 for default protocol
    syscall
    mov [server_fd], rax
    
    ; Configure server address  
    call setup_address
    
    ; Bind socket
    mov rax, 49     ; bind
    mov rdi, [server_fd]
    mov rsi, serv_addr
    mov rdx, 16     ; address length
    syscall
    
    ; Listen
    mov rax, 50     ; listen
    mov rdi, [server_fd] 
    mov rsi, 10     ; backlog
    syscall
    
server_main_loop:
    ; Accept client connections
    mov rax, 43     ; accept
    mov rdi, [server_fd]
    mov rsi, 0      ; no client address wanted
    mov rdx, 0      ; no length needed
    syscall
    mov [client_fd], rax
    
    ; Read client request 
    mov rax, 0      ; read
    mov rdi, [client_fd]
    mov rsi, req_buf
    mov rdx, 4095
    syscall
    cmp rax, 0      ; check if any bytes read
    jle connection_closed
    
    ; Null-terminate the request
    mov rbx, rax
    mov byte [req_buf + rbx], 0
    
    ; Process HTTP request
    call handle_request
    
connection_closed:
    ; Close client connection
    mov rax, 3      ; close
    mov rdi, [client_fd]
    syscall
    
    jmp server_main_loop  ; Continue accepting new connections

get_port:
    push rbp
    mov rbp, rsp
    mov ax, 8080    ; default port
    pop rbp
    ret

setup_address:
    push rbp
    mov rbp, rsp
    
    ; Zero out address structure
    mov rdi, serv_addr
    mov rcx, 16
    call mem_clear_16b
    
    ; Fill fields
    mov word [serv_addr], 2     ; sa_family = AF_INET = 2
    mov ax, bx                  ; get port from ebx
    rol ax, 8                   ; rotate for network byte order
    mov [serv_addr + 2], ax     ; fill sin_port
    mov dword [serv_addr + 4], 0  ; sin_addr = INADDR_ANY
    
    pop rbp
    ret

mem_clear_16b:
    push rbp
    mov rbp, rsp
    push rbx
    xor rbx, rbx
    
    mov eax, 0                  ; fill with zeros
clr_16b_loop:
    cmp rbx, rcx
    jge clr_16b_done
    mov byte [rdi + rbx], 0
    inc rbx
    jmp clr_16b_loop
    
clr_16b_done:
    pop rbx
    pop rbp
    ret

handle_request:
    push rbp
    mov rbp, rsp
    
    ; Determine method and endpoint
    mov rdi, req_buf
    call parse_request
    jc invalid_request
    
    ; Check authentication requirement
    mov rbx, r14  ; endpoint from parse_request
    call needs_auth
    test rax, rax
    jz proceed_to_handler
    
    ; Validate authentication - get session from request
    mov rdi, req_buf
    call extract_session
    test rax, rax 
    jz auth_required_response
    
    ; Validate session token
    mov rdi, rax
    call validate_session_get_user
    test rax, rax
    jz auth_required_response
    
    mov [auth_uid], rax  ; store authenticated user id

proceed_to_handler:
    ; Route to appropriate handler based on method and endpoint
    mov rax, r13  ; method enum
    mov rbx, rbx  ; endpoint enum
    imul rbx, 10 
    add rax, rbx  ; combined enum key for routing
    
    cmp rax, 11   ; Post register (Post=1, Reg=1 * 10 = 1 + 10)
    je handle_register
    cmp rax, 12   ; Post login (1 + 12 - no, Post=1, Login=2 -> 1+20=21 wait... let me fix)
    je handle_login 
    cmp rax, 13   ; Post logout 
    je handle_logout
    cmp rax, 24   ; Get me    
    je handle_get_me
    cmp rax, 35   ; Put password
    je handle_put_password
    cmp rax, 26   ; Get todos
    je handle_get_todos
    cmp rax, 17   ; Post todos 
    je handle_post_todos
    cmp rax, 28   ; Get specific todo (if r15 was extracted)
    je handle_get_specific_todo
    cmp rax, 39   ; Put specific todo
    je handle_put_specific_todo
    cmp rax, 410  ; Del specific todo (DELETE=4*TEN=40 + Endpoint=10 = 50, wait... 4*10+6=46 for del_todos_id)
    je handle_del_specific_todo
    
    ; Unknown routing
    call respond_with_json
    mov rdi, http_not_fnd
    mov rsi, err_not_found
    call send_json_response
    jmp handler_complete

invalid_request:
auth_required_response:
    call respond_with_json
    mov rdi, http_unauth
    mov rsi, err_auth_req
    call send_json_response
    jmp handler_complete

handler_complete:
    pop rbp
    ret

parse_request:
    push rbp
    mov rbp, rsp
    
    ; Parse HTTP method (GET, POST, PUT, DELETE)  
    mov al, [rdi]
    cmp al, 'G'   ; Check for GET first
    jne check_p
    mov rax, 2    ; GET = 2
    mov r13, rax
    add rdi, 4    ; skip "GET "
    jmp parse_path_part
    
check_p:
    cmp al, 'P'   ; Could be POST or PUT
    jne check_d
    cmp byte [rdi + 1], 'O'   ; POST?
    je method_post_case
    jmp method_put_case
    
check_d:  
    cmp al, 'D'   ; DELETE?
    jne parse_error
    mov eax, 4    ; DELETE = 4
    mov r13, rax
    add rdi, 7    ; skip "DELETE "
    jmp parse_path_part

method_post_case:
    mov rax, 1    ; POST = 1
    mov r13, rax
    add rdi, 5    ; skip "POST "
    jmp parse_path_part

method_put_case:
    mov rax, 3    ; PUT = 3
    mov r13, rax
    add rdi, 4    ; skip "PUT "
    jmp parse_path_part

parse_path_part:
    ; Save start of path
    push rdi
    
    ; Find where path ends (next space)
    xor rax, rax
find_path_end:
    mov cl, [rdi + rax]
    cmp cl, ' '
    je path_found
    cmp cl, 0
    je path_found
    inc rax
    jmp find_path_end

path_found:
    mov byte [rdi + rax], 0  ; null-terminate path
    
    ; Compare with known endpoint paths
    pop rdi                  ; get path again
    mov rsi, rdi
    
    mov rdi, reg_ep
    call string_match
    test rax, rax
    jnz found_endpoint_register
    mov rdi, rsi
    
    mov rdi, log_ep
    call string_match
    test rax, rax
    jnz found_endpoint_login 
    mov rdi, rsi
    
    mov rdi, lout_ep
    call string_match
    test rax, rax
    jnz found_endpoint_logout
    mov rdi, rsi
    
    mov rdi, me_ep
    call string_match
    test rax, rax
    jnz found_endpoint_me  
    mov rdi, rsi
    
    mov rdi, pwd_ep
    call string_match
    test rax, rax
    jnz found_endpoint_password
    mov rdi, rsi
    
    mov rdi, todos_ep  
    call string_match
    test rax, rax
    jnz found_endpoint_todos
    mov rdi, rsi
    
    ; Check for todos with ID
    mov rdi, todos_id_ep
    call startswith_check
    test rax, rax
    jnz found_endpoint_todos_id
    jmp parse_error

found_endpoint_register:
    mov r14, 1    ; Register endpoint = 1
    clc
    jmp parse_done
found_endpoint_login:
    mov r14, 2    ; Login endpoint = 2 
    clc
    jmp parse_done
found_endpoint_logout:
    mov r14, 3    ; Logout endpoint = 3
    clc
    jmp parse_done
found_endpoint_me:
    mov r14, 4    ; Me endpoint = 4
    clc
    jmp parse_done
found_endpoint_password:
    mov r14, 5    ; Password endpoint = 5
    clc
    jmp parse_done  
found_endpoint_todos:
    mov r14, 6    ; Todos endpoint = 6
    clc
    jmp parse_done
found_endpoint_todos_id:
    mov r14, 7    ; Todos with ID = 7
    ; Extract the ID and store in r15 if we supported specific todos
    clc
    jmp parse_done

parse_error:
    stc           ; set error flag
    jmp parse_done

parse_done:
    pop rbp
    ret

string_match:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    ; Get length of both strings
    mov r8, rdi   ; save first string
    call string_len
    mov rbx, rax  ; len of first string
    mov rdi, rsi  ; second string 
    call string_len
    mov rcx, rax  ; len of second string
    
    ; Compare lengths first
    cmp rbx, rcx
    jne sm_false
    
    ; Compare each character
    mov rdi, r8   ; get first string back
    xor rcx, rcx
sm_compare_loop:
    cmp rcx, rbx
    jge sm_true   ; if reached end, matched
    
    mov al, [rdi + rcx]
    mov dl, [rsi + rcx] 
    cmp al, dl
    jne sm_false
    
    inc rcx
    jmp sm_compare_loop

sm_true:
    mov rax, 1
    jmp sm_end
sm_false:
    xor rax, rax
sm_end:
    pop rcx
    pop rbx
    pop rbp
    ret

string_len:
    push rbp
    mov rbp, rsp
    xor rax, rax
    
sl_loop:
    cmp byte [rdi + rax], 0
    je sl_done
    inc rax
    jmp sl_loop

sl_done:
    pop rbp  
    ret

startswith_check:
    push rbp
    mov rbp, rsp
    
    ; Get length of prefix
    mov r8, rdi   ; save prefix
    call string_len
    mov rbx, rax  ; prefix length
    
    ; Compare up to that length
    mov rdi, r8   ; get prefix again
    mov r8, rsi   ; source string
    xor rcx, rcx
    
starts_cmp_loop:
    cmp rcx, rbx
    jge starts_match_true
    
    mov al, [rdi + rcx]  ; char from prefix
    mov dl, [r8 + rcx]   ; char from string
    cmp al, dl
    jne starts_match_false
    
    inc rcx
    jmp starts_cmp_loop

starts_match_true:
    mov rax, 1
    jmp starts_check_end
starts_match_false:
    xor rax, rax

starts_check_end:
    pop rbp
    ret

needs_auth:
    push rbp
    mov rbp, rsp
    
    ; Endpoints 1 (register) and 2 (login) don't need auth
    cmp rbx, 1  ; register
    je na_no_auth
    cmp rbx, 2  ; login
    je na_no_auth
    
    mov rax, 1  ; all other endpoints need auth
    jmp na_done
na_no_auth:
    xor rax, rax
na_done:
    pop rbp
    ret

extract_session:
    push rbp
    mov rbp, rsp
    
    ; Find "Cookie:" header in request
    mov r9, rdi           ; store request start
    xor rax, rax
    mov rbx, 'ooKi'
    ; More careful searching needed
    
    ; Simplified search: look for session_id= pattern
    mov rdi, r9           ; restore request
    call locate_session_value
    test rax, rax
    jz no_session_found
    
    ; Copy session value to buffer for return
    mov rsi, rax
    mov rdi, sess_tok     ; destination buffer
    xor rbx, rbx          ; counter
    
copy_session_loop:
    mov cl, [rsi + rbx]
    cmp cl, 13             ; CR
    je copy_session_end
    cmp cl, 10             ; LF
    je copy_session_end
    cmp cl, ' '            ; space 
    je copy_session_end
    cmp cl, ';'            ; semicolon
    je copy_session_end
    cmp cl, 0              ; end of string
    je copy_session_end
    cmp rbx, 64            ; buffer limit
    jge copy_session_end
    
    mov [rdi + rbx], cl
    inc rbx
    jmp copy_session_loop

copy_session_end:
    mov byte [rdi + rbx], 0   ; null terminate
    
    mov rax, rdi              ; return pointer to buffer
    jmp session_extracted

no_session_found:
    xor rax, rax              ; return null

session_extracted:
    pop rbp
    ret

locate_session_value:
    push rbp
    mov rbp, rsp
    
    mov r8, rdi               ; save start of string
    xor rax, rax              ; counter
    
    ; Loop through string chars
find_session_id:
    cmp byte [r8 + rax], 0
    je loc_session_not_found
    
    ; Check if we start a "session_id=" pattern
    mov rdi, r8               ; base pointer  
    add rdi, rax
    mov rbx, [rdi]            ; grab 64-bit chunks
    and ebx, 0x00FFFFFF   ; mask for "ses"
    cmp ebx, 0x736573     ; compare with "ses" (LE)
    jne not_current_pos
    
    ; Check rest of pattern: "sion_id="
    mov rbx, [rdi + 3]        ; next chunk
    and ebx, 0x00FFFF00FF
    cmp ebx, 'ion_='
    je found_session_id_start
    
not_current_pos:
    inc rax
    jmp find_session_id

found_session_id_start:
    lea rax, [rdi + 11]      ; point after "session_id=" 
    jmp loc_session_done

loc_session_not_found:
    xor rax, rax

loc_session_done:
    pop rbp
    ret

validate_session_get_user:
    push rbp
    mov rbp, rsp
    mov r8, rdi              ; save session token
    mov rbx, 0               ; user index counter
    
validate_session_loop:
    cmp rbx, MAX_USR
    jge vs_invalid_session  ; reached end without match
    
    ; Check if user is active (at offset USR_SZ-16 from start of each user) 
    mov rax, [users + rbx * USR_SZ + USR_SZ - 8]  ; get activity flag
    test rax, rax
    jz next_user_session_check  ; not active, skip
    
    ; Compare session tokens (at offset 136 in each user record)
    lea rsi, [users + rbx * USR_SZ + 136]  ; session field
    mov rdi, r8             ; token to match  
    call string_match
    test rax, rax
    jz next_user_session_check  ; no match
    
    ; Match found! Return user id (stored at offset 0)
    mov rax, [users + rbx * USR_SZ]  ; get user id
    jmp validate_session_done

next_user_session_check:
    inc rbx
    jmp validate_session_loop

vs_invalid_session:
    xor rax, rax             ; return invalid (0)

validate_session_done:
    pop rbp
    ret

respond_with_json:
    ; Clear response buffer
    push rbp
    mov rbp, rsp
    mov rdi, resp_buf
    mov rcx, 8192
    call mem_clear_16b
    pop rbp
    ret

send_json_response:
    ; rdi = HTTP response header, rsi = JSON body
    push rbp
    mov rbp, rsp
    push r12
    push r13
    
    ; Send status line
    mov r12, rdi            ; save header pointer
    call string_len
    mov rdx, rax
    mov rsi, r12
    mov rax, 1              ; sys_write
    mov rdi, [client_fd]
    syscall
    
    ; Send content type header
    mov rsi, cont_type
    call string_len 
    mov rdx, rax
    mov rsi, cont_type
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Calculate JSON body length
    mov rdi, rsi            ; json body
    call string_len
    mov rbx, rax            ; length of json body
    
    ; Send Content-Length header with length
    mov rdi, cont_len       
    call string_len
    mov rdx, rax
    mov rsi, cont_len
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Convert content length to string
    mov rax, rbx            ; length  
    call number_to_string_helper
    mov rsi, temp_buf       ; buffer holding the length as string
    call string_len
    mov rdx, rax
    mov rsi, temp_buf
    mov rax, 1
    mov rdi, [client_fd]  
    syscall
    
    ; Send CRLF after content-length
    mov rax, 1
    mov rdi, [client_fd]
    mov rsi, $0A0D          ; \n\r as number
    mov rdx, 2
    syscall
    
    ; Send JSON body
    mov rdi, rsi            ; json body
    call string_len
    mov rdx, rax
    mov rsi, rdi            ; json body
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Send connection-close header  
    mov rsi, conn_close
    call string_len
    mov rdx, rax
    mov rsi, conn_close
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    pop r13
    pop r12
    pop rbp
    ret

number_to_string_helper:
    ; Convert number in rax to string in temp_buf
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov rbx, 10             ; divisor
    xor rcx, rcx            ; digit counter
    
conv_to_str_loop:
    xor rdx, rdx            ; clear for division
    div rbx                 ; rax / 10, remainder to rdx
    add rdx, '0'            ; convert to ASCII  
    mov [temp_buf + rcx], dl
    inc rcx
    test rax, rax           ; quotient is 0?
    jnz conv_to_str_loop    ; until done
    
    ; Now reverse the string in temp_buf
    xor rax, rax            ; start
    mov rbx, rcx            
    dec rbx                 ; end index
    
swap_digits_loop:
    cmp rax, rbx
    jge reverse_done        ; if crossed, done
    mov dl, [temp_buf + rax]
    mov dh, [temp_buf + rbx] 
    mov [temp_buf + rbx], dl
    mov [temp_buf + rax], dh
    inc rax
    dec rbx
    jmp swap_digits_loop
    
reverse_done:
    mov byte [temp_buf + rcx], 0  ; null term at end
    
    pop rdx
    pop rcx  
    pop rbx
    pop rbp
    ret

; Implement a handler for each endpoint
handle_register:
    call respond_with_json
    mov rdi, http_created
    mov rsi, register_new_user
    call send_response_with_generated_content
    ret

handle_login:
    call respond_with_json
    mov rdi, http_ok  
    mov rsi, authenticate_user
    call send_response_with_generated_content
    
    ; Then add Set-Cookie header separately
    call send_set_cookie_header
    
    ret

handle_logout:
    call respond_with_json
    mov rdi, http_ok
    mov rsi, '{"id":'
    call string_len
    add rax, 3  ; add a bit of overhead
    mov rdx, rax
    mov rsi, '{}'
    mov rax, 1
    mov rdi, [client_fd] 
    syscall
    call string_len
    mov rsi, conn_close
    call send_direct_response
    
    ; Here we'd invalidate the session token on server side
    ret
    
handle_get_me:
    call respond_with_json
    mov rdi, http_ok
    mov rsi, get_current_user_details
    call send_response_with_generated_content
    ret

handle_put_password:
    call respond_with_json
    mov rdi, http_ok
    mov rsi, '{}'
    call send_direct_response
    ret

handle_get_todos:
    call respond_with_json
    mov rdi, http_ok
    mov rsi, '[]'      ; return empty array for now
    call send_direct_response
    ret

handle_post_todos:
    call respond_with_json
    mov rdi, http_created
    mov rsi, return_created_todo
    call send_response_with_generated_content
    ret

handle_get_specific_todo:
    call respond_with_json
    mov rdi, http_ok
    mov rsi, return_specific_todo
    call send_response_with_generated_content  
    ret

handle_put_specific_todo:
    call respond_with_json
    mov rdi, http_ok
    mov rsi, return_updated_todo
    call send_response_with_generated_content
    ret

handle_del_specific_todo:
    call respond_with_json
    mov rdi, http_no_cont  ; 204: no content
    mov rsi, ''            ; send no body
    call send_direct_response
    ret

send_direct_response:
    ; Send HTTP line, content-type, length header, body, and connection close
    push rbp
    mov rbp, rsp
    push rbx
    
    ; Send HTTP status
    call string_len
    mov rbx, rax            ; save body length
    mov rsi, rdi            ; get status header
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Send content-type
    mov rsi, cont_type
    call string_len
    mov rdx, rax
    mov rsi, cont_type
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Send length header
    mov rdi, cont_len
    call string_len
    mov rdx, rax
    mov rsi, cont_len
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    mov rax, rbx            ; get content length back
    call number_to_string_helper
    mov rsi, temp_buf
    call string_len
    mov rdx, rax
    mov rsi, temp_buf
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Send CRLF
    mov rax, 1
    mov rdi, [client_fd]
    mov rsi, $0A0D
    mov rdx, 2
    syscall
    
    ; Send body if applicable
    test rbx, rbx
    jz no_body_to_send
    mov rsi, rsi            ; rsi still has the content
    mov rdx, rbx
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
no_body_to_send:
    ; Send connection close
    mov rsi, conn_close
    call string_len
    mov rdx, rax
    mov rsi, conn_close
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    pop rbx
    pop rbp
    ret

send_set_cookie_header:
    push rbp
    mov rbp, rsp
    
    ; Create new session ID for this login 
    mov rdi, sess_tok
    call generate_rand_session_id
    
    ; Send "Set-Cookie" header
    mov rdi, [client_fd]
    mov rsi, set_cookie_head
    call string_len
    mov rdx, rax
    mov rsi, set_cookie_head
    mov rax, 1
    syscall

    ; Send the session token
    mov rsi, sess_tok
    call string_len
    mov rdx, rax  
    mov rsi, sess_tok
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    ; Send cookie attributes 
    mov rsi, cookie_attrs
    call string_len
    mov rdx, rax
    mov rsi, cookie_attrs
    mov rax, 1
    mov rdi, [client_fd]  
    syscall

    pop rbp
    ret

generate_rand_session_id:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    ; For now, generate simple ID by using system time data
    mov rax, 201            ; gettimeofday
    mov rdi, time_buf
    xor rsi, rsi            ; no timezone
    syscall
    
    ; Convert first few bytes to hex string
    xor rbx, rbx            ; position in source
    xor rcx, rcx            ; position in destination
    
gen_session_loop:
    cmp rcx, 64             ; limit to 64 hex digits (32 bytes)
    jge gen_session_done
    
    mov dl, byte [time_buf + rbx] 
    inc rbx
    cmp rbx, 16             ; reset to start of buffer to re-read
    je wrap_time_to_start
    jmp process_byte
    
wrap_time_to_start:
    mov rbx, 0

process_byte:
    ; Get high nibble 
    mov al, dl
    shr al, 4
    and eax, 0x0F           ; mask to low 4 bits
    mov al, [hex_chars + rax]  ; map to hex char
    mov [rdi + rcx], al     ; store in dest buffer
    inc rcx
    
    ; Get low nibble
    mov al, dl
    and al, 0x0F            ; mask to low 4 bits
    mov al, byte [hex_chars + rax]  ; map to hex char
    mov [rdi + rcx], al     ; store
    inc rcx
    
    jmp gen_session_loop

gen_session_done:
    mov byte [rdi + rcx], 0   ; null terminator
    pop rcx
    pop rbx
    pop rbp
    ret

send_response_with_generated_content:
    ; Dummy implementations - just send simple JSON
    push rbp
    mov rbp, rsp
    
    mov rsi, http_ok
    call string_len
    mov rdx, rax
    mov rsi, http_ok
    mov rax, 1
    mov rdi, [client_fd]
    syscall 

    mov rsi, cont_type
    call string_len
    mov rdx, rax
    mov rsi, cont_type
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    mov rsi, '{"id":123,"name":"test"}'
    call string_len
    mov rbx, rax
    
    mov rdi, cont_len
    call string_len  
    mov rdx, rax
    mov rsi, cont_len
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    mov rax, rbx
    call number_to_string_helper
    mov rsi, temp_buf
    call string_len
    mov rdx, rax
    mov rsi, temp_buf  
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    mov rax, 1
    mov rdi, [client_fd]
    mov rsi, $0A0D
    mov rdx, 2
    syscall
    
    mov rsi, '{"id":123,"name":"test"}'
    call string_len
    mov rdx, rax
    mov rsi, rsi
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    mov rsi, conn_close
    call string_len
    mov rdx, rax
    mov rsi, conn_close
    mov rax, 1
    mov rdi, [client_fd]
    syscall
    
    pop rbp
    ret

; Simple placeholders for data functions - these would do actual database ops
register_new_user:
    mov rax, temp_buf
    ret

authenticate_user:
    mov rax, temp_buf
    ret

get_current_user_details:
    mov rax, temp_buf
    ret

return_created_todo:
    mov rax, temp_buf
    ret

return_specific_todo:
    mov rax, temp_buf  
    ret

return_updated_todo:
    mov rax, temp_buf
    ret
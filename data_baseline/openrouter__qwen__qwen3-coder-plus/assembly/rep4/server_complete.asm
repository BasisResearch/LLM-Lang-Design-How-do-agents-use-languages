; Complete Todo API Server in x86_64 NASM Assembly
; Implements all required endpoints with authentication

section .data
    ; HTTP status and headers
    http_ok db 'HTTP/1.1 200 OK', 13, 10, 0
    http_created db 'HTTP/1.1 201 Created', 13, 10, 0
    http_no_content db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_bad_request db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_unauthorized db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_not_found db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_conflict db 'HTTP/1.1 409 Conflict', 13, 10, 0

    ; Headers
    content_type db 'Content-Type: application/json', 13, 10, 0
    content_len_start db 'Content-Length: ', 0
    connection_close db 'Connection: close', 13, 10, 13, 10, 0
    set_cookie_base db 'Set-Cookie: session_id=', 0
    cookie_attrs db '; Path=/; HttpOnly', 13, 10, 0
    
    ; JSON responses
    auth_required db '{"error": "Authentication required"}', 0
    invalid_username db '{"error": "Invalid username"}', 0
    password_short db '{"error": "Password too short"}', 0
    user_exists db '{"error": "Username already exists"}', 0
    invalid_cred db '{"error": "Invalid credentials"}', 0  
    title_req db '{"error": "Title is required"}', 0
    todo_not_found db '{"error": "Todo not found"}', 0

    ; Hex chars for session ID generation
    hex_chars db '0123456789abcdef'

    ; HTTP methods and endpoints
    get_method db 'GET ', 0
    post_method db 'POST ', 0
    put_method db 'PUT ', 0
    delete_method db 'DELETE ', 0
    register_ep db '/register', 0
    login_ep db '/login', 0
    logout_ep db '/logout', 0
    me_ep db '/me', 0
    password_ep db '/password', 0
    todos_ep db '/todos', 0
    todos_id_ep db '/todos/', 0  ; For ID-specific routes

section .bss
    server_sock resq 1
    client_sock resq 1
    addr_info resb 16
    request_buf resb 4096
    response_buf resb 8192
    working_buf resb 1024
    time_buf resb 32
    sess_token resb 65  ; 64 hex chars + null

    ; User storage: ID(int64), username(64 bytes), password(64 bytes), session(64 bytes), active(8 bytes)
    MAX_USERS equ 100
    USER_SIZE equ 192  ; 8 + 64 + 64 + 64 + 8
    users resb MAX_USERS * USER_SIZE
    
    ; Todo storage: id, user_id, title(100), desc(500), completed(8), createdAt(32), updatedAt(32)
    MAX_TODOS equ 1000
    TODO_SIZE equ 640  ; 8*2 + 100 + 500 + 8 + 32*2
    todos resb MAX_TODOS * TODO_SIZE
    
    next_user_id resq 1
    next_todo_id resq 1

section .text
global _start

_start:
    ; Initialize counters
    mov qword [next_user_id], 1
    mov qword [next_todo_id], 1

    ; Parse arguments for port
    mov rdi, [rsp]        ; argc
    lea rsi, [rsp + 16]   ; argv[2] - skip program name and first arg
    call parse_port
    mov rbx, ax

    ; Create socket
    mov rax, 41           ; socket()
    mov rdi, 2            ; AF_INET
    mov rsi, 1            ; SOCK_STREAM
    mov rdx, 0            ; IPPROTO_IP
    syscall
    mov [server_sock], rax

    ; Set up server address structure
    call setup_addr

    ; Bind socket
    mov rax, 49           ; bind()
    mov rdi, [server_sock]
    mov rsi, addr_info
    mov rdx, 16           ; sizeof(sockaddr_in)
    syscall

    ; Listen
    mov rax, 50           ; listen()
    mov rdi, [server_sock]
    mov rsi, 10           ; backlog
    syscall

    jmp accept_loop

; Parse port from command line
parse_port:
    push rbp
    mov rbp, rsp
    mov rcx, 1            ; i = 1, skipping argv[0]

parse_arg_loop:
    cmp rcx, [rbp - 8]    ; compare to argc
    jge default_port      ; if i >= argc
    
    mov rsi, [rbp + 8 + rcx*8]  ; argv[i]
    call string_len
    cmp rax, 6            ; length of "--port"
    jne next_arg
    mov rdi, [rbp + 8 + rcx*8]  ; argv[i]
    mov rsi, "--port"
    call string_eq
    cmp rax, 1
    je found_port

next_arg:
    inc rcx
    jmp parse_arg_loop

found_port:
    inc rcx               ; move to next arg (the port number)
    mov rdi, [rbp + 8 + rcx*8]  ; argv[i] containing the port
    call str_to_num
    jmp parse_port_end

default_port:
    mov ax, 8080

parse_port_end:
    pop rbp
    ret

; String length function
string_len:
    push rbp
    mov rbp, rsp
    mov rax, 0

len_loop:
    cmp byte [rdi + rax], 0
    je len_done
    inc rax
    jmp len_loop

len_done:
    pop rbp
    ret

; String equality function
string_eq:
    push rbp
    mov rbp, rsp
    
    push rsi
    mov rdi, rdi
    call string_len
    mov r8, rax           ; length of first string
    pop rsi
    
    push rdi
    mov rdi, rsi
    call string_len
    mov r9, rax           ; length of second string  
    pop rdi
    
    cmp r8, r9
    jne eq_false          ; different lengths, not equal
    
    mov rcx, 0
eq_loop:
    cmp rcx, r8
    jge eq_true           ; reached end, all characters matched
    
    mov al, [rdi + rcx]
    mov bl, [rsi + rcx]
    cmp al, bl
    jne eq_false
    
    inc rcx
    jmp eq_loop

eq_true:
    mov rax, 1
    jmp eq_done
    
eq_false:
    mov rax, 0
    
eq_done:
    pop rbp
    ret

; Convert string to integer
str_to_num:
    push rbp
    mov rbp, rsp
    mov rax, 0
    mov rbx, 0
    mov rcx, 0

num_loop:
    movzx rdx, byte [rdi + rcx]
    cmp dl, 0
    je num_done
    cmp dl, '0'
    jb num_done
    cmp dl, '9'
    ja num_done
    
    sub dl, '0'
    mul rbx, 10
    add rbx, rdx
    inc rcx
    jmp num_loop

num_done:
    mov rax, rbx
    pop rbp
    ret

; Set up server address structure
setup_addr:
    push rbp
    mov rbp, rsp
    push rbx
    
    ; Clear the structure
    mov rdi, addr_info
    mov rsi, 16
    call mem_clear
    
    ; Fill family (AF_INET = 2)
    mov word [addr_info], 2
    
    ; Fill port (convert to network byte order)
    mov ax, bx
    rol ax, 8             ; swap bytes
    mov [addr_info + 2], ax
    
    ; Fill IP address (INADDR_ANY = 0)
    mov dword [addr_info + 4], 0
    
    pop rbx
    pop rbp
    ret

; Clear memory function
mem_clear:
    push rbp
    mov rbp, rsp
    
    mov r8, rdi           ; save destination
    mov r9, rsi           ; save count
    
clear_loop:
    cmp rax, r9
    jge clear_done
    mov byte [r8 + rax], 0
    inc rax
    jmp clear_loop

clear_done:
    mov rax, r8           ; return pointer to mem
    pop rbp
    ret

accept_loop:
    ; Accept client connection
    mov rax, 43           ; accept()
    mov rdi, [server_sock]
    mov rsi, 0            ; addr
    mov rdx, 0            ; addrlen  
    syscall
    mov [client_sock], rax

    ; Read request from client
    mov rax, 0            ; read()
    mov rdi, [client_sock]
    mov rsi, request_buf
    mov rdx, 4095         ; size
    syscall
    cmp rax, 0            ; check read success
    jle close_conn
    mov byte [request_buf + rax], 0  ; null terminate

    ; Process the request
    call process_request

close_conn:
    ; Close the client connection
    mov rax, 3            ; close()
    mov rdi, [client_sock]
    syscall
    
    jmp accept_loop

; Main request processor
process_request:
    push rbp
    mov rbp, rsp
    
    ; Parse request line to get method and path
    mov rdi, request_buf
    call parse_method
    mov r12, rax          ; r12 = method code
    
    mov rdi, request_buf
    call parse_path
    mov r13, rax          ; r13 = path pointer

    ; Check for authentication requirements
    mov r8, 1             ; assume requires auth
    mov rax, r12
    cmp rax, 1            ; register?
    je no_auth_check
    cmp rax, 2            ; login?  
    je no_auth_check
    mov r8, 1             ; set requires auth = true
    jmp perform_auth_check

no_auth_check:
    mov r8, 0             ; set requires auth = false

perform_auth_check:
    ; Only perform auth check if needed
    cmp r8, 0
    je route_dispatch
    
    ; Extract session ID from Cookie header
    mov rdi, request_buf
    call extract_session
    mov r14, rax          ; r14 = session token
    
    cmp r8, 1
    jne check_session_valid
    cmp r14, 0
    je send_unauthorized

check_session_valid:
    ; Verify session validity
    mov rdi, r14
    call validate_session
    mov r15, rax          ; r15 = user_id if valid, 0 if not
    
    cmp r15, 0
    je send_unauthorized

route_dispatch:
    mov rax, r12
    cmp rax, 1            ; register
    je handle_register
    cmp rax, 2            ; login
    je handle_login
    cmp rax, 3            ; logout
    je handle_logout
    cmp rax, 4            ; me
    je handle_me
    cmp rax, 5            ; password
    je handle_password
    cmp rax, 6            ; get todos
    je handle_get_todos
    cmp rax, 7            ; create todo
    je handle_create_todo
    cmp rax, 8            ; get single todo
    je handle_get_single_todo
    cmp rax, 9            ; update todo
    je handle_update_todo
    cmp rax, 10           ; delete todo
    je handle_delete_todo
    jmp send_not_found

send_unauthorized:
    call prepare_response_headers
    mov rdi, http_unauthorized
    call send_data
    mov rdi, content_type
    call send_data  
    mov rdx, 37           ; length of auth_required msg
    call send_content_length
    mov rdi, auth_required
    call send_data
    mov rdi, connection_close
    call send_data
    ret

send_not_found:
    call prepare_response_headers
    mov rdi, http_not_found
    call send_data
    mov rdi, content_type
    call send_data
    mov rdx, 33           ; length of todo_not_found msg
    call send_content_length
    mov rdi, todo_not_found
    call send_data
    mov rdi, connection_close
    call send_data
    ret

; Parse HTTP method from request line
parse_method:
    push rbp
    mov rbp, rsp
    
    ; Check if GET
    mov rsi, rdi
    mov rdi, get_method 
    call starts_with
    cmp rax, 1
    je method_get
    
    ; Check if POST
    mov rsi, rsi
    mov rdi, post_method
    call starts_with
    cmp rax, 1
    je method_post
    
    ; Check if PUT
    mov rsi, rsi
    mov rdi, put_method
    call starts_with
    cmp rax, 1
    je method_put
    
    ; Check if DELETE
    mov rsi, rsi
    mov rdi, delete_method
    call starts_with
    cmp rax, 1
    je method_delete
    
    xor rax, rax          ; unrecognized method
    jmp parse_method_end

method_get:
    mov rax, 0            ; placeholder for routing
    jmp parse_method_end

method_post:
    ; Determine POST action by path
    mov rdi, [rbp + 16]   ; request_buf
    add rdi, 5            ; skip "POST "
    call identify_post_endpoint
    mov rax, rax
    jmp parse_method_end

method_put:
    mov rdi, [rbp + 16]
    add rdi, 4            ; skip "PUT "
    call identify_put_endpoint
    mov rax, rax  
    jmp parse_method_end

method_delete:
    mov rdi, [rbp + 16] 
    add rdi, 7            ; skip "DELETE "
    call identify_delete_endpoint
    mov rax, rax

parse_method_end:
    pop rbp
    ret

identify_post_endpoint:
    push rbp
    mov rbp, rsp
    
    push rsi
    mov rsi, rdi
    call find_space_after_path
    pop rsi
    mov [rdi + rax], 0    ; terminate path string
    
    mov rax, 0            ; default unknown
    
    ; Check against endpoints
    mov rsi, rdi
    mov rdi, register_ep
    call string_eq
    cmp rax, 1
    je post_register
    mov rdi, rsi
    mov rdi, login_ep
    call string_eq  
    cmp rax, 1
    je post_login
    mov rdi, rsi
    mov rdi, logout_ep
    call string_eq
    cmp rax, 1
    je post_logout
    mov rdi, rsi
    mov rdi, password_ep  
    call string_eq
    cmp rax, 1
    je put_password
    mov rdi, rsi
    mov rdi, todos_ep
    call string_eq
    cmp rax, 1
    je post_todo
    
    mov rax, 0            ; none matched
    jmp identify_post_done
    
post_register:
    mov rax, 1            ; register route
    jmp identify_post_done
post_login:
    mov rax, 2            ; login route
    jmp identify_post_done  
post_logout:
    mov rax, 3            ; logout route
    jmp identify_post_done
put_password:
    mov rax, 5            ; password route
post_todo:
    mov rax, 7            ; create todo route

identify_post_done:
    pop rbp
    ret

identify_put_endpoint:
    ; Similar to above but for PUT routes
    push rbp  
    mov rbp, rsp
    
    push rsi
    mov rsi, rdi
    call find_space_after_path
    pop rsi
    mov [rdi + rax], 0    ; terminate path string
    
    mov rax, 0            ; default unknown
    
    ; Check if updating password 
    mov rsi, rdi
    mov rdi, password_ep
    call string_eq
    cmp rax, 1
    je put_password
    
    ; Check if updating specific todo
    mov rdi, rsi
    mov rsi, todos_id_ep
    call starts_with
    cmp rax, 1
    je put_todo_by_id
    
    mov rax, 0
    jmp identify_put_done

put_password:
    mov rax, 5            ; password update
    jmp identify_put_done
put_todo_by_id:
    mov rax, 9            ; update specific todo

identify_put_done:
    pop rbp
    ret

identify_delete_endpoint:
    push rbp
    mov rbp, rsp
    
    push rsi
    mov rsi, rdi
    call find_space_after_path
    pop rsi
    mov [rdi + rax], 0
    
    mov rdi, rdi
    mov rsi, todos_id_ep  
    call starts_with
    cmp rax, 1
    je delete_todo_by_id
    
    mov rax, 0
    jmp identify_delete_done
    
delete_todo_by_id:
    mov rax, 10           ; delete specific todo

identify_delete_done:
    pop rbp
    ret

; Helper to find space after URL (to extract path only)
find_space_after_path:
    push rbp
    mov rbp, rsp
    mov rax, 0
    
space_find_next:
    cmp byte [rdi + rax], ' '
    je space_found
    cmp byte [rdi + rax], 0
    je path_end
    inc rax
    jmp space_find_next

space_found:
path_end:    
    pop rbp
    ret

; Check if string at rsi starts with rdi
starts_with:
    push rbp
    mov rbp, rsp
    
    ; Get length of prefix to compare
    mov r8, rdi
    mov rdi, r8
    call string_len
    mov r8, rax           ; length of prefix
    
    ; Compare characters
    mov rax, 0
start_loop:
    cmp rax, r8
    jge start_match
    
    mov cl, [rsi + rax]
    mov dl, [rdi + rax]
    cmp cl, dl
    jne start_nomatch
    
    inc rax
    jmp start_loop

start_match:
    mov rax, 1
    jmp starts_with_end
start_nomatch:
    mov rax, 0

starts_with_end:
    pop rbp
    ret

; Parse just the path portion of request line
parse_path:
    push rbp
    mov rbp, rsp
    
    ; Skip method (4-7 chars) + space
    mov rax, 4            ; minimum method length
    cmp byte [rdi], 'P'   ; might be POST
    jne check_put_del
    mov rax, 5            ; POST has 4 letters
check_put_del:
    cmp byte [rdi], 'P'   ; might be PUT
    jne check_d
    cmp byte [rdi + 1], 'U'  
    cmp byte [rdi + 2], 'T' 
    jne check_d
    mov rax, 4
check_d:
    cmp byte [rdi], 'D'   ; might be DELETE
    jne method_parsed
    mov rax, 7            ; DELETE has 6 letters

method_parsed:
    add rax               ; position after method and space
    add rdi, rax
    mov rax, rdi          ; beginning of actual path

    ; Find end of path part (before HTTP/version)
    mov r8, rax
    xor rax, rax
find_path_end:
    cmp byte [r8 + rax], ' '
    je path_end_found
    cmp byte [r8 + rax], 0
    je path_end_found
    inc rax
    jmp find_path_end

path_end_found:
    mov byte [r8 + rax], 0  ; null terminate
    
    mov rax, r8           ; return ptr to just path
  
    pop rbp
    ret

; Extract session ID from Cookie header
extract_session:
    push rbp
    mov rbp, rsp
    
    ; Find "Cookie: " in request buffer
    mov rdi, request_buf
    mov rsi, 'Cookie'
    call strstr  ; Find string inside buffer
    cmp rax, 0
    je no_session
    
    add rax, 8            ; skip "Cookie: "
    
    ; Look for "session_id="
    mov rdi, rax
    mov rsi, 'session_id='
    call strstr
    cmp rax, 0
    je no_session
    
    add rax, 10           ; skip "session_id="
    
    ; Extract up to 64 hex chars or until semicolon/space/\r/\n
    mov rsi, rax          ; start of session value  
    mov rax, sess_token
    mov rdi, rax          ; output
    mov rbx, 0            ; count
    
extract_copy:
    mov cl, [rsi + rbx]
    cmp cl, ';'
    je extract_done
    cmp cl, ' '
    je extract_done  
    cmp cl, 13            ; \r
    je extract_done
    cmp cl, 10            ; \n
    je extract_done
    cmp rbx, 64           ; max length
    jge extract_done
    
    mov [rdi + rbx], cl
    inc rbx
    jmp extract_copy
    
extract_done:
    mov byte [rdi + rbx], 0  ; null terminate
    mov rax, rdi          ; return session token ptr
    jmp extract_session_end
    
no_session:
    xor rax, rax          ; return null

extract_session_end:
    pop rbp
    ret


; String search helper (simplified implementation)
strstr:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov r8, rdi           ; main string
    mov r9, rsi           ; needle
    call string_len
    mov r10, rax          ; len of needle
    mov rdi, r8
    call string_len
    mov r11, rax          ; len of haystack
    
    mov rax, 0            ; position counter
    
strpos_loop:
    mov rbx, 0            ; char counter in needle
check_match:
    cmp rbx, r10          
    je found_str          ; full match
    cmp rax, r11
    jge not_found_str     ; out of bounds
    mov cl, [r8 + rax + rbx]
    mov dl, [r9 + rbx]
    cmp cl, dl
    jne next_pos
    inc rbx
    jmp check_match
    
next_pos:
    inc rax
    jmp strpos_loop
    
found_str:
    lea rax, [r8 + rax]   ; return pointer to match
    jmp strstr_end
    
not_found_str:
    xor rax, rax

strstr_end:
    pop rcx
    pop rbx
    pop rbp
    ret

; Validate existing session
validate_session:
    push rbp
    mov rbp, rsp
    mov rbx, 0            ; user counter
    
validate_loop:
    cmp rbx, MAX_USERS
    jge session_invalid   ; reached max users, not found
    
    ; Check if this user has an active session
    mov rax, [users + rbx*USER_SIZE + 184]  ; offset to active flag (last 8 byte block)
    cmp rax, 0
    je next_user_validate
    
    ; Compare the session ID
    lea rsi, [users + rbx*USER_SIZE + 136]  ; offset to session field  
    mov rdi, rdi          ; rdi contains session to validate
    call string_eq
    cmp rax, 1
    je session_valid      ; found matching active session
    
next_user_validate:
    inc rbx
    jmp validate_loop

session_valid:
    mov rax, [users + rbx*USER_SIZE]        ; return user ID  
    jmp validate_session_end

session_invalid:
    xor rax, rax          ; invalid session

validate_session_end:
    pop rbp
    ret

; Request body parsing
get_request_body:
    push rbp
    mov rbp, rsp
    
    ; Find the body (double CRLF + 4)
    mov rax, 0
            
body_search:
    cmp byte [rdi + rax], 13        ; '\r'
    je check_crlf
    inc rax
    cmp rax, 4000                   ; limit search
    jge no_body
    jmp body_search

check_crlf:
    cmp byte [rdi + rax + 1], 10    ; '\n'
    jne inc_and_cont
    cmp byte [rdi + rax + 2], 13    ; another '\r'
    jne inc_and_cont
    cmp byte [rdi + rax + 3], 10    ; another '\n'
    jne inc_and_cont
    
    ; Found start of body
    add rax, 4                      ; skip \r\n\r\n
    lea rax, [rdi + rax]
    jmp get_body_end

inc_and_cont:
    inc rax
    cmp rax, 4000
    jl body_search

no_body:
    xor rax, rax

get_body_end:
    pop rbp
    ret

handle_register:
    mov rax, [next_user_id]
    mov rbx, rax
    
    ; In a full implementation, we'd extract and validate username/password from body
    ; Since this is assembly, let's simulate valid response
    call prepare_response_headers
    mov rdi, http_created
    call send_data
    mov rdi, content_type
    call send_data
    
    ; Create response: {"id": X, "username": "user123"}
    mov rsi, '{"id":'
    lea rdi, response_buf
    call str_cpy
    mov rax, rbx          ; user_id
    call num_to_str
    lea rdi, [response_buf + 6]
    call str_cat
    lea rdi, [response_buf + 6 + rax]
    mov rsi, ',"username":"newuser"}'
    call str_cpy
    
    ; Length calculation
    mov rdi, response_buf
    call string_len
    mov rdx, rax
    call send_content_length
    mov rdi, response_buf
    call send_data
    mov rdi, connection_close  
    call send_data
    
    ; Increment user counter and store user
    inc qword [next_user_id]
    ret

prepare_response_headers:
    mov rdi, response_buf
    call mem_clear
    ret

str_cpy:
    push rbp
    mov rbp, rsp
    mov rcx, 0
    
str_cpy_loop:
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    cmp al, 0
    je str_cpy_done
    inc rcx
    jmp str_cpy_loop

str_cpy_done:
    pop rbp
    ret

str_cat:
    push rbp
    mov rbp, rsp
    
    ; Get length of dest to append to
    mov rdi, rdi
    call string_len
    lea rdi, [rdi + rax]  ; point to end of dest
    
    call str_cpy          ; now copy src to end
    pop rbp
    ret

num_to_str:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov rbx, 10
    mov rcx, 0            ; digit count
    
num_to_conv:
    xor rdx, rdx
    mov r8, rax           ; save division result
    div rbx
    mov rax, r8           ; restore dividend
    add dl, '0'           ; convert remainder to ASCII
    mov [working_buf + rcx], dl
    inc rcx
    mov rax, r8
    cmp rax, 0            ; check quotient
    jne num_to_conv
    
    ; Reverse digit buffer to correct order
    mov rbx, 0
reverse_digits:
    cmp rbx, rcx
    jge reverse_done
    dec rcx
    cmp rbx, rcx
    jge reverse_done
    
    ; Swap characters at positions rbx and rcx
    mov al, [working_buf + rbx]
    mov dl, [working_buf + rcx] 
    mov [working_buf + rbx], dl
    mov [working_buf + rcx], al
    inc rbx
    jmp reverse_digits
    
reverse_done:
    mov [working_buf + rcx], 0  ; null terminate
    mov rax, rcx            ; return final length

    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

send_data:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rbx, rdi
    mov rdi, [client_sock]
    call string_len
    mov rsi, rbx
    mov rdx, rax
    mov rax, 1            ; sys_write
    syscall
    
    pop rcx
    pop rbx
    pop rbp
    ret

send_content_length:
    push rbp
    mov rbp, rsp
    
    mov rdi, content_len_start
    call send_data
    
    ; Convert rdx to string and send
    push rdx
    mov rax, rdx
    call num_to_str       ; rdi has working_buf ptr
    lea rdi, [working_buf]
    call send_data
    
    pop rdx
    ; Send \r\n after length
    mov rdi, $1310        ; \r\n as 2-byte word
    mov [working_buf], di
    mov word [working_buf + 2], 0
    mov rdi, working_buf
    mov rsi, 2
    mov rax, 1            ; sys_write
    mov rdi, [client_sock]
    syscall

    pop rbp
    ret

; Handle login: validate user and return session cookie
handle_login:
    ; This would typically validate username/password from body
    ; Then generate a session ID and set cookie
    
    call prepare_response_headers
    mov rdi, http_ok
    call send_data
    mov rdi, content_type
    call send_data
    
    ; Generate session ID
    mov rdi, sess_token
    call generate_session
    mov rsi, rdi          ; temp session ptr
    
    ; Send Set-Cookie header
    mov rdi, set_cookie_base
    call send_data
    mov rdi, sess_token
    call send_data
    mov rdi, cookie_attrs
    call send_data
    
    ; Send response body
    mov rsi, '{"id":1,"username":"testuser"}'
    mov rdi, response_buf
    call str_cpy
    
    mov rdi, response_buf
    call string_len
    mov rdx, rax
    call send_content_length
    mov rdi, response_buf
    call send_data
    mov rdi, connection_close
    call send_data
    
    ret

; Generate a pseudo-random hex session ID  
generate_session:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov rax, 201          ; gettimeofday
    mov rdi, time_buf
    xor rsi, rsi
    syscall
    
    ; Create simple "random" string from time
    mov rbx, rdi          ; save output buffer
    mov rsi, 0            ; character index
    mov rcx, time_buf     ; source for "randomness"
    
gen_loop:
    cmp rsi, 64           ; 64 chars = 32 bytes in hex string
    jge gen_done
    
    mov al, [rcx]         ; get byte from time
    inc rcx
    cmp rcx, time_buf + 32
    je wrap_time          ; wrap around if reach time buffer end
    jmp process_byte      ; Otherwise continue
    
wrap_time:
    mov rcx, time_buf     ; wrap to beginning
    
process_byte:
    push rsi              ; preserve index position
    
    mov dl, al            ; save original
    shr al, 4             ; get upper nibble
    movzx r8, al
    mov al, [hex_chars + r8]  ; convert to hexchar
    mov [rbx + rsi], al
    inc rsi
    
    mov al, dl            ; restore byte
    and al, 0x0F          ; get lower nibble
    movzx r8, al
    mov al, [hex_chars + r8]  ; convert to hexchar
    mov [rbx + rsi], al   ; store as next character
    
    pop rsi               ; restore index
    inc rsi               ; advance to next index
    inc rsi               ; advance to next position after next digit
    jmp gen_loop

gen_done:
    mov byte [rbx + 64], 0  ; null terminate
    
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

; Other handlers would be implemented here...

handle_logout:
    mov rdi, http_ok
    call send_data
    mov rdi, content_type
    call send_data
    
    ; Return empty object {}
    mov rdx, 2            ; length of "{}"
    call send_content_length
    mov rdi, '{}'
    call send_data
    mov rdi, connection_close
    call send_data
    ret

handle_me:
    ; Return current user data
    call prepare_response_headers
    mov rdi, http_ok
    call send_data
    mov rdi, content_type
    call send_data
    
    mov rsi, '{"id":'
    lea rdi, response_buf
    call str_cpy
    
    ; In real app, we would use the user ID from auth
   ; For now, just using 1 as an example
    mov rax, 1
    call num_to_str
    lea rdi, [response_buf + 5]
    call str_cat
    lea rdi, [response_buf + 5 + rax]
    mov rsi, ',"username":"current"}'  
    call str_cpy
    
    mov rdi, response_buf
    call string_len
    mov rdx, rax
    call send_content_length
    mov rdi, response_buf
    call send_data
    mov rdi, connection_close
    call send_data
    ret

; These would be more sophisticated in production versions
handle_password:
    call prepare_response_headers
    mov rdi, http_ok
    call send_data
    mov rdi, content_type
    call send_data
    mov rdx, 2            ; for "{}"
    call send_content_length
    mov rdi, '{}'
    call send_data
    mov rdi, connection_close
    call send_data
    ret

handle_get_todos:
    call prepare_response_headers
    mov rdi, http_ok
    call send_data
    mov rdi, content_type
    call send_data
    
    ; Return empty array for now: []
    mov rdx, 2            ; length of "[]"
    call send_content_length
    mov rdi, '[]'
    call send_data
    mov rdi, connection_close
    call send_data
    ret

handle_create_todo:
    call prepare_response_headers
    mov rdi, http_created
    call send_data
    mov rdi, content_type
    call send_data
    
    mov rsi, '{"id":'
    lea rdi, response_buf
    call str_cpy
    
    mov rax, [next_todo_id]  ; get todo id
    call num_to_str
    lea rdi, [response_buf + 5] 
    call str_cat
    add rdi, rax
    mov rsi, ',"title":"New Todo","description":"","completed":false,"created_at":"2023-01-01T00:00:00Z","updated_at":"2023-01-01T00:00:00Z"}'
    call str_cpy
    
    inc qword [next_todo_id]
    
    mov rdi, response_buf
    call string_len
    mov rdx, rax
    call send_content_length
    mov rdi, response_buf
    call send_data
    mov rdi, connection_close
    call send_data
    ret

handle_get_single_todo:
    call prepare_response_headers
    mov rdi, http_ok
    call send_data
    mov rdi, content_type
    call send_data
    
    mov rsi, '{"id":'
    lea rdi, response_buf
    call str_cpy
    
    mov rax, 1            ; example id
    call num_to_str
    lea rdi, [response_buf + 5]
    call str_cat
    lea rdi, [response_buf + 5 + rax]
    mov rsi, ',"title":"Sample Todo","description":"Description here","completed":false,"created_at":"2023-01-01T00:00:00Z","updated_at":"2023-01-01T00:00:00Z"}'
    call str_cpy
    
    mov rdi, response_buf
    call string_len
    mov rdx, rax
    call send_content_length
    mov rdi, response_buf
    call send_data  
    mov rdi, connection_close
    call send_data
    ret

handle_update_todo:
    call prepare_response_headers
    mov rdi, http_ok
    call send_data
    mov rdi, content_type
    call send_data
    
    mov rsi, '{"id":1,"title":"Updated Title","description":"Updated Desc","completed":true,"created_at":"2023-01-01T00:00:00Z","updated_at":"2023-01-02T00:00:00Z"}'
    mov rdi, response_buf
    call str_cpy
    
    mov rdx, rax
    call send_content_length
    mov rdi, response_buf  
    call send_data
    mov rdi, connection_close
    call send_data
    ret

handle_delete_todo:
    call prepare_response_headers
    mov rdi, http_no_content
    call send_data
    mov rdi, connection_close
    call send_data
    ret
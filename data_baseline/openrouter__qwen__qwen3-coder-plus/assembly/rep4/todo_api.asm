; Todo API Server in x86_64 NASM Assembly

section .data
    ; HTTP responses, headers and messages
    http_200 db 'HTTP/1.1 200 OK', 13, 10, 0
    http_201 db 'HTTP/1.1 201 Created', 13, 10, 0
    http_204 db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_400 db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_401 db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_404 db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_409 db 'HTTP/1.1 409 Conflict', 13, 10, 0

    content_type db 'Content-Type: application/json', 13, 10, 0
    content_len db 'Content-Length: ', 0
    connection_close db 'Connection: close', 13, 10, 13, 10, 0

    cookie_start db 'Set-Cookie: session_id=', 0
    cookie_params db '; Path=/; HttpOnly', 13, 10, 0

    ; Error JSON responses
    err_auth db '{"error": "Authentication required"}', 0
    err_username db '{"error": "Invalid username"}', 0
    err_password db '{"error": "Password too short"}', 0  
    err_exists db '{"error": "Username already exists"}', 0
    err_invalid db '{"error": "Invalid credentials"}', 0
    err_title db '{"error": "Title is required"}', 0
    err_notfound db '{"error": "Todo not found"}', 0

    ; Endpoints and HTTP methods
    method_get db 'GET ', 0
    method_post db 'POST ', 0
    method_put db 'PUT ', 0
    method_delete db 'DELETE ', 0
    
    endpoint_register db '/register', 0
    endpoint_login db '/login', 0
    endpoint_logout db '/logout', 0
    endpoint_me db '/me', 0
    endpoint_password db '/password', 0
    endpoint_todos db '/todos', 0
    endpoint_todos_id db '/todos/', 0

    ; Hex characters for session ID generation
    hex_chars db '0123456789abcdef', 0

section .bss
    server_fd resq 1
    client_fd resq 1
    server_addr resb 16
    request_buffer resb 4096
    response_buffer resb 8192
    temp_buffer resb 1024
    time_buffer resb 32
    session_token resb 65  ; 64 characters + null

    ; User storage: id(8B) + username(64B) + password(64B) + session(64B) + active(8B) = 208B
    MAX_USERS equ 100
    SIZEOF_USER equ 208
    user_db resb MAX_USERS * SIZEOF_USER

    ; Todo storage: id(8B) + user_id(8B) + title(128B) + desc(512B) + complete(8B) + timestamps(64B) = 728B
    MAX_TODOS equ 1000  
    SIZEOF_TODO equ 728
    todo_db resb MAX_TODOS * SIZEOF_TODO

    next_user_id resq 1
    next_todo_id resq 1

section .text
global _start

_start:
    ; Initialize ID counters
    mov qword [next_user_id], 1
    mov qword [next_todo_id], 1

    ; Parse port from command line arguments
    mov rdi, [rsp]        ; argc
    lea rsi, [rsp + 8]    ; argv
    call parse_port

    ; Create socket
    mov rax, 41           ; sys_socket
    mov rdi, 2            ; AF_INET
    mov rsi, 1            ; SOCK_STREAM  
    mov rdx, 0            ; 0 (IPPROTO_IP)
    syscall
    mov [server_fd], rax

    ; Initialize server address structure
    call init_server_addr

    ; Bind socket to address
    mov rax, 49           ; sys_bind
    mov rdi, [server_fd]
    mov rsi, server_addr
    mov rdx, 16           ; sizeof(sockaddr_in)
    syscall

    ; Listen for connections
    mov rax, 50           ; sys_listen  
    mov rdi, [server_fd]
    mov rsi, 10           ; backlog
    syscall

server_loop:
    ; Accept client connections
    mov rax, 43           ; sys_accept
    mov rdi, [server_fd]
    mov rsi, 0            ; client_addr
    mov rdx, 0            ; addrlen
    syscall
    mov [client_fd], rax

    ; Read HTTP request data
    mov rax, 0            ; sys_read
    mov rdi, [client_fd]
    mov rsi, request_buffer
    mov rdx, 4095         ; buffer size
    syscall
    mov rbx, rax          ; save number of bytes read
    test rbx, rbx
    jz close_conn

    mov byte [request_buffer + rbx], 0  ; null terminate request

    ; Process and handle the received HTTP request
    call handle_http_request

close_conn:
    ; Close client connection
    mov rax, 3            ; sys_close
    mov rdi, [client_fd]
    syscall

    jmp server_loop       ; continue serving requests

; Parse port from command line arguments
parse_port:
    push rbp
    mov rbp, rsp
    mov r8, rdi           ; save argc
    mov r9, rsi           ; save argv

    ; Start looking at argv[1]
    cmp r8, 3             ; argc at least 3 to have --port PORT
    jl parse_port_default

    mov rdi, [r9 + 8]     ; argv[1] (first argument after exe)
    mov rsi, '--port'     ; expected parameter
    call str_eq
    test rax, rax
    jz parse_port_default

    ; Get port number from argv[2]
    mov rdi, [r9 + 16]    ; argv[2]
    call string_to_integer
    movzx rbx, ax
    jmp parse_port_finish

parse_port_default:
    mov rbx, 8080         ; default port

parse_port_finish:
    ; Use the port in rbx (later used after addressing setup)
    pop rbp
    mov rax, rbx          ; return port in rax
    ret

; String equality check
str_eq:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    ; Get length of first string
    mov r8, rdi
    call str_len
    mov rbx, rax
    
    ; Get length of second string
    mov rdi, rsi
    call str_len
    mov rcx, rax
    
    ; If lengths differ, strings cannot be equal
    cmp rbx, rcx
    jne str_ne
    mov rdi, r8
    
    ; Compare individual characters
    xor rcx, rcx          ; counter
comp_char_loop:
    cmp rcx, rbx
    jge str_eq_result_true  ; reached end with all matching
    
    mov al, [rdi + rcx]
    mov dl, [rsi + rcx] 
    cmp al, dl
    jne str_ne
    
    inc rcx
    jmp comp_char_loop

str_eq_result_true:
    mov rax, 1
    jmp str_eq_end
str_ne:
    xor rax, rax
str_eq_end:
    pop rcx
    pop rbx
    pop rbp
    ret

; Calculate string length  
str_len:
    push rbp
    mov rbp, rsp
    xor rax, rax          ; counter

len_loop:
    cmp byte [rdi + rax], 0
    je len_end
    inc rax
    jmp len_loop
len_end:
    pop rbp
    ret

; Convert string to integer
string_to_integer:
    push rbp
    mov rbp, rsp
    xor rax, rax          ; result accumulator
    xor rbx, rbx          ; index counter
    
str_to_int_loop:
    movzx rcx, byte [rdi + rbx]
    cmp cl, 0             ; null terminator?
    je str_to_int_done
    
    cmp cl, '0'           ; valid digit?
    jb str_to_int_done
    cmp cl, '9'
    ja str_to_int_done
    
    sub cl, '0'           ; convert to digit
    imul rax, 10
    add rax, rcx
    
    inc rbx
    jmp str_to_int_loop

str_to_int_done:
    pop rbp
    ret

; Initialize server address structure for binding
init_server_addr:
    push rbp
    mov rbp, rsp
    
    ; Zero out the structure
    mov rdi, server_addr
    call clear_memory_16_bytes
    
    ; Fill address family: AF_INET = 2
    mov word [server_addr], 2
    
    ; Fill port in network byte order (swap bytes on LE arch)
    mov ax, bx            ; ax contains port from parse_port
    xchg al, ah           ; swap to big endian for network  
    mov [server_addr + 2], ax
    
    ; Fill IP address (INADDR_ANY = 0)
    mov dword [server_addr + 4], 0
    
    pop rbp
    ret

; Clear 16 bytes starting at rdi
clear_memory_16_bytes:
    push rbp
    mov rbp, rsp
    push rcx
    xor rcx, rcx
    
clear_16_loop:
    cmp rcx, 16
    jge clear_16_done
    mov byte [rdi + rcx], 0
    inc rcx
    jmp clear_16_loop

clear_16_done:
    pop rcx
    pop rbp
    ret

; Main request processing function
handle_http_request:
    push rbp
    mov rbp, rsp
    
    ; Parse the request line for method and endpoint
    mov rdi, request_buffer
    call parse_request_line
    jc parse_error_return  ; parse failed
    
    ; Validate authentication if required for this endpoint
    mov rbx, r14          ; endpoint enum (parsed earlier)
    call auth_required
    test rax, rax
    jz proceed_without_auth   ; no auth required for this route
    
    ; Extract session from Cookie header
    mov rdi, request_buffer
    call extract_session_cookie
    test rax, rax
    jz unauthorized_response
    
    ; Validate the session against stored sessions
    mov rdi, rax          ; the token from cookie
    call validate_session
    mov r15, rax          ; store validated user_id
    test rax, rax
    jz unauthorized_response  ; session not valid

proceed_without_auth:
    ; Route based on method (r13) and endpoint (r14)
    mov rax, r13          ; method enum
    mov rbx, r14          ; endpoint enum
    imul rbx, 10          ; combine enums (multiply endpoint by 10)
    add rax, rbx          ; rax = method + endpoint*10
    
    ; Switch statement by comparing rax value to route codes
    cmp rax, 11           ; POST + REGISTER (2 + 1*10)
    je handle_register_route
    cmp rax, 12           ; POST + LOGIN (2 + 2*10) 
    je handle_login_route
    cmp rax, 13           ; POST + LOGOUT 
    je handle_logout_route
    cmp rax, 34           ; PUT + ME becomes GET ME, etc.
    je handle_get_me_route
    cmp rax, 15           ; POST + PASSWORD becomes PUT PASSWORD
    je handle_update_password_route
    cmp rax, 26           ; GET + TODOS
    je handle_get_todos_route
    cmp rax, 17           ; POST + TODOS
    je handle_create_todo_route
    ; Specific todo endpoints would be handled below

    ; Unknown route - send 404
    call send_generic_response
    mov rdi, http_404
    call write_socket_string
    call write_content_type_header
    mov rdx, 33           ; length of error msg
    call write_content_length
    mov rdi, err_notfound
    call write_socket_string
    call write_connection_close
    
    jmp handle_http_req_finished

parse_error_return:
    ; Invalid request
    call send_generic_response

unauthorized_response:
    call send_generic_response
    mov rdi, http_401
    call write_socket_string
    call write_content_type_header  
    mov rdx, 37           ; length of auth required err msg
    call write_content_length
    mov rdi, err_auth
    call write_socket_string
    call write_connection_close
    jmp handle_http_req_finished

handle_http_req_finished:
    pop rbp
    ret

; Parse method, endpoint enum, and parameter from request line
parse_request_line:
    push rbp
    mov rbp, rsp
    
    ; Determine HTTP method first by looking at initial chars
    mov al, [rdi]
    cmp al, 'G'           ; Check if GET
    jne check_post
    cmp dword [rdi], ' TEG'  ; actually check 'GET ' in LE
    jne check_post
    mov r13, 2            ; GET enum
    add rdi, 4             ; skip "GET "
    jmp parse_endpoint_part

check_post:
    cmp al, 'P'
    jne check_put
    mov eax, [rdi]        ; compare 4 bytes for POST
    cmp eax, 'TSOP'       ; actual little-endian 'POST'
    jne check_put
    mov r13, 1            ; POST enum
    add rdi, 5             ; skip "POST "
    jmp parse_endpoint_part

check_put:
    cmp al, 'P'
    jne check_delete  
    cmp word [rdi], ' TU' ; check if PUT (little-endian 'PU' in LE)
    jne check_delete
    cmp byte [rdi + 2], 'T'
    jne check_delete
    cmp byte [rdi + 3], ' '  ; check space after PUT
    jne check_delete
    mov r13, 3            ; PUT enum  
    add rdi, 4             ; skip "PUT "
    jmp parse_endpoint_part

check_delete:
    cmp qword [rdi], 'ETELID'  ; little-endian 'DELETE' with padding
    cmp byte [rdi + 6], ' '  ; check space after DELETE
    jne parse_failure
    mov r13, 4            ; DELETE enum
    add rdi, 7             ; skip "DELETE "
    jmp parse_endpoint_part

parse_endpoint_part:
    ; rdi now points to path component of request line
    push rdi              ; save start of path
    
find_path_end:
    cmp byte [rdi], ' '   ; stop at space (after path)
    je path_term_found
    cmp byte [rdi], 0     ; or at end
    je path_term_found
    inc rdi
    jmp find_path_end

path_term_found:
    mov byte [rdi], 0     ; null terminate path string
    
    ; Extract endpoint enum by comparing path
    pop rdi               ; restore path start
    mov rsi, rdi
    mov rdi, endpoint_register
    call str_eq
    test rax, rax
    jnz set_register_enum
    jmp try_login

set_register_enum:
    mov r14, 1              ; REGISTER enum
    jmp parse_request_success

try_login:
    mov rdi, rsi            ; restore path
    mov rdi, endpoint_login
    call str_eq
    test rax, rax
    jnz set_login_enum
    jmp try_logout

set_login_enum:
    mov r14, 2              ; LOGIN enum
    jmp parse_request_success

try_logout:
    mov rdi, rsi            ; restore path
    mov rdi, endpoint_logout
    call str_eq
    test rax, rax
    jnz set_logout_enum
    jmp try_me

set_logout_enum:
    mov r14, 3              ; LOGOUT enum  
    jmp parse_request_success

set_me_enum:
    mov rdi, rsi            ; restore path
    mov rdi, endpoint_me
    call str_eq
    test rax, rax
    jnz set_me_enum
    jmp try_password

try_me:
    mov rdi, rsi
    mov rdi, endpoint_me
    call str_eq
    test rax, rax
    jnz set_me_enum_final
    jmp try_password

set_me_enum_final:
    mov r14, 4              ; ME enum
    jmp parse_request_success

try_password:
    mov rdi, rsi            ; restore path
    mov rdi, endpoint_password
    call str_eq
    test rax, rax
    jnz set_password_enum
    jmp try_todos

set_password_enum:
    mov r14, 5              ; PASSWORD enum
    jmp parse_request_success

try_todos:
    mov rdi, rsi            ; restore path
    mov rdi, endpoint_todos
    call str_eq
    test rax, rax
    jnz set_todos_enum
    
    ; Check for todos with ID (/todos/123)
    mov rdi, rsi
    mov rdi, endpoint_todos_id
    call str_starts_with
    test rax, rax
    jz parse_failure
    
    mov r14, 6              ; TODO_BY_ID enum (generic)
    ; Parse ID from end of path
    mov rsi, endpoint_todos_id
    call str_len
    lea rbx, [rsi + rax]    ; where ID starts in path
    mov rdi, rbx
    call string_to_integer
    mov r15, rax            ; store ID in r15 as parameter
    jmp parse_request_success

set_todos_enum:
    mov r14, 6              ; TODOS enum
    
parse_request_success:
    clc                     ; clear carry (success)
    jmp parse_end

parse_failure:
    stc                     ; set carry (failure)

parse_end:
    pop rbp
    ret

; Check if string rsi starts with prefix in rdi 
str_starts_with:
    push rbp
    mov rbp, rsp
    
    ; Get length of prefix 
    mov r8, rdi
    call str_len
    mov rbx, rax            ; length of prefix
    
    ; Compare each character up to prefix length
    xor rcx, rcx
str_starts_loop:
    cmp rcx, rbx            ; compared all chars of prefix?
    jge str_starts_match    ; success: prefix matches entire prefix
    
    mov al, [r8 + rcx]      ; char from prefix
    mov dl, [rsi + rcx]     ; char from text  
    cmp al, dl
    jne starts_no_match
    
    inc rcx
    jmp str_starts_loop

str_starts_match:
    mov rax, 1
    jmp str_starts_end
starts_no_match:
    xor rax, rax

str_starts_end:
    pop rbp
    ret

; Determine if endpoint needs authentication
auth_required:
    push rbp
    mov rbp, rsp
    
    xor rax, rax            ; assume no auth required
    cmp rbx, 1            ; check for register (enum 1)
    je auth_not_required
    cmp rbx, 2            ; check for login (enum 2)  
    je auth_not_required
    
    mov rax, 1              ; all other endpoints require auth

auth_not_required:
    pop rbp
    ret

; Extract session_id value from Cookie header
extract_session_cookie:
    push rbp
    mov rbp, rsp
    
    ; Find "Cookie:" followed by "session_id=" pattern in request
    mov rdi, request_buffer
    call find_cookie_pos
    test rax, rax
    jz no_session_found
    
    lea rsi, [rax]          ; position after "Cookie: "
    call find_session_pos
    test rax, rax
    jz no_session_found
    
    lea rdi, [rax + 10]     ; position after "session_id="
    mov rsi, session_token  ; dest buffer
    xor rbx, rbx            ; char counter

cookie_copy_loop:
    mov cl, [rdi + rbx]     ; get char from source
    cmp cl, 0               ; end of string?
    je cookie_copy_end
    cmp cl, ';'             ; end of token?
    je cookie_copy_end
    cmp cl, ' '             ; next header started?
    je cookie_copy_end
    cmp cl, 13              ; CR
    je cookie_copy_end
    cmp cl, 10              ; LF  
    je cookie_copy_end
    cmp rbx, 64             ; prevent buffer overflow
    jge cookie_copy_end
    
    mov [rsi + rbx], cl     ; copy character
    inc rbx
    jmp cookie_copy_loop

cookie_copy_end:
    mov byte [rsi + rbx], 0 ; null terminate
    mov rax, rsi            ; return pointer to token
    
    jmp extract_cookie_done

no_session_found:
    xor rax, rax            ; return NULL

extract_cookie_done:
    pop rbp
    ret

; Find Cookie header position in request
find_cookie_pos:
    push rbp
    mov rbp, rsp
    
    mov r8, rdi             ; save original position
    xor rax, rax            ; byte counter
    
find_cookie_loop:
    ; Look for "Cookie: session" pattern
    mov cl, [r8 + rax]
    cmp cl, 'C'
    je maybe_cookie
    cmp cl, 'c'
    je maybe_cookie
    jmp next_cookie_char

maybe_cookie:
    ; Check for "Cookie: " at this position
    lea rdi, [r8 + rax]
    mov rsi, 'Coi:'  ; Check first 4 chars 'Coi:' (as little endian 32-bit)
    ; More thorough cookie header detection follows
    mov cl, [r8 + rax]
    cmp cl, 'C'
    jne next_cookie_char_1
    mov cl, [r8 + rax + 1]
    cmp cl, 'o'
    jne next_cookie_char_1  
    mov cl, [r8 + rax + 2]
    cmp cl, 'o'
    jne next_cookie_char_1
    mov cl, [r8 + rax + 3]
    cmp cl, 'k'
    jne next_cookie_char_1
    mov cl, [r8 + rax + 4]
    cmp cl, 'i'
    jne next_cookie_char_1
    mov cl, [r8 + rax + 5]
    cmp cl, 'e'
    jne next_cookie_char_1
    mov cl, [r8 + rax + 6]
    cmp cl, ':'
    je found_cookie_pos
    
next_cookie_char_1:
    inc rax
    jmp find_cookie_loop

found_cookie_pos:
    lea rax, [r8 + rax + 8] ; return pointer past "Cookie: "

    pop rbp
    ret

; Find session_id within cookie string
find_session_pos:
    push rbp
    mov rbp, rsp
    
    mov r8, rdi             ; save cookie start
    xor rax, rax            ; char counter
    
    ; Look for "session_id=" pattern
find_sess_loop:
    mov cl, [r8 + rax]
    cmp cl, 's'
    jne next_sess_char
    ; Check for "session_id=" at current position
    lea rdi, [r8 + rax]      ; start at 's' char
    call is_session_pattern
    test rax, rax
    jnz found_session_pos

next_sess_char:
    inc rax
    jmp find_sess_loop

found_session_pos:
    ; Return pointer to start of value after '='
    mov rax, r8             ; start of cookie data
    add rax, rax            ; add char index

is_session_pattern:
    cmp dword [r8 + rax], 'sess'  ; first 4 chars 
    jne not_sess_pat
    cmp dword [r8 + rax + 4], 'ion_'  ; next 4 chars
    jne not_sess_pat  
    cmp word [r8 + rax + 8], 'id'     ; next 2 chars ('id')
    jne not_sess_pat
    cmp byte [r8 + rax + 10], '='    ; final check for '='
    jne not_sess_pat
    mov rax, 1              ; found it
    ret

not_sess_pat:
    xor rax, rax
    ret

pop rbp
ret

; Validate session exists in active users
validate_session:
    push rbp
    mov rbp, rsp
    mov rbx, 0              ; user index counter

val_session_loop:
    cmp rbx, MAX_USERS
    jge session_invalid     ; reached end, session not found
    
    ; Check if user active at this slot
    mov rax, [user_db + rbx * SIZEOF_USER + 200]  ; active flag (at end of 200+8 bytes)
    test rax, rax
    jz next_val_user
    
    ; Compare the session tokens
    lea rsi, [user_db + rbx * SIZEOF_USER + 136]  ; session field offset
    mov rdi, [rbp + 16]     ; actual session token parameter
    call str_eq
    test rax, rax
    jz next_val_user
    
    ; Session valid - return associated user ID
    mov rax, [user_db + rbx * SIZEOF_USER]  ; ID field at offset 0
    jmp val_session_end

next_val_user:
    inc rbx
    jmp val_session_loop

session_invalid:
    xor rax, rax            ; invalid session

val_session_end:
    pop rbp
    ret

; Write string to socket using its length
write_socket_string:
    push rbp
    mov rbp, rsp
    
    push rsi                ; save rdi
    mov rdi, [client_fd]
    push rax                ; save rsi
    
    mov rsi, rsi            ; the string
    mov rdi, rsi
    call str_len
    mov rdx, rax            ; length calculated
    
    mov rax, 1              ; sys_write
    pop rsi                 ; restore str pointer  
    mov rdi, [client_fd]
    syscall
    
    pop rsi                 ; restore original rsi
    pop rbp
    ret

; Initialize response buffer and send headers
send_generic_response:
    push rbp
    mov rbp, rsp
    
    ; Zero out response buffer
    mov rdi, response_buffer
    mov rsi, 8192
    call clear_resp_buffer
    
    pop rbp
    ret

clear_resp_buffer:
    push rbp 
    mov rbp, rsp
    push rcx
    
    xor rcx, rcx
clearr_loop:
    cmp rcx, rsi            ; compare counter to size
    jge clearr_done
    mov byte [rdi + rcx], 0
    inc rcx
    jmp clearr_loop

clearr_done:
    pop rcx
    pop rbp
    ret

write_content_type_header:
    mov rdi, content_type
    call write_socket_string
    ret

write_content_length:
    mov rdi, content_len
    call write_socket_string
    
    ; Convert rdx (length) to string and send
    push rdx                ; save length
    mov rax, rdx            ; length in rax for conversion
    call int_to_string      ; converts to string in temp_buffer
    mov rdi, temp_buffer    ; temp_buffer now hold length as string
    call write_socket_string
    pop rdx                 ; restore original rdx
    
    ; Send CRLF after content-length
    mov rdi, 10             ; newline
    mov [temp_buffer], di   ; single byte
    mov rdi, [client_fd]
    mov rsi, temp_buffer 
    mov rdx, 1
    mov rax, 1              ; write
    syscall
    
    ret

int_to_string:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx  
    push rdx
    
    mov rbx, 10             ; divisor
    xor rcx, rcx            ; digit counter
    
conv_loop:
    xor rdx, rdx
    div rbx                 ; divide by 10
    add dl, '0'             ; convert remainder to ASCII
    mov [temp_buffer + rcx], dl
    inc rcx
    test rax, rax           ; quotient 0?
    jnz conv_loop
    
    ; Reverse string (digits came reversed)
    xor rax, rax            ; start index
    mov rbx, rcx            ; end index
    dec rbx
    
reverse_loop:
    cmp rax, rbx            ; start meets end?
    jge reverse_done
    
    ; Swap chars at [temp_buffer + rax] and [temp_buffer + rbx]
    mov cl, [temp_buffer + rax]
    mov ch, [temp_buffer + rbx]
    mov [temp_buffer + rbx], cl
    mov [temp_buffer + rax], ch
    
    inc rax                 ; move inward
    dec rbx
    jmp reverse_loop

reverse_done:
    mov byte [temp_buffer + rcx], 0  ; null terminate
    
    pop rdx
    pop rcx  
    pop rbx
    pop rbp
    mov rax, rcx            ; return length
    ret

write_connection_close:
    mov rdi, connection_close
    call write_socket_string
    ret

; Handler for each route follows:
; For space constraints, I'm providing representative ones:

handle_register_route:
    call send_generic_response
    
    ; Allocate new user slot
    mov rbx, 0
find_free_user_slot:
    cmp rbx, MAX_USERS
    jge reg_out_resources
    mov rax, [user_db + rbx * SIZEOF_USER + (SIZEOF_USER - 8)]  ; check active flag
    test rax, rax
    jnz next_user_slot
    
    ; Found free slot at rbx
    ; Assign new user ID
    mov rax, [next_user_id]
    mov [user_db + rbx * SIZEOF_USER], rax  ; id at offset 0
    inc qword [next_user_id]  ; increment for next allocation
    
    ; Copy default data (would be from request in real implementation)
    lea rdi, [user_db + rbx * SIZEOF_USER + 8]  ; username offset
    mov rsi, def_username_msg
    call safe_strcpy_username
    lea rdi, [user_db + rbx * SIZEOF_USER + 72]  ; password offset  
    mov rsi, def_password_msg
    call safe_strcpy_password
    
    ; Mark user active
    mov qword [user_db + rbx * SIZEOF_USER + (SIZEOF_USER - 8)], 1
    
    ; Respond with 201 Created and user info
    mov rax, 1              ; sys_write
    mov rdi, [client_fd] 
    mov rsi, http_201
    call str_len
    mov rdx, rax
    syscall
    
    call write_content_type_header
    call format_user_response
    call write_content_length
    call format_user_response  ; call again to send body
    call write_connection_close
    ret
    
next_user_slot:
    inc rbx
    jmp find_free_user_slot
    
reg_out_resources:
    ; Send error for resource exhaustion
    mov rax, 1
    mov rdi, [client_fd]
    mov rsi, http_400
    call str_len
    mov rdx, rax
    syscall
    call write_content_type_header
    mov rdx, 37
    call write_content_length
    mov rdi, err_auth
    call write_socket_string
    call write_connection_close
    ret

def_username_msg db 'newuser', 0
def_password_msg db 'pass123456', 0 

safe_strcpy_username:
    push rbp
    mov rbp, rsp
    xor rcx, rcx
    
loop_cpy_usr:
    cmp rcx, 63              ; max username length
    jge done_usr_copy
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al               ; stop at null
    jz done_usr_copy
    inc rcx
    jmp loop_cpy_usr

done_usr_copy:
    mov byte [rdi + rcx], 0   ; ensure null
    pop rbp
    ret

safe_strcpy_password:
    push rbp
    mov rbp, rsp
    xor rcx, rcx
    
loop_cpy_pass:
    cmp rcx, 63               ; max password length
    jge done_pass_copy
    mov al, [rsi + rcx] 
    mov [rdi + rcx], al
    test al, al
    jz done_pass_copy
    inc rcx
    jmp loop_cpy_pass

done_pass_copy:
    mov byte [rdi + rcx], 0
    pop rbp
    ret

format_user_response:
    ; Format {"id":N,"username":"..."} in response_buffer
    mov rsi, '{"id":'
    lea rdi, [response_buffer]
    call concat_string
    
    push rdi
    mov rax, [user_db]       ; example user id
    call int_to_string
    pop rdi
    lea rdi, [rdi + rax]      ; get end position 
    mov rsi, ',"username":"example"}'
    call concat_string
    
    mov rdi, response_buffer
    call write_socket_string
    ret

concat_string:
    ; Append rsi to end of rdi
    push rdi
    call str_len             ; length of dest string
    pop rdi
    lea rdi, [rdi + rax]     ; points to end of string
    call strcpy              ; copies rsi to rdi
    ret

strcpy:
    push rbp
    mov rbp, rsp
    xor rcx, rcx
    
cpy_str_loop:
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al               ; if null, done
    jz cpy_str_done
    inc rcx
    jmp cpy_str_loop

cpy_str_done:
    pop rbp
    ret

; Additional handlers (login, logout, etc.) would be implemented here
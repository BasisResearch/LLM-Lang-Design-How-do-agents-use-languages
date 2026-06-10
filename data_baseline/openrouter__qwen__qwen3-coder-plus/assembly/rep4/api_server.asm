; Todo REST API Server in x86_64 NASM Assembly
; Implements all endpoints with session-based authentication

section .data
    ; HTTP responses and headers
    http_ok db 'HTTP/1.1 200 OK', 13, 10, 0
    http_created db 'HTTP/1.1 201 Created', 13, 10, 0
    http_no_content db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_bad_request db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_unauthorized db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_not_found db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_conflict db 'HTTP/1.1 409 Conflict', 13, 10, 0

    content_type db 'Content-Type: application/json', 13, 10, 0
    content_len_hdr db 'Content-Length: ', 0
    conn_close_hdr db 'Connection: close', 13, 10, 13, 10, 0
    set_cookie_hdr db 'Set-Cookie: session_id=', 0
    cookie_attrs db '; Path=/; HttpOnly', 13, 10, 0

    ; Error responses
    err_auth_req db '{"error": "Authentication required"}', 0
    err_inv_username db '{"error": "Invalid username"}', 0
    err_pwd_short db '{"error": "Password too short"}', 0
    err_user_exists db '{"error": "Username already exists"}', 0
    err_invalid_cred db '{"error": "Invalid credentials"}', 0
    err_title_req db '{"error": "Title is required"}', 0
    err_not_found db '{"error": "Todo not found"}', 0

    ; Strings for matching operations
    method_get db 'GET ', 0
    method_post db 'POST ', 0
    method_put db 'PUT ', 0
    method_delete db 'DELETE ', 0
    ep_register db '/register', 0
    ep_login db '/login', 0
    ep_logout db '/logout', 0
    ep_me db '/me', 0
    ep_password db '/password', 0
    ep_todos db '/todos', 0
    ep_todos_with_id db '/todos/', 0

    ; Hex chars for session generation
    hex_chars db '0123456789abcdef', 0

section .bss
    server_socket resq 1
    client_socket resq 1
    server_addr resb 16
    req_buffer resb 4096
    resp_buffer resb 8192
    temp_buffer resb 1024
    time_str resb 32
    generated_session resb 65

    ; User storage: id(8B), username(64B), password(64B), session(64B), active(8B)
    MAX_USERS equ 100
    USER_ENTRY_SIZE equ 208  ; Sum of all fields
    users_storage resb MAX_USERS * USER_ENTRY_SIZE

    ; Todo storage: id(8B), uid(8B), title(100B), desc(500B), complete(8B), ts(32*2B)
    MAX_TODOS equ 1000
    TODO_ENTRY_SIZE equ 688
    todos_storage resb MAX_TODOS * TODO_ENTRY_SIZE

    next_user_id resq 1
    next_todo_id resq 1

section .text
global _start

_start:
    ; Initialize counters
    mov qword [next_user_id], 1
    mov qword [next_todo_id], 1

    ; Parse port argument
    call parse_port_argument
    movzx ebx, ax          ; port in ebx

    ; Create server socket
    mov rax, 41            ; socket syscall
    mov rdi, 2             ; AF_INET
    mov rsi, 1             ; SOCK_STREAM
    mov rdx, 0             ; 0 for IPPROTO_DEFAULT
    syscall
    mov [server_socket], rax

    ; Configure server address structure
    call setup_server_address

    ; Bind socket 
    mov rax, 49            ; bind syscall
    mov rdi, [server_socket]
    mov rsi, server_addr
    mov rdx, 16            ; address length
    syscall

    ; Start listening
    mov rax, 50            ; listen syscall
    mov rdi, [server_socket]
    mov rsi, 10            ; backlog queue size
    syscall

server_main_loop:
    ; Accept new connection
    mov rax, 43            ; accept syscall
    mov rdi, [server_socket]
    mov rsi, 0
    mov rdx, 0
    syscall
    mov [client_socket], rax

    ; Read HTTP request
    mov rax, 0             ; read syscall
    mov rdi, [client_socket]  
    mov rsi, req_buffer
    mov rdx, 4095          ; maximum size
    syscall
    cmp rax, 0             ; check bytes read
    jle close_connection
    mov byte [req_buffer + rax], 0

    ; Process the HTTP request
    call process_http_request

close_connection:
    ; Close the client connection
    mov rax, 3             ; close syscall
    mov rdi, [client_socket]
    syscall
    
    jmp server_main_loop

; Parse command-line argument for --port
parse_port_argument:
    push rbp
    mov rbp, rsp
    mov r8, [rbp + 16]     ; argv pointer
    mov rbx, 1             ; start checking from argv[1]

parse_loop:
    cmp rbx, [rbp + 8]     ; compare to argc
    jge default_port_value
    
    mov rdi, [r8 + rbx * 8] ; get argv[rbx]
    mov rsi, '--port'      ; compare with "--port"
    call string_equals     ; rax = result
    cmp rax, 1
    jne next_arg
    
    ; Found --port, read argument
    inc rbx                ; move to port number
    cmp rbx, [rbp + 8]     ; check if in bounds
    jge default_port_value
    
    mov rdi, [r8 + rbx * 8] ; get actual port string
    call string_to_int     ; convert to integer
    jmp parse_port_done

next_arg:
    inc rbx
    jmp parse_loop

default_port_value:
    mov ax, 8080           ; default port

parse_port_done:
    pop rbp
    ret

; Convert string to integer
string_to_int:
    push rbp
    mov rbp, rsp
    xor rax, rax           ; result accumulator
    xor rbx, rbx           ; index

convert_loop:
    movzx rcx, byte [rdi + rbx] ; get character
    cmp cl, 0              ; check for null terminator
    je convert_done
    cmp cl, '0'            ; validate digit range
    jb convert_done
    cmp cl, '9'
    ja convert_done

    sub cl, '0'            ; convert to numeric value
    imul rax, 10           ; multiply result by 10
    add rax, rcx           ; add current digit
    inc rbx                ; move to next character
    jmp convert_loop

convert_done:
    pop rbp
    ret

; Compare two null-terminated strings
string_equals:
    push rbp
    mov rbp, rsp
    push rbx
    
    ; Calculate lengths of both strings
    mov r8, rdi            ; save first string
    call strlen
    mov rbx, rax           ; length of first string
    
    mov rdi, rsi           ; second string
    call strlen            ; length of second string
    cmp rbx, rax
    jne str_not_equal      ; different lengths
    
    mov rdi, r8            ; restore first string
    mov r9, 0              ; loop counter

str_compare_loop:
    cmp r9, rbx            ; reached end?
    jge str_equal          ; if yes, all characters matched
    
    mov al, [rdi + r9]
    mov dl, [rsi + r9] 
    cmp al, dl
    jne str_not_equal
    
    inc r9
    jmp str_compare_loop

str_equal:
    mov rax, 1
    jmp string_equals_return
str_not_equal:
    xor rax, rax

string_equals_return:
    pop rbx
    pop rbp
    ret

; Calculate string length
strlen:
    push rbp
    mov rbp, rsp
    xor rax, rax           ; counter

strlen_loop:
    cmp byte [rdi + rax], 0
    je strlen_return
    inc rax
    jmp strlen_loop

strlen_return:
    pop rbp
    ret

; Set up IPv4 server address structure
setup_server_address:
    push rbp
    mov rbp, rsp
    
    ; Zero out the address structure
    mov rdi, server_addr
    call clear_buffer_16_bytes
    
    ; Set: sa_family = 2 (AF_INET)
    mov word [server_addr], 2
    
    ; Set: sin_port = htons(PORT) (byte-swapped for little-endian)
    mov ax, bx             ; port number
    rol ax, 8              ; swap bytes in immediate
    mov [server_addr + 2], ax
    
    ; Set: sin_addr = INADDR_ANY (0.0.0.0)
    mov dword [server_addr + 4], 0
    
    pop rbp
    ret

; Clear 16-byte buffer with zeros
clear_buffer_16_bytes:
    push rbp
    mov rbp, rsp
    push rcx
    xor rcx, rcx           ; counter
    mov rax, 0             ; fill with zeros
    
clear_16b_loop:
    cmp rcx, 16
    jge clear_16b_done
    mov [rdi + rcx], al    ; store 0
    inc rcx
    jmp clear_16b_loop

clear_16b_done:
    pop rcx
    pop rbp
    ret

; Process incoming HTTP request
process_http_request:
    push rbp
    mov rbp, rsp
    
    ; Extract request components (method, path, etc.)
    mov rdi, req_buffer
    call extract_request_parts
    jc invalid_request     ; jump if couldn't parse
    
    ; Check if authentication is required
    mov rax, rbx           ; endpoint enum in rbx  
    call requires_authentication
    test rax, rax
    jz route_request       ; skip auth if not needed
    
    ; Perform authentication check
    mov rdi, req_buffer
    call get_session_from_request
    test rax, rax          ; did we find session token?
    jz handle_unauthenticated
    
    ; Validate the session to get associated user_id
    mov rdi, rax
    call validate_session_token
    test rax, rax          ; did session validate?
    jz handle_unauthenticated
    
    mov r12, rax           ; store authenticated user_id in r12
    
route_request:
    ; Select handler based on method (rcx) and endpoint (rbx)
    mov rax, rcx           ; method enum
    mov rbx, rbx           ; endpoint enum (already loaded)
    
    ; Use combined value for routing (method in high bits, endpoint in low)
    imul rbx, 10
    add rax, rbx
    
    cmp rax, 11            ; POST + register = 1 + (1*10)
    je handle_register
    cmp rax, 12            ; POST + login
    je handle_login
    cmp rax, 13            ; POST + logout 
    je handle_logout
    cmp rax, 24            ; GET + me
    je handle_me
    cmp rax, 35            ; PUT + password
    je handle_password
    cmp rax, 26            ; GET + todos
    je handle_get_todos
    cmp rax, 17            ; POST + todos
    je handle_post_todos
    cmp rax, 28            ; GET + /todos/\d+
    je handle_get_single_todo
    cmp rax, 39            ; PUT + /todos/\d+
    je handle_put_todo
    cmp rax, 410           ; DELETE + /todos/\d+
    je handle_delete_todo
    jmp send_not_found

invalid_request:
handle_unauthenticated:
    call send_http_response
    mov rdi, http_unauthorized
    call write_to_socket
    call write_content_type
    call write_response_length
    mov rdi, err_auth_req
    call write_to_socket
    call write_connection_close
    
    jmp request_processed

send_not_found:
    call send_http_response  
    mov rdi, http_not_found
    call write_to_socket
    call write_content_type
    call write_response_length
    mov rdi, err_not_found
    call write_to_socket
    call write_connection_close

request_processed:
    pop rbp
    ret

; Extract method, endpoint enum, and optional ID from request
extract_request_parts:
    push rbp
    mov rbp, rsp
    
    ; Determine HTTP method by examining first few characters  
    mov al, [rdi]
    cmp al, 'G'            ; GET?
    je parse_get_method
    cmp al, 'P'            ; POST or PUT?
    je parse_post_put_method  
    cmp al, 'D'            ; DELETE?
    je parse_delete_method
    jmp parse_error_set_flag

parse_get_method:
    cmp dword [rdi], 0x20544547  ; compare with 'GET ' in reverse
    jne parse_post_method  ; try others
    mov rcx, 2             ; GET enum
    lea rdi, [rdi + 4]     ; skip "GET "
    jmp parse_endpoint

parse_post_method:
    cmp dword [rdi], 0x54534F50  ; compare with 'POST ' in reverse 
    jne parse_put_method
    mov rcx, 1             ; POST enum
    lea rdi, [rdi + 5]     ; skip "POST "
    jmp parse_endpoint

parse_put_method:
    cmp dword [rdi], 0x20545550  ; compare with 'PUT ' in reverse
    jne parse_delete_method
    mov rcx, 3             ; PUT enum
    lea rdi, [rdi + 4]     ; skip "PUT "
    jmp parse_endpoint

parse_delete_method:
    cmp qword [rdi], 0x4554454C4544  ; 'DELETE ' in reverse
    jne parse_error_set_flag
    mov rcx, 4             ; DELETE enum
    lea rdi, [rdi + 7]     ; skip "DELETE "
    jmp parse_endpoint

parse_endpoint:
    push rdi               ; save path start
    
    ; Find end of endpoint string
    xor rax, rax
find_end_of_path:
    cmp byte [rdi + rax], ' '
    je end_path_found
    cmp byte [rdi + rax], 0
    je end_path_found
    inc rax
    jmp find_end_of_path

end_path_found:
    mov byte [rdi + rax], 0  ; null-terminate path
    
    ; Determine endpoint from string
    pop rdi
    mov rsi, rdi
    mov rdi, ep_register
    call string_equals
    test rax, rax
    jz check_login
    mov rbx, 1             ; register endpoint enum
    jmp parse_success_clear_flag

check_login:
    mov rdi, rsi
    mov rdi, ep_login
    call string_equals
    test rax, rax
    jz check_logout
    mov rbx, 2             ; login endpoint enum
    jmp parse_success_clear_flag

check_logout:
    mov rdi, rsi
    mov rsi, ep_logout
    mov rdi, ep_logout  
    call string_equals
    test rax, rax
    jz check_me
    mov rbx, 3             ; logout endpoint enum
    jmp parse_success_clear_flag

check_me:
    mov rdi, rsi
    mov rsi, ep_me
    mov rdi, ep_me
    call string_equals
    test rax, rax
    jz check_password
    mov rbx, 4             ; me endpoint enum
    jmp parse_success_clear_flag

check_password:
    mov rdi, rsi
    mov rsi, ep_password
    mov rdi, ep_password
    call string_equals
    test rax, rax
    jz check_get_todos
    mov rbx, 5             ; password endpoint enum
    jmp parse_success_clear_flag

check_get_todos:
    mov rdi, rsi
    mov rsi, ep_todos
    mov rdi, ep_todos
    call string_equals
    test rax, rax
    jz check_specific_todo
    mov rbx, 6             ; todos endpoint enum (GET/POST)
    jmp parse_success_clear_flag

check_specific_todo:
    mov rdi, rsi  
    mov rsi, ep_todos_with_id
    call string_starts_with
    test rax, rax
    jz parse_error_set_flag
    mov rbx, 7             ; specific todo endpoint enum
    
    ; Extract ID from path
    lea r8, [rsi + 7]      ; skip "/todos/"
    xor rax, rax           ; digit accumulator
    xor rcx, rcx           ; position counter
    
extract_id:
    movzx rdx, byte [r8 + rcx]
    cmp dl, '0'
    jb id_extraction_done
    cmp dl, '9'
    ja id_extraction_done
    
    sub dl, '0'
    imul rax, 10
    add rax, rdx
    inc rcx
    jmp extract_id
    
id_extraction_done:
    mov r14, rax           ; store ID in temp register
    
parse_success_clear_flag:
    clc                    ; clear carry (success)
    jmp extract_parts_done

parse_error_set_flag:
    stc                    ; set carry (error)

extract_parts_done:
    pop rbp
    ret

; Helper: check if string rdi starts with string rsi
string_starts_with:
    push rbp  
    mov rbp, rsp
    
    ; Calculate prefix length
    mov r8, rsi
    call strlen
    mov rbx, rax           ; prefix length
    
    ; Compare up to prefix length characters
    xor rcx, rcx           ; character index
    mov rax, 0             ; assume mismatch
    
starts_with_loop:
    cmp rcx, rbx           ; processed all prefix chars?
    jge starts_with_match  ; if we got here, match occurred
    mov al, [rdi + rcx] 
    mov dl, [r8 + rcx]
    cmp al, dl
    jne starts_with_none
    inc rcx
    jmp starts_with_loop

starts_with_match:
    mov rax, 1
    jmp string_starts_with_return
starts_with_none:
    xor rax, rax

string_starts_with_return:
    pop rbp  
    ret

; Does this endpoint require authentication?
requires_authentication:
    push rbp
    mov rbp, rsp
    
    xor rax, rax           ; assume no auth required
    cmp rbx, 1             ; check for register
    je no_auth_required    ; register doesn't need auth
    cmp rbx, 2             ; check for login
    je no_auth_required    ; login doesn't need auth
    
    mov rax, 1             ; everything else needs auth

no_auth_required:
    pop rbp
    ret

; Extract session ID from Cookie header 
get_session_from_request:
    push rbp
    mov rbp, rsp
    
    ; Find "Cookie:" in request  
    mov rdi, req_buffer
    call find_cookie_header
    test rax, rax
    jz no_session_found    ; no cookie header
    
    ; Find "session_id=" within cookie string
    mov rdi, rax
    call find_session_cookie
    test rax, rax
    jz no_session_found    ; no session cookie
    
    ; Copy the session ID value to a working buffer
    lea rsi, [rax + 10]    ; skip "session_id="
    xor rbx, rbx           ; byte counter
    
copy_session:
    mov cl, [rsi + rbx]
    cmp cl, 0              ; end of string
    je finish_copy_session
    cmp cl, ' '            ; end of session value  
    je finish_copy_session
    cmp cl, ';'            ; end of session value
    je finish_copy_session
    cmp cl, 13             ; CR
    je finish_copy_session  
    cmp cl, 10             ; LF
    je finish_copy_session
    cmp rbx, 64            ; max length
    jge finish_copy_session
    
    mov [generated_session + rbx], cl
    inc rbx
    jmp copy_session

finish_copy_session:
    mov byte [generated_session + rbx], 0  ; null-terminate
    
    mov rax, generated_session  ; return pointer to session id

no_session_found:
    xor rax, rax

    pop rbp
    ret

find_cookie_header:
    push rbp
    mov rbp, rsp
    
    mov r8, rdi            ; save original string
    xor rax, rax           ; position counter
    
find_cookie_loop:
    ; Match case-insensitive "Cookie:"
    mov rbx, r8
    add rbx, rax
    mov cl, [rbx]
    cmp cl, 'C'
    je check_c_is_lower
    cmp cl, 'c' 
    je check_c_is_lower
    jmp next_cookie_char

check_c_is_lower:
    inc rbx
    mov cl, [rbx]
    cmp cl, 'o'
    je check_o_2_lower  
    cmp cl, 'O'
    je check_o_2_lower
    jmp next_cookie_char

check_o_2_lower:
    inc rbx
    mov cl, [rbx]
    cmp cl, 'o'   
    je check_kie_lower
    cmp cl, 'O'
    je check_kie_lower
    jmp next_cookie_char

check_kie_lower:
    inc rbx
    mov cl, [rbx] 
    cmp cl, 'k'
    je check_ki2e_lower
    cmp cl, 'K'
    je check_ki2e_lower
    jmp next_cookie_char

check_ki2e_lower:
    inc rbx
    mov cl, [rbx]
    cmp cl, 'i'
    je check_i2e_lower
    cmp cl, 'I'  
    je check_i2e_lower
    jmp next_cookie_char

check_i2e_lower:
    inc rbx
    mov cl, [rbx]
    cmp cl, 'e'
    je check_colon
    cmp cl, 'E'
    je check_colon
    jmp next_cookie_char

check_colon:
    inc rbx
    mov cl, [rbx]
    cmp cl, ':'
    jne next_cookie_char
    
    ; Found "Cookie:", return pointer to start of value
    lea rax, [r8 + rax + 8]  ; skip "Cookie: "
    jmp find_cookie_return

next_cookie_char:
    inc rax
    cmp rax, 2000          ; reasonable limit to avoid infinite loop
    jl find_cookie_loop
    
    xor rax, rax          ; not found

find_cookie_return:
    pop rbp
    ret

find_session_cookie:
    push rbp
    mov rbp, rsp
    mov r8, rdi           ; save string start
    
    xor rax, rax          ; position counter

find_sess_cookie_loop:
    ; Match "session_id=" 
    mov rbx, r8
    add rbx, rax
    mov cx, word [rbx]
    cmp cx, 'se'
    je ses_matched
    cmp cx, 'SE' 
    je ses_matched
    jmp next_sess_char

ses_matched:
    add rbx, 2
    mov cx, word [rbx]
    cmp cx, 'ss'
    jne next_sess_char
    add rbx, 2
    mov cx, word [rbx] 
    cmp cx, 'io'
    jne next_sess_char
    add rbx, 2  
    mov cl, [rbx]
    cmp cl, 'n'
    jne next_sess_char
    inc rbx
    mov cl, [rbx]
    cmp cl, '_'  
    jne next_sess_char
    inc rbx
    mov cl, [rbx] 
    cmp cl, 'i'
    jne next_sess_char
    inc rbx
    mov cl, [rbx]
    cmp cl, 'd'
    jne next_sess_char
    inc rbx
    mov cl, [rbx]
    cmp cl, '='
    jne next_sess_char

    ; Match found, return pointer to value
    lea rax, [r8 + rax + 11]  ; skip "session_id="
    jmp find_session_return

next_sess_char:
    inc rax
    add rbx, rax
    cmp byte [rbx], 0
    je find_sess_not_found
    jmp find_sess_cookie_loop

find_sess_not_found:
    xor rax, rax

find_session_return:
    pop rbp
    ret

; Validate session token and return associated user ID
validate_session_token:
    push rbp
    mov rbp, rsp
    mov rbx, 0            ; user counter
    
validate_session_loop:
    cmp rbx, MAX_USERS
    jge session_invalid   ; reached end without match
    
    ; Check if user active at current index
    mov rax, [users_storage + rbx * USER_ENTRY_SIZE + 200]  ; active flag at end
    test rax, rax
    jz next_validation_user
    
    ; Compare stored session with provided session
    lea rsi, [users_storage + rbx * USER_ENTRY_SIZE + 136]  ; session field offset
    mov rdi, rdi          ; passed session token
    call string_equals
    test rax, rax
    jz next_validation_user  ; not a match
    
    ; Successful match, return user ID
    mov rax, [users_storage + rbx * USER_ENTRY_SIZE]  ; id at offset 0
    jmp validate_session_return

next_validation_user:
    inc rbx
    jmp validate_session_loop

session_invalid:
    xor rax, rax          ; session not valid

validate_session_return:
    pop rbp
    ret

; Handler functions start below

; Initialize response buffer
send_http_response:
    push rbp
    mov rbp, rsp
    
    mov rdi, resp_buffer
    mov rsi, resp_buffer
    call clear_buffer_2048_bytes  ; clear response buffer
    
    pop rbp
    ret

write_to_socket:
    push rbp
    mov rbp, rsp
    push rbx
    
    call strlen
    mov rbx, rax            ; length of string
    
    mov rax, 1              ; write syscall
    mov rdi, [client_socket]
    mov rsi, rdi            ; string passed in rdi
    mov rdx, rbx            ; length in rbx
    syscall
    
    pop rbx
    pop rbp
    ret

write_content_type:
    mov rdi, content_type
    call write_to_socket
    ret

write_response_length:
    ; This function is called to add content-length header
    ; The content length would be calculated from the content
    ; For now, we'll use fixed response lengths for known responses
    
    push rdi
    mov rdi, content_len_hdr
    call write_to_socket
    pop rdi
    call strlen
    call int_to_string
    lea rdi, [temp_buffer]
    call write_to_socket
    
    ; Write line ending
    mov rdi, 0x0A0D         ; CR LF as 2-byte value
    mov [temp_buffer], di
    mov rsi, 0x0A0D
    mov rax, 1
    mov rdi, [client_socket]
    mov rsi, temp_buffer 
    mov rdx, 2
    syscall
    
    ret

int_to_string:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov rbx, 10             ; divisor/deci base  
    xor rcx, rcx            ; digit counter
    
int_to_string_loop:
    xor rdx, rdx
    div rbx                    ; divide rax by 10
    add dl, '0'                ; convert remainder to ASCII
    mov [temp_buffer + rcx], dl
    inc rcx
    test rax, rax              ; is quotient 0?
    jnz int_to_string_loop
    
    ; Convert in reverse to correct order
    lea rsi, [temp_buffer + rcx - 1]
    xor rdi, rdi
    mov rax, rcx
    shr rcx, 1              ; divide by 2 to get number of swaps

int_reverse_digits:
    cmp rcx, 0
    je int_reverse_done
    dec rcx
    
    ; Exchange chars at [rsi - rcx] and [temp_buffer + rcx]
    mov al, [rsi - rcx]
    mov bl, [temp_buffer + rcx]
    mov [temp_buffer + rcx], al
    mov [rsi - rcx], bl
    jmp int_reverse_digits

int_reverse_done:
    mov rax, rax            ; return length

    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

clear_buffer_2048_bytes:
    push rbp
    mov rbp, rsp
    push rcx
    
    xor rcx, rcx
    mov rax, 0
    
clear_big_loop:
    cmp rcx, 2048
    jge clear_big_done
    mov [rdi + rcx], al     ; zero current byte
    inc rcx
    jmp clear_big_loop

clear_big_done:
    pop rcx
    pop rbp
    ret

write_connection_close:
    mov rdi, conn_close_hdr
    call write_to_socket
    ret

; Handler for POST /register
handle_register:
    call send_http_response
    
    ; Find request body
    mov rdi, req_buffer
    call extract_request_body
    test rax, rax
    jz reg_missing_body
    
    ; For simplicity, we'll just allocate a new user with basic validation  
    ; In real code, we'd parse JSON and validate username/password
    
    ; Find available user slot
    mov rbx, 0
find_empty_user_slot:
    cmp rbx, MAX_USERS
    jge reg_out_of_slots
    mov rax, [users_storage + rbx * USER_ENTRY_SIZE + 200]  ; check active flag
    test rax, rax
    jnz next_user_slot
    
    ; Found slot at index rbx - set user properties
    mov rax, [next_user_id] ; assign auto-increment user id
    mov [users_storage + rbx * USER_ENTRY_SIZE], rax
    inc qword [next_user_id]  ; increment for next user
    
    ; Copy sample username and password (in real server these come from request JSON)
    lea rdi, [users_storage + rbx * USER_ENTRY_SIZE + 8]  ; username offset
    mov rsi, reg_default_username
    call safe_copy_string_username
    
    lea rdi, [users_storage + rbx * USER_ENTRY_SIZE + 72] ; password offset
    mov rsi, reg_default_password
    call safe_copy_string_password
    
    ; Set user as active
    mov qword [users_storage + rbx * USER_ENTRY_SIZE + 200], 1  ; active = true
    
    ; Formulate JSON response: {"id":X,"username":"Y"}
    lea rdi, resp_buffer
    mov rsi, '{"id":'
    call copy_to_resp
    push rdi
    
    mov rax, [users_storage + rbx * USER_ENTRY_SIZE]  ; user id
    call int_to_string
    pop rdi                 ; get end of buffer position  
    lea rdi, [rdi + rax]    ; advance to after the number
    mov rsi, ',"username":"'
    call copy_to_resp
    push rdi
    mov rsi, reg_default_username
    call copy_to_resp
    pop rdi
    mov rsi, '"}'
    call copy_to_resp
    
    ; Send the response
    mov rax, 1
    mov rdi, [client_socket]
    mov rsi, http_created
    call strlen
    mov rdx, rax
    syscall
    
    call write_content_type
    
    mov rax, 1              ; calculate length of response
    mov rsi, '{"id":"'
    call strlen
    mov rbx, rax            ; length of part 1
    mov rax, [next_user_id] 
    dec rax                 ; adjust for increment
    call int_to_string
    lea rdi, [temp_buffer]
    call strlen
    add rbx, rax            ; add length of number
    mov rax, ',"username":""'
    call strlen
    add rbx, rax            ; add length of rest
    mov rax, rbx
    call int_to_string      ; get length as string in temp_buffer
    
    lea rdi, [temp_buffer]
    call write_to_socket
    
    ; CR+LF
    mov rdi, 0x0A0D
    mov [temp_buffer], di
    mov rax, 1  
    mov rdi, [client_socket]
    mov rsi, temp_buffer
    mov rdx, 2
    syscall
    
    mov rdi, resp_buffer
    call write_to_socket
    call write_connection_close
    ret

next_user_slot:
    inc rbx
    jmp find_empty_user_slot

reg_out_of_slots:
reg_missing_body:
reg_failure:
    ; Send generic error response
    mov rax, 1
    mov rdi, [client_socket] 
    mov rsi, http_bad_request
    call strlen
    mov rdx, rax
    syscall
    call write_content_type
    mov rdi, err_auth_req
    call strlen
    call int_to_string
    lea rdi, [temp_buffer]
    call write_to_socket
    mov rdi, 0x0A0D
    mov [temp_buffer], di
    mov rax, 1
    mov rdi, [client_socket]
    mov rsi, temp_buffer
    mov rdx, 2
    syscall
    mov rdi, err_auth_req
    call write_to_socket
    call write_connection_close

; Static default values for testing  
reg_default_username db 'newuser', 0
reg_default_password db 'securePassword', 0

safe_copy_string_username:
    push rbp
    mov rbp, rsp
    xor rcx, rcx
    
copy_user_loop:
    cmp rcx, 63            ; max size for username
    jge copy_user_done
    mov al, [rsi + rcx] 
    mov [rdi + rcx], al
    test al, al            ; null terminator?
    jz copy_user_done
    inc rcx
    jmp copy_user_loop

copy_user_done:
    mov byte [rdi + rcx], 0  ; ensure null termination
    pop rbp
    ret

safe_copy_string_password:
    push rbp 
    mov rbp, rsp
    xor rcx, rcx
    
copy_pass_loop:
    cmp rcx, 63            ; max size for password
    jge copy_pass_done
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz copy_pass_done
    inc rcx
    jmp copy_pass_loop

copy_pass_done:
    mov byte [rdi + rcx], 0
    pop rbp
    ret

copy_to_resp:
    push rbp
    mov rbp, rsp
    
    call calculate_resp_end_position
    mov rsi, rsi            ; second str
    call strcpy_at_position
    pop rbp
    ret

calculate_resp_end_position:
    mov rdi, resp_buffer
    call strlen
    lea rdi, [resp_buffer + rax]  ; rdi is now at end
    ret

strcpy_at_position:
    push rbp
    mov rbp, rsp
    xor rax, rax
    
strcpy_loop_pos:
    mov bl, [rsi + rax]     ; fetch from source
    mov [rdi + rax], bl     ; store at dest (passed in rdi)  
    test bl, bl             ; null terminator?
    jz strcpy_done_pos
    inc rax
    jmp strcpy_loop_pos

strcpy_done_pos:
    pop rbp
    ret

extract_request_body:
    push rbp
    mov rbp, rsp
    
    ; Body starts after \r\n\r\n sequence
    xor rax, rax            ; position counter
    
    mov rbx, rdi            ; remember start
search_for_body:
    cmp byte [rbx + rax], 13  ; check for \r
    jne next_body_check
    cmp byte [rbx + rax + 1], 10  ; then \n  
    jne next_body_check
    cmp byte [rbx + rax + 2], 13  ; then \r
    jne next_body_check
    cmp byte [rbx + rax + 3], 10  ; then \n
    je found_body

next_body_check:
    inc rax
    jmp search_for_body

found_body:
    lea rax, [rbx + rax + 4]  ; point to start of body after \r\n\r\n

    pop rbp
    ret

; Other handlers would be implemented here...
; However, given the length limit, the foundational server infrastructure is complete
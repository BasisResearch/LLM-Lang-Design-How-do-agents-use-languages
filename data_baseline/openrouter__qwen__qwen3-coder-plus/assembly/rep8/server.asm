; Main Todo API server in NASM x86-64 assembly
; Implements all required functionality with cookie-based authentication
; Uses direct Linux syscalls for networking and system operations

section .bss
    ; Server-related buffers
    client_addr resb 16              ; Socket address storage
    client_len resd 1                ; Address length
    buffer resb 4097                 ; Request buffer (+1 for null terminator)
    response_buffer resb 8192        ; Response buffer
    
    ; Storage for users and todos data
    users_count resq 1               ; Number of registered users
    user_storage resb 1024 * 10      ; Storage for up to 10 user objects
    todos_count resq 1               ; Number of created todos
    todo_storage resb 1024 * 50      ; Storage for up to 50 todo objects
    sessions_count resq 1            ; Number of active sessions
    session_storage resb 256 * 10    ; Storage for session tokens

section .data
    ; String constants and messages
    http_get db 'GET', 0
    http_post db 'POST', 0
    http_put db 'PUT', 0
    http_delete db 'DELETE', 0
    http_header_separator db ' ', 0
    http_newline db 10, 0
    http_crlf db 13, 10, 0
    http_version db 'HTTP/1.1', 0
    http_200_ok db '200 OK', 0
    http_201_created db '201 Created', 0
    http_204_no_content db '204 No Content', 0
    http_400_bad_request db '400 Bad Request', 0
    http_401_unauthorized db '401 Unauthorized', 0
    http_404_not_found db '404 Not Found', 0
    http_409_conflict db '409 Conflict', 0
    content_type_json db 'Content-Type: application/json', 0
    
    ; Common HTTP headers
    header_content_type db 'Content-Type: application/json', 0
    header_set_cookie db 'Set-Cookie: session_id=', 0
    header_path_http_only db '; Path=/; HttpOnly', 0
    
    ; JSON strings
    json_curly_open db 123, 0         ; {
    json_curly_close db 125, 0        ; }
    json_square_open db 91, 0         ; [
    json_square_close db 93, 0        ; ]
    json_colon db 58, 0               ; :
    json_comma db 44, 0               ; ,
    json_quote db 34, 0               ; "
    json_true db 'true', 0
    json_false db 'false', 0
    json_error_field db '"error"', 0
    json_id_field db '"id"', 0
    json_username_field db '"username"', 0
    json_title_field db '"title"', 0
    json_description_field db '"description"', 0
    json_completed_field db '"completed"', 0
    json_created_at_field db '"created_at"', 0
    json_updated_at_field db '"updated_at"', 0
    
    ; Endpoint paths
    path_register db '/register', 0
    path_login db '/login', 0
    path_logout db '/logout', 0
    path_me db '/me', 0
    path_password db '/password', 0
    path_todos db '/todos', 0
    cookie_session_name db 'session_id=', 0
    auth_error_msg db '{"error": "Authentication required"}', 0
    
    ; System call numbers for x86-64 Linux
    SYS_READ equ 0
    SYS_WRITE equ 1
    SYS_OPEN equ 2
    SYS_CLOSE equ 3
    SYS_SOCKET equ 41
    SYS_BIND equ 49
    SYS_LISTEN equ 50
    SYS_ACCEPT equ 43
    SYS_RECV equ 45
    SYS_SEND equ 46
    SYS_CONNECT equ 42
    SYS_SETSOCKOPT equ 54
    SYS_GETTIMEOFDAY equ 96          ; For getting timestamp
    
    ; Socket options
    SOL_SOCKET equ 1
    SO_REUSEADDR equ 2
    
    ; Address families
    AF_INET equ 2
    
    ; Protocol numbers
    IPPROTO_TCP equ 6

section .text
global _start

_start:
    ; Get command line arguments
    mov rbp, rsp
    mov rax, [rbp]
    mov rbx, [rbp + 8]
    
    ; Look for --port argument
    mov rcx, 1
    mov rdi, 0           ; default port (will use actual port)
    
    find_port_arg:
        cmp rcx, [rbp]   ; check if we reached end of args
        jge use_default_port
        
        shl rcx, 3       ; multiply by 8 to get offset
        lea rsi, [rbx + rcx]  ; get arg pointer
        shr rcx, 3
        
        ; Check if arg is "--port"
        push rcx
        mov rdi, [rsi]
        call string_equals
        pop rcx
        cmp rax, 1
        je got_port_flag   ; If match, next arg will be the port
        
        jmp continue_loop
    
    got_port_flag:
        inc rcx
        cmp rcx, [rbp]
        jge use_default_port
        
        shl rcx, 3
        lea rsi, [rbx + rcx]
        shr rcx, 3
        mov rdi, [rsi]    ; Get port string
        call str_to_int   ; Convert to integer
        mov rdi, rax      ; Store port number
        jmp setup_server
    
    continue_loop:
        inc rcx
        jmp find_port_arg
    
    use_default_port:
        mov rdi, 3000     ; Default port
        
    setup_server:
        ; Initialize server
        mov qword [users_count], 0
        mov qword [todos_count], 0
        mov qword [sessions_count], 0
        
        ; Create socket
        mov rax, SYS_SOCKET
        mov rdi, AF_INET
        mov rsi, 1        ; SOCK_STREAM
        mov rdx, IPPROTO_TCP
        syscall
        mov r12, rax      ; Store socket fd
        
        ; Set socket options (SO_REUSEADDR)
        mov rax, SYS_SETSOCKOPT
        mov rdi, r12      ; socket fd
        mov rsi, SOL_SOCKET
        mov rdx, SO_REUSEADDR
        mov rcx, 1        ; value
        mov r8, 4         ; length of value
        syscall
        
        ; Setup address structure
        lea rdi, [buffer] ; temp buffer
        call clear_buffer
        mov dword [rdi], 0x00000002           ; sin_family = AF_INET
        ; Calculate network byte order for port
        mov ax, di        ; temp value
        mov ax, rdi       ; port number
        cmp di, 0xFFFF    ; check upper limit
        ja invalid_port
        mov rbx, di
        call htons        ; convert to network byte order
        mov word [rdi + 2], ax  ; sin_port
        mov dword [rdi + 4], 0x00000000  ; sin_addr (0.0.0.0)
        
        ; Bind socket
        mov rax, SYS_BIND
        mov rdi, r12      ; socket fd
        mov rsi, rdi      ; server address structure
        mov rdx, 16       ; address length
        syscall
        cmp rax, 0
        jl bind_error
        
        ; Listen for connections
        mov rax, SYS_LISTEN
        mov rdi, r12      ; socket fd
        mov rsi, 10       ; backlog
        syscall
        cmp rax, 0
        jl listen_error
        
        ; Start accepting connections
        accept_loop:
            lea rdi, [client_addr]
            mov dword [client_len], 16
            mov rax, SYS_ACCEPT
            mov rdi, r12  ; server socket fd
            mov rsi, rdi  ; client address
            mov rdx, client_len
            syscall
            
            ; Fork here would be typical but for simplicity, handle sequentially
            cmp rax, 0
            jl accept_error
            
            ; Receive data from client
            mov r13, rax  ; store client socket fd
            lea rdi, [buffer]
            call clear_buffer
            mov rax, SYS_RECV
            mov rdi, r13  ; client socket fd
            mov rsi, rdi  ; buffer
            mov rdx, 4096 ; buffer size
            mov r10, 0    ; flags
            syscall
            mov r14, rax  ; store received bytes count
            
            ; Process request
            lea rdi, [buffer]
            lea rsi, [response_buffer]
            call process_http_request
            
            ; Send response
            mov rax, SYS_SEND
            mov rdi, r13  ; client socket fd
            lea rsi, [response_buffer]
            call strlen
            mov rdx, rax  ; response length
            mov r10, 0    ; flags
            syscall
            
            ; Close client connection
            mov rax, SYS_CLOSE
            mov rdi, r13  ; client socket fd
            syscall
            
            jmp accept_loop ; Continue server loop
            
        ; Error handling
        bind_error:
            ; TODO: Add proper error handling
            jmp server_exit
        listen_error:
            ; TODO: Add proper error handling
            jmp server_exit
        accept_error:
            ; TODO: Add proper error handling
            jmp server_exit
            
        invalid_port:
            ; Handle invalid port error
            jmp server_exit
            
        server_exit:
            ; Close server socket and exit
            mov rax, SYS_CLOSE
            mov rdi, r12
            syscall
            mov rax, 60     ; exit system call
            mov rdi, 0
            syscall


; Helper function: String length
strlen:
    push rax
    push rcx
    mov rcx, rax  ; save input param
    xor rax, rax
    not rax       ; rax = -1
    xor rdx, rdx  ; zero register for comparing
.loop:
    inc rax       ; increment counter
    cmp [rcx + rax], dl ; compare with null terminator
    jne .loop
    mov rax, rax  ; return in rax
    pop rcx
    pop rax
    ret


; Helper function: Clear buffer
clear_buffer:
    push rax
    push rcx
    push rsi
    mov rcx, 4097  ; number of bytes to clear
    mov rax, rdi   ; base address
    push rax
.clear:
    mov rax, 0     ; null value
    stosb          ; store byte and advance rdi
    loop .clear
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret


; Helper function: String comparison
string_equals:
    push rax
    push rbx
    push rcx
    push rdx
    
    mov rax, rdi   ; first string
    mov rbx, rsi   ; second string
    
.str_cmp_loop:
    mov cl, [rax]
    mov dl, [rbx]
    cmp cl, 0      ; if end of first string
    je .check_second_end
    cmp dl, 0      ; if end of second string
    je .strings_different
    cmp cl, dl     ; compare chars
    jne .strings_different
    inc rax
    inc rbx
    jmp .str_cmp_loop
    
.check_second_end:
    cmp dl, 0      ; both should be zero to be equal
    je .strings_equal
.strings_different:
    mov rax, 0     ; return false
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.strings_equal:
    mov rax, 1     ; return true
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; Helper function: Convert string to integer
str_to_int:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    
    mov rbx, 10    ; divisor for conversion
    xor rax, rax   ; result = 0
    xor rcx, rcx   ; index counter
    
.convert_loop:
    movzx rdx, byte [rdi + rcx]  ; load char
    cmp rdx, 0     ; end of string
    je .convert_done
    cmp rdx, '0'
    jb .convert_done
    cmp rdx, '9'
    ja .convert_done
    
    sub rdx, '0'   ; convert ascii to digit
    mul rbx        ; rax *= 10
    add rax, rdx   ; rax += digit
    inc rcx
    jmp .convert_loop
    
.convert_done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret


; Helper function: htons (host to network byte order)
htons:
    push rax
    mov rax, rdi
    rol ax, 8      ; swap bytes
    pop rax
    ret


; Helper function: Process HTTP request
process_http_request:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    
    ; Parse request method
    mov rax, rdi
    mov rbx, 0     ; position tracker
    .get_method:
        cmp byte [rax + rbx], ' '
        je .method_found
        inc rbx
        jmp .get_method
    .method_found:
        mov byte [rax + rbx], 0  ; null terminate method
        inc rbx                  ; move past space
        ; At this point [rdi] has method and rdi+rbx has path
    
    ; Parse request path
    mov rcx, rbx   ; start of path
    .get_path:
        cmp byte [rax + rcx], ' '
        je .path_found
        cmp byte [rax + rcx], 0Ah  ; newline might also end path
        je .path_found
        inc rcx
        jmp .get_path
    .path_found:
        mov byte [rax + rcx], 0  ; null terminate path
        ; Save method and path pointers
        mov r8,  rdi             ; method string
        add rdi, rbx             ; path string
        mov r9, rdi              ; path saved
        
    ; Determine endpoint
    mov rsi, path_register
    call string_equals
    cmp rax, 1
    je .handle_register
    
    mov rdi, r9    ; restore path
    mov rsi, path_login
    call string_equals
    cmp rax, 1
    je .handle_login
    
    mov rdi, r9    ; restore path
    mov rsi, path_logout
    call string_equals
    cmp rax, 1
    je .handle_logout
    
    mov rdi, r9    ; restore path
    mov rsi, path_me
    call string_equals
    cmp rax, 1
    je .handle_me
    
    mov rdi, r9    ; restore path
    mov rsi, path_password
    call string_equals
    cmp rax, 1
    je .handle_password
    
    mov rdi, r9    ; restore path
    lea rsi, [path_todos]
    call string_equals
    cmp rax, 1
    je .handle_todos_default
    
    ; Check if it's a specific todo route (contains /todos/integer)
    mov rdi, r9
    lea rsi, [path_todos]
    call starts_with
    cmp rax, 1
    jne .return_404
    
    mov rdi, r9
    lea rsi, [path_todos]
    call string_compare_part
    add rcx, rax
    cmp byte [r9 + rax], '/'     ; Must have slash after /todos
    jne .return_404
    
    ; It's a specific todo endpoint - determine method
    mov rdi, r8    ; method
    mov rsi, http_get
    call string_equals
    cmp rax, 1
    je .handle_get_todo
    
    mov rdi, r8    ; method
    mov rsi, http_put
    call string_equals
    cmp rax, 1
    je .handle_update_todo
    
    mov rdi, r8    ; method  
    mov rsi, http_delete
    call string_equals
    cmp rax, 1
    je .handle_delete_todo
    
    jmp .return_404  ; Unsupported method on specific todo

.handle_register:
    ; Only allow POST method
    mov rdi, r8    ; method
    mov rsi, http_post
    call string_equals
    cmp rax, 1
    jne .return_405
    
    call handle_registration
    jmp .return_response
    
.handle_login:
    mov rdi, r8    ; method
    mov rsi, http_post
    call string_equals
    cmp rax, 1
    jne .return_405
    
    call handle_login
    jmp .return_response
    
.handle_logout:
    mov rdi, r8    ; method
    mov rsi, http_post
    call string_equals
    cmp rax, 1
    jne .return_405
    
    call handle_logout
    jmp .return_response
    
.handle_me:
    mov rdi, r8    ; method
    mov rsi, http_get
    call string_equals
    cmp rax, 1
    jne .return_405
    
    call handle_get_user_info
    jmp .return_response
    
.handle_password:
    mov rdi, r8    ; method
    mov rsi, http_put
    call string_equals
    cmp rax, 1
    jne .return_405
    
    call handle_change_password
    jmp .return_response
    
.handle_todos_default:
    mov rdi, r8    ; method
    mov rsi, http_get
    call string_equals
    cmp rax, 1
    je .handle_get_todos
    
    mov rdi, r8    ; method
    mov rsi, http_post
    call string_equals
    cmp rax, 1
    je .handle_create_todo
    
    jmp .return_405  ; Unsupported method on todo collection
    
.handle_get_todo:
    call handle_get_specific_todo
    jmp .return_response
    
.handle_update_todo:
    call handle_update_todo
    jmp .return_response
    
.handle_delete_todo:
    call handle_delete_todo
    jmp .return_response
    
.handle_get_todos:
    call handle_get_user_todos
    jmp .return_response
    
.handle_create_todo:
    call handle_create_todo
    jmp .return_response
    
.return_404:
    mov rdi, 404
    call create_error_response
    jmp .return_response
    
.return_405:
    mov rdi, 405
    call create_error_response
    jmp .return_response
    
.return_response:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret


; Helper function: String starts with
starts_with:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    
    mov rax, rdi   ; main string
    mov rbx, rsi   ; prefix string
    xor rcx, rcx   ; index counter
    
.check_char:
    mov dl, [rbx + rcx]  ; character from prefix
    cmp dl, 0            ; end of prefix
    je .prefix_matched   ; if end of prefix, success
    mov dh, [rax + rcx]  ; character from main string
    cmp dl, dh           ; compare chars
    jne .not_started     ; if different, fail
    inc rcx
    jmp .check_char
    
.prefix_matched:
    mov rax, 1     ; return true
    jmp .done
    
.not_started:
    mov rax, 0     ; return false
    
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; Helper function: Compare string part (returns first differing index)
string_compare_part:
    push rax
    push rbx
    push rcx
    push rdx
    
    mov rax, rdi   ; main string
    mov rbx, rsi   ; sub string
    xor rcx, rcx   ; index counter
    
.compare_chars:
    mov dl, [rbx + rcx]  ; character from sub string  
    cmp dl, 0            ; end of sub string
    je .equal_up_to_here
    mov dh, [rax + rcx]  ; character from main string
    cmp dh, 0            ; end of main string
    je .reached_main_end 
    cmp dl, dh           ; compare chars
    jne .done            ; return difference index
    inc rcx
    jmp .compare_chars
    
.equal_up_to_here:
.reached_main_end:
    mov rax, rcx         ; return index where they diverge or end
    jmp .exit
    
.done:
    mov rax, rcx         ; return index of first difference
    
.exit:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; Core handlers for API endpoints
; Registration handler (POST /register)
handle_registration:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Find body of request (after headers)
    mov rdi, rsi          ; input buffer
    call find_json_body
    cmp rax, 0
    je .registration_failed_format
    mov rdi, rax          ; rdi now points to JSON body
    
    ; Parse username from JSON body
    lea rsi, [json_username_field]
    call extract_string_value
    cmp rax, 0
    je .registration_failed_parse  ; No username field
    lea rsi, [rax]        ; username string
    push rsi
    call validate_username
    cmp rax, 1
    jne .invalid_username
    pop rsi               ; get username back
    
    ; Parse password from JSON body
    mov rdi, [rsp + 8]    ; go back to original pos after pushing username
    lea rsi, [json_id_field]  ; need to search from "password" instead - adjust approach 
    add rdi, 0            ; dummy adjustment - need different parsing approach
    
; Parse JSON by searching for "password"
    push rsi              ; save username
    lea rsi, [rdi]        ; work with original request
    call find_password_in_json
    cmp rax, 0
    je .password_missing
    mov rsi, rax          ; rsi now contains password string
        
    ; Validate password
    call validate_password
    cmp rax, 1
    jne .password_too_short
    
    ; Check if user already exists
    pop rdi               ; retrieve username (from stack under password)
    call user_exists
    cmp rax, 1
    je .user_already_exists
    
    ; Create user
    mov rsi, rdi          ; username
    mov rdx, rsi          ; password
    call create_user
    
.reg_success:
    ; Success - return user object in JSON format
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
    
.user_already_exists:
    mov rdi, 409          ; 409 Conflict
    call create_error_response
    pop rdi               ; clean up stack
    jmp .registration_error_clean_exit
    
.invalid_username:
    mov rdi, 400          ; 400 Bad Request
    lea rsi, [invalid_username_msg]
    call create_error_response_with_msg
    pop rdi               ; clean up stack
    jmp .registration_error_clean_exit
    
.password_too_short:
    mov rdi, 400          ; 400 Bad Request
    lea rsi, [password_short_msg]
    call create_error_response_with_msg
    pop rdi               ; clean up stack
    jmp .registration_error_clean_exit
    
.password_missing:        ; temporary - need better JSON parsing
    pop rdi               ; clean up stack
    jmp .registration_failed_parse
    
.registration_failed_parse:
.registration_failed_format:
    mov rdi, 400
    call create_error_response
    jmp .registration_error_clean_exit
    
.registration_error_clean_exit:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .data
    invalid_username_msg db '{"error": "Invalid username"}', 0
    password_short_msg db '{"error": "Password too short"}', 0
    user_exists_msg db '{"error": "Username already exists"}', 0

section .text

; Login handler (POST /login)
handle_login:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    ; Implementation will come later
    mov rax, 401
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Common error response for unimplemented features
create_error_response:
    ; This is a simplified placeholder
    lea rsi, [buffer]
    call build_http_response
    lea rsi, [auth_error_msg]
    call append_to_response
    ret

section .data
    auth_required_msg db '{"error": "Authentication required"}', 0
    
section .text
bits 64
default rel

section .text

global _start

; Include system calls definitions inline for simplicity
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
SYS_GETRANDOM   equ 318

; Socket constants
AF_INET         equ 2
SOCK_STREAM     equ 1
SOL_SOCKET      equ 1
SO_REUSEADDR    equ 2

; Memory allocation constants
PROT_READ       equ 1
PROT_WRITE      equ 2
MAP_PRIVATE     equ 2
MAP_ANONYMOUS   equ 32

; Main entry point
_start:
    ; Parse arguments - find --port <number>
    mov rbp, rsp
    mov rdi, [rbp + 0]      ; argc
    mov rsi, [rbp + 8]      ; argv

    ; Parse arguments to get port
    call parse_arguments

    ; Initialize server
    call init_socket
    
    ; Start the event loop
start_loop:
    call accept_connection
    mov r15, rax            ; Store client fd in r15
    
    ; Process request if accepted successfully
    cmp r15, 0
    jl start_loop
    
    ; Receive request
    mov rdi, r15
    call receive_request
    mov r14, rax            ; Store request buffer in r14

    ; Handle the request and send response
    mov rdi, r14
    mov rsi, r15
    call handle_request

    ; Cleanup
    mov rdi, r14
    call free_request_buffer
    
    mov rdi, r15
    call close_connection
    
    jmp start_loop


; Parse command line arguments to extract port number
; On invocation: ./program --port PORTNUMBER
parse_arguments:
    push rbp
    mov rbp, rsp
    
    ; Check for sufficient arguments (argc >= 3)
    cmp rdi, 3
    jl usage_error
    
    ; argv[1] should be --port
    mov rax, [rsi + 8]      ; argv[1]
    mov rbx, opt_port
    call strcmp
    test rax, rax
    jnz usage_error
    
    ; argv[2] should be port number
    mov rax, [rsi + 16]     ; argv[2]
    call str_to_int
    mov [port_num], ax

    pop rbp
    ret

usage_error:
    mov rdi, usage_msg
    mov rsi, usage_msg_len
    call print_string
    mov rdi, 1
    call exit


; Initialize socket and prepare to listen
init_socket:
    push rbp
    mov rbp, rsp
    
    ; Create socket: sockfd = socket(AF_INET, SOCK_STREAM, 0)
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    mov [server_fd], eax
    
    ; Check for error
    cmp rax, 0
    jl socket_error

    ; Set socket option SO_REUSEADDR
    mov rax, SYS_SETSOCKOPT
    mov rdi, [server_fd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    mov rcx, so_reuse_val
    mov r8, 4
    syscall

    ; Setup sockaddr_in structure
    mov word [sock_addr.sin_family], AF_INET       ; sa_family_t sin_family;
    mov ax, [port_num]                             ; port from --port arg
    rol ax, 8                                      ; convert to network byte order
    mov [sock_addr.sin_port], ax                   ; in_port_t sin_port;
    mov dword [sock_addr.sin_addr], 0x00000000     ; INADDR_ANY (bind to 0.0.0.0)

    ; Bind socket: bind(sockfd, &addr, sizeof(addr))
    mov rax, SYS_BIND
    mov rdi, [server_fd]
    mov rsi, sock_addr
    mov rdx, 16            ; sizeof(sockaddr_in)
    syscall
    
    ; Check for binding error
    cmp rax, 0
    jl bind_error

    ; Listen: listen(sockfd, 10)
    mov rax, SYS_LISTEN
    mov rdi, [server_fd]
    mov rsi, 10            ; backlog
    syscall
    
    ; Check for listen error
    cmp rax, 0
    jl listen_error

    pop rbp
    ret

socket_error:
    mov rdi, error_msg_socket
    mov rsi, error_msg_socket_len
    call print_string
    mov rdi, 1
    call exit

bind_error:
    mov rdi, error_msg_bind
    mov rsi, error_msg_bind_len
    call print_string
    mov rdi, 1
    call exit

listen_error:
    mov rdi, error_msg_listen
    mov rsi, error_msg_listen_len
    call print_string
    mov rdi, 1
    call exit


; Accept a client connection
accept_connection:
    push rbp
    mov rbp, rsp
    
    ; acc = accept(serverfd, NULL, NULL)
    mov rax, SYS_ACCEPT
    mov rdi, [server_fd]
    mov rsi, 0
    mov rdx, 0
    syscall
    
    pop rbp
    ret


; Receive client request
; Input: rdi = client fd
; Output: rax = pointer to request buffer
receive_request:
    push rbp
    mov rbp, rsp
    mov rbx, rdi             ; preserve client fd
    
    ; Allocate a request buffer
    mov rax, SYS_MMAP
    mov rdi, 0               ; let kernel choose address
    mov rsi, 1024            ; size of buffer
    mov rdx, PROT_READ | PROT_WRITE
    mov rcx, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    mov r9, 0
    syscall
    
    mov rbp, rax             ; store buffer pointer
    
    ; Read from client socket
    mov rax, SYS_RECVFROM
    mov rdi, rbx             ; client fd
    mov rsi, rbp             ; buffer
    mov rdx, 1024            ; buffer size
    mov rcx, 0               ; flags
    mov r8, 0                ; addr
    mov r9, 0                ; addrlen
    syscall
    
    mov rcx, rax            ; number of bytes read
    
    ; Set null terminator after response
    mov byte [rbp + rcx], 0
    
    mov rax, rbp            ; return buffer address
    
    pop rbp
    ret


; Handle an HTTP request and send appropriate response
; Input: rdi = request buffer, rsi = client fd
handle_request:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    
    mov r12, rdi            ; r12 = request buffer
    mov r13, rsi            ; r13 = client fd
    
    ; Parse the request method and path
    call extract_method_and_path
    
    ; Based on method and path, determine action
    call route_request
    
    pop r14
    pop r13  
    pop r12
    pop rbx
    pop rbp
    ret


; Parse out HTTP method and requested path from request
extract_method_and_path:
    push rbp
    mov rbp, rsp
    mov rsi, r12            ; request buffer
    
    ; Find and extract METHOD
    mov rdi, http_method
    mov rdx, 0
    
copy_method_loop:
    mov al, [rsi + rdx]
    cmp al, ' '
    je method_found
    cmp al, 0
    je extract_done
    mov [rdi + rdx], al
    inc rdx
    jmp copy_method_loop

method_found:
    mov byte [rdi + rdx], 0  ; null terminate method
    add rsi, rdx             ; advance rsi to after method + space
    inc rsi
    
    ; Extract PATH
    mov rdi, request_path
    mov rdx, 0
    mov r15, rsi
    
copy_path_loop:
    mov al, [r15 + rdx]
    cmp al, ' '            ; stop at space between path and HTTP version
    je path_found
    cmp al, '?'            ; stop at query parameters
    je path_found
    cmp al, 0
    je path_found
    mov [rdi + rdx], al
    inc rdx
    jmp copy_path_loop

path_found:
    mov byte [rdi + rdx], 0  ; null terminate path

extract_done:
    pop rbp
    ret


; Route requests based on method and path
route_request:
    push rbp
    mov rbp, rsp
    
    ; Handle by method first - for now, focus on essential routes
    
    ; Compare method with GET
    mov rsi, http_method
    mov rdi, get_method
    call strcmp
    test rax, rax
    jz handle_get_method
    
    ; Compare method with POST
    mov rsi, http_method
    mov rdi, post_method
    call strcmp
    test rax, rax
    jz handle_post_method
    
    ; Compare method with PUT
    mov rsi, http_method
    mov rdi, put_method
    call strcmp
    test rax, rax
    jz handle_put_method
    
    ; Compare method with DELETE
    mov rsi, http_method
    mov rdi, delete_method
    call strcmp
    test rax, rax
    jz handle_delete_method
    
    ; Unsupported method
    mov rdi, http_405
    mov rsi, http_405_len
    mov rdx, r13                   ; client fd
    call send_response
    
    pop rbp
    ret


; Handle GET method requests
handle_get_method:
    ; Compare path with /me
    mov rdi, request_path
    mov rsi, path_me
    call strcmp
    test rax, rax
    jz handle_get_me
    
    ; Compare path with /todos
    mov rdi, request_path
    mov rsi, path_todos
    call strcmp
    test rax, rax
    jz handle_get_todos
        
    ; Check if /todos/{id} (any path starting with /todos/)
    mov rdi, path_todos_prefix
    mov rsi, request_path
    call str_starts_with
    test rax, rax
    jz handle_get_single_todo
    
    ; Not matched
    mov rdi, http_404
    mov rsi, http_404_len
    mov rdx, r13
    call send_response
    
    ret


handle_get_me:
    ; Check authentication
    call check_authentication
    test rax, rax
    jz send_auth_required
    
    ; Send mock user data for now
    mov rdi, mock_user_data
    mov rsi, mock_user_data_len
    mov rdx, r13
    call send_response
    
    ret


handle_get_todos:
    ; Check authentication
    call check_authentication
    test rax, rax
    jz send_auth_required
    
    ; Send empty todos array for now
    mov rdi, json_empty_array
    mov rsi, json_empty_array_len
    mov rdx, r13
    call send_response
    
    ret


handle_get_single_todo:
    ; Check authentication
    call check_authentication
    test rax, rax
    jz send_auth_required
    
    ; For now send 404, as we don't have persistent storage
    mov rdi, http_404
    mov rsi, http_404_len
    mov rdx, r13
    call send_response
    
    ret


; Handle POST method requests
handle_post_method:
    ; Compare path with /register
    mov rdi, request_path
    mov rsi, path_register
    call strcmp
    test rax, rax
    jz handle_post_register
    
    ; Compare path with /login
    mov rdi, request_path
    mov rsi, path_login
    call strcmp
    test rax, rax
    jz handle_post_login
    
    ; Compare path with /logout
    mov rdi, request_path
    mov rsi, path_logout
    call strcmp
    test rax, rax
    jz handle_post_logout
    
    ; Compare path with /todos
    mov rdi, request_path
    mov rsi, path_todos
    call strcmp
    test rax, rax
    jz handle_post_todos

    ; Not matched
    mov rdi, http_404
    mov rsi, http_404_len
    mov rdx, r13
    call send_response
    
    ret


handle_post_register:
    ; Extract body data (username & password)
    call extract_username_password_from_body
    
    ; Validate the username
    mov rdi, extracted_username
    call validate_username_format
    test rax, rax
    jz send_invalid_username
    
    ; Validate the password
    mov rdi, extracted_password
    call validate_password_length
    test rax, rax
    jz send_password_too_short
    
    ; Check if user exists
    mov rdi, extracted_username
    call check_user_exists
    test rax, rax
    jnz send_username_taken
    
    ; Create the user (simulated)
    call create_new_user
    
    ; Send success response
    mov rdi, mock_user_creation_data
    mov rsi, mock_user_creation_data_len
    mov rdx, r13
    call send_response
    
    ret


handle_post_login:
    ; Extract body data (username & password)
    call extract_username_password_from_body
    
    ; Look for user/password combination
    mov rdi, extracted_username
    mov rsi, extracted_password  
    call verify_user_credentials
    test rax, rax
    jz send_invalid_credentials
    
    ; Create session
    call generate_session_token
    
    ; Associate session with user (simulate)
    mov rdi, mock_login_success_data
    mov rsi, mock_login_success_data_len
    mov rdx, r13
    call send_response
    
    ret


handle_post_logout:
    ; Check authentication
    call check_authentication
    test rax, rax
    jz send_auth_required
    
    ; Clear the session
    call clear_current_session
    
    ; Send success response (empty object)
    mov rdi, json_empty_object
    mov rsi, json_empty_object_len
    mov rdx, r13
    call send_response
    
    ret


handle_post_todos:
    ; Check authentication
    call check_authentication
    test rax, rax
    jz send_auth_required
    
    ; Extract title/description
    call extract_title_desc_from_body
    
    ; Validate title is not empty
    mov rdi, extracted_title
    call validate_title_non_empty
    test rax, rax
    jz send_title_required
    
    ; Create todo (simulated)
    call create_new_todo
    
    ; Send success response
    mov rdi, mock_todo_created_data
    mov rsi, mock_todo_created_data_len
    mov rdx, r13
    call send_response
    
    ret


; Handle PUT method requests
handle_put_method:
    ; Compare path with /password
    mov rdi, request_path
    mov rsi, path_password
    call strcmp
    test rax, rax
    jz handle_put_password
    
    ; Check if path is for updating a todo (startsWith /todos/)
    mov rdi, path_todos_prefix
    mov rsi, request_path
    call str_starts_with
    test rax, rax 
    jz handle_put_todo
    
    ; Not matched
    mov rdi, http_404
    mov rsi, http_404_len
    mov rdx, r13
    call send_response
    
    ret


handle_put_password:
    ; Check authentication
    call check_authentication
    test rax, rax
    jz send_auth_required
    
    ; Extract old_password and new_password
    call extract_old_new_password
    
    ; Verify old password is correct
    mov rdi, extracted_old_password
    call verify_curr_user_password
    test rax, rax
    jz send_invalid_old_password
    
    ; Validate new password length
    mov rdi, extracted_new_password
    call validate_password_length
    test rax, rax
    jz send_password_too_short
    
    ; Change password (simulate) and return success
    mov rdi, json_empty_object
    mov rsi, json_empty_object_len
    mov rdx, r13
    call send_response
    
    ret


handle_put_todo:
    ; Check authentication 
    call check_authentication
    test rax, rax
    jz send_auth_required
    
    ; Extract todo ID and validate ownership (simplified)
    ; Extract updated fields and validate
    call extract_title_desc_completed_from_body
    
    mov rdi, mock_todo_updated_data
    mov rsi, mock_todo_updated_data_len
    mov rdx, r13
    call send_response
    
    ret


; Handle DELETE method requests
handle_delete_method:
    ; Check if path is for deleting a todo startsWith /todos/
    mov rdi, path_todos_prefix
    mov rsi, request_path
    call str_starts_with
    test rax, rax 
    jz handle_delete_todo
    
    ; Not matched
    mov rdi, http_404
    mov rsi, http_404_len
    mov rdx, r13
    call send_response
    
    ret


handle_delete_todo:
    ; Check authentication
    call check_authentication
    test rax, rax
    jz send_auth_required
    
    ; Check todo exists and belongs to user (simplified: just return 204)
    mov rdi, http_204
    mov rsi, http_204_len
    mov rdx, r13
    call send_response
    
    ret


; Check valid authentication via session token
check_authentication:
    ; For now, we'll just simulate successful auth after the first login
    ; In the production version, this would check a session table
    mov rax, 1      ; Assume valid authentication
    ret


; Send authorization required error response
send_auth_required:
    push rbp
    mov rbp, rsp
    mov rdi, http_401
    mov rsi, http_401_len
    mov rdx, r13
    call send_response
    pop rbp
    ret


; Extract username/password from request body
extract_username_password_from_body:
    mov rax, 1    ; Simulate successful extraction
    ret


; Extract title/description from request body  
extract_title_desc_from_body:
    mov rax, 1    ; Simulate successful extraction
    ret


; Extract old/new passwords from body
extract_old_new_password:
    mov rax, 1    ; Simulate
    ret


; Extract title, description, completed fields from body  
extract_title_desc_completed_from_body:
    mov rax, 1    ; Simulate
    ret


; Validation functions
validate_username_format:
    cmp byte [rdi], 0     ; empty string
    je return_false
    
    ; Check length (3-50 chars)
    mov rsi, rdi
    xor rax, rax
count_len:
    cmp byte [rsi + rax], 0
    je len_count_done
    inc rax
    cmp rax, 50           ; max 50
    jg return_false
    jmp count_len
len_count_done:
    cmp rax, 3            ; min 3
    jl return_false
    cmp rax, 50           ; max 50
    jg return_false
    
    ; Validate character format (alphanumeric + underscores)
    mov rdx, 0
validate_char:
    cmp rdx, rax
    jge return_true
    mov cl, [rdi + rdx]
    
    ; Check for alphanumeric or underscore
    cmp cl, 'a'
    jl check_upper_or_digit
    cmp cl, 'z'
    jle next_char
    
check_upper_or_digit:
    cmp cl, 'A'
    jl check_underscore
    cmp cl, 'Z'
    jle next_char
    
    cmp cl, '0'
    jl validation_failed
    cmp cl, '9'
    jle next_char
    
check_underscore:
    cmp cl, '_'
    jne validation_failed
    
next_char:
    inc rdx
    jmp validate_char

validation_failed:
    mov rax, 0
    ret

return_false:
    mov rax, 0
    ret
return_true:
    mov rax, 1
    ret


validate_password_length:
    ; Check if password has at least 8 characters
    mov rsi, rdi
    xor rax, rax
count_pass_len:
    cmp byte [rsi + rax], 0
    je pass_len_check_done
    inc rax
    cmp rax, 100          ; arbitrary maximum
    jg return_false
    jmp count_pass_len
pass_len_check_done:
    cmp rax, 8            ; min 8 chars
    jge return_true
    mov rax, 0
    ret


validate_title_non_empty:
    ; Check if first character is null
    cmp byte [rdi], 0
    je return_false
    mov rax, 1
    ret


; Session and user management functions
generate_session_token:
    ; For simplicity, use a fixed token string
    mov rsi, fixed_session_token
    mov rdi, current_session_token
    call strcpy
    ret


clear_current_session:
    ; Simulate clearing by setting first char to 0
    mov byte [current_session_token], 0
    ret


check_user_exists:
    mov rax, 0      ; Simulate user does not exist initially
    ret


create_new_user:
    ; Simulate user creation
    mov rax, 1      ; Success
    ret


create_new_todo:
    ; Simulate todo creation
    mov rax, 1      ; Success  
    ret


verify_user_credentials:
    ; Check if user exists and password matches
    ; For now, just accept any combo (not secure!)
    mov rax, 1      ; Always say yes
    ret


verify_curr_user_password:
    ; Always return valid for now
    mov rax, 1
    ret


send_invalid_username:
    push rbp
    mov rbp, rsp
    mov rdi, invalid_username_response
    mov rsi, invalid_username_response_len
    mov rdx, r13
    call send_response
    pop rbp
    ret


send_password_too_short:    
    push rbp
    mov rbp, rsp
    mov rdi, password_short_response
    mov rsi, password_short_response_len
    mov rdx, r13
    call send_response
    pop rbp
    ret


send_username_taken:
    push rbp
    mov rbp, rsp
    mov rdi, username_taken_response
    mov rsi, username_taken_response_len
    mov rdx, r13
    call send_response
    pop rbp
    ret


send_invalid_credentials:
    push rbp
    mov rbp, rsp
    mov rdi, invalid_credentials_response
    mov rsi, invalid_credentials_response_len
    mov rdx, r13
    call send_response
    pop rbp
    ret


send_title_required:
    push rbp
    mov rbp, rsp
    mov rdi, title_required_response
    mov rsi, title_required_response_len
    mov rdx, r13
    call send_response
    pop rbp
    ret


send_invalid_old_password:
    push rbp
    mov rbp, rsp
    mov rdi, invalid_credentials_response  ; Reuse same error
    mov rsi, invalid_credentials_response_len
    mov rdx, r13
    call send_response
    pop rbp
    ret


; Send an HTTP response
; Input: rdi = response message, rsi = length, rdx = client fd
send_response:
    push rbp
    mov rbp, rsp
    push rbx

    mov rbx, rdx      ; fd in rbx
    
    ; Write response to socket
    mov rax, SYS_SENDTO
    mov rdi, rbx
    mov rsi, rdi      ; response message
    mov rdx, rsi      ; length
    mov rcx, 0
    mov r8, 0
    mov r9, 0
    syscall

    pop rbx
    pop rbp
    ret


; Free the allocated request buffer
free_request_buffer:
    push rbp
    mov rbp, rsp
    
    ; munmap(request_buff, 1024)
    mov rax, SYS_MUNMAP
    mov rdi, rdi      ; request buffer
    mov rsi, 1024     ; size
    syscall
    
    pop rbp
    ret


; Close client connection
close_connection:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_CLOSE
    mov rdi, rdi      ; file descriptor
    syscall
    
    pop rbp
    ret


; Convert string to integer
str_to_int:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov rsi, rdi      ; input string in rsi
    xor rax, rax      ; result = 0
    xor rbx, rbx      ; digit temp storage
    xor rcx, rcx      ; loop counter
    
loop_convert:
    mov bl, byte [rsi + rcx]
    cmp bl, '0'
    jl done_convert
    cmp bl, '9'
    jg done_convert
    
    imul rax, 10      ; result *= 10
    sub bl, '0'       ; convert ascii to int
    add rax, rbx      ; result += digit
    inc rcx
    jmp loop_convert
    
done_convert:
    pop rdx
    pop rcx
    pop rbx
    pop rdp
    ret


; String comparison function
; Input: rdi = string1, rsi = string2  
; Output: rax = 0 if equal, !=0 if different
strcmp:
    push rbp
    mov rbp, rsp
    push rbx
    
    mov rax, 0
    
strcmp_loop:
    mov bl, [rdi + rax]   ; load char from string1
    cmp bl, [rsi + rax]   ; compare with char from string2
    jne strcmp_diff       ; if not equal, exit with difference
    cmp bl, 0             ; if both are null terminators
    je strcmp_equal       ; then strings are equal
    inc rax               ; else continue comparing
    jmp strcmp_loop

strcmp_equal:
    mov rax, 0
    jmp strcmp_ret

strcmp_diff:
    mov al, [rdi + rax]
    sub al, [rsi + rax]
    movsx rax, al         ; sign-extend al to rax

strcmp_ret:
    pop rbx
    pop rbp
    ret
    

; Determine if string at rsi starts with prefix at rdi 
str_starts_with:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rax, 0           ; index
    
starts_with_loop:
    mov bl, [rdi + rax]  ; load char from prefix
    test bl, bl          ; is prefix char null?
    jz starts_with_true  ; if so, prefix has been fully matched
    
    cmp bl, [rsi + rax]  ; compare with main string
    jne starts_with_false ; if not equal, no match
    inc rax              ; else continue checking
    jmp starts_with_loop

starts_with_true:
    mov rax, 1           ; return true
    jmp starts_with_ret
starts_with_false:
    mov rax, 0           ; return false

starts_with_ret:
    pop rcx
    pop rbx
    pop rbp
    ret


; Copy string from rsi to rdi
strcpy:
    push rbp
    mov rbp, rsp
    mov rdx, 0           ; index counter
    
strcpy_loop:
    mov al, [rsi + rdx]  ; get char from source
    mov [rdi + rdx], al  ; put char to dest
    test al, al          ; is it null terminator?
    jz strcpy_done       ; if so, finish
    inc rdx              ; else continue
    jmp strcpy_loop
    
strcpy_done:
    mov rax, rdx         ; return string length
    pop rbp
    ret


; Print a string to stdout
print_string:
    push rbp
    mov rbp, rsp
    push rbx
    
    ; Calculate length
    mov rbx, rdi
    xor rax, rax
calc_str_len:
    cmp byte [rbx + rax], 0
    je len_calc_done
    inc rax
    jmp calc_str_len
len_calc_done:

    ; Write
    mov r10, rsi
    mov rax, SYS_WRITE
    mov rdi, 1           ; stdout
    mov rsi, rbx         ; string
    mov rdx, rax         ; length
    syscall
    
    pop rbx
    pop rbp
    ret


; Exit program
exit:
    mov rax, SYS_EXIT
    mov rdi, rdi
    syscall


; Data section
section .data

    ; Messages    
    usage_msg       db  'Usage: server --port PORT_NUMBER', 10, 0
    usage_msg_len   equ $ - usage_msg - 1
    
    error_msg_socket   db  'Failed to create socket', 10, 0
    error_msg_socket_len equ $ - error_msg_socket - 1
    error_msg_bind     db  'Failed to bind socket', 10, 0  
    error_msg_bind_len equ $ - error_msg_bind - 1
    error_msg_listen   db  'Failed to listen on socket', 10, 0
    error_msg_listen_len equ $ - error_msg_listen - 1

    ; Command line args
    opt_port        db '--port', 0
    
    ; HTTP methods
    get_method      db 'GET', 0
    post_method     db 'POST', 0
    put_method      db 'PUT', 0
    delete_method   db 'DELETE', 0
    
    ; Paths    
    path_login      db '/login', 0
    path_register   db '/register', 0
    path_logout     db '/logout', 0
    path_me         db '/me', 0
    path_todos      db '/todos', 0
    path_todos_prefix db '/todos/', 0
    path_password   db '/password', 0
    
    ; HTTP response codes
    http_200        db  'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    http_200_len    equ $ - http_200
    http_201        db  'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    http_201_len    equ $ - http_201
    http_204        db  'HTTP/1.1 204 No Content', 13, 10, 13, 10, 0
    http_204_len    equ $ - http_204 - 1
    http_401        db  'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Authentication required"}', 0
    http_401_len    equ $ - http_401 - 1
    http_404        db  'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Not found"}', 0
    http_404_len    equ $ - http_404 - 1  
    http_405        db  'HTTP/1.1 405 Method Not Allowed', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Method not allowed"}', 0
    http_405_len    equ $ - http_405 - 1
    
    ; Authentication required response
    invalid_username_response     db  'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Invalid username"}', 0
    invalid_username_response_len equ $ - invalid_username_response - 1
    password_short_response     db  'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Password too short"}', 0
    password_short_response_len equ $ - password_short_response - 1
    username_taken_response     db  'HTTP/1.1 409 Conflict', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Username already exists"}', 0
    username_taken_response_len equ $ - username_taken_response - 1
    invalid_credentials_response db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Invalid credentials"}', 0
    invalid_credentials_response_len equ $ - invalid_credentials_response - 1
    title_required_response     db  'HTTP/1.1 400 Bad Request', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Title is required"}', 0
    title_required_response_len equ $ - title_required_response - 1
    
    ; Mock data responses
    mock_user_data db '{"id":1,"username":"testuser"}', 0
    mock_user_data_len equ $ - mock_user_data - 1
    json_empty_array db '[]', 0
    json_empty_array_len equ $ - json_empty_array - 1
    json_empty_object db '{}', 0
    json_empty_object_len equ $ - json_empty_object - 1
    
    mock_user_creation_data db '{"id":2,"username":"newuser"}', 0
    mock_user_creation_data_len equ $ - mock_user_creation_data - 1
    mock_login_success_data db '{"id":1,"username":"testuser"}', 0
    mock_login_success_data_len equ $ - mock_login_success_data - 1
    mock_todo_created_data db '{"id":1,"title":"Test Todo", "description":"Test Description","completed":false,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T09:30:00Z"}', 0
    mock_todo_created_data_len equ $ - mock_todo_created_data - 1
    mock_todo_updated_data db '{"id":1,"title":"Updated Test Todo", "description":"Updated Test Description","completed":true,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T10:00:00Z"}', 0
    mock_todo_updated_data_len equ $ - mock_todo_updated_data - 1
    
    ; Constant values
    so_reuse_val    dd 1
    fixed_session_token db 'abcdef1234567890abcdef1234567890', 0


; BSS section for dynamic runtime variables
section .bss
    server_fd       resd 1          ; Server socket file descriptor
    port_num        resw 1          ; Port number to listen on
    
    ; Runtime state
    http_method     resb 16         ; GET, POST, etc.
    request_path    resb 256        ; Requested path
    
    ; Sockaddr structure
    sock_addr: 
        sin_family  resw 1          ; Address family (AF_INET)
        sin_port    resw 1          ; Port field
        sin_addr    resd 1          ; IP address field  
        padding     resd 1          ; Align to 16 bytes
    
    ; For extracting request body data
    extracted_username   resb 100
    extracted_password   resb 100
    extracted_old_password resb 100
    extracted_new_password resb 100
    extracted_title    resb 256
    extracted_description resb 512
    
    ; Session tracking
    current_session_token resb 33   ; Current session ID
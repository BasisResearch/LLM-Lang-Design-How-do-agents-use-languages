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
SOCKADDR_IN_SIZE equ 16

; Main entry
_start:
    mov rbp, rsp
    mov rdi, [rbp + 0*8]    ; argc
    mov rsi, [rbp + 1*8]    ; argv

    ; Process command line arguments
    call process_args
    
    ; Start server
    call start_server


process_args:
    push rbp
    mov rbp, rsp
    
    ; Check number of arguments (minimum 3: exe --port number)
    cmp rdi, 3
    jb print_usage
    
    ; Compare argv[1] with "--port"
    mov rax, [rsi + 1*8]    ; argv[1]
    mov rbx, string_port_arg
    call strcmp
    test rax, rax
    jne print_usage
    
    ; Convert argv[2] to port number
    mov rdi, [rsi + 2*8]    ; argv[2]
    call atoi
    mov [port_number], ax
    
    pop rbp
    ret

print_usage:
    mov rdi, usage_message
    mov rsi, usage_len
    call print_string
    mov rdi, 1
    call exit

atoi:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov rbx, rdi     ; copy string pointer
    xor rax, rax     ; result = 0
    xor rcx, rcx     ; index = 0
    
.strloop:
    mov dl, [rbx + rcx]
    cmp dl, 0        ; null terminator?
    je .done
    cmp dl, '0'      
    jl .done
    cmp dl, '9'
    jg .done
    
    imul rax, 10      ; result *= 10
    sub dl, '0'       ; convert ASCII to digit
    add rax, rdx      ; result += digit
    inc rcx           ; index++
    jmp .strloop
    
.done:
    mov [port_number], ax ; store value
    pop rdx
    pop rcx  
    pop rbx
    pop rbp
    ret


start_server:
    push rbp
    mov rbp, rsp
    
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    mov [server_fd], eax
    
    ; Set socket option SO_REUSEADDR
    mov rax, SYS_SETSOCKOPT
    mov rdi, [server_fd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    mov rcx, opt_val_ptr  ; pointer to 1
    mov r8, 4
    syscall
    
    ; Set up sockaddr_in structure
    mov word [addr_struct], AF_INET                    ; sin_family
    mov word [addr_struct + 2], [port_number]          ; sin_port (already in net order)
    mov dword [addr_struct + 4], 0                     ; sin_addr - INADDR_ANY = 0.0.0.0
    
    ; Zero padding (addr_struct + 8 to +15)
    mov dword [addr_struct + 8], 0
    mov dword [addr_struct + 12], 0
    
    ; Bind socket
    mov rax, SYS_BIND
    mov rdi, [server_fd]
    mov rsi, addr_struct
    mov rdx, SOCKADDR_IN_SIZE
    syscall
    test rax, rax
    js .bind_err
    
    ; Listen
    mov rax, SYS_LISTEN
    mov rdi, [server_fd]
    mov rsi, 10
    syscall
    test rax, rax
    js .listen_err
    
    ; Server loop
.server_loop:
    ; Accept connections
    mov rax, SYS_ACCEPT
    mov rdi, [server_fd]
    mov rsi, 0
    mov rdx, 0
    syscall
    mov r15, rax        ; r15 = client fd
    
    ; Receive request
    call alloc_request_buffer
    mov r14, rax
    
    mov rax, SYS_RECVFROM
    mov rdi, r15        ; client fd
    mov rsi, r14        ; buffer
    mov rdx, REQUEST_BUF_SIZE
    mov rcx, 0
    mov r8, 0
    mov r9, 0
    syscall
    mov r13, rax        ; bytes received
    
    ; Process and respond to request
    mov rdi, r14        ; request buffer  
    mov rsi, r15        ; client fd
    mov rdx, r13        ; bytes received
    call handle_request
    
    ; Clean up
    mov rdi, r14
    call free_request_buffer
    
    mov rdi, r15
    call close_connection
    
    jmp .server_loop
    
.bind_err:
    mov rdi, bind_error
    mov rsi, bind_error_len
    call print_string
    mov rdi, 1
    call exit
    
.listen_err:    
    mov rdi, listen_error
    mov rsi, listen_error_len
    call print_string
    mov rdi, 1
    call exit

REQUEST_BUF_SIZE equ 4096

alloc_request_buffer:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_MMAP
    mov rdi, 0
    mov rsi, REQUEST_BUF_SIZE
    mov rdx, PROT_READ | PROT_WRITE
    mov rcx, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    mov r9, 0
    syscall
    
    ; Ensure success
    cmp rax, 0xFFFFFFFFFFFF0000  ; Compare sign-extended range
    ja .error
    jmp .success
    
.error:
    mov rax, 0
.success:
    pop rbp
    ret


free_request_buffer:
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_MUNMAP 
    mov rdi, rdi      ; buffer
    mov rsi, REQUEST_BUF_SIZE
    syscall
    
    pop rbp
    ret


handle_request:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    
    mov r12, rdi      ; request buffer
    mov r13, rsi      ; client fd
    mov r14, rdx      ; bytes received

    ; Parse HTTP method - simplest possible: first word of request
    ; Expected format "METHOD PATH HTTP/x.y"
    mov rax, 0        ; start at beginning
    mov rbx, 0        ; count characters for method
    
.scan_method:
    mov cl, [r12 + rax]
    cmp cl, ' '
    je .found_method_delim
    mov [temp_method + rbx], cl
    inc rax
    inc rbx
    cmp rbx, 15       ; max method length
    jl .scan_method
    ; Too long method, just continue
    
.found_method_delim:
    mov byte [temp_method + rbx], 0   ; null terminate
    inc rax                           ; skip the space
    
    ; Now parse resource path
    mov rbx, 0                        ; count characters for path
    mov rcx, rax                      ; start scanning from here 

.scan_path:
    mov dl, [r12 + rcx]
    cmp dl, ' '
    je .found_path_delim
    cmp dl, 0x0D    ; \r
    je .found_path_delim
    cmp dl, 0x0A    ; \n  
    je .found_path_delim
    mov [temp_path + rbx], dl
    inc rcx
    inc rbx
    cmp rbx, 127       ; max path length
    jl .scan_path

.found_path_delim:
    mov byte [temp_path + rbx], 0   ; null terminate

    ; Route based on method and path
    call route_request

.finish_up:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


route_request:
    push rbp
    mov rbp, rsp
    
    ; Check method first - if not GET/POST/PUT/DELETE, return 405
    mov rdi, temp_method
    mov rsi, method_get
    call strcmp
    test rax, rax
    jz .is_get_method
    
    mov rdi, temp_method  
    mov rsi, method_post
    call strcmp
    test rax, rax
    jz .is_post_method
    
    mov rdi, temp_method
    mov rsi, method_put
    call strcmp
    test rax, rax
    jz .is_put_method
    
    mov rdi, temp_method
    mov rsi, method_delete
    call strcmp
    test rax, rax
    jz .is_delete_method
    
    ; Unknown method
    mov rdi, msg_405_method_not_allowed
    mov rsi, len_405_method_not_allowed
    mov rdx, r13     ; client fd
    call send_response
    jmp .done
    
.is_get_method:
    call handle_get
    jmp .done

.is_post_method:
    call handle_post
    jmp .done

.is_put_method:
    call handle_put
    jmp .done

.is_delete_method:
    call handle_delete
    jmp .done
	
.done:
    pop rbp
    ret


handle_get:
    push rbp
    mov rbp, rsp
    
    ; Check exact path matches first
    mov rdi, temp_path
    mov rsi, path_me
    call strcmp
    test rax, rax
    jz .handle_get_me
    
    mov rdi, temp_path
    mov rsi, path_todos
    call strcmp
    test rax, rax
    jz .handle_get_todos
    
    ; Check for paths starting with /todos/ (for single todo access)
    mov rdi, temp_path
    mov rsi, path_todos_prefix
    call starts_with
    test rax, rax
    jnz .handle_get_todo_by_id

    ; No match
    mov rdi, msg_404_not_found
    mov rsi, len_404_not_found
    mov rdx, r13
    call send_response
    jmp .done
    
.handle_get_me:
    ; This requires authentication
    call check_authenticated
    test rax, rax
    jz .send_auth_required
    
    mov rdi, res_200_user_info_example
    mov rsi, len_200_user_info_example
    mov rdx, r13
    call send_response
    jmp .done

.handle_get_todos:
    ; This also requires authentication
    call check_authenticated
    test rax, rax
    jz .send_auth_required
    
    mov rdi, res_200_empty_todos
    mov rsi, len_200_empty_todos
    mov rdx, r13
    call send_response
    jmp .done

.handle_get_todo_by_id:
    call check_authenticated
    test rax, rax
    jz .send_auth_required
    
    mov rdi, msg_404_not_found  ; For now, since we don't track todos
    mov rsi, len_404_not_found
    mov rdx, r13
    call send_response
    jmp .done

.send_auth_required:
    mov rdi, msg_401_unauthorized
    mov rsi, len_401_unauthorized
    mov rdx, r13
    call send_response
    jmp .done

.done:
    pop rbp
    ret


handle_post:
    push rbp
    mov rbp, rsp
    
    ; Check exact path matches
    mov rdi, temp_path
    mov rsi, path_register
    call strcmp
    test rax, rax
    jz .handle_post_register
    
    mov rdi, temp_path
    mov rsi, path_login
    call strcmp
    test rax, rax
    jz .handle_post_login
    
    mov rdi, temp_path
    mov rsi, path_logout
    call strcmp
    test rax, rax
    jz .handle_post_logout

    mov rdi, temp_path
    mov rsi, path_todos
    call strcmp
    test rax, rax
    jz .handle_post_todos
    
    ; No match
    mov rdi, msg_404_not_found
    mov rsi, len_404_not_found
    mov rdx, r13
    call send_response
    jmp .done

.handle_post_register:
    call perform_registration
    test rax, rax
    jz .send_response
    mov rdi, res_201_user_registered
    mov rsi, len_201_user_registered
    mov rdx, r13
    call send_response
    jmp .done

.handle_post_login:
    call validate_login
    test rax, rax
    jz .send_login_failure
    mov rdi, res_200_login_success
    mov rsi, len_200_login_success
    mov rdx, r13
    call send_response
    jmp .done

.send_login_failure:
    mov rdi, msg_401_unauthorized
    mov rsi, len_401_unauthorized
    mov rdx, r13
    call send_response
    jmp .done
    
.handle_post_logout:
    call check_authenticated
    test rax, rax
    jz .send_auth_required
    ; For now just return success (no sessions tracked yet)
    mov rdi, res_200_logged_out
    mov rsi, len_200_logged_out_len
    mov rdx, r13
    call send_response
    jmp .done

.handle_post_todos:
    call check_authenticated
    test rax, rax
    jz .send_auth_required
    mov rdi, res_201_todo_created
    mov rsi, len_201_todo_created
    mov rdx, r13
    call send_response
    jmp .done

.send_response:
.send_auth_required:
    mov rdi, msg_401_unauthorized
    mov rsi, len_401_unauthorized
    mov rdx, r13
    call send_response

.done:
    pop rbp
    ret


handle_put:
    push rbp
    mov rbp, rsp
    
    ; Check exact path matches
    mov rdi, temp_path
    mov rsi, path_password
    call strcmp
    test rax, rax
    jz .handle_put_password
    
    ; Check for paths starting with /todos/ (for updating todo)
    mov rdi, temp_path
    mov rsi, path_todos_prefix
    call starts_with
    test rax, rax
    jnz .handle_update_todo
    
    ; No match
    mov rdi, msg_404_not_found
    mov rsi, len_404_not_found
    mov rdx, r13
    call send_response
    jmp .done

.handle_put_password:
    call check_authenticated
    test rax, rax 
    jz .send_auth_required
    mov rdi, json_empty_obj
    mov rsi, len_json_empty_obj
    mov rdx, r13
    call send_response
    jmp .done

.handle_update_todo:
    call check_authenticated
    test rax, rax
    jz .send_auth_required
    mov rdi, res_200_todo_updated
    mov rsi, len_200_todo_updated
    mov rdx, r13
    call send_response
    jmp .done
    
.send_auth_required:
    mov rdi, msg_401_unauthorized
    mov rsi, len_401_unauthorized
    mov rdx, r13
    call send_response
    jmp .done

.done:
    pop rbp
    ret


handle_delete:
    push rbp
    mov rbp, rsp
    
    ; Only deletion available is todos
    mov rdi, temp_path
    mov rsi, path_todos_prefix
    call starts_with
    test rax, rax
    jz .handle_delete_todo
    
    ; No match
    mov rdi, msg_404_not_found
    mov rsi, len_404_not_found
    mov rdx, r13
    call send_response
    jmp .done

.handle_delete_todo:
    call check_authenticated
    test rax, rax
    jz .send_auth_required
    
    ; Send 204 No Content
    mov rdi, msg_204_no_content
    mov rsi, len_204_no_content
    mov rdx, r13
    call send_response
    jmp .done

.send_auth_required:
    mov rdi, msg_401_unauthorized
    mov rsi, len_401_unauthorized
    mov rdx, r13
    call send_response

.done:
    pop rbp
    ret


perform_registration:
    ; Extract username and password from request body
    mov rdi, r12  ; request body
    call extract_register_fields
    
    ; Validate fields
    mov rdi, temp_username
    call validate_username  
    test rax, rax
    jz .invalid
    
    mov rdi, temp_password
    call validate_password
    test rax, rax
    jz .invalid_password
    
    ; Check if user already exists (would do DB lookup normally)
    mov rdi, temp_username
    call check_user_existence
    test rax, rax
    jnz .user_exists

    mov rax, 1   ; Return 1 for success
    ret

.invalid:
    mov rax, 0 
    ret

.invalid_password:
    mov rax, 0
    ret

.user_exists:
    mov rax, 0   ; Fail because user exists
    ret


validate_login:
    ; Extract username and password from body  
    mov rdi, r12  ; request body
    call extract_login_fields
    
    ; Validate credentials
    mov rdi, temp_username
    mov rsi, temp_password
    call authenticate_user
    test rax, rax
    jz .failed
    
    mov rax, 1   ; Success
    ret

.failed:
    mov rax, 0   ; Failed
    ret


check_authenticated:
    ; Would check cookies/sessions here
    ; For now, allow all if it looks plausible
    mov rax, 1   ; For now, return success for all requests
    ret


send_response:
    push rbp
    mov rbp, rsp
    
    mov r12, rdi  ; response string
    mov r13, rsi  ; length
    mov r14, rdx  ; client fd
    
    ; Actually perform sendto
    mov rax, SYS_SENDTO
    mov rdi, r14    ; client fd
    mov rsi, r12    ; message
    mov rdx, r13    ; length
    mov rcx, 0      ; flags
    mov r8, 0       ; dest_addr
    mov r9, 0       ; dest_len  
    syscall
    
    pop rbp
    ret


check_user_existence:
    mov rax, 0    ; For now, assume user doesn't exist
    ret


authenticate_user:
    mov rax, 1    ; For now, always succeed 
    ret


validate_username:
    ; Check length 3-50 chars
    mov rsi, rdi
    xor rax, rax
    
.count_chars:
    cmp byte [rsi + rax], 0
    je .length_check
    cmp rax, 51
    jge .fail
    inc rax
    jmp .count_chars

.length_check:
    cmp rax, 3
    jl .fail
    cmp rax, 50
    jg .fail

    ; Validate character set (alphanumeric, underscore)
.valid_char_loop:
    cmp rax, 0
    je .valid
    dec rax
    mov cl, [rdi + rax]
    cmp cl, 'a'
    jl .check_upper_lower_digit
    cmp cl, 'z'
    jle .valid_char_loop
.check_upper_lower_digit:
    cmp cl, 'A'  
    jl .check_digit
    cmp cl, 'Z'
    jle .valid_char_loop
.check_digit:
    cmp cl, '0'
    jl .check_underscore
    cmp cl, '9'
    jle .valid_char_loop
.check_underscore:
    cmp cl, '_'
    je .valid_char_loop
.not_valid:
.fail:
    mov rax, 0
    ret
.valid:
    mov rax, 1
    ret


validate_password:
    ; Must be at least 8 chars
    mov rsi, rdi
    xor rax, rax

.pass_count:
    cmp byte [rsi + rax], 0
    je .pass_len_check
    inc rax
    jmp .pass_count

.pass_len_check:
    cmp rax, 8
    jge .pass_valid
    mov rax, 0
    ret
.pass_valid:
    mov rax, 1
    ret


; String helper functions
strcmp:
    push rbp
    mov rbp, rsp
    push rbx
    
    xor rax, rax
    
.loop:
    mov bl, [rdi + rax]
    cmp bl, [rsi + rax]
    jne .diff
    cmp bl, 0
    je .equal
    inc rax
    jmp .loop
    
.equal:
    xor rax, rax   ; return 0 if equal
    jmp .done
.diff:
    movzx rax, byte [rdi + rax]
    movzx rbx, byte [rsi + rax]
    sub rax, rbx   ; return difference if not equal
.done:
    pop rbx
    pop rbp
    ret


starts_with:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx
    
.loop:
    mov bl, [rdi + rcx]    ; prefix string character
    cmp bl, 0
    je .prefix_match   ; entire prefix matched
    
    cmp bl, [rsi + rcx]    ; compare with main string
    jne .not_match
    
    inc rcx
    jmp .loop
    
.prefix_match:
    mov rax, 1    ; yes, starts with prefix
    jmp .done
.not_match:    
    mov rax, 0
.done:
    pop rcx
    pop rbx
    pop rbp
    ret


print_string:
    push rbp
    mov rbp, rsp
    
    ; Calculate string length first
    mov r12, rdi
    xor rdx, rdx
    
.len_loop:
    cmp byte [r12 + rdx], 0
    je .len_done  
    inc rdx
    jmp .len_loop
    
.len_done:
    mov rax, SYS_WRITE
    mov rdi, 1      ; stdout
    mov rsi, r12    ; string
    mov rdx, rdx    ; calculated length
    syscall
    
    pop rbp
    ret


exit:
    mov rax, SYS_EXIT
    mov rdi, rdi
    syscall
    ret


close_connection:
    mov rax, SYS_CLOSE
    mov rdi, rdi
    syscall 
    ret


; Placeholder functions (to be implemented fully)
extract_register_fields:
    ; Just return success as placeholder
    mov rax, 1
    ret

extract_login_fields:
    ; Just return success as placeholder
    mov rax, 1
    ret


; Data section
section .data

    ; Command args
    string_port_arg db '--port', 0
    
    ; Error messages
    usage_message  db 'Usage: server --port PORT_NUMBER', 10, 0
    usage_len      equ $ - usage_message - 1
    
    bind_error db 'Error: Could not bind to port', 10, 0
    bind_error_len equ $ - bind_error - 1
    
    listen_error db 'Error: Could not listen on socket', 10, 0
    listen_error_len equ $ - listen_error - 1

    ; Response messages
    msg_404_not_found db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Not found"}', 10, 0
    len_404_not_found equ $ - msg_404_not_found - 2   ; Don't count final null + newline 

    msg_204_no_content db 'HTTP/1.1 204 No Content', 13, 10, 13, 10, 0
    len_204_no_content equ $ - msg_204_no_content - 1
    
    msg_405_method_not_allowed db 'HTTP/1.1 405 Method Not Allowed', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Method not allowed"}', 0
    len_405_method_not_allowed equ $ - msg_405_method_not_allowed - 1
    
    msg_401_unauthorized db 'HTTP/1.1 401 Unauthorized', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Authentication required"}', 0
    len_401_unauthorized equ $ - msg_401_unauthorized - 1

    ; Sample data responses
    res_200_user_info_example db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":1,"username":"testuser"}', 0
    len_200_user_info_example equ $ - res_200_user_info_example - 1
    
    res_200_empty_todos db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '[]', 0
    len_200_empty_todos equ $ - res_200_empty_todos - 1

    res_200_todo_updated db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":1,"title":"Updated","description":"Updated Desc","completed":true,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T10:00:00Z"}', 0
    len_200_todo_updated equ $ - res_200_todo_updated - 1

    res_201_todo_created db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":1,"title":"Test todo","description":"Test description","completed":false,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T09:30:00Z"}', 0
    len_201_todo_created equ $ - res_201_todo_created - 1

    res_201_user_registered db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":2,"username":"newuser"}', 0
    len_201_user_registered equ $ - res_201_user_registered - 1

    res_200_login_success db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":1,"username":"testuser"}', 10, 0
    len_200_login_success equ $ - res_200_login_success - 2  ; exclude final null and newline  

    res_200_logged_out db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{}', 0
    len_200_logged_out_len equ $ - res_200_logged_out - 1

    json_empty_obj db '{}', 0
    len_json_empty_obj equ $ - json_empty_obj - 1

    ; Request methods
    method_get    db  'GET', 0
    method_post   db  'POST', 0
    method_put    db  'PUT', 0
    method_delete db  'DELETE', 0
    
    ; Paths
    path_register     db '/register', 0
    path_login        db '/login', 0  
    path_logout       db '/logout', 0
    path_me           db '/me', 0
    path_todos        db '/todos', 0
    path_todos_prefix db '/todos/', 0
    path_password     db '/password', 0

    ; Option values
    opt_on dd 1
    opt_val_ptr dq opt_on


; BSS section
section .bss

    ; Runtime data storage
    server_fd resd 1
    port_number resw 1
    
    ; Fixed-size strings (parsing)
    temp_method resb 16        ; max length for HTTP method
    temp_path resb 128         ; for URL path  
    temp_username resb 256
    temp_password resb 256 
    temp_old_password resb 256
    temp_new_password resb 256
    
    ; Socket structure  
    addr_struct resb SOCKADDR_IN_SIZE
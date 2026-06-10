bits 64
default rel

section .text

global _start

; System call numbers for Linux x86_64
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

; Memory protection / mapping
PROT_READ       equ 1
PROT_WRITE      equ 2
MAP_PRIVATE     equ 2
MAP_ANONYMOUS   equ 32

_start:
    ; Set up initial stack frame
    mov rbp, rsp
    mov rdi, [rbp + 0]  ; argc
    mov rsi, [rbp + 8]  ; argv
    
    ; Parse CLI arguments --port NUMBER
    call parse_arguments
    
    ; Initialize and start server
    call server_init
    call server_loop

parse_arguments:
    ; Check if we have at least 3 arguments: program --port number
    cmp rdi, 3
    jl .usage_error
    
    ; Compare argv[1] with "--port"
    mov rax, [rsi + 8]  ; argv[1]
    mov rbx, str_port_option
    call string_cmp
    test rax, rax
    jnz .usage_error
    
    ; Convert argv[2] to integer (port number)
    mov rdi, [rsi + 16]  ; argv[2]
    call str_to_int
    mov [cli_port], ax   ; Store the port number
    
    ret

.usage_error:
    mov rdi, usage_msg
    mov rsi, usage_len
    call output_string
    mov rdi, 1
    call exit

str_to_int:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov rbx, rdi    ; Save string address
    xor rax, rax    ; Result accumulator
    xor rcx, rcx    ; Index counter
    
.convert_loop:
    mov dl, [rbx + rcx]  ; Load next character
    cmp dl, 0            ; Stop at null terminator
    je .conversion_done
    cmp dl, '0'          ; Valid digit?
    jb .conversion_done
    cmp dl, '9'
    ja .conversion_done
    
    imul rax, 10         ; result *= 10
    sub dl, '0'          ; Convert character to digit
    add rax, rdx         ; result += digit
    inc rcx
    jmp .convert_loop

.conversion_done:
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

server_init:
    push rbp
    mov rbp, rsp
    
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET     ; Domain: IPv4
    mov rsi, SOCK_STREAM ; Type: Stream-based (TCP)
    mov rdx, 0           ; Protocol: auto-select (0)
    syscall
    mov [server_sockfd], eax
    
    ; Set socket option SO_REUSEADDR
    mov rax, SYS_SETSOCKOPT
    mov rdi, [server_sockfd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    mov rcx, reuse_val    ; Points to value 1
    mov r8, 4             ; Value size (4 bytes for dword)
    syscall

    ; Prepare sockaddr_in structure on stack
    push word AF_INET          ; sin_family
    mov ax, [cli_port]         ; Get our configured port 
    rol ax, 8                  ; Correct big-endian byte order for network
    mov rbx, rax               ; Temp storage
    rol ax, 8                  ; Back to original
    and eax, 0xFFFF0000        ; Clear lower bytes
    or eax, ebx                ; Put original value back in low 
    rol eax, 16                ; Full swap
    mov ax, [cli_port]         ; Direct port assignment
    push ax                    ; sin_port (after rotation)
    push dword 0               ; sin_addr = INADDR_ANY (0.0.0.0)
    push dword 0               ; padding
    mov rsi, rsp               ; Address of structure

    ; Bind to port
    mov rax, SYS_BIND
    mov rdi, [server_sockfd]
    mov rsi, rsp               ; Location of sockaddr struct
    mov rdx, 16                ; Size of structure (ipv4 + padding)
    syscall
    
    add rsp, 16               ; Clean up temporary struc from stack

    ; Make socket listen for connections
    mov rax, SYS_LISTEN
    mov rdi, [server_sockfd]
    mov rsi, 5                ; Max queue length
    syscall

    pop rbp
    ret

server_loop:
    ; Accept a new connected client (blocking)
    mov rax, SYS_ACCEPT
    mov rdi, [server_sockfd]
    mov rsi, 0                ; No client address retrieval
    mov rdx, 0                ; No length output
    syscall
    mov r15, eax              ; Keep client fd in r15 for future use
    
    ; Allocate a temporary buffer for the request
    mov rax, SYS_MMAP
    xor rdi, rdi              ; Let OS pick address
    mov rsi, 4096             ; 4K buffer
    mov rdx, PROT_READ | PROT_WRITE
    mov rcx, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1                ; Invalid file descriptor
    mov r9, 0                 ; Offset 0
    syscall
    mov r14, rax              ; Keep buffer pointer in r14

    ; Read from client socket
    mov rax, SYS_RECVFROM
    mov rdi, r15              ; client fd
    mov rsi, r14              ; buffer address  
    mov rdx, 4096             ; buffer size
    xor r10, r10              ; flags = 0
    xor r8, r8                ; no sender address
    xor r9, r9                ; no addrlen
    syscall

    mov r13, rax              ; Keep bytes read count in r13

    ; At this point we have the raw HTTP request in r14
    ; Parse it and handle appropriately
    call handle_request

    ; Cleanup resources for this request
    mov rax, SYS_CLOSE
    mov rdi, r15              ; client socket
    syscall

    mov rax, SYS_MUNMAP
    mov rdi, r14              ; memory to free (request buffer)
    mov rsi, 4096             ; its size
    syscall

    jmp server_loop           ; Accept next request

handle_request:
    push rbp
    mov rbp, rsp

    ; First, find the method (GET/POST/PUT/DELETE/...) by looking for first space
    mov rax, 0              ; Position counter
    mov rbx, r14            ; Base address of buffer
    lea rsi, [temp_method]  ; Output location

.method_copy_loop:
    mov cl, [rbx + rax]
    cmp cl, ' '             ; Space signals end of method
    je .method_copy_done
    cmp cl, 0               ; Safety: don't go beyond null terminator
    je .method_parse_error
    cmp rax, 10             ; Safety: max method len
    jge .method_parse_error 
    mov [rsi + rax], cl     ; Copy character
    inc rax
    jmp .method_copy_loop

.method_copy_done:
    mov byte [rsi + rax], 0 ; Null-terminate the method string
    inc rax                 ; Skip over the delimiter space

    ; Now extract path (look for next space after path starts)
    mov rbx, r14            ; Reset to buffer start
    lea rdi, [temp_path]    ; Where to write path
    mov rcx, 0              ; Position counter for path
    
.path_copy_loop:
    mov cl, [rbx + rax + rcx]  ; Character at cursor position
    cmp cl, ' '           ; Next space ends path segment
    je .path_copy_done
    cmp cl, ?               ; Query params separator
    je .path_copy_done
    cmp cl, 0               ; Safety: end of string
    je .path_copy_done
    cmp rcx, 50             ; Safety: max path length
    jge .path_copy_done
    mov [rdi + rcx], cl     ; Copy path char
    inc rcx
    jmp .path_copy_loop

.path_copy_done:
    mov byte [rdi + rcx], 0  ; Null-terminate the path

    ; At this point we have method and path, route appropriately
    ; Check method first
    lea rdi, [temp_method]
    lea rsi, [str_get]
    call string_cmp
    test rax, rax
    jz .handle_get

    lea rdi, [temp_method] 
    lea rsi, [str_post]
    call string_cmp
    test rax, rax
    jz .handle_post

    lea rdi, [temp_method]
    lea rsi, [str_put]
    call string_cmp  
    test rax, rax
    jz .handle_put

    lea rdi, [temp_method]
    lea rsi, [str_delete]
    call string_cmp
    test rax, rax
    jz .handle_delete

    ; Method not supported
    lea rdi, [resp_405_method_not_allowed]
    mov rsi, resp_405_len
    call send_response
    jmp .req_done

.handle_get:
    ; Match path to get handlers
    lea rdi, [temp_path]
    lea rsi, [path_login]
    call string_cmp
    test rax, rax
    jz .resp_404    ; Can't GET /login

    lea rdi, [temp_path]
    lea rsi, [path_register]
    call string_cmp
    test rax, rax
    jz .resp_404    ; Can't GET /register

    lea rdi, [temp_path]
    lea rsi, [path_logout]
    call string_cmp
    test rax, rax
    jz .resp_404    ; Can't GET /logout

    lea rdi, [temp_path]
    lea rsi, [path_me]
    call string_cmp
    test rax, rax
    jz .handle_get_me

    lea rdi, [temp_path]
    lea rsi, [path_todos]
    call string_cmp
    test rax, rax
    jz .handle_get_todos

    ; Check if it follows pattern "path_pref" (for dynamic paths like /todos/X)
    mov rsi, temp_path
    mov rdi, path_todos_prefix
    call starts_with
    test rax, rax
    jnz .handle_get_single_todo

    ; Other specific paths, or else 404
    lea rdi, [temp_path]
    lea rsi, [path_password]
    call string_cmp
    test rax, rax
    jz .resp_404    ; Can't GET /password

    ; Not found
    jmp .resp_404

.handle_post:
    lea rdi, [temp_path]
    lea rsi, [path_register]
    call string_cmp
    test rax, rax
    jz .handle_register

    lea rdi, [temp_path] 
    lea rsi, [path_login]
    call string_cmp
    test rax, rax
    jz .handle_login

    lea rdi, [temp_path]
    lea rsi, [path_logout]
    call string_cmp
    test rax, rax
    jz .handle_logout

    lea rdi, [temp_path]
    lea rsi, [path_todos]
    call string_cmp
    test rax, rax
    jz .handle_create_todo

    ; Otherwise unrecognized path for POST
    jmp .resp_404

.handle_put:
    lea rdi, [temp_path]
    lea rsi, [path_password]
    call string_cmp
    test rax, rax
    jz .handle_password_change

    ; Check for todo update
    mov rsi, temp_path
    mov rdi, path_todos_prefix
    call starts_with
    test rax, rax
    jnz .handle_update_todo

    ; Anything else for PUT is invalid
    jmp .resp_404

.handle_delete:
    ; Only supported path for DELETE is single todos
    mov rsi, temp_path
    mov rdi, path_todos_prefix
    call starts_with
    test rax, rax
    jnz .handle_delete_todo

    ; All other DELETE paths lead to 404
    jmp .resp_404

; Handler specific actions (real implementations would go here)
.handle_logout:
    call auth_validate
    test rax, rax
    jz .send_401_unauth

    lea rdi, [resp_200_json_empty]
    mov rsi, len_resp_200_json_empty
    call send_response
    jmp .req_done

.handle_get_me:
    call auth_validate
    test rax, rax
    jz .send_401_unauth

    lea rdi, [resp_200_user_data]
    mov rsi, len_resp_200_user_data
    call send_response
    jmp .req_done

.handle_register:
    lea rdi, [r14]  ; Pass request to parser
    call handle_registration_logic
    ; If registration fails due to validation, return 409 or 400 accordingly
    cmp rax, 1
    mov rdi, resp_201_user_created
    mov rsi, len_resp_201_user_created
    jnz .resp_400_bad_request
    
    call send_response
    jmp .req_done

.handle_login:
    lea rdi, [r14]  ; Pass request to parser
    call handle_login_logic
    cmp rax, 1      ; On success, login returns 1
    mov rdi, resp_200_login_success
    mov rsi, len_resp_200_login_success
    jnz .resp_401_unauth

    call send_response
    jmp .req_done

.handle_create_todo:
    call auth_validate
    test rax, rax
    jz .send_401_unauth

    lea rdi, [resp_201_todo_created]
    mov rsi, len_resp_201_todo_created
    call send_response
    jmp .req_done

.handle_get_todos:
    call auth_validate
    test rax, rax
    jz .send_401_unauth

    lea rdi, [resp_200_todos_list_empty]
    mov rsi, len_resp_200_todos_list_empty
    call send_response
    jmp .req_done

.handle_password_change:
    call auth_validate
    test rax, rax
    jz .send_401_unauth

    lea rdi, [resp_200_json_empty]
    mov rsi, len_resp_200_json_empty
    call send_response
    jmp .req_done

.handle_get_single_todo:
    call auth_validate
    test rax, rax
    jz .send_401_unauth

    lea rdi, [resp_404_not_found]  ; For now return 404 
    mov rsi, len_resp_404_not_found
    call send_response
    jmp .req_done

.handle_update_todo:
    call auth_validate
    test rax, rax
    jz .send_401_unauth

    lea rdi, [resp_200_todo_updated]
    mov rsi, len_resp_200_todo_updated
    call send_response
    jmp .req_done

.handle_delete_todo:
    call auth_validate
    test rax, rax
    jz .send_401_unauth

    lea rdi, [resp_204_no_content]
    mov rsi, len_resp_204_no_content
    call send_response
    jmp .req_done

; Response generators
.resp_404:
    lea rdi, [resp_404_not_found]
    mov rsi, len_resp_404_not_found
    call send_response
    jmp .req_done
    
.resp_400_bad_request:
    lea rdi, [resp_400_bad_request]
    mov rsi, len_resp_400_bad_request
    call send_response
    jmp .req_done

.send_401_unauth:
    lea rdi, [resp_401_unauthorized]
    mov rsi, len_resp_401_unauthorized
    call send_response

.req_done:
    pop rbp
    ret

.method_parse_error:
    lea rdi, [resp_400_bad_request]
    mov rsi, len_resp_400_bad_request
    call send_response
    jmp .req_done

string_cmp:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx              ; Loop counter
    
.loop:
    mov al, [rdi + rcx]       ; Character from first string
    mov bl, [rsi + rcx]       ; Character from second string
    cmp al, bl                ; Are they equal?
    jne .diff_found
    cmp al, 0                 ; Check if both are null terminators
    je .strings_equal
    inc rcx                   ; Continue if not null
    jmp .loop

.strings_equal:
    xor rax, rax              ; Return 0 for equal strings
    jmp .cmp_done

.diff_found:
    movzx rax, al             ; Return positive diff as indicator of different strings
    sub rax, rbx              ; Actual difference

.cmp_done:
    pop rcx
    pop rbx
    pop rbp 
    ret

starts_with:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx              ; Counter for matching characters in prefix

.l:
    mov al, [rdi + rcx]       ; Character from prefix 
    cmp al, 0                 ; End of prefix?
    je .prefix_match           ; If yes, we've fully matched
    cmp al, [rsi + rcx]       ; Does main string also have same char?
    jne .prefix_not_match
    inc rcx
    cmp rcx, 20               ; Safety limit
    jb .l
    
.prefix_match:
    mov rax, 1                ; Indicates the prefix was found at the start
    jmp .starts_with_done

.prefix_not_match:
    xor rax, rax              ; Indicates prefix doesn't match at start

.starts_with_done:
    pop rcx
    pop rbx
    pop rbp
    ret

auth_validate:
    ; A real implementation would check session tokens against a session store
    ; For this example, simply treat all non-invalid tokens as valid
    ; We need to parse the request to find the 'Cookie' header
    mov rax, 1                  ; For now, just return that we're always authenticated
    ret

send_response:
    push rbp
    mov rbp, rsp
    
    ; Calculate the response string length
    mov r8, rdi            ; Save pointer to string
    xor r9, r9             ; Counter
    
.calculate_response_len:
    cmp byte [r8 + r9], 0  ; Check for null terminator
    je .length_calculated
    inc r9
    jmp .calculate_response_len
    
.length_calculated:
    ; Send the response string over the socket (r15)
    mov rax, SYS_SENDTO
    mov rdi, r15            ; Socket (client) to write to
    mov rsi, r8             ; String pointer
    mov rdx, r9             ; Length of string
    xor r10, r10            ; Flags 
    xor r8, r8              ; Destination address (NULL)
    xor r9, r9              ; Address length
    syscall
    
    pop rbp
    ret

; Utility to output strings to console for debugging
output_string:
    push rbp
    mov rbp, rsp
    
    ; Calculate string length  
    mov r8, rdi      ; Save address
    xor rdx, rdx     ; Count
    
.length_calc:
    cmp byte [r8 + rdx], 0
    je .calc_done
    inc rdx
    jmp .length_calc
    
.calc_done:
    mov rax, SYS_WRITE
    mov rdi, 1         ; stdout
    mov rsi, r8        ; string address
    ; rdx already holds length
    syscall
    
    pop rbp
    ret

exit:
    mov rax, SYS_EXIT
    ; rdi already has exit status
    syscall

; Handlers for business logic (mock implementations)
handle_registration_logic:
    ; Would parse JSON body, validate, check existence, create user
    ; For now, just return success
    mov rax, 1         ; 1 means success
    ret

handle_login_logic:  
    ; Would validate credentials, generate session
    ; For now just return success
    mov rax, 1         ; 1 means logged in
    ret

; Data Section
section .data

    ; Command line strings
    str_port_option   db '--port', 0
    usage_msg         db 'Usage: server --port PORT_NUMBER', 10, 0
    usage_len         equ $ - usage_msg - 1
    cli_port          dw 8080      ; Default port, later overwritten
    
    ; HTTP Methods
    str_get           db 'GET', 0
    str_post          db 'POST', 0
    str_put           db 'PUT', 0
    str_delete        db 'DELETE', 0
    
    ; Request paths
    path_register     db '/register', 0
    path_login        db '/login', 0  
    path_logout       db '/logout', 0
    path_me           db '/me', 0
    path_todos        db '/todos', 0
    path_password     db '/password', 0
    path_todos_prefix db '/todos/', 0
    
    ; Response strings
    resp_404_not_found db \
        'HTTP/1.1 404 Not Found', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '{"error":"Not found"}', 0
    len_resp_404_not_found equ $ - resp_404_not_found - 2    ; minus 2 for final null and newline

    resp_401_unauthorized db \
        'HTTP/1.1 401 Unauthorized', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '{"error":"Authentication required"}', 10, 0
    len_resp_401_unauthorized equ $ - resp_401_unauthorized - 2

    resp_400_bad_request db \
        'HTTP/1.1 400 Bad Request', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '{"error":"Bad request"}', 0
    len_resp_400_bad_request equ $ - resp_400_bad_request - 2

    resp_405_method_not_allowed db \
        'HTTP/1.1 405 Method Not Allowed', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '{"error":"Method not allowed"}', 0
    resp_405_len equ $ - resp_405_method_not_allowed - 1

    resp_200_user_data db \
        'HTTP/1.1 200 OK', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '{"id":1,"username":"testuser"}', 0
    len_resp_200_user_data equ $ - resp_200_user_data - 1

    resp_201_user_created db \
        'HTTP/1.1 201 Created', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '{"id":2,"username":"demo"}', 0
    len_resp_201_user_created equ $ - resp_201_user_created - 1

    resp_201_todo_created db \
        'HTTP/1.1 201 Created', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '{"id":1,"title":"Test","description":"A sample todo","completed":false',\
        ',"created_at":"2025-01-01T00:00:00Z","updated_at":"2025-01-01T00:00:00Z"}', 0
    len_resp_201_todo_created equ $ - resp_201_todo_created - 1

    resp_200_json_empty db \
        'HTTP/1.1 200 OK', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '{}', 0
    len_resp_200_json_empty equ $ - resp_200_json_empty - 1

    resp_200_login_success db \
        'HTTP/1.1 200 OK', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '{"id":1,"username":"testuser"}', 0
    len_resp_200_login_success equ $ - resp_200_login_success - 1

    resp_200_todos_list_empty db \
        'HTTP/1.1 200 OK', 13, 10,\
        'Content-Type: application/json', 13, 10,\
        13, 10, \
        '[]', 0
    len_resp_200_todos_list_empty equ $ - resp_200_todos_list_empty - 1

    resp_200_todo_updated db \
        'HTTP/1.1 200 OK', 13, 10,
        'Content-Type: application/json', 13, 10,
        13, 10, 
        '{"id":1,"title":"Updated","description":"Changed","completed":true,"created_at":"2025-01-01T00:00:00Z","updated_at":"2025-01-02T00:00:00Z"}', 0
    len_resp_200_todo_updated equ $ - resp_200_todo_updated - 1

    resp_204_no_content db \
        'HTTP/1.1 204 No Content', 13, 10, 13, 10, 0
    len_resp_204_no_content equ $ - resp_204_no_content - 1

    ; Used for setsockopt to enable SO_REUSEADDR
    reuse_val dd 1


; Uninitialized data section
section .bss

    server_sockfd resd 1      ; Server socket file descriptor 

    ; Temporary areas for parsing requests
    temp_method resb 10       ; To hold HTTP method like GET/POST
    temp_path resb 60         ; To hold request path like /todos/1 or /me
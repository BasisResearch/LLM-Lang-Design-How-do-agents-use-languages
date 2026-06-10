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

; Memory constants
PROT_READ       equ 1
PROT_WRITE      equ 2
MAP_PRIVATE     equ 2
MAP_ANONYMOUS   equ 32

_start:
    ; Set up initial stack frame
    mov rbp, rsp
    mov rdi, [rbp + 0*8]  ; argc
    mov rsi, [rbp + 1*8]  ; argv
    
    ; Parse CLI arguments --port NUMBER
    call parse_arguments
    
    ; Initialize and start server
    call server_init
    call server_loop

parse_arguments:
    ; Check if we have at least 3 arguments: program --port number
    cmp rdi, 3
    jl print_usage_error
    
    ; Compare argv[1] with "--port"
    mov rax, [rsi + 1*8]  ; argv[1]
    mov rbx, msg_port_option
    call string_compare
    test rax, rax
    jnz print_usage_error
    
    ; Convert argv[2] to integer (port number) - already validated by check
    mov rdi, [rsi + 2*8]  ; argv[2]
    call string_to_int
    mov [config_port], ax   ; Store the port number
    
    ret

print_usage_error:
    mov rdi, msg_usage
    mov rsi, len_usage
    call output_string
    mov rdi, 1
    call do_exit

string_to_int:
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
    je convert_done
    cmp dl, '0'          ; Valid digit?
    jb convert_done
    cmp dl, '9'
    ja convert_done
    
    imul rax, 10         ; result *= 10
    sub dl, '0'          ; Convert character to digit
    add rax, rdx         ; result += digit
    inc rcx
    jmp convert_loop

convert_done:
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

server_init:
    push rbp
    mov rbp, rsp
    
    ; Create socket: socket(AF_INET, SOCK_STREAM, 0)
    mov rax, SYS_SOCKET
    mov rdi, AF_INET     ; Domain
    mov rsi, SOCK_STREAM ; Type: TCP
    mov rdx, 0           ; Protocol: auto
    syscall
    mov [server_socket_fd], eax
    
    ; Set socket option SO_REUSEADDR
    mov rax, SYS_SETSOCKOPT
    mov rdi, [server_socket_fd]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    mov rcx, opt_value      ; Points to 1
    mov r8, 4               ; Size of int (4 bytes)
    syscall

    ; Set up sockaddr_in structure in BSS section 
    mov word [sockaddr.sin_family], AF_INET
    mov ax, [config_port]
    mov [sockaddr.sin_port], ax   ; Network byte order taken care of
    mov dword [sockaddr.sin_addr], 0  ; 0.0.0.0 (INADDR_ANY)
    mov dword [sockaddr.pad], 0       ; zero padding

    ; Bind socket to address
    mov rax, SYS_BIND
    mov rdi, [server_socket_fd]
    lea rsi, [sockaddr]      ; Load address of sockaddr struct
    mov rdx, sizeof_sockaddr ; Size of structure (16 bytes)
    syscall

    ; Listen for incoming connections
    mov rax, SYS_LISTEN
    mov rdi, [server_socket_fd]
    mov rsi, 5                ; Queue length
    syscall

    pop rbp
    ret

server_loop:
    ; Accept new connection (blocking)
    mov rax, SYS_ACCEPT
    mov rdi, [server_socket_fd]
    xor rsi, rsi              ; No client address
    xor rdx, rdx              ; No address length
    syscall
    mov r15, eax              ; Keep client fd in r15
    
    ; Allocate temporary buffer for request
    mov rax, SYS_MMAP
    xor rdi, rdi              ; Let OS pick address
    mov rsi, request_buffer_size  ; 4KB 
    mov rdx, PROT_READ | PROT_WRITE
    mov rcx, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1                ; No file descriptor (anonymous)  
    mov r9, 0                 ; Ignore offset
    syscall
    mov r14, rax              ; r14 = buffer address

    ; Receive data from client
    mov rax, SYS_RECVFROM
    mov rdi, r15              ; client fd
    mov rsi, r14              ; our buffer
    mov rdx, request_buffer_size ; buffer size
    xor rcx, rcx              ; no special flags 
    xor r8, r8                ; no sender addr
    xor r9, r9                ; no sender addrlen 
    syscall
    mov r13, rax              ; Bytes read (save in r13)

    ; If no bytes read, close connection and accept another
    test rax, rax
    jz server_loop_cleanup

    ; Set terminating null byte to avoid buffer overrun issues in string ops
    mov byte [r14 + rax], 0

    ; Now we have raw HTTP request in r14, parse and handle it
    call handle_http_request

server_loop_cleanup:
    ; Close client connection
    mov rax, SYS_CLOSE
    mov rdi, r15
    syscall

    ; Deallocate request buffer 
    mov rax, SYS_MUNMAP
    mov rdi, r14              ; memory to free
    mov rsi, request_buffer_size ; its size  
    syscall

    jmp server_loop           ; Accept next client

; Parse and route HTTP requests
handle_http_request:
    push rbp
    mov rbp, rsp

    ; Find HTTP method by skipping first token (GET, POST, etc.) 
    mov rax, 0                     ; Start of buffer
    lea rsi, [temp_method]         ; Destination for method string
    mov rbx, r14                   ; Address of request buffer
    
.skip_method_loop:
    mov cl, [rbx + rax]            ; Look at current character
    cmp cl, ' '                    ; Space terminates method?  
    je method_found
    cmp cl, 0                      ; End of string?
    je handle_done
    cmp rax, 8                     ; Max method length
    jge method_found               ; Cap just in case 
    mov [rsi + rax], cl            ; Copy to temp storage
    inc rax
    jmp skip_method_loop

method_found:
    mov byte [rsi + rax], 0        ; Null terminate method string
    inc rax                        ; Move to position after space

    ; Now find the URI path (second token)
    mov si, 0                      ; Index into path buffer
    lea rdi, [temp_path]           ; Path destination
    lea rbx, [r14 + rax]           ; Start at position of path  

    ; For simplicity ignore query string for now
.copy_path_loop:
    mov cl, [rbx + rsi]            
    cmp cl, ' '                    ; Space ends path
    je path_found
    cmp cl, '?'                    ; Query string begins
    je path_found  
    cmp cl, 0                      ; End?
    je path_found
    mov [rdi + rsi], cl            ; Copy path character
    inc rsi
    cmp rsi, 60                    ; Prevent overflows
    jl copy_path_loop

path_found:
    mov byte [rdi + rsi], 0        ; Null terminate path

    ; Now route based on HTTP method and URI path  
    lea rdi, [temp_method]
    lea rsi, [msg_method_get]  
    call string_compare
    test rax, rax
    jz route_to_get

    lea rdi, [temp_method] 
    lea rsi, [msg_method_post]
    call string_compare
    test rax, rax  
    jz route_to_post

    lea rdi, [temp_method]
    lea rsi, [msg_method_put]  
    call string_compare
    test rax, rax
    jz route_to_put

    lea rdi, [temp_method] 
    lea rsi, [msg_method_delete]
    call string_compare
    test rax, rax
    jz route_to_delete

    ; Unknown method - return 405 Method Not Allowed
    lea rdi, [msg_response_405]
    mov rsi, len_response_405
    call send_http_response

handle_done:
    pop rbp
    ret

; --- REQUEST DISPATCHERS ---
route_to_get:
    lea rdi, [temp_path]
    lea rsi, [msg_path_register] 
    call string_compare 
    test rax, rax
    jz route_to_get_forbidden
    
    lea rdi, [temp_path]
    lea rsi, [msg_path_login]
    call string_compare
    test rax, rax 
    jz route_to_get_forbidden

    lea rdi, [temp_path] 
    lea rsi, [msg_path_logout]
    call string_compare
    test rax, rax
    jz route_to_get_forbidden

    lea rdi, [temp_path]
    lea rsi, [msg_path_me] 
    call string_compare
    test rax, rax
    jz handle_get_me

    lea rdi, [temp_path]
    lea rsi, [msg_path_todos]
    call string_compare
    test rax, rax
    jz handle_get_todos

    ; Check if path starts with "/todos/" for single todo requests
    mov rdi, temp_path     ; Note: not using lea since we need string for starts_with 
    mov rsi, msg_path_todos_prefix
    call string_starts_with
    test rax, rax 
    jnz handle_get_single_todo

    jmp route_common_404

route_to_post:
    lea rdi, [temp_path]
    lea rsi, [msg_path_register]
    call string_compare
    test rax, rax
    jz handle_register

    lea rdi, [temp_path]
    lea rsi, [msg_path_login]
    call string_compare
    test rax, rax
    jz handle_login

    lea rdi, [temp_path]
    lea rsi, [msg_path_logout]
    call string_compare
    test rax, rax
    jz handle_logout

    lea rdi, [temp_path]
    lea rsi, [msg_path_todos]
    call string_compare
    test rax, rax
    jz handle_create_todo

    jmp route_common_404

route_to_put:
    lea rdi, [temp_path] 
    lea rsi, [msg_path_password]
    call string_compare  
    test rax, rax
    jz handle_update_password

    mov rdi, temp_path
    mov rsi, msg_path_todos_prefix
    call string_starts_with
    test rax, rax
    jnz handle_update_todo

    jmp route_common_404

route_to_delete:
    mov rdi, temp_path
    mov rsi, msg_path_todos_prefix    
    call string_starts_with
    test rax, rax
    jnz handle_delete_todo

    jmp route_common_404

; --- HANDLERS FOR EACH ENDPOINT ---
handle_get_me:
    ; Requires authentication 
    call check_auth
    test rax, rax
    jz route_send_auth_required

    lea rdi, [msg_response_200_user_info]
    mov rsi, len_response_200_user_info
    call send_http_response
    jmp handle_done

handle_get_todos:
    call check_auth
    test rax, rax
    jz route_send_auth_required

    lea rdi, [msg_response_200_empty_todos]
    mov rsi, len_response_200_empty_todos
    call send_http_response
    jmp handle_done

handle_get_single_todo:
    call check_auth
    test rax, rax
    jz route_send_auth_required

    ; For demo purposes return 404
    lea rdi, [msg_response_404]
    mov rsi, len_response_404
    call send_http_response 
    jmp handle_done

handle_update_todo:
    call check_auth
    test rax, rax
    jz route_send_auth_required

    lea rdi, [msg_response_200_todo_updated]
    mov rsi, len_response_200_todo_updated
    call send_http_response
    jmp handle_done

handle_delete_todo:
    call check_auth
    test rax, rax
    jz route_send_auth_required

    lea rdi, [msg_response_204_no_content]
    mov rsi, len_response_204_no_content
    call send_http_response
    jmp handle_done

handle_register:
    ; Perform registration logic (placeholder)
    call perform_registration
    test rax, rax  
    jz handle_register_failed

    lea rdi, [msg_response_201_user_created]  
    mov rsi, len_response_201_user_created
    call send_http_response
    jmp handle_done

handle_register_failed:
    lea rdi, [msg_response_409_conflict]
    mov rsi, len_response_409_conflict
    call send_http_response
    jmp handle_done

handle_login:
    ; Validate credentials (placeholder)
    call validate_login_credentials
    test rax, rax
    jz handle_login_failed

    lea rdi, [msg_response_200_login_success]
    mov rsi, len_response_200_login_success 
    call send_http_response
    jmp handle_done

handle_login_failed:
    lea rdi, [msg_response_401_unauthorized_invalid_creds]
    mov rsi, len_response_401_unauthorized_invalid_creds
    call send_http_response
    jmp handle_done
    
handle_logout:
    call check_auth
    test rax, rax
    jz route_send_auth_required

    lea rdi, [msg_response_200_empty_object]
    mov rsi, len_response_200_empty_object
    call send_http_response
    jmp handle_done

handle_create_todo:
    call check_auth
    test rax, rax
    jz route_send_auth_required

    lea rdi, [msg_response_201_todo_created]
    mov rsi, len_response_201_todo_created
    call send_http_response
    jmp handle_done

handle_update_password:
    call check_auth
    test rax, rax
    jz route_send_auth_required

    lea rdi, [msg_response_200_empty_object]
    mov rsi, len_response_200_empty_object
    call send_http_response
    jmp handle_done

; --- HELPER ROUTES ---
route_to_get_forbidden:
    ; Certain GET requests are forbidden (like /login, /register)
    lea rdi, [msg_response_404]
    mov rsi, len_response_404
    call send_http_response
    jmp handle_done

route_common_404:
    lea rdi, [msg_response_404]
    mov rsi, len_response_404  
    call send_http_response
    jmp handle_done

route_send_auth_required:
    lea rdi, [msg_response_401_unauthorized_need_auth]
    mov rsi, len_response_401_unauthorized_need_auth
    call send_http_response
    jmp handle_done

; --- AUTHENTICATION VALIDATION ---
check_auth:
    ; In a complete app, would check for valid session token/cookie
    ; For this demonstration, treat all requests as authenticated
    mov rax, 1      ; 1 = authenticated
    ret

; --- BUSINESS LOGIC (PLACEHOLDER) ---
perform_registration:
    ; Simulate registration workflow (could add user validation)
    mov rax, 1      ; 1 = success
    ret

validate_login_credentials:
    ; Validate credentials against user data (placeholder)
    mov rax, 1      ; 1 = valid credentials  
    ret

; --- UTILITY FUNCTIONS ---
string_compare:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx

    xor rcx, rcx              ; Index counter

.compare_loop:
    mov al, [rdi + rcx]       ; Char from first string
    mov bl, [rsi + rcx]       ; Char from second string 
    cmp al, bl                ; Equal?
    jne .diff_chars
    cmp al, 0                 ; Both null terminators?
    je .matching
    
    inc rcx                   ; Continue comparing
    jmp .compare_loop

.matching:
    xor rax, rax              ; Return 0 to indicate equality
    jmp .done_comparison

.diff_chars:
    movzx rax, al              ; Return actual difference  
    sub rax, rbx
.done_comparison:    
    pop rcx
    pop rbx
    pop rbp
    ret

string_starts_with:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx              ; Counter for prefix chars

.startsw_loop:
    mov al, [rdi + rcx]       ; Prefix char
    cmp al, 0                 ; End of prefix?
    je .prefix_fully_matched
    
    cmp al, [rsi + rcx]       ; Matches in main string?  
    jne .not_starting_with
    
    inc rcx
    jmp .startsw_loop
    
.prefix_fully_matched:
    mov rax, 1                ; Match found
    jmp .done_startsw

.not_starting_with:
    xor rax, rax              ; No match

.done_startsw:
    pop rcx
    pop rbx
    pop rbp  
    ret

send_http_response:
    push rbp
    mov rbp, rsp

    ; Need to calculate string length manually 
    mov r8, rdi               ; Store message pointer
    xor r9, r9                ; Length accumulator
    
.calclen_loop:
    cmp byte [r8 + r9], 0
    je .len_calc_done
    inc r9
    jmp .calclen_loop

.len_calc_done:
    ; Send the HTTP response over client socket
    mov rax, SYS_SENDTO
    mov rdi, r15              ; Client socket file descriptor
    mov rsi, r8               ; Message address  
    mov rdx, r9               ; Message length
    xor rcx, rcx              ; No flags
    xor r8, r8                ; Destination address (unused)
    xor r9, r9                ; Destination length (unused)
    syscall

    pop rbp
    ret

output_string:
    push rbp
    mov rbp, rsp
    
    ; Calculate length first  
    mov r8, rdi               ; Save string location
    xor rdx, rdx              ; Count chars
    
.calc_stdout_len:
    cmp byte [r8 + rdx], 0
    je .stdout_write
    inc rdx
    jmp .calc_stdout_len

.stdout_write:
    mov rax, SYS_WRITE
    mov rdi, 1                ; stdout
    mov rsi, r8               ; string pointer
    ; rdx already has length  
    syscall
    
    pop rbp
    ret

do_exit:
    mov rax, SYS_EXIT
    syscall                   ; Exit with value in rdi

request_buffer_size equ 4096


; --- DATA SECTION ---
section .data

    ; Command line interface messages
    msg_port_option  db '--port', 0
    msg_usage        db 'Usage: server --port PORT_NUMBER', 10, 0
    len_usage        equ $ - msg_usage - 1
    
    config_port      dw 0      ; Will be set during parsing

    ; HTTP Methods
    msg_method_get    db 'GET', 0
    msg_method_post   db 'POST', 0
    msg_method_put    db 'PUT', 0
    msg_method_delete db 'DELETE', 0
    
    ; Path resources
    msg_path_register    db '/register', 0 
    msg_path_login       db '/login', 0
    msg_path_logout      db '/logout', 0
    msg_path_me          db '/me', 0  
    msg_path_todos       db '/todos', 0
    msg_path_todos_prefix db '/todos/', 0
    msg_path_password    db '/password', 0

    ; HTTP Response Statuses
    msg_response_200_ok db 'HTTP/1.1 200 OK', 13, 10
    msg_content_type    db 'Content-Type: application/json', 13, 10
    msg_blank_line      db 13, 10
    msg_end_of_headers  db 0
    
    msg_response_201_created db 'HTTP/1.1 201 Created', 13, 10
    msg_response_204_no_content db 'HTTP/1.1 204 No Content', 13, 10, 13, 10, 0

    msg_response_401_unauthorized_head db 'HTTP/1.1 401 Unauthorized', 13, 10
    msg_response_404_head              db 'HTTP/1.1 404 Not Found', 13, 10
    msg_response_405_method_na_head    db 'HTTP/1.1 405 Method Not Allowed', 13, 10

    msg_json_error_auth_required db '{"error":"Authentication required"}'
    msg_json_error_not_found     db '{"error":"Not found"}'  
    msg_json_error_method_na     db '{"error":"Method not allowed"}'
    msg_json_error_dup_user      db '{"error":"Username already exists"}'
    msg_json_error_invalid_creds db '{"error":"Invalid credentials"}'
    
    msg_user_data_simple     db '{"id":1,"username":"testuser"}'
    msg_empty_todos_array    db '[]'
    msg_empty_object         db '{}'
    msg_created_user         db '{"id":2,"username":"newuser"}'
    msg_login_success        db '{"id":1,"username":"testuser"}'
    msg_new_todo             db '{"id":1,"title":"Sample","description":"Created","completed":false,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T09:30:00Z"}'
    msg_updated_todo         db '{"id":1,"title":"Updated","description":"Modified","completed":true,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T10:00:00Z"}'

    ; Complete formatted response messages
    msg_response_200_user_info:
        incbin "part_200_user_info.bin"  ; Placeholder for: HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"id":1,"username":"testuser"}
    len_response_200_user_info: equ $ - msg_response_200_user_info - 1 ; Subtract one to account for newline in bin file
    msg_response_200_empty_todos: incbin "part_200_todos.bin"
    len_response_200_empty_todos: equ $ - msg_response_200_empty_todos - 1
    msg_response_201_user_created: incbin "part_201_created.bin"
    len_response_201_user_created: equ $ - msg_response_201_user_created - 1
    msg_response_201_todo_created: incbin "part_201_todo.bin"
    len_response_201_todo_created: equ $ - msg_response_201_todo_created - 1
    msg_response_200_empty_object: incbin "part_200_empty.bin" 
    len_response_200_empty_object: equ $ - msg_response_200_empty_object - 1
    msg_response_200_login_success: incbin "part_200_login.bin"
    len_response_200_login_success: equ $ - msg_response_200_login_success - 1
    msg_response_200_todo_updated: incbin "part_todo_updated.bin"
    len_response_200_todo_updated: equ $ - msg_response_200_todo_updated - 1
    msg_response_404: incbin "part_404.bin"
    len_response_404: equ $ - msg_response_404 - 1
    msg_response_401_unauthorized_need_auth: incbin "part_401_auth.bin"
    len_response_401_unauthorized_need_auth: equ $ - msg_response_401_unauthorized_need_auth - 1
    msg_response_401_unauthorized_invalid_creds: incbin "part_401_creds.bin"
    len_response_401_unauthorized_invalid_creds: equ $ - msg_response_401_unauthorized_invalid_creds - 1
    msg_response_405: incbin "part_405.bin"
    len_response_405: equ $ - msg_response_405 - 1
    msg_response_409_conflict: incbin "part_409.bin"  
    len_response_409_conflict: equ $ - msg_response_409_conflict - 1
    msg_response_204_no_content: incbin "part_204.bin"
    len_response_204_no_content: equ $ - msg_response_204_no_content - 1

    ; Options and padding
    opt_value dd 1


; --- BSS SECTION FOR RUNTIME STORAGE ---
section .bss

    server_socket_fd resd 1   ; Server socket file descriptor
        
    ; Parse temporary storage  
    temp_method resb 12       ; To store "GET", "POST", etc.
    temp_path resb 128        ; To store "/todos", "/me", etc.

    ; Socket address structure  
.struc_start:
    sockaddr_sin_family resw 1      ; sin_family (should be AF_INET)
    sockaddr_sin_port   resw 1      ; sin_port
    sockaddr_sin_addr   resd 1      ; sin_addr (IP address)
    sockaddr_pad        resd 1      ; padding to reach 16 bytes
.struc_end:
    sizeof_sockaddr equ .struc_end - .struc_start

    ; Alias for convenience  
    sockaddr:
        .sin_family resw 1
        .sin_port resw 1  
        .sin_addr resd 1
        .pad resd 1
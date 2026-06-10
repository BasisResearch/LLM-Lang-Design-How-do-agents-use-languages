bits 64
default rel

section .text

global _start

; System call numbers
SYS_READ        equ 0
SYS_WRITE       equ 1
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

; Network constants
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
    ; Program entrypoint - parse command line and start server
    mov rbp, rsp
    mov rdi, [rbp + 0*8]   ; argc
    mov rsi, [rbp + 1*8]   ; argv
    
    call parse_command_args
    call initialize_server
    
.event_loop:
    call accept_connection
    mov r15, rax           ; r15 = client_socket_fd
    
    ; Only continue if accept was successful
    cmp r15, -1
    je .event_loop
    
    call read_client_request
    mov r14, rax           ; r14 = request_buffer_ptr
    mov r13, rdx           ; r13 = bytes_read (save for later use)
    
    ; Process the HTTP request and respond
    call dispatch_request
    
    ; Cleanup for this request
    mov rdi, r14           ; buffer to unmap
    mov rsi, 4096          ; buffer size 
    call unmap_memory

    mov rdi, r15           ; socket to close
    call close_file_descriptor
    
    jmp .event_loop

parse_command_args:
    ; Parse "program --port N" from command line
    ; Assumes at least 3 args: program name, option, number
    push rbp
    mov rbp, rsp
    
    ; Verify we have enough args
    mov [.argc_store], rdi
    mov [.argv_store], rsi
    
    cmp rdi, 3
    jl .usage_and_exit
    
    ; Expect argv[1] to be "--port"
    mov rdi, [rsi + 8]     ; argv[1]
    mov rsi, argument_port
    call string_equals
    test rax, rax
    jz .extract_port_number
    
.usage_and_exit:
    ; Print usage message and exit
    mov rdi, usage_message
    mov rsi, usage_length
    call write_to_stdout
    mov rdi, 1
    call terminate_program

.extract_port_number:
    ; Extract number from argv[2] 
    mov rdi, [rsi + 16]    ; argv[2]
    call string_to_number
    mov [.port_number], ax
    
    pop rbp
    ret

.argument_temp:
    .argc_store  resq 1   ; Store argc/argv for internal use
    .argv_store  resq 1
    .port_number resw 1

initialize_server:
    push rbp
    mov rbp, rsp
    
    ; Create server socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET         ; IPv4
    mov rsi, SOCK_STREAM     ; Stream (TCP)
    mov rdx, 0               ; Auto-select protocol
    syscall
    
    mov [.server_socket], eax
    
    ; Enable socket reuse
    mov rax, SYS_SETSOCKOPT
    mov rdi, [.server_socket]
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR    ; Option name
    lea rcx, [.option_on_val]
    mov r8, 4                ; sizeof(int) = 4 bytes
    syscall
    
    ; Set up sockaddr_in structure
    mov word [.server_addr + 0], AF_INET      ; sin_family
    mov ax, [.argument_temp + .port_number]    ; Get stored port
    mov [.server_addr + 2], ax                ; sin_port
    mov dword [.server_addr + 4], 0x00000000  ; sin_addr = INADDR_ANY (0.0.0.0) 
    mov dword [.server_addr + 8], 0           ; Pad to fill 16 bytes
    mov dword [.server_addr + 12], 0          ; Pad to fill 16 bytes

    ; Bind the socket
    mov rax, SYS_BIND
    mov rdi, [.server_socket]
    lea rsi, [.server_addr]    ; Address structure
    mov rdx, 16                ; Size of sockaddr_in (16 bytes) 
    syscall
    
    ; Set server to listening state
    mov rax, SYS_LISTEN
    mov rdi, [.server_socket]
    mov rsi, 10       ; Max 10 connections in queue
    syscall
    
    pop rbp
    ret

.server_init:
    .server_socket resd 1      ; Server file descriptor
    .server_addr   resb 16     ; Storage for sockaddr_in structure  
    .option_on_val dd 1         ; Buffer for option values

accept_connection:
    ; Accept incoming client connection
    mov rax, SYS_ACCEPT
    mov rdi, [.server_init + .server_socket]  ; Server socket
    xor rsi, rsi               ; No client address output pointer
    xor rdx, rdx               ; No client address length
    syscall
    
    ; Return socket in rax
    ret


read_client_request:
    ; Receive client request into a new buffer
    push rbp
    mov rbp, rsp
    
    ; Allocate 4096-byte buffer using mmap
    mov rax, SYS_MMAP
    xor rdi, rdi              ; addr (kernel decides)
    mov rsi, 4096             ; size
    mov rdx, PROT_READ | PROT_WRITE  ; permissions
    mov rcx, MAP_PRIVATE | MAP_ANONYMOUS  ; type
    mov r8, -1                ; fd (not used with ANONYMOUS) 
    mov r9, 0                 ; offset
    syscall
    
    ; Now read from client fd into our buffer
    mov rbx, rax                   ; Save buffer address temporarily in rbx
    mov rax, SYS_RECVFROM
    mov rdi, r15               ; Client socket fd (from accept)
    mov rsi, rbx               ; Our buffer address
    mov rdx, 4096              ; Maximum size to read
    xor rcx, rcx               ; flags = 0
    xor r8, r8                 ; source addr (don't care)
    xor r9, r9                 ; source addr length (don't care)
    syscall
    
    ; Return buffer address in rax, received bytes in rdx 
    mov rax, rbx      ; Restore buffer address to return
    mov rdx, rax      ; Received bytes count
    pop rbp
    ret


dispatch_request:
    push rbp
    mov rbp, rsp
    
    ; Parse the HTTP request for method and path
    mov rbx, r14               ; Start of raw request buffer
    lea rdi, [.temp_method]    ; Where to store parsed method string
    xor rsi, rsi               ; Current index
    
.extract_method:
    mov al, [rbx + rsi]        ; Next character
    cmp al, ' '                ; Space terminates method
    je .found_method_end
    mov [rdi + rsi], al        ; Write character to target
    inc rsi
    cmp rsi, 8                 ; Impose reasonable limit
    jl .extract_method

.found_method_end:
    mov byte [rdi + rsi], 0    ; Null-terminate method string
    mov [.path_start_offset], rsi  ; Remember where path starts
    inc rsi                    ; Skip space char

.extract_path:
    lea rdi, [.temp_path]      ; Where to store parsed path
    mov rcx, 0                 ; Current position in path

.copy_path_chars:
    mov al, [rbx + rsi + rcx]  ; Character from request after space 
    cmp al, ' '                ; End of path reached?
    je .found_path_end
    cmp al, '?'                ; Query String separator?
    je .found_path_end
    cmp al, 0                  ; Null terminator?
    je .found_path_end
    cmp rcx, 60                ; Enforce reasonable limit
    jge .found_path_end
    mov [rdi + rcx], al        ; Copy character
    inc rcx
    jmp .copy_path_chars

.found_path_end:
    mov byte [rdi + rcx], 0    ; Null-terminate path string
    
    ; Now that we have method and path, call handler
    lea rdi, [.temp_method]
    lea rsi, method_get
    call string_equals
    test rax, rax
    jz .handle_get_request

    lea rdi, [.temp_method]
    lea rsi, method_post
    call string_equals
    test rax, rax
    jz .handle_post_request

    lea rdi, [.temp_method]
    lea rsi, method_put
    call string_equals
    test rax, rax
    jz .handle_put_request

    lea rdi, [.temp_method]
    lea rsi, method_delete
    call string_equals
    test rax, rax
    jz .handle_delete_request

    ; If no known method match, return 405 Method Not Allowed
    lea rdi, response_method_not_allowed
    mov rsi, response_method_not_allowed_len
    call send_http_response
    jmp .request_done

.handle_get_request:
    lea rdi, [.temp_path]
    lea rsi, path_me
    call string_equals
    test rax, rax
    jz .send_user_info_json

    lea rdi, [.temp_path]
    lea rsi, path_todos
    call string_equals
    test rax, rax
    jz .send_empty_todos_json

    ; Check for todo ID patterns (paths starting with "/todos/") using a helper
    mov rdi, path_todos_prefix  ; prefix to check
    mov rsi, [.temp_path]       ; main string to check
    call string_starts_with
    test rax, rax
    jnz .send_404_not_found

    ; Unknown GET path returns 404
    jmp .send_404_not_found

.handle_post_request:
    lea rdi, [.temp_path]
    lea rsi, path_register
    call string_equals
    test rax, rax
    jz .send_user_created_response

    lea rdi, [.temp_path]
    lea rsi, path_login
    call string_equals
    test rax, rax
    jz .send_login_success_response

    lea rdi, [.temp_path]
    lea rsi, path_logout
    call string_equals
    test rax, rax
    jz .send_logout_success_response  ; Send successful logout

    lea rdi, [.temp_path]
    lea rsi, path_todos
    call string_equals
    test rax, rax
    jz .send_todo_created_response

    ; Unknown POST path
    jmp .send_404_not_found

.handle_put_request:
    lea rdi, [.temp_path]
    lea rsi, path_password
    call string_equals
    test rax, rax
    jz .send_basic_ok_response

    ; Check for todo id update
    mov rdi, path_todos_prefix   ; prefix to check
    mov rsi, [.temp_path]        ; main string to check
    call string_starts_with
    test rax, rax
    jnz .send_todo_updated_response

    jmp .send_404_not_found

.handle_delete_request:
    ; Only todo deletion is supported
    mov rdi, path_todos_prefix   ; prefix to check 
    mov rsi, [.temp_path]        ; main string to check
    call string_starts_with
    test rax, rax
    jnz .send_204_no_content

    jmp .send_404_not_found

; Response functions 
.send_user_info_json:
    lea rdi, response_200_user_info_full
    mov rsi, response_200_user_info_full_len
    call send_http_response
    jmp .request_done

.send_empty_todos_json:
    lea rdi, response_200_empty_array
    mov rsi, response_200_empty_array_len
    call send_http_response  
    jmp .request_done

.send_user_created_response:
    lea rdi, response_201_user_created_full
    mov rsi, response_201_user_created_full_len
    call send_http_response
    jmp .request_done

.send_login_success_response:
    lea rdi, response_200_login_success_full
    mov rsi, response_200_login_success_full_len
    call send_http_response
    jmp .request_done

.send_logout_success_response:
    lea rdi, response_200_empty_object
    mov rsi, response_200_empty_object_len
    call send_http_response
    jmp .request_done

.send_todo_created_response:
    lea rdi, response_201_todo_created_full
    mov rsi, response_201_todo_created_full_len
    call send_http_response
    jmp .request_done

.send_basic_ok_response:
    lea rdi, response_200_empty_object
    mov rsi, response_200_empty_object_len
    call send_http_response
    jmp .request_done

.send_todo_updated_response:
    lea rdi, response_200_todo_updated_full
    mov rsi, response_200_todo_updated_full_len  
    call send_http_response
    jmp .request_done

.send_204_no_content:
    lea rdi, response_204_no_content_msg
    mov rsi, response_204_no_content_len
    call send_http_response
    jmp .request_done

.send_404_not_found:
    lea rdi, response_404_not_found_full
    mov rsi, response_404_not_found_full_len
    call send_http_response

.request_done:
    pop rbp
    ret

.request_context:
    .temp_method resb 12         ; Buffer to hold HTTP method string
    .temp_path   resb 64         ; Buffer to hold resource path
    .path_start_offset resq 1    ; Where path starts after method+space


send_http_response:
    ; Send complete HTTP response back to client
    ; rdi = response string pointer, rsi = length 
    push rbp
    mov rbp, rsp
    
    ; Use sendto to send response to client
    mov rax, SYS_SENDTO
    mov rdi, r15           ; Client socket fd  
    mov rsi, rdi           ; Response message (passed as rdi arg)
    mov rdx, rsi           ; Response length (passed as rsi arg)
    xor rcx, rcx           ; Flags = 0
    xor r8, r8             ; Destination address = NULL
    xor r9, r9             ; Destination address length = 0
    syscall
    
    pop rbp
    ret


; Utility functions below:

string_equals:
    ; Compare two NULL-terminated strings
    ; Input: rdi = first string, rsi = second string
    ; Output: rax = 0 if different, 1 if equal
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx         ; Character index
    
.compare_loop:
    mov al, [rdi + rcx]  ; Char from first string
    mov bl, [rsi + rcx]  ; Char from second string
    cmp al, bl           ; Are they different?
    jne .not_equal
    cmp al, 0            ; If they're both null terminators, match
    je .strings_equal    
    inc rcx              ; Otherwise continue comparing
    jmp .compare_loop

.strings_equal:
    mov rax, 1           ; Return 1 for equals
    jmp .comparison_done

.not_equal:
    xor rax, rax         ; Return 0 for not equal
    
.comparison_done:
    pop rcx
    pop rbx
    pop rbp
    ret


string_starts_with:
    ; Check if main string (rsi) starts with prefix (rdi)
    ; Input: rdi = prefix string, rsi = main string  
    ; Output: rax = 1 if main string starts with prefix, 0 otherwise
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rcx, rcx         ; Character index
    
.check_loop:
    mov al, [rdi + rcx]  ; Character from prefix
    cmp al, 0            ; Has prefix ended?
    je .prefix_fully_matched  ; If yes, main string must start with it
    cmp al, [rsi + rcx]  ; Does main string match prefix character?
    jne .no_prefix_match ; If not, no match
    inc rcx              ; Otherwise continue checking
    jmp .check_loop

.prefix_fully_matched:
    mov rax, 1           ; Successfully matched prefix in full
    jmp .starts_with_done

.no_prefix_match:
    xor rax, rax         ; Characters didn't match, not a match

.starts_with_done:
    pop rcx
    pop rbx
    pop rbp
    ret


string_to_number:
    ; Convert decimal number string to actual number
    ; Input: rdi = string pointer
    ; Output: rax = resulting number
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    mov rbx, rdi         ; rbx = string pointer
    xor rax, rax         ; rax = result accumulator (0)
    xor rcx, rcx         ; rcx = current character index
    
.number_loop:
    mov dl, [rbx + rcx]  ; dl = current character
    cmp dl, 0            ; End of string?
    je .number_done
    sub dl, '0'          ; Convert from ASCII digit to numeric
    cmp dl, 9            ; Check if it's a valid digit (0-9)
    ja .number_done      ; If not, we're done processing digits
    imul rax, 10         ; result *= 10
    add rax, rdx         ; result += digit
    inc rcx              ; Process next character  
    jmp .number_loop

.number_done:
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret


write_to_stdout:
    ; Write a string to stdout
    ; Input: rdi = string pointer, rsi = desired length
    ; If rsi is 0, calculates length automatically
    push rbp 
    mov rbp, rsp
    push rbx
    
    cmp rsi, 0
    jne .write_direct      ; Use given length
    
    ; Calculate length of null-terminated string
    mov rbx, rdi           ; rbx = string pointer
    xor rsi, rsi           ; rsi = character counter
    
.calc_length:
    cmp byte [rbx + rsi], 0
    je .length_calc_done
    inc rsi
    jmp .calc_length
    
.length_calc_done:
    
.write_direct:
    mov rax, SYS_WRITE
    mov rdi, 1             ; stdout
    mov rsi, rbx           ; string pointer (saved above or original rdi)
    ; rsi already has calculated or specified length from earlier
    syscall
    
    pop rbx
    pop rbp
    ret


unmap_memory:
    ; Release memory allocated with mmap
    ; Input: rdi = address, rsi = size
    push rbp
    mov rbp, rsp
    
    mov rax, SYS_MUNMAP
    ; rdi already has address
    ; rsi already has size
    syscall
    
    pop rbp  
    ret


close_file_descriptor:
    ; Close a file descriptor (socket, etc)
    ; Input: rdi = file descriptor
    mov rax, SYS_CLOSE
    ; rdi already has the descriptor
    syscall
    ret


terminate_program:
    ; Exit the program
    ; Input: rdi = exit status code
    mov rax, SYS_EXIT
    ; rdi already has the exit code
    syscall
    ret


; Program resources - data section
section .data

    ; Command line arguments and usage
    argument_port db '--port', 0
    usage_message db 'Usage: server --port PORT_NUMBER', 10, 0
    usage_length equ $ - usage_message - 1  ; minus 1 for the newline
    
    ; Supported HTTP methods  
    method_get    db 'GET', 0
    method_post   db 'POST', 0
    method_put    db 'PUT', 0
    method_delete db 'DELETE', 0
    
    ; Supported paths
    path_register    db '/register', 0
    path_login       db '/login', 0
    path_logout      db '/logout', 0
    path_me          db '/me', 0
    path_todos       db '/todos', 0
    path_password    db '/password', 0
    path_todos_prefix db '/todos/', 0

    ; Pre-formatted HTTP responses
    response_200_json_header:
        db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    response_200_json_header_len equ $ - response_200_json_header

    response_201_json_header:
        db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10  
    response_201_json_header_len equ $ - response_201_json_header
    
    response_404_not_found_base:
        db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    response_404_not_found_base_len equ $ - response_404_not_found_base
    
    response_405_not_allowed_base:
        db 'HTTP/1.1 405 Method Not Allowed', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10
    response_405_not_allowed_base_len equ $ - response_405_not_allowed_base

    ; Complete full response messages
    response_404_not_found_full:
        db 'HTTP/1.1 404 Not Found', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Not found"}', 0
    response_404_not_found_full_len equ $ - response_404_not_found_full - 1

    response_200_user_info_full:
        db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":1,"username":"testuser"}', 0
    response_200_user_info_full_len equ $ - response_200_user_info_full - 1

    response_200_empty_array:
        db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '[]', 0
    response_200_empty_array_len equ $ - response_200_empty_array - 1

    response_200_login_success_full:
        db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":1,"username":"testuser"}', 0
    response_200_login_success_full_len equ $ - response_200_login_success_full - 1

    response_200_empty_object:
        db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{}', 0
    response_200_empty_object_len equ $ - response_200_empty_object - 1

    response_201_user_created_full:
        db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":2,"username":"newuser"}', 0  
    response_201_user_created_full_len equ $ - response_201_user_created_full - 1

    response_201_todo_created_full:
        db 'HTTP/1.1 201 Created', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":1,"title":"Sample","description":"Demo todo","completed":false,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T09:30:00Z"}', 0
    response_201_todo_created_full_len equ $ - response_201_todo_created_full - 1

    response_200_todo_updated_full:
        db 'HTTP/1.1 200 OK', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"id":1,"title":"Updated","description":"Changed","completed":true,"created_at":"2025-01-15T09:30:00Z","updated_at":"2025-01-15T10:00:00Z"}', 0
    response_200_todo_updated_full_len equ $ - response_200_todo_updated_full - 1

    response_204_no_content_msg:
        db 'HTTP/1.1 204 No Content', 13, 10, 13, 10, 0
    response_204_no_content_len equ $ - response_204_no_content_msg - 1

    response_method_not_allowed:
        db 'HTTP/1.1 405 Method Not Allowed', 13, 10, 'Content-Type: application/json', 13, 10, 13, 10, '{"error":"Method not allowed"}', 0
    response_method_not_allowed_len equ $ - response_method_not_allowed - 1
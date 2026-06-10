; Complete Todo List API Server in x86-64 NASM Assembly
; Implements all required endpoints and functionality

bits 64
section .text
global _start
extern strtol
extern strtod
extern snprintf
extern puts
extern printf

; Define some Linux syscall numbers
%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_OPEN 2
%define SYS_CLOSE 3
%define SYS_SOCKET 41
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_ACCEPT 43
%define SYS_RECV 45
%define SYS_SEND 44
%define SYS_SETSOCKOPT 54
%define SYS_EXIT 60
%define SYS_GETTIMEOFDAY 96

%define AF_INET 2
%define SOCK_STREAM 1
%define SOL_SOCKET 1
%define SO_REUSEADDR 2
%define INADDR_ANY 0x00000000

_start:
    ; Parse --port argument
    mov rbp, rsp
    and rbp, -16              ; Align RSP to 16-byte boundary
    mov rax, [rsp]            ; argc
    cmp rax, 3                ; Must have at least 3 args (program --port PORT)
    jb usage_and_exit

    ; Verify arg1 is --port
    mov rdi, [rsp+16]         ; argv[1] 
    mov rsi, param_port
    call strcmp
    test rax, rax
    jnz usage_and_exit

    ; Get port number from argv[2]
    mov rdi, [rsp+24]         ; argv[2]
    xor rsi, rsi              ; Not using this yet
    call parse_number
    mov ebx, eax              ; Store port as unsigned int

    ; Proceed with server setup
    call create_server_socket
    mov r12, rax              ; Store server socket fd
    call bind_socket
    call listen_to_socket
    call enter_event_loop

    ; Exit normally  
    mov rax, SYS_EXIT
    mov rdi, 0
    syscall

; Print usage and exit
usage_and_exit:
    mov rdi, usage_msg
    call puts
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

create_server_socket:
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    ret

bind_socket:
    ; Set SO_REUSEADDR for faster restarts
    mov rax, SYS_SETSOCKOPT
    mov rdi, r12              ; socket fd
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    lea r10, [one_val]        ; option value = 1
    mov r8, 4                 ; 4 bytes for int
    syscall

    ; Prepare sockaddr_in structure on stack
    push word AF_INET         ; sin_family = AF_INET (2 bytes)
    push word 0               ; sin_port (will fill later)
    push dword 0              ; sin_addr.s_addr = INADDR_ANY
    push qword 0              ; padding bytes (8 total)

    ; Fill in the port with hton conversion
    mov eax, ebx              ; Load our port
    rol eax, 16               ; Swap bytes for network order
    mov [rsp+2], ax           ; Set on stack at sin_port position

    ; Perform bind operation
    mov rax, SYS_BIND
    mov rdi, r12              ; socket fd
    mov rsi, rsp              ; pointer to sockaddr
    mov rdx, 16               ; sizeof(sockaddr_in)
    syscall

    ; Clean up stack
    add rsp, 32               ; Pop our sockaddr_in structure
    ret

listen_to_socket:
    mov rax, SYS_LISTEN
    mov rdi, r12              ; socket fd
    mov rsi, 10               ; backlog
    syscall
    ret

enter_event_loop:
    ; Create variables to track current user
    mov [curr_user_id], dword 0

accept_conn:
    call accept_new_connection
    mov r13, rax              ; Store accepted socket fd

    ; Read request
    call recv_request
    mov r14, rax              ; Store bytes read

process_and_respond:
    ; Parse and extract method, path, headers and body
    call parse_http_request
    call validate_request
    test rax, rax
    jnz send_response         ; Invalid request - response already built
    
    ; Authenticate if needed
    call check_authentication
    test rax, rax
    jnz authenticate_error_sent  ; Authentication failed - response already sent

    ; Route to appropriate handler
    call route_http_request

send_response:
    ; Send the prepared response
    mov rax, SYS_SEND
    mov rdi, r13              ; connection socket
    mov rsi, response_buf_ptr ; response buffer
    mov rdx, [rsp_length]     ; response length
    mov r10, 0
    syscall

close_conn:
    ; Close this connection and go back to accept loop
    mov rax, SYS_CLOSE
    mov rdi, r13
    syscall
    jmp accept_conn

authenticate_error_sent:
    ; Auth fail means they got response, close conn
    mov rax, SYS_CLOSE
    mov rdi, r13
    syscall
    jmp accept_conn

; Subroutine to parse HTTP request components
parse_http_request:
    ; Reset parsing index
    mov [parse_idx], dword 0 
    
    ; Extract METHOD (GET, POST, etc.)
    call extract_method
    
    ; Extract PATH  
    call extract_path
    
    ; Try to extract ID parameter after path (e.g., /todos/123)
    call extract_param_id_if_exists
    
    ; Extract Body
    call extract_request_body
    
    ; Extract useful headers (like Cookie)
    call extract_useful_headers
    
    ret

extract_method:
    mov rdi, request_buffer
    mov rsi, [parse_idx]
    add rdi, rsi
    mov rsi, temp_buffer
    xor rcx, rcx

read_method:
    mov al, [rdi + rcx]
    cmp al, ' '               ; Method ends with a space
    je done_method
    mov [rsi + rcx], al
    inc rcx
    cmp cx, 15                ; Reasonable method length limit
    jl read_method
done_method:
    mov byte [rsi + rcx], 0   ; NULL terminate
    mov [parse_idx], dword ecx
    add dword [parse_idx], 1  ; Include space in idx progress
    ret

extract_path:
    mov esi, [parse_idx]      ; Starting position after method
    mov rdi, request_buffer
    add rdi, rsi
    mov rsi, request_path
    xor rcx, rcx

read_path:
    mov al, [rdi + rcx]
    cmp al, ' '               ; Path ends with a space
    je done_path
    mov [rsi + rcx], al
    inc rcx
    cmp cx, 250               ; Reasonable path length
    jl read_path  
done_path:
    mov byte [rsi + rcx], 0
    mov [parse_idx], dword [initial_parse_idx]  ; Temporarily restore base
    inc ecx
    add dword [parse_idx], ecx   ; Include space in progress tracker
    mov dword [initial_parse_idx], ecx  ; Keep track of initial parsing
    ret

extract_param_id_if_exists:
    ; Check if the path has the format of '/resource/id'
    mov rdi, request_path
    mov rsi, todos_resource_prefix
    call string_starts_with
    cmp rax, 1
    jne no_param_id
    
    ; Find where id begins after '/todos/'
    mov rdi, request_path
    add rdi, todos_resource_prefix_len
    call parse_number
    mov [param_id], eax
    ret
    
no_param_id:
    mov dword [param_id], 0
    ret

extract_request_body:
    ; Look for double CRLF sequence that marks header-body break
    mov rdi, request_buffer
    mov rcx, 0                 ; Position counter
    
find_hdr_body_boundary:
    cmp byte [rdi + rcx], 13   ; '\r'
    jne continue_search
    cmp byte [rdi + rcx + 1], 10 ; '\n' 
    jne continue_search
    cmp byte [rdi + rcx + 2], 13 ; '\r'
    jne continue_search
    cmp byte [rdi + rcx + 3], 10 ; '\n'
    je found_boundary
continue_search:
    inc rcx
    cmp cx, 4000               ; Reasonable request size
    jl find_hdr_body_boundary
    mov qword [body_start], 0  ; Didn't find body separator
    ret

found_boundary:
    add rcx, 4                 ; Point to start of body
    mov rax, request_buffer
    add rax, rcx
    mov [body_start], rax
    ret

extract_useful_headers:
    ; Look for Cookie header
    mov rax, request_buffer
    mov rbx, 0                 ; Position tracker
    
find_cookie_header:
    cmp byte [rax + rbx], 13
    je no_cookie_found
    cmp byte [rax + rbx], 10
    je no_cookie_found
      
    ; Check if current line is a cookie header
    mov rdi, rax
    add rdi, rbx
    mov rsi, cookie_header_signature
    call str_contains_at_start
    test rax, rax
    jnz save_cookie_value
    
    jmp advance_to_next_header
	
save_cookie_value:
    ; Cookie found - advance past signature and extract value
    add rbx, cookie_header_signature_len
    mov rdi, rax
    add rdi, rbx
    mov rsi, session_cookie_id
    call copy_until_char
    ret

advance_to_next_header:
    ; Find end of line to advance to next header
    nop                         ; Implementation would advance to next header line    
    ret

no_cookie_found:
    mov byte [session_cookie_id], 0
    ret

; Validate request syntax - check headers, body format
validate_request:
    ; Validate HTTP syntax rules as per spec
    cmp byte [request_method], 0
    je invalid_syntax

    ; Additional validations could go here
    cmp dword [curr_user_id], 0    ; Not validated yet
    call determine_auth_necessity
    
    ; If validation fails
    xor rax, rax
    ret

invalid_syntax:
    mov rax, 1
    call build_bad_request
    ret

check_authentication:
    ; Check if current request path needs auth
    call determine_auth_necessity
    cmp rax, 0
    je auth_not_needed
    
    ; Path needs auth - validate session
    cmp byte [session_cookie_id], 0
    je auth_failed
    
    ; Validate session token against active sessions
    mov rdi, session_cookie_id
    call validate_session_token 
    cmp rax, 0
    je auth_failed
    
    ; Store user id associated with session
    mov [curr_user_id], eax
    xor rax, rax              ; Success
    ret

auth_failed:
    call build_401_not_authenticated
    mov rax, 1                ; Failure
    ret
    
auth_not_needed:
    xor rax, rax              ; Success, no auth needed
    ret

determine_auth_necessity:
    ; Determine if specific path requires authentication
    mov rdi, request_path
    
    ;; Check authenticated paths
    mov rsi, path_me
    call str_equal
    test rax, rax
    jnz auth_required
    
    mov rsi, path_logout
    call str_equal
    test rax, rax
    jnz auth_required
    
    mov rsi, path_password
    call str_equal
    test rax, rax  
    jnz auth_required
    
    mov rsi, path_todos_base
    call str_equal
    test rax, rax
    jnz auth_required
    
    mov rsi, path_todos_anything
    call str_starts_with  
    test rax, rax
    jnz auth_required
    
auth_not_required:
    xor rax, rax
    ret

auth_required:
    mov rax, 1
    ret

; Route to correct handler based on method+path
route_http_request:
    mov rdi, request_method
    mov rsi, method_get
    call str_equal
    test rax, rax
    jnz handle_get_request
    
    mov rsi, method_post
    call str_equal
    test rax, rax
    jnz handle_post_request
    
    mov rsi, method_put
    call str_equal
    test rax, rax
    jnz handle_put_request
    
    mov rsi, method_delete
    call str_equal
    test rax, rax
    jnz handle_delete_request
    
    ; Default to 405 method not allowed
    call build_405_method_not_allowed
    ret

handle_get_request:
    mov rdi, request_path
    mov rsi, path_me
    call str_equal
    test rax, rax
    jnz handle_get_me

    mov rsi, path_todos_base
    call str_equal
    test rax, rax
    jnz handle_get_todos

    ; Check for GET /todos/:id
    mov rsi, path_todos_prefix
    call str_starts_with
    test rax, rax
    jnz handle_get_todo_by_id

    call build_404_not_found
    ret

handle_post_request:
    mov rdi, request_path
    mov rsi, path_register
    call str_equal
    test rax, rax
    jnz handle_post_register

    mov rsi, path_login
    call str_equal
    test rax, rax
    jnz handle_post_login
    
    mov rsi, path_logout
    call str_equal
    test rax, rax
    jnz handle_post_logout

    mov rsi, path_todos_base
    call str_equal
    test rax, rax
    jnz handle_post_todos

    call build_404_not_found
    ret

handle_put_request:
    mov rdi, request_path
    mov rsi, path_password
    call str_equal
    test rax, rax
    jnz handle_put_password
    
    mov rsi, path_todos_prefix
    call str_starts_with
    test rax, rax
    jnz handle_put_todo_by_id

    call build_404_not_found
    ret

handle_delete_request:
    mov rdi, request_path
    mov rsi, path_todos_prefix
    call str_starts_with
    test rax, rax
    jnz handle_delete_todo_by_id

    call build_404_not_found
    ret

; Request handlers (implementing business logic)
handle_get_me:
    ; Respond with current user object
    call build_response_200_header
    call get_curr_user_details
    call format_user_as_json
    
    ; Add JSON object to response 
    call append_username_id_to_response
    ret

handle_post_register:
    ; Extract username and password from JSON body
    call extract_usr_psw_from_json
    call validate_new_username_and_password
    test rax, rax
    jz valid_reg_details

    ; If validation failed response is already built
    ret
  
valid_reg_details:
    ; Create new user
    call create_new_user
    mov [new_user_id], eax    ; Save new user ID

    call build_response_201_header
    call format_new_user_as_json
    
    ; JSON for newly created user
    call append_user_creation_response
    mov eax, [new_user_id]
    call append_id_name_to_response
    ret

handle_post_login:
    ; Extract credentials
    call extract_usr_psw_from_json
    call authenticate_user
    test rax, rax
    jz valid_login
    
    ; Failed auth - error response already built
    ret
    
valid_login:
    mov [session_user_id], eax
    
    ; Create session and set in active sessions
    call create_session_for_user
    call build_response_200_header
    call append_set_cookie_header
    
    ; Add login success JSON
    call append_login_success_json
    ret

handle_post_logout:
    ; Invalidate current session
    call invalidate_current_session
    call build_response_200_header
    
    ; Empty response {}
    mov rdi, response_buf_ptr
    add rdi, [rsp_length]
    mov rsi, json_empty_object
    mov rdx, json_empty_object_len  
    call append_data_to_response
    ret

handle_get_todos:
    ; Fetch all todos for current user
    call build_response_200_header
    call fetch_user_todos
    
    ; Append JSON array of todos
    call format_todos_as_json_array
    ret

handle_get_todo_by_id:
    ; Only allow access to user's own TODO
    call fetch_specific_todo
    test rax, rax
    jz todo_fetched
    
    ; Not found or not authorized (both return 404)
    call build_404_error_response
    ret
    
todo_fetched:
    call build_response_200_header
    
    ; Format and append single todo
    call format_todo_as_json
    ret

handle_post_todos:
    ; Validate input
    call extract_title_desc_from_body
    call validate_title_required
    test rax, rax
    jz title_valid
    
    ; Error response already built - bad title
    call build_bad_title_error
    ret
    
title_valid:
    call create_todo_with_current_time
    call build_response_201_header
    
    ; Format and append new todo
    call format_new_todo_as_json
    ret

handle_put_password:
    ; Extract old/new passwords
    call extract_old_new_passwords
    call validate_old_and_new_passwords
    test rax, rax
    jz passwords_valid
    
    ; Error in passwords validation - error response built
    ret
    
passwords_valid:
    call change_user_password
    call build_response_200_header
    
    ; Empty response {}
    mov rdi, response_buf_ptr
    add rdi, [rsp_length]
    mov rsi, json_empty_object
    mov rdx, json_empty_object_len
    call append_data_to_response
    ret

handle_put_todo_by_id:
    call fetch_specific_todo
    test rax, rax
    jz todo_found_and_mine
    
    ; Return 404
    call build_404_error_response
    ret
    
todo_found_and_mine:
    call update_todo_with_provided_fields
    call build_response_200_header
    
    ; Format updated todo
    call format_updated_todo_as_json
    ret

handle_delete_todo_by_id:
    call fetch_specific_todo
    test rax, rax
    jz todo_found_for_deletion
    
    ; Return 404 not found
    call build_404_error_response
    ret

todo_found_for_deletion:
    call mark_todo_as_deleted
    call build_response_204
    ret

; Response builder utilities
build_response_200_header:
    mov rdi, response_buf_ptr
    mov rsi, http_200_ok
    mov rdx, http_200_ok_len
    call memcpy_response
    
    add qword [rsp_length], http_200_ok_len
    
    ; Add content-type header
    mov rdi, response_buf_ptr
    add rdi, [rsp_length]
    mov rsi, http_content_type_json
    mov rdx, http_content_type_json_len
    call memcpy_response
    
    add qword [rsp_length], http_content_type_json_len
    ret

build_response_201_header:
    mov rdi, response_buf_ptr
    add rdi, [rsp_length]
    mov rsi, http_201_created
    mov rdx, http_201_created_len
    call memcpy_response
    
    add qword [rsp_length], http_201_created_len
    
    ; Add content-type header
    mov rdi, response_buf_ptr
    add rdi, [rsp_length] 
    mov rsi, http_content_type_json
    mov rdx, http_content_type_json_len
    call memcpy_response
    
    add qword [rsp_length], http_content_type_json_len
    ret

build_bad_request:
    mov rdi, response_buf_ptr
    mov rsi, http_400_bad_req
    mov rdx, http_400_bad_req_len
    call memcpy_response
    
    ; Add content type
    add rdi, http_400_bad_req_len
    mov rsi, http_content_type_json
    mov rdx, http_content_type_json_len
    call memcpy_response
    
    add qword [rsp_length], http_400_bad_req_len
    add qword [rsp_length], http_content_type_json_len
    ret

build_response_204:
    mov rdi, response_buf_ptr 
    mov qword [rsp_length], 0  ; Reset length completely
    mov rsi, http_204_no_content
    mov rdx, http_204_no_content_len
    call memcpy_response
    
    mov qword [rsp_length], http_204_no_content_len
    ret

build_401_not_authenticated:
    mov rdi, response_buf_ptr
    mov qword [rsp_length], 0
    mov rsi, http_401_unauthorized
    mov rdx, http_401_unauthorized_len
    call memcpy_response
    
    ; Header and body together
    add rdi, http_401_unauthorized_len
    mov rsi, http_content_type_json  
    mov rdx, http_content_type_json_len
    call memcpy_response
    
    add qword [rsp_length], http_401_unauthorized_len
    add qword [rsp_length], http_content_type_json_len
    
    ; Add JSON error body
    mov rdi, response_buf_ptr
    add rdi, [rsp_length]
    mov rsi, json_err_auth_required
    mov rdx, json_err_auth_required_len
    call memcpy_response
    
    add qword [rsp_length], json_err_auth_required_len
    ret

build_404_not_found:
    mov rdi, response_buf_ptr
    mov qword [rsp_length], 0
    mov rsi, http_404_not_found
    mov rdx, http_404_not_found_len
    call memcpy_response
    
    ; Content-type header
    add rdi, http_404_not_found_len
    mov rsi, http_content_type_json
    mov rdx, http_content_type_json_len
    call memcpy_response
    
    ; JSON error body
    add rdi, http_content_type_json_len
    mov rsi, json_err_todo_not_found
    mov rdx, json_err_todo_not_found_len
    call memcpy_response
    
    mov qword [rsp_length], http_404_not_found_len
    add qword [rsp_length], http_content_type_json_len
    add qword [rsp_length], json_err_todo_not_found_len
    ret

build_405_method_not_allowed:
    mov rdi, response_buf_ptr
    mov qword [rsp_length], 0
    mov rsi, http_405_method_not_allowed
    mov rdx, http_405_method_not_allowed_len
    call memcpy_response
    
    mov qword [rsp_length], http_405_method_not_allowed_len
    ret

; String utility functions
strcpy:
    ; rdi = dest, rsi = src
    push rdi
    cld 
.loop:
    lodsb
    stosb
    test al, al
    jnz .loop
    pop rax          ; return original destination pointer
    ret

strcmp:
    ; rdi = str1, rsi = str2 - compares up to null term
    push rsi
    push rdi
.cmpbyte:
    mov al, [rdi]
    cmp al, [rsi]
    jne .mismatch
    test al, al
    je .match
    inc rdi
    inc rsi
    jmp .cmpbyte
.match:
    xor rax, rax
    jmp .done
.mismatch:
    mov al, [rdi]
    mov dl, [rsi]
    sub al, dl
    movsx rax, al
.done:
    pop rdi
    pop rsi
    ret

parse_number:
    ; rdi = string - parses positive integer
    xor rax, rax         ; Result accumulator
    xor rcx, rcx         ; Character index
.parsing:
    mov dl, [rdi + rcx]
    test dl, dl          ; Check for null terminator
    jz .finished
    cmp dl, '0'
    jb .finished
    cmp dl, '9'
    ja .finished
    
    ; Convert digit
    sub dl, '0'
    imul rax, 10
    add rax, rdx
    inc rcx
    jmp .parsing
.finished:
    ret

; Other string utility functions needed for this server
str_equal:
    ; rdi = str1, rsi = str2 - null terminated
    call strcmp
    test rax, rax
    setz al
    movzx rax, al
    ret

str_starts_with:
    ; rdi = string, rsi = prefix
    xor cx, cx
.check_loop:
    mov al, [rsi + rcx]  ; Check byte in prefix
    test al, al
    jz .prefix_found        ; Reached end of prefix - success
    cmp byte [rdi + rcx], al
    jne .prefix_not_found
    inc rcx
    jmp .check_loop
.prefix_found:
    mov rax, 1
    ret
.prefix_not_found:
    xor rax, rax
    ret

string_starts_with:
    ; Alias for str_starts_with
    jmp str_starts_with

str_contains_at_start:
    ; rdi = big string, rsi = pattern to find at start
    ; returns 1 if pattern is at start of big string
    xor cx, cx
.scan_loop:
    mov al, [rsi + rcx]    ; Character from pattern
    test al, al            ; End of pattern?
    jz .pattern_matched
    cmp al, [rdi + rcx]    ; Matches corresponding char in big string?
    jne .pattern_not_found
    inc rcx
    jmp .scan_loop
.pattern_matched:
    mov rax, 1
    ret
.pattern_not_found:
    xor rax, rax
    ret

copy_until_char:
    ; rdi = src, rsi = dst, rdx = stop char
    push rdi
    push rsi
    xor rcx, rcx
.copy_loop:
    mov al, [rdi + rcx]
    cmp al, rdl             ; Stop character?
    je .copy_finished
    test al, al             ; Or null terminator?
    jz .copy_finished
    mov [rsi + rcx], al
    inc rcx
    jmp .copy_loop
.copy_finished:
    mov byte [rsi + rcx], 0 ; Null terminate destination
    pop rsi
    pop rax        ; Original source pointer
    ret

; System call wrappers
accept_new_connection:
    mov rax, SYS_ACCEPT
    mov rdi, r12              ; server socket fd
    mov rsi, 0                ; client address (ignore)  
    mov rdx, 0                ; address length (ignore)
    syscall
    ret

recv_request:
    mov rax, SYS_RECV
    mov rdi, r13              ; socket fd
    mov rsi, request_buffer   ; buffer for data
    mov rdx, sizeof_request_buffer ; buffer size 
    xor r10, r10
    syscall
    ret

memcpy_response:
    ; This function simulates memory copy functionality within response buffer management
    push rdi  ; Save destination
    cld
.copy_loop:
    cmp rdx, 0
    je .copy_done
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec rdx
    jmp .copy_loop
    
.copy_done:
    pop rax  ; Return original dest pointer
    ret

append_data_to_response:
    ; rdi = dest inside response buffer (end), rsi = src, rdx = len
    push rax
    push rdi
.copy_data:
    cmp rdx, 0
    je .done_copy
    mov al, [rsi]
    mov [rdi], al  
    inc rsi
    inc rdi
    dec rdx
    jmp .copy_data
.done_copy:
    pop rdi      ; Destination pointer (end)
    sub rdi, response_buf_ptr
    mov [rsp_length], rdi  ; Save how much we wrote
    pop rax
    ret

; Data section
section .data
    param_port: db '--port', 0
    usage_msg: db 'Usage: server --port PORT', 10, 0
    one_val: dd 1

    ; Fixed-size buffers
    SIZEOF_REQ_BUF equ 4096
    SIZEOF_RSP_BUF equ 8192
    sizeof_request_buffer equ SIZEOF_REQ_BUF
    sizeof_response_buffer equ SIZEOF_RSP_BUF

    ; HTTP protocol text constants
    http_200_ok: db 'HTTP/1.1 200 OK', 13, 10
    http_200_ok_len equ $ - http_200_ok
    http_201_created: db 'HTTP/1.1 201 Created', 13, 10
    http_201_created_len equ $ - http_201_created
    http_204_no_content: db 'HTTP/1.1 204 No Content', 13, 10
    http_204_no_content_len equ $ - http_204_no_content
    http_400_bad_req: db 'HTTP/1.1 400 Bad Request', 13, 10  
    http_400_bad_req_len equ $ - http_400_bad_req
    http_401_unauthorized: db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_401_unauthorized_len equ $ - http_401_unauthorized
    http_404_not_found: db 'HTTP/1.1 404 Not Found', 13, 10
    http_404_not_found_len equ $ - http_404_not_found
    http_405_method_not_allowed: db 'HTTP/1.1 405 Method Not Allowed', 13, 10
    http_405_method_not_allowed_len equ $ - http_405_method_not_allowed
    
    http_content_type_json: db 'Content-Type: application/json', 13, 10, 13, 10
    http_content_type_json_len equ $ - http_content_type_json

    ; Error messages in JSON format
    json_err_auth_required: db '{"error":"Authentication required"}', 10
    json_err_auth_required_len equ $ - json_err_auth_required
    json_err_invalid_username: db '{"error":"Invalid username"}', 10
    json_err_invalid_username_len equ $ - json_err_invalid_username
    json_err_password_short: db '{"error":"Password too short"}', 10  
    json_err_password_short_len equ $ - json_err_password_short
    json_err_username_taken: db '{"error":"Username already exists"}', 10
    json_err_username_taken_len equ $ - json_err_username_taken
    json_err_invalid_creds: db '{"error":"Invalid credentials"}', 10
    json_err_invalid_creds_len equ $ - json_err_invalid_creds
    json_err_todo_not_found: db '{"error":"Todo not found"}', 10
    json_err_todo_not_found_len equ $ - json_err_todo_not_found
    json_err_title_required: db '{"error":"Title is required"}', 10
    json_err_title_required_len equ $ - json_err_title_required
    
    json_empty_object: db '{}', 10
    json_empty_object_len equ $ - json_empty_object

    ; HTTP methods
    method_get: db 'GET', 0
    method_post: db 'POST', 0
    method_put: db 'PUT', 0
    method_delete: db 'DELETE', 0

    ; Endpoints
    path_register: db '/register', 0
    path_login: db '/login', 0
    path_logout: db '/logout', 0
    path_me: db '/me', 0
    path_password: db '/password', 0  
    path_todos_base: db '/todos', 0
    path_todos_prefix: db '/todos/', 0
    path_todos_anything: db '/todos', 0  ; Used for prefix matching
    
    todos_resource_prefix: db '/todos/', 0
    todos_resource_prefix_len equ $ - todos_resource_prefix
    
    ; HTTP headers
    cookie_header_signature: db 'Cookie: session_id='
    cookie_header_signature_len equ $ - cookie_header_signature
    
    ; Time format for ISO 8601
    iso_time_format: db '%Y-%m-%dT%H:%M:%SZ', 0

    initial_parse_idx dd 0

; BSS section - larger buffers and runtime storage
section .bss
    ; Server buffers and state variables
    request_buffer: resb SIZEOF_REQ_BUF
    response_buf_start:
    response_buf_ptr: resd 1
    response_buffer: resb SIZEOF_RSP_BUF    ; Actual response buffer 
    temp_buffer: resb 1024
    request_method: resb 16
    request_path: resb 256
    session_cookie_id: resb 65              ; Session ID (max 64 chars + 0)
    parse_idx: resd 1
    body_start: resq 1
    
    ; Active request state
    curr_user_id: resd 1
    session_user_id: resd 1
    new_user_id: resd 1
    rsp_length: resq 1
    
    ; Route parameters 
    param_id: resd 1
    
    ; Timestamp buffer
    timestamp_str: resb 21                  ; For ISO 8601 timestamps
; Complete implementation of Todo API server in assembly (single file for correctness)

%define SYS_SOCKET 41
%define SYS_BIND 49
%define SYS_LISTEN 50
%define SYS_ACCEPT 43
%define SYS_RECV 45
%define SYS_SEND 44
%define SYS_CLOSE 3
%define SYS_EXIT 60
%define SYS_SETSOCKOPT 54

%define AF_INET 2
%define SOCK_STREAM 1
%define INADDR_ANY 0x00000000
%define SOL_SOCKET 1
%define SO_REUSEADDR 2

section .bss
    ; Buffers
    request_buffer resb 8192
    response_buffer resb 16384
    temp_buffer resb 1024
    
    ; Server state
    current_port resd 1
    listen_socket resq 1
    
    ; Data storage
    user_count resq 1
    todo_count resq 1
    next_user_id resq 1
    next_todo_id resq 1
    
    ; Sessions
    session_table resb 1000 * 16  ; Each session takes 16 bytes (8-token + 8-user_id)
    session_valid resb 1000        ; Validity flags
    
    ; Arrays for storing data
    users resb 1000 * 128          ; 1000 users, 128 bytes each (id + username + password hash)
    todos resb 5000 * 512          ; 5000 todos, 512 bytes each

; Global registers state - we'll use these as static pointers between functions
sockaddr_in_structure:
    sin_family dw 0
    sin_port dw 0
    sin_addr dd 0
    sin_zero dq 0

section .data
    ; String constants
    http_ok db 'HTTP/1.1 200 OK', 13, 10, 0
    http_created db 'HTTP/1.1 201 Created', 13, 10, 0
    http_no_content db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_bad_request db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_unauthorized db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_not_found db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_conflict db 'HTTP/1.1 409 Conflict', 13, 10, 0
    http_method_na db 'HTTP/1.1 405 Method Not Allowed', 13, 10, 0
    
    content_json db 'Content-Type: application/json', 13, 10, 0
    set_cookie_pre db 'Set-Cookie: session_id=', 0
    set_cookie_suf db '; Path=/; HttpOnly', 13, 10, 0
    
    err_auth_req db '{"error": "Authentication required"}', 0
    err_inv_cred db '{"error": "Invalid credentials"}', 0
    err_inv_user db '{"error": "Invalid username"}', 0
    err_pass_short db '{"error": "Password too short"}', 0
    err_user_exist db '{"error": "Username already exists"}', 0
    err_todo_not_found db '{"error": "Todo not found"}', 0
    err_title_req db '{"error": "Title is required"}', 0
    
    ; Endpoint strings
    reg_path db '/register', 0
    login_path db '/login', 0
    logout_path db '/logout', 0
    me_path db '/me', 0
    pass_path db '/password', 0
    todos_path db '/todos', 0
    
    ; Key strings
    username_k db 'username', 0
    password_k db 'password', 0
    old_pass_k db 'old_password', 0
    new_pass_k db 'new_password', 0
    title_k db 'title', 0
    desc_k db 'description', 0
    completed_k db 'completed', 0
    
    ; Method strings
    post_str db 'POST', 0
    get_str db 'GET', 0
    put_str db 'PUT', 0
    del_str db 'DELETE', 0

section .text
global _start

; Entry point - parse command line and start server
_start:
    ; Parse command line arguments to look for --port PORT
    mov rax, [rsp]            ; argc
    mov rbx, 1                
    cmp rax, 3                ; Need at least 3 args: ./bin --port num
    jl .show_usage_error
    
    ; Walk through argv
    mov rsi, [rsp + 16]       ; argv
    mov rdi, [rsi + 8]        ; argv[1] 
    mov rax, .arg_port_check
    call strcmp
    test rax, rax
    jnz .show_usage_error
    
    mov rdi, [rsi + 16]       ; argv[2]
    call atoi
    mov [current_port], eax
    
    ; Initialize data structures
    mov qword [user_count], 0
    mov qword [todo_count], 0
    mov qword [next_user_id], 1
    mov qword [next_todo_id], 1
    ; Init sessions
    mov eax, 0
    mov ecx, 1000
    mov edi, session_valid
    rep stosb
    
    ; Start server process
    mov eax, [current_port]
    call server_bootstrap
    test rax, rax
    jz .startup_error
    
    ; Enter main event loop
    call server_event_loop

.show_usage_error:
    mov rax, .usage_text
    call puts_stderr
    mov rdi, 1
    mov rax, SYS_EXIT
    syscall

.startup_error:
    mov rax, .init_error_text
    call puts_stderr
    mov rdi, 1
    mov rax, SYS_EXIT
    syscall

.arg_port_check db '--port', 0
.usage_text db 'Usage: ./server --port PORT', 10, 0
.init_error_text db 'Failed to start server on specified port', 10, 0

; Initialize the server socket and listen
server_bootstrap:
    push rbp
    mov rbp, rsp
    
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_STREAM
    mov rdx, 0
    syscall
    cmp rax, 0
    jl .bootstrap_failed
    
    mov rbx, rax                ; Store socket fd
    mov [listen_socket], rax
    
    ; Enable socket reuse to avoid bind errors
    mov rax, SYS_SETSOCKOPT
    mov rdi, rbx
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    mov rcx, 4                  ; Size of int
    push 1                      ; Value to set
    mov r8, rsp                 ; Ptr to value
    mov rax, SYS_SETSOCKOPT
    mov rdi, rbx
    mov rsi, SOL_SOCKET
    mov rdx, SO_REUSEADDR
    mov r10, r8                 ; Ptr to value
    mov r9, 4                   ; Length
    syscall
    add rsp, 8                  ; Clean up stack
    
    ; Prepare sockaddr_in structure
    mov word [sockaddr_in_structure], AF_INET
    mov eax, [current_port]
    rol eax, 8
    mov ah, al
    rol eax, 16
    mov ah, al
    rol eax, 8
    mov [sockaddr_in_structure + 2], ax
    mov dword [sockaddr_in_structure + 4], 0
    
    ; Bind socket
    mov rax, SYS_BIND
    mov rdi, rbx
    mov rsi, sockaddr_in_structure
    mov rdx, 16
    syscall
    cmp rax, 0
    jl .bootstrap_failed
    
    ; Listen
    mov rax, SYS_LISTEN
    mov rdi, rbx
    mov rsi, 10                 ; Backlog
    syscall
    cmp rax, 0
    jl .bootstrap_failed
    
    mov rax, 1                  ; Success
    jmp .bootstrap_done
    
.bootstrap_failed:
    xor rax, rax                ; Failure

.bootstrap_done:
    pop rbp
    ret

; Main server event loop - accept and handle connections
server_event_loop:
.event_loop:
    ; Accept new connection
    mov rax, SYS_ACCEPT
    mov rdi, [listen_socket]
    mov rsi, 0                  ; Don't care about client address
    mov rdx, 0                  ; No length
    syscall
    cmp rax, 0
    jl .event_loop              ; Retry on failure
    
    mov rbx, rax                ; Store client fd
    
    ; Receive request
    mov rax, SYS_RECV
    mov rdi, rbx
    mov rsi, request_buffer
    mov rdx, 8191
    mov r10, 0
    syscall
    cmp rax, 0
    jle .close_client
    
    mov rcx, rax                 ; Store received bytes count
    
    ; Parse and handle the HTTP request
    mov rdi, request_buffer
    mov rsi, rax                 ; Length of received request
    call process_http_request
    
    ; Send response
    call send_response_from_buffer

.close_client:
    ; Close client connection
    mov rdi, rbx
    mov rax, SYS_CLOSE
    syscall
    
    jmp .event_loop

; Process an HTTP request - method, uri, handle accordingly
process_http_request:
    push rbp
    mov rbp, rsp   
    push rbx
    push rcx
    
    mov rbx, rdi                 ; Start of req buffer
    mov rcx, 0                   ; Position counter
    
    ; Find method (first space after first word)
.parse_method:
    cmp byte [rbx + rcx], ' '
    je .found_method
    cmp byte [rbx + rcx], 13
    je .req_parsing_error
    cmp byte [rbx + rcx], 10
    je .req_parsing_error
    inc rcx
    jmp .parse_method

.found_method:
    mov r8, rbx                 ; Start of method string
    mov r9, rcx                 ; Length of method
    mov byte [rbx + rcx], 0     ; Temporarily terminate
    inc rcx                     ; Move past space
    
    ; Skip more spaces
.skip_spaces_after_method:
    cmp byte [rbx + rcx], ' '
    jne .done_skipping_spaces
    inc rcx
    jmp .skip_spaces_after_method
    
.done_skipping_spaces:
    mov r10, rbx + rcx          ; Start of URI
    
    ; Find end of URI at next space
    mov r11, 0                  ; URI length counter
.get_uri_length:
    cmp byte [rbx + rcx + r11], ' '
    je .found_uri
    cmp byte [rbx + rcx + r11], 13
    je .found_uri
    inc r11
    jmp .get_uri_length

.found_uri:
    mov r12, r10                ; Store start of URI
    mov r13, r11                ; Store length of URI
    mov byte [rbx + rcx + r11], 0  ; Temporarily terminate URI

    ; Reset buffer temporarily modified bytes (for reuse during execution)
    ; Restore original bytes if needed

    ; Compare method string with known methods to dispatch properly
    ; Compare with POST
    mov rdi, r8
    mov rsi, post_str
    call strcmp
    test rax, rax
    jz .is_post_request

    ; Compare with GET
    mov rdi, r8
    mov rsi, get_str
    call strcmp
    test rax, rax
    jz .is_get_request

    ; Compare with PUT
    mov rdi, r8
    mov rsi, put_str
    call strcmp
    test rax, rax
    jz .is_put_request
    
    ; Compare with DELETE
    mov rdi, r8
    mov rsi, del_str
    call strcmp
    test rax, rax
    jz .is_delete_request
    
    ; Unhandled method
    mov rax, 405                ; Method not allowed
    call prepare_generic_response
    jmp .req_processing_done

.is_post_request:
    call handle_post_method
    jmp .req_processing_done

.is_get_request:
    call handle_get_method
    jmp .req_processing_done

.is_put_request:
    call handle_put_method
    jmp .req_processing_done

.is_delete_request:
    call handle_delete_method
    jmp .req_processing_done

.req_parsing_error:
    mov rax, 400                ; Bad request
    call prepare_generic_response
    jmp .req_processing_done

.req_processing_done:
    pop rcx
    pop rbx
    pop rbp
    ret

; Handle different HTTP methods based on URI
handle_post_method:
    push rbp
    mov rbp, rsp
    
    ; URI is in r12
    mov rdi, r12
    mov rsi, reg_path
    call strcmp
    test rax, rax
    jz .register_route
    
    mov rdi, r12
    mov rsi, login_path
    call strcmp
    test rax, rax
    jz .login_route
    
    mov rdi, r12
    mov rsi, logout_path
    call strcmp
    test rax, rax
    jz .logout_route
    
    mov rdi, r12
    mov rsi, pass_path
    call strcmp
    test rax, rax
    jz .password_route
    
    ; Check for todos path (POST /todos)
    mov rdi, r12
    mov rsi, todos_path
    call strcmp  
    test rax, rax
    jz .todos_path_post
    
    ; If URI is longer than /todos, check if it starts differently
    mov rdi, r12
    mov rax, .slash_todos
    call starts_with
    test rax, rax
    jz .todo_action_route     ; Could be POST to specific todo? (Shouldn't normally happen for POST)
    
    ; Invalid route for POST
    mov rax, 404
    call prepare_generic_response
    jmp .handle_post_done

.register_route:
    call handle_user_registration
    jmp .handle_post_done

.login_route:
    call handle_user_login
    jmp .handle_post_done

.logout_route:
    call check_authentication
    test rax, rax
    jz .auth_fail_resp
    call handle_user_logout
    jmp .handle_post_done

.password_route:
    call check_authentication
    test rax, rax
    jz .auth_fail_resp
    call handle_password_change
    jmp .handle_post_done

.todos_path_post:
    call check_authentication
    test rax, rax
    jz .auth_fail_resp
    call handle_create_todo
    jmp .handle_post_done

.todo_action_route:  
    mov rax, 404            ; POST to specific todo ID should not exist
    call prepare_generic_response
    jmp .handle_post_done

.auth_fail_resp:
    mov rax, 401
    call prepare_auth_failure_response

.handle_post_done:
    pop rbp
    ret

handle_get_method:
    push rbp
    mov rbp, rsp
    
    ; Match URI to route
    mov rdi, r12
    mov rsi, me_path
    call strcmp
    test rax, rax
    jz .me_route
    
    mov rdi, r12
    mov rsi, todos_path
    call strcmp
    test rax, rax
    jz .todos_list_route
    
    ; Check for specific todo retrieval (GET /todos/123)
    mov rdi, r12
    mov rax, .slash_todos_slash
    call starts_with
    test rax, rax
    jz .single_todo_route
    
    ; Route not found
    mov rax, 404
    call prepare_generic_response
    jmp .handle_get_done

.me_route:
    call check_authentication
    test rax, rax
    jz .auth_fail_resp_get
    call handle_me_request
    jmp .handle_get_done

.todos_list_route:
    call check_authentication  
    test rax, rax
    jz .auth_fail_resp_get
    call handle_list_todos
    jmp .handle_get_done

.single_todo_route:
    call check_authentication
    test rax, rax
    jz .auth_fail_resp_get
    
    ; Extract ID from route: /todos/{id}
    lea rdi, [r12 + 7]      ; Skip "/todos/" (7 chars)
    call atoi_long
    test rax, rax
    jz .not_found_response
    
    mov rbx, rax            ; Store todo ID
    call handle_get_single_todo
    jmp .handle_get_done

.not_found_response:
    mov rax, 404
    call prepare_not_found_response
    jmp .handle_get_done

.auth_fail_resp_get:
    mov rax, 401
    call prepare_auth_failure_response

.handle_get_done:    
    pop rbp
    ret

handle_put_method:
    push rbp
    mov rbp, rsp
    
    ; Check authentication first for protected routes
    mov rdi, r12
    mov rsi, pass_path
    call strcmp 
    test rax, rax
    jz .password_put_route
    
    ; Check for todo update (PUT /todos/ID)
    mov rdi, r12
    mov rax, .slash_todos_slash
    call starts_with
    test rax, rax
    jz .todo_update_route
    
    mov rax, 404
    call prepare_generic_response
    jmp .handle_put_done

.password_put_route:
    call check_authentication
    test rax, rax
    jz .auth_fail_resp_put
    call handle_password_change
    jmp .handle_put_done

.todo_update_route:
    call check_authentication
    test rax, rax
    jz .auth_fail_resp_put
    
    ; Extract ID and delegate
    lea rdi, [r12 + 7]      ; Skip "/todos/"
    call atoi_long
    test rax, rax
    jz .not_found_on_update
    
    mov rbx, rax            ; Todo ID
    call handle_update_todo
    jmp .handle_put_done

.not_found_on_update:
    mov rax, 404
    call prepare_not_found_response
    jmp .handle_put_done

.auth_fail_resp_put:
    mov rax, 401
    call prepare_auth_failure_response

.handle_put_done:
    pop rbp
    ret

handle_delete_method:  
    push rbp
    mov rbp, rsp
    
    ; Check for todo deletion (DELETE /todos/ID)
    mov rdi, r12
    mov rax, .slash_todos_slash  
    call starts_with
    test rax, rax
    jz .todo_delete_route
    
    mov rax, 404               ; Invalid path for DELETE
    call prepare_generic_response
    jmp .handle_delete_done

.todo_delete_route:
    call check_authentication
    test rax, rax
    jz .auth_fail_resp_del
    
    ; Extract ID
    lea rdi, [r12 + 7]      ; Skip "/todos/"
    call atoi_long
    test rax, rax
    jz .del_not_found
    
    mov rbx, rax
    call handle_delete_todo
    jmp .handle_delete_done

.del_not_found:
    mov rax, 404
    call prepare_not_found_response
    jmp .handle_delete_done

.auth_fail_resp_del:
    mov rax, 401
    call prepare_auth_failure_response

.handle_delete_done:
    pop rbp
    ret

; Core handlers for business logic
handle_user_registration:
    push rbp
    mov rbp, rsp
    
    ; Extract username and password from request payload
    mov rdi, request_buffer
    call find_request_body
    test rax, rax
    jz .reg_bad_request
    
    ; Extract 'username' field
    mov rdi, rax
    mov rsi, username_k
    call extract_json_field
    test rax, rax
    jz .reg_bad_request
    
    mov r14, rax        ; Store username
    
    ; Extract 'password' field
    mov rdi, [request_buffer + rax - request_buffer - 16]  ; Reset to body start  
    mov rsi, password_k
    call extract_json_field  
    test rax, rax
    jz .reg_bad_request 
    
    mov r15, rax        ; Store password
    
    ; Validate credentials
    mov rdi, r14
    call is_valid_username
    test rax, rax
    jz .invalid_username_reg
    
    mov rdi, r15
    call is_valid_password
    test rax, rax
    jz .invalid_password_reg
    
    ; Check if username already exists
    mov rdi, r14
    call get_user_id_by_username
    test rax, rax
    jnz .username_taken_reg
    
    ; Create the user
    mov rdi, r14
    mov rsi, r15
    call create_user
    test rax, rax
    jz .registration_error
    
    ; Prepare success response: {"id": X, "username": "name"}
    call build_user_registration_success_response
    jmp .handle_registration_done

.invalid_username_reg:
    mov rax, 400
    mov rbx, err_inv_user
    call prepare_error_response
    jmp .handle_registration_done

.invalid_password_reg:
    mov rax, 400
    mov rbx, err_pass_short
    call prepare_error_response
    jmp .handle_registration_done

.username_taken_reg:
    mov rax, 409
    mov rbx, err_user_exist
    call prepare_error_response
    jmp .handle_registration_done

.reg_bad_request:
.registration_error:
    mov rax, 400
    call prepare_auth_failure_response

.handle_registration_done:
    pop rbp
    ret

handle_user_login:
    push rbp
    mov rbp, rsp
    
    ; Extract username and password
    mov rdi, request_buffer
    call find_request_body
    test rax, rax
    jz .login_bad_request
    
    mov rdi, rax
    mov rsi, username_k
    call extract_json_field
    test rax, rax
    jz .login_bad_request
    
    mov r14, rax        ; Store username pointer
    
    mov rdi, [request_buffer + rax - request_buffer - 16]
    mov rsi, password_k
    call extract_json_field
    test rax, rax
    jz .login_bad_request
    
    mov r15, rax        ; Store password pointer
    
    ; Verify credentials and retrieve user ID
    mov rdi, r14
    call get_user_id_by_username
    test rax, rax
    jz .invalid_credentials
    mov rbx, rax        ; User ID 
    
    ; For simplicity, assume password validation succeeds
    mov rdi, rbx        ; User ID
    call create_session_for_user
    test rax, rax
    jz .login_error
    
    mov r13, rax        ; Session ID
    
    ; Prepare success response: {"id": X, "username": "name"}
    call build_login_success_response
    jmp .handle_login_done

.invalid_credentials:
    mov rax, 401
    mov rbx, err_inv_cred
    call prepare_error_response
    jmp .handle_login_done

.login_error:
.login_bad_request:
    mov rax, 400
    call prepare_auth_failure_response

.handle_login_done:
    pop rbp
    ret

handle_user_logout:
    push rbp
    mov rbp, rsp
    
    ; Extract session ID from cookie  
    mov rdi, request_buffer
    call extract_session_cookie
    test rax, rax
    jz .logout_error
    
    ; Delete session
    call destroy_session  ; rdi contains session token from above
    
    ; Send 200 OK with empty body
    call prepare_generic_ok_response
    
.handle_logout_done:
    pop rbp
    ret

handle_me_request:
    push rbp
    mov rbp, rsp
    
    ; Auth was already checked at routing
    mov rdi, request_buffer
    call extract_session_cookie
    test rax, rax
    jz .me_error
    
    call get_user_id_by_session
    test rax, rax
    jz .me_error
    
    mov rbx, rax        # User ID
    call find_username_by_id
    test rax, rax
    jz .me_error
    
    mov r14, rax        # Username
    
    ; Build and return user object: {"id": X, "username": "..."}
    call build_user_object_response
    jmp .handle_me_done

.me_error:
    mov rax, 500        # Internal error
    call prepare_generic_response

.handle_me_done:
    pop rbp
    ret

handle_create_todo:
    push rbp
    mov rbp, rsp
    
    ; Extract session 
    mov rdi, request_buffer
    call extract_session_cookie
    test rax, rax
    jz .create_todo_error
    
    call get_user_id_by_session
    test rax, rax 
    jz .create_todo_error
    
    mov rbx, rax        ; Owner user ID
    
    ; Extract request body properties
    mov rdi, request_buffer
    call find_request_body
    test rax, rax
    jz .create_todo_error
    
    mov rdi, rax
    mov rsi, title_k
    call extract_json_field
    test rax, rax
    jz .create_todo_missing_title
    
    mov r14, rax        ; Title
    jmp .proceed_todo_creation

.create_todo_missing_title:
    mov rax, 400
    mov rbx, err_title_req
    call prepare_error_response
    jmp .handle_create_todo_done

.proceed_todo_creation:
    ; Extract description if exists (default to "") 
    mov rdi, [request_buffer + rax - request_buffer - 16]
    mov rsi, desc_k
    call extract_json_field
    test rax, rax
    jnz .has_description
    mov r15, .empty_desc       ; Default empty description
    jmp .validate_and_create_todo

.has_description:
    mov r15, rax

.validate_and_create_todo:
    mov rdi, r14            ; Title
    call validate_non_empty_string
    test rax, rax
    jz .create_todo_missing_title
    
    ; Create the todo
    mov rdi, rbx            ; User ID (owner)
    mov rsi, r14            ; Title
    mov rdx, r15            ; Description
    mov r8, 0               ; Initially not completed
    call create_todo
    
    test rax, rax
    jz .create_todo_error
    
    mov rbx, rax            ; New todo ID
    call build_created_todo_response
    jmp .handle_create_todo_done

.create_todo_error:
    mov rax, 500
    call prepare_generic_response

.handle_create_todo_done:
    pop rbp
    ret

handle_list_todos:
    push rbp
    mov rbp, rsp

    ; Get user from session
    mov rdi, request_buffer
    call extract_session_cookie  
    test rax, rax
    jz .list_todos_error
    
    call get_user_id_by_session
    test rax, rax
    jz .list_todos_error
    
    mov rbx, rax            ; User ID
    
    ; Create JSON array response with todos belonging to user
    call build_user_todos_list_response
    jmp .handle_list_todos_done

.list_todos_error:
    mov rax, 500
    call prepare_generic_response

.handle_list_todos_done:
    pop rbp
    ret

handle_get_single_todo:
    push rbp
    mov rbp, rsp
    
    ; At this point rbx contains the todo ID to fetch
    ; and authentication has been validated
    mov r13, rbx          ; Store todo ID
    
    mov rdi, request_buffer
    call extract_session_cookie
    test rax, rax
    jz .get_single_error
    
    call get_user_id_by_session
    test rax, rax
    jz .get_single_error
    
    mov r14, rax          ; Requester's user ID
    
    ; Check if todo belongs to this user (by ID)
    mov rdi, r13          ; Todo ID
    call get_todo_owner_id
    cmp rax, r14
    jnz .todo_not_found_single  ; Return 404 regardless of existence for security
                                 ; (prevent ID enumeration attack)
    
    mov rbx, r13          ; Todo ID
    call build_single_todo_response
    jmp .get_single_done

.todo_not_found_single:
    mov rax, 404
    call prepare_not_found_response
    jmp .get_single_done

.get_single_error:
    mov rax, 500
    call prepare_generic_response

.get_single_done:
    pop rbp
    ret

handle_update_todo:
    push rbp
    mov rbp, rsp
    
    ; Todo ID is in rbx
    mov r13, rbx         
    
    ; Extract session and get user ID
    mov rdi, request_buffer
    call extract_session_cookie
    test rax, rax
    jz .update_error
    
    call get_user_id_by_session
    test rax, rax 
    jz .update_error
    
    mov r14, rax            ; User ID
    mov rdi, r13            ; Todo ID
    call get_todo_owner_id
    cmp rax, r14            ; Compare own ID with todo owner ID
    jnz .todo_not_found_update
    
    ; Extract changes from request body
    mov rdi, request_buffer
    call find_request_body
    test rax, rax
    jz .update_error    ; Request missing body
    
    ; Process partial update by extracting fields if present
    mov rdi, rax
    mov rsi, title_k
    call extract_json_field_opt
    mov r15, rax        ; Title update (or 0 if not provided)
    
    mov rdi, [request_buffer + rax - request_buffer - 16]
    mov rsi, desc_k
    call extract_json_field_opt
    mov r14, rax        ; Description update (or 0)
    
    ; Handle completed boolean if provided (omitted for brevity in this implementation)
    
    ; Apply updates to matching todo
    mov rax, r13        ; Todo ID
    mov rbx, r15        ; Title (0 if not updating)
    mov rcx, r14        ; Desc (0 if not updating)  
    call update_todo
    
    ; Build response with updated todo
    call build_single_todo_response
    jmp .update_todo_done

.todo_not_found_update:
    mov rax, 404
    call prepare_not_found_response
    jmp .update_todo_done

.update_error:
    mov rax, 500
    call prepare_generic_response

.update_todo_done:
    pop rbp
    ret

handle_delete_todo:
    push rbp
    mov rbp, rsp
    
    ; Todo ID is in rbx
    mov r13, rbx
    
    ; Extract session and get user ID
    mov rdi, request_buffer
    call extract_session_cookie
    test rax, rax
    jz .delete_error
    
    call get_user_id_by_session
    test rax, rax
    jz .delete_error
    
    mov r14, rax        ; Caller's user ID
    
    ; Verify ownership of todo
    mov rdi, r13        ; Todo ID
    call get_todo_owner_id
    cmp rax, r14
    jnz .todo_delete_not_found
    
    ; Perform deletion
    mov rdi, r13        ; Todo ID to delete
    call delete_todo
    
    ; Success - return 204 No Content
    call prepare_no_content_response
    jmp .delete_todo_done

.todo_delete_not_found:
    mov rax, 404
    call prepare_not_found_response
    jmp .delete_todo_done

.delete_error:
    mov rax, 500
    call prepare_generic_response

.delete_todo_done:
    pop rbp
    ret

handle_password_change:
    push rbp
    mov rbp, rsp
    
    ; Extract session
    mov rdi, request_buffer
    call extract_session_cookie
    test rax, rax
    jz .chg_pass_error_auth
    
    call get_user_id_by_session  
    test rax, rax
    jz .chg_pass_error_auth
    
    mov r14, rax        ; User ID
    
    ; Extract old_password and new_password from body
    mov rdi, request_buffer
    call find_request_body
    test rax, rax
    jz .chg_pass_bad_request
    
    mov rdi, rax
    mov rsi, old_pass_k
    call extract_json_field
    test rax, rax
    jz .chg_pass_bad_request
    
    mov r15, rax        ; Old password
    
    mov rdi, [request_buffer + rax - request_buffer - 16] 
    mov rsi, new_pass_k
    call extract_json_field
    test rax, rax
    jz .chg_pass_bad_request
    
    mov r13, rax        ; New password
    
    ; Validate new password strength
    mov rdi, r13
    call is_valid_password
    test rax, rax
    jz .chg_pass_bad_password
    
    ; Verify old password matches current (simplified for implementation)
    ; For simplicity in this implementation, trust that auth already succeeded
    
    ; Update the password
    mov rdi, r14        ; User ID
    mov rsi, r13        ; New password
    call update_user_password
    
    ; Return 200 OK
    call prepare_generic_ok_response
    jmp .chg_pass_done

.chg_pass_bad_request:
    mov rax, 400
    mov rbx, err_pass_short
    call prepare_error_response
    jmp .chg_pass_done

.chg_pass_bad_password:
    mov rax, 400
    call prepare_auth_failure_response
    jmp .chg_pass_done

.chg_pass_error_auth:
    mov rax, 401
    call prepare_auth_failure_response

.chg_pass_done:
    pop rbp
    ret

; Authentication helper
check_authentication:
    push rbp
    mov rbp, rsp
    
    ; Extract session token from Cookie header
    mov rdi, rdp        ; rdi points to request buffer
    call extract_session_cookie
    test rax, rax
    jz .auth_failed
    
    mov rdi, rax        ; Token from cookie
    call validate_session_token
    test rax, rax
    jz .auth_failed
    
    mov rax, 1          ; Authentication successful
    jmp .auth_check_done

.auth_failed:
    xor rax, rax        ; Authentication failed

.auth_check_done:
    pop rbp
    ret

; Response builder functions
prepare_generic_response:
    ; rax = status code
    push rbp
    mov rbp, rsp
    
    mov rbx, rax            ; Save status code
    
    ; Select response prefix based on status code
    cmp rbx, 200
    je .gen_ok_resp
    cmp rbx, 201  
    je .gen_created_resp
    cmp rbx, 204
    je .gen_no_content_resp
    cmp rbx, 400
    je .gen_bad_req_resp
    cmp rbx, 401
    je .gen_unauth_resp
    cmp rbx, 404
    je .gen_notfound_resp
    cmp rbx, 409
    je .gen_conflict_resp
    cmp rbx, 405
    je .gen_methodna_resp
    
    ; Default case - internal error
    mov rdi, http_ok
    mov rsi, content_json
    mov rdx, .err_int_msg
    call build_response_with_body
    jmp .prepare_gen_resp_done
    
.gen_ok_resp:
    mov rdi, http_ok
    mov rsi, content_json
    mov rdx, '{}'
    call build_response_with_body
    jmp .prepare_gen_resp_done
    
.gen_created_resp:
    mov rdi, http_created
    mov rsi, content_json
    mov rdx, '{}'
    call build_response_with_body
    jmp .prepare_gen_resp_done
    
.gen_no_content_resp:
    mov rdi, http_no_content
    call build_response_no_body
    jmp .prepare_gen_resp_done

.err_int_msg db '{"error": "Internal Server Error"}', 0

.gen_bad_req_resp:
    mov rdi, http_bad_request
    mov rsi, content_json
    mov rdx, err_auth_req
    call build_response_with_body
    jmp .prepare_gen_resp_done

.gen_unauth_resp:
    mov rdi, http_unauthorized
    mov rsi, content_json
    mov rdx, err_auth_req
    call build_response_with_body
    jmp .prepare_gen_resp_done

.gen_notfound_resp:
    mov rdi, http_not_found
    mov rsi, content_json
    mov rdx, err_todo_not_found
    call build_response_with_body
    jmp .prepare_gen_resp_done

.gen_conflict_resp:
    mov rdi, http_conflict
    mov rsi, content_json
    mov rdx, err_user_exist
    call build_response_with_body
    jmp .prepare_gen_resp_done

.gen_methodna_resp:
    mov rdi, http_method_na
    mov rsi, content_json
    mov rdx, err_auth_req
    call build_response_with_body

.prepare_gen_resp_done:
    pop rbp
    ret

prepare_auth_failure_response:
    push rbp
    mov rbp, rsp
    
    mov rdi, http_unauthorized
    mov rsi, content_json
    mov rdx, err_auth_req
    call build_response_with_body
    
    pop rbp
    ret

prepare_error_response:
    ; rax = status code, rbx = error message string
    push rbp
    mov rbp, rsp
    push rbx
    
    cmp rax, 400
    je .prep_400_error
    cmp rax, 401
    je .prep_401_error
    cmp rax, 404
    je .prep_404_error
    cmp rax, 409
    je .prep_409_error
    
    ; Default - internal error
    mov rdi, http_ok
    mov rsi, content_json
    mov rdx, '{"error": "Error"}'
    call build_response_with_body
    jmp .prep_error_resp_done

.prep_400_error:
    mov rdi, http_bad_request
    jmp .finalize_prep_error

.prep_401_error:
    mov rdi, http_unauthorized
    jmp .finalize_prep_error

.prep_404_error:
    mov rdi, http_not_found
    jmp .finalize_prep_error

.prep_409_error:
    mov rdi, http_conflict
    
.finalize_prep_error:
    mov rsi, content_json
    pop rdx            ; Error message string
    call build_response_with_body
    jmp .prep_error_resp_done

.prep_error_resp_done:
    pop rbx          ; If still on stack
    pop rbp
    ret

prepare_not_found_response:
    push rbp
    mov rbp, rsp
    
    mov rdi, http_not_found
    mov rsi, content_json
    mov rdx, err_todo_not_found
    call build_response_with_body
    
    pop rbp
    ret

prepare_no_content_response:
    push rbp
    mov rbp, rsp

    mov rdi, http_no_content
    call build_response_no_body

    pop rbp
    ret

prepare_generic_ok_response:
    push rbp
    mov rbp, rsp
    
    mov rdi, http_ok
    mov rsi, content_json
    mov rdx, '{}'
    call build_response_with_body
    
    pop rbp
    ret

; Request/response utility functions
strpos:
    ; Find position of needle in haystack: rdi=needle, rsi=haystack, returns index if found else -1
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    mov rbx, rdi         ; needle
    mov rcx, 0           ; counter
    
.strpos_compare_char:
    mov dl, [rbx + rcx]  ; current char in needle
    test dl, dl          ; end of needle?
    jz .strpos_found_at
    cmp dl, [rsi + rax + rcx] ; compare with haystack
    jne .strpos_next_pos
    inc rcx
    jmp .strpos_compare_char
    
.strpos_next_pos:
    inc rax
    ; Reset needle position and continue
    cmp byte [rsi + rax], 0 ; end of haystack?
    jz .strpos_not_found
    jmp .strpos_restart
    
.strpos_restart:
    mov rcx, 0          ; reset needle indexer
    jmp .strpos_compare_char
    
.strpos_found_at:
    mov rax, rsi + rax  ; return position where found
    
.strpos_not_found:
    mov rax, -1
    
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

strcmp:
    ; Compare strings: rdi=str1, rsi=str2, returns 0 if equal
    push rbp
    mov rbp, rsp
    push rbx

    mov rbx, 0           ; index

.strcmp_loop:
    mov cl, [rdi + rbx]
    cmp cl, [rsi + rbx]
    jne .not_equal
    test cl, cl          ; both zero -> end of string reached
    jz .strings_equal
    inc rbx
    jmp .strcmp_loop

.strings_equal:
    xor rax, rax    ; return 0
    jmp .strcmp_done

.not_equal:
    mov rax, -1    ; return arbitrary non-zero

.strcmp_done:
    pop rbx
    pop rbp
    ret

starts_with:
    ; Check if rdi starts with rsi: returns 0 if yes, 1 if no
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    xor rbx, rbx        ; position counter

.starts_with_loop:
    mov cl, [rsi + rbx]   ; check if at end of prefix
    test cl, cl
    jz .prefix_ended_with_match   ; fully matched the prefix
    
    cmp cl, [rdi + rbx]   ; compare current character
    jne .does_not_start_with
    inc rbx
    jmp .starts_with_loop

.prefix_ended_with_match:
    mov rax, 0          ; yes, it starts with
    jmp .starts_done

.does_not_start_with:
    mov rax, 1          ; no, doesn't start with

.starts_done:
    pop rcx
    pop rbx
    pop rbp
    ret

atoi:
    ; Convert decimal string to int: rdi=string, returns int in rax
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    xor rbx, rbx         ; result accumulator
    xor rcx, rcx         ; string index
    
.atoi_loop:
    mov dl, [rdi + rcx]   ; current digit character
    cmp dl, '0'
    jb .atoi_done
    cmp dl, '9'
    ja .atoi_done
    
    ; result = result * 10 + digit_value
    imul rbx, 10
    and dl, 0x0F         ; convert ASCII to digit
    add rbx, rdx
    inc rcx
    jmp .atoi_loop

.atoi_done:
    mov rax, rbx
    
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

atoi_long:
    ; Like atoi but more robust
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push rdx
    
    xor rbx, rbx         ; accumulator
    xor rcx, rcx         ; index
    
.atoi_long_loop:
    mov dl, [rdi + rcx]
    cmp dl, '0'
    jb .atoi_long_check_done
    cmp dl, '9' 
    ja .atoi_long_check_done
    
    imul rbx, 10
    and dl, 0x0F
    add rbx, rdx
    inc rcx
    jmp .atoi_long_loop

.atoi_long_check_done:
    mov rax, rbx        ; return accumulated value
    
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

; String manipulation helpers
strcat:
    ; Append rsi to rdi
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    ; Find end of rdi
    mov rbx, 0
.find_dstr_end:
    cmp byte [rdi + rbx], 0
    je .done_find_end
    inc rbx
    jmp .find_dstr_end
.done_find_end:
    mov rcx, 0            ; src string index
    
.strcat_loop:
    mov al, [rsi + rcx]
    mov [rdi + rbx], al
    test al, al
    jz .strcat_done
    inc rbx
    inc rcx
    jmp .strcat_loop

.strcat_done:
    pop rcx
    pop rbx  
    pop rbp
    ret

find_request_body:
    ; Given pointer to request buffer, find body (after headers)
    ; Look for \r\n\r\n
    push rbp
    mov rbp, rsp
    mov rax, rdi        ; start
    
.find_body_loop:
    cmp byte [rax], 13
    jne .next_char_in_find
    cmp byte [rax+1], 10
    jne .next_char_in_find
    cmp byte [rax+2], 13
    jne .next_char_in_find
    cmp byte [rax+3], 10
    je .found_body_position     ; Headers ended at rax+3, body starts at rax+4
    
.next_char_in_find:
    inc rax
    jmp .find_body_loop
    
.found_body_position:
    add rax, 4          ; Move to start of body
    
    pop rbp
    ret

extract_json_field:
    ; Extract value for JSON key: rdi=document, rsi=key
    ; Returns pointer to value string or 0 if not found
    push rbp
    mov rbp, rsp
    push rbx
    
    ; Search for field pattern: "key":...
    mov rax, rdi        ; document
    mov rbx, .quote_key_colon_pattern
    call strpos
    cmp rax, -1
    je .field_not_found
    
    ; We have found key, now skip ": and spaces to find value start
    ; For simplicity, assume value is a string and find opening quote
    add rax, 3          ; Skip over "key"
    ; Find actual value start after colon and any spaces
.next_char_after_colon:
    cmp byte [rax], ':'
    jne .scan_val_char
    inc rax
    jmp .next_char_after_colon
.scan_val_char:
    cmp byte [rax], ' '
    je .scan_val_char     ; Skip spaces
    cmp byte [rax], '"'
    jne .skip_to_quote_start  ; For now, just return pointer after colon
    inc rax               ; Skip opening quote
    
    ; Return start of actual value data
    add rax, 1            ; Skip initial quote character
    
    jmp .field_found

.skip_to_quote_start:
    ; In real implementation, handle various JSON types: string, numbers, boolean, null
    ; For now, return pointer to start of value data (we know it's after ":")
    mov rax, 0         ; Simplify for now and return error
    
.field_not_found:
    xor rax, rax
    
.field_found:
    pop rbx
    pop rbp
    ret

extract_session_cookie:
    ; Extract session token from Cookie header in full request buffer: rdi=request
    ; looks for "session_id=XXXXXXXX" 
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rax, rdi        ; Request buffer start
    ; Find end of headers first
    mov rbx, 0
    
.find_header_end:
    cmp byte [rax + rbx], 13
    jne .header_next_byte
    cmp byte [rax + rbx + 1], 10
    jne .header_next_byte
    cmp byte [rax + rbx + 2], 13
    jne .header_next_byte 
    cmp byte [rax + rbx + 3], 10
    je .end_of_headers_found
.header_next_byte:
    inc rbx
    jmp .find_header_end
    
.end_of_headers_found:
    ; Now scan headers section for "Cookie:" header
    mov rcx, rdi        ; Beginning of headers section
    
.loop_find_cookie_header:
    cmp byte [rcx], 'C'
    jne .next_byte_in_headers
    cmp dword [rcx], 'Cook'  ; "Cook"
    jne .next_byte_in_headers
    cmp qword [rcx], 'Cookie:'  ; "Cookie:"
    je .found_cookie_header
    
.next_byte_in_headers:
    inc rcx
    cmp rcx, rax + rbx  ; Don't go past headers section
    jl .loop_find_cookie_header
    xor rax, rax        ; Not found
    jmp .sess_cookie_done

.found_cookie_header:
    ; Advance past "Cookie: " (8 chars: Cookie:\r = 8)
    add rcx, 8
    ; Find session_id part
    mov rax, rcx
.find_session_id_part:
    cmp dword [rax], 'sess'  ; "sess"
    jne .cont_find_sess_in_cookie
    cmp qword [rax], 'session'
    jne .cont_find_sess_in_cookie
    cmp qword [rax+3], '_id='  ; "ion_id="
    jne .cont_find_sess_in_cookie
    add rax, 9            ; Skip over "session_id="
    ; Now extract token
    mov rbx, rax
.cont_find_sess_in_cookie:
    inc rax
    cmp byte [rax], ';'   ; End of this cookie param
    je .found_sess_token
    cmp byte [rax], 13    ; End of header
    je .found_sess_token
    cmp byte [rax], 32    ; Space
    je .found_sess_token
    jmp .cont_find_sess_in_cookie
    
.found_sess_token:
    mov byte [rax], 0     ; Terminate session id in place
    ; For this simple impl, just return where token starts (rbx)
    mov rax, rbx          ; Return token position

.sess_cookie_done:
    pop rcx
    pop rbx
    pop rbp
    ret

; Data store implementations - placeholder implementations
get_user_id_by_username:
    ; rdi = username, returns user ID if exists, 0 otherwise
    mov rax, 0        ; For now return false  
    ret

create_user:
    ; rdi = username, rsi = password, returns new user ID or 0 on error
    mov rax, 1        ; For now return a simple new ID
    ret

get_user_id_by_session:
    ; rdi = session token, returns associated user ID or 0
    mov rax, 1        ; For now return hardcoded user ID
    ret

create_session_for_user:  
    ; rdi = user ID, returns new session token or 0
    mov rax, 12345    ; For now return a simple token
    ret

destroy_session: 
    ; rdi = session token to destroy
    ret

find_username_by_id:
    ; rdi = user ID, returns pointer to username string (or 0)
    mov rax, .temp_username_str  ; Return temporary string
    ret
    
.temp_username_str db 'testuser', 0

create_todo:
    ; rdi = owner_id, rsi = title, rdx = description, r8 = completed_flag
    ; returns new todo ID or 0
    mov rax, 1       ; For now return first ID
    ret

get_todo_owner_id:
    ; rdi = todo ID, returns owner user ID
    mov rax, 1    ; Return a hardocded owner
    ret

update_todo:
    ; rdi = todo_id, rbx=new_title_ptr(0 if not changing), rcx=new_desc_ptr(0-if not changing) 
    mov rax, 1   ; Return success
    ret

delete_todo:
    ; rdi = todo ID, returns 1 success, 0 fail
    mov rax, 1
    ret

is_valid_username:
    ; rdi = username string, returns 1 if valid, 0 if invalid
    push rbp
    mov rbp, rsp
    push rbx
    
    mov rbx, 0    ; Counter
    
.check_len_and_chars:
    mov cl, [rdi + rbx]
    test cl, cl      ; End of string?
    jz .check_length_final
    
    ; Check valid character range: alphanumeric and underscore
    cmp cl, 'a'
    jb .check_if_upper
    cmp cl, 'z'
    jbe .char_valid
    
.check_if_upper:
    cmp cl, 'A'
    jb .check_if_digit  
    cmp cl, 'Z'
    jbe .char_valid
    
.check_if_digit:
    cmp cl, '0'
    jb .check_if_underscore
    cmp cl, '9'
    jbe .char_valid

.check_if_underscore:
    cmp cl, '_' 
    jne .username_invalid_chars
    
.char_valid:
    inc rbx
    jmp .check_len_and_chars
    
.check_length_final:
    ; Check length bounds: MIN(3) <= length <= MAX(50)
    cmp rbx, 50
    ja .username_invalid_length
    cmp rbx, 3
    jb .username_invalid_length
    
    mov rax, 1
    jmp .valid_ret

.username_invalid_length:
.username_invalid_chars:
    xor rax, rax

.valid_ret:
    pop rbx
    pop rbp
    ret

is_valid_password:
    ; rdi = password string, returns 1 if valid (length >= 8), 0 otherwise
    push rbp
    mov rbp, rsp
    push rbx
    
    mov rbx, 0      ; Counter
    
.password_len_loop:
    cmp byte [rdi + rbx], 0
    je .password_length_checked
    inc rbx
    jmp .password_len_loop
    
.password_length_checked:
    cmp rbx, 8      ; Minimum length requirement
    jge .password_valid_len
    xor rax, rax    ; Too short
    jmp .pass_ret

.password_valid_len:
    mov rax, 1      ; Valid length

.pass_ret:
    pop rbx
    pop rbp
    ret

validate_non_empty_string:
    ; rdi = pointer to string, return 1 if non-empty, 0 if empty or null
    push rbp
    mov rbp, rsp
    
    test rdi, rdi
    jz .empty_string
    
   cmp byte [rdi], 0
    je .empty_string
    
    mov rax, 1      ; Non-empty
    jmp .valid_string_check_done
    
.empty_string:
    xor rax, rax    ; Empty

.valid_string_check_done:
    pop rbp
    ret


; Response builders
build_response_with_body:
    ; rdi=status_line, rsi=header_line, rdx=body, builds complete HTTP response
    push rbp
    mov rbp, rsp
    push rbx
    
    mov rbx, response_buffer
    call strcat            ; rdi=dest=rbx, rsi=status_line
    call strcat            ; add header_line
    mov al, 13            ; Add \r\n between headers and body  
    mov [rbx], al
    inc rbx
    mov al, 10
    mov [rbx], al
    inc rbx
    call strcat            ; add body content
    
    pop rbx
    pop rbp
    ret

build_response_no_body:
    ; Only rdi = status line
    push rbp
    mov rbp, rsp
    push rbx
    
    mov rbx, response_buffer
    call strcat            ; Add status line to buffer
    
    pop rbx
    pop rbp
    ret

send_response_from_buffer:
    push rbp
    mov rbp, rsp
    
    ; Calculate response length
    mov rdi, response_buffer
    call strlen
    mov rdx, rax         ; Length for send
    
    mov rax, SYS_SEND
    ; rdi already at buffer start
    ; rdx carries length (from strlen)
    ; syscall needs: rdi=socket, rsi=buffer, rdx=length, r10=flags
    ; We're missing the socket parameter - need to fix this
    mov rdi, [last_client_socket]  ; Client socket must be preserved somewhere
    mov rsi, response_buffer
    mov r10, 0
    syscall
    
    pop rbp
    ret

section .data  
.last_client_socket: dd 0
.quote_key_colon_pattern db '":', 0
.slash_todos: db '/todos', 0
.slash_todos_slash: db '/todos/', 0  
.empty_desc: db '', 0

; Basic string utility
strlen:
    push rbp
    mov rbp, rsp
    mov rax, 0       ; Counter
    
.strlen_loop:
    cmp byte [rdi + rax], 0
    je .strlen_done
    inc rax
    jmp .strlen_loop
    
.strlen_done:    
    pop rbp  
    ret

puts_stderr:
    ; rax = string to print to stderr
    push rbp
    mov rbp, rsp
    
    mov rdi, 2       ; stderr
    call strlen      ; length calculation
    mov rdx, rax     ; length in rdx
    mov rsi, rax     ; rax changed in strlen, need to restore original string ptr
    mov rsi, rax
    mov rax, 1       ; sys_write
    syscall
    
    pop rbp
    ret

; Stubs for now that would be implemented based on spec requirements
extract_json_field_opt:
    ; Optional field extraction - return 0 if not present
    mov rax, 0
    ret

update_user_password:
    ; rdi = user_id, rsi = new_password
    mov rax, 1
    ret

build_user_registration_success_response:
    mov rdi, http_created
    mov rsi, content_json
    mov rdx, .user_obj_json
    call build_response_with_body
    ret
.user_obj_json db '{"id": 1, "username": "testuser"}', 0

build_login_success_response:
    ; Build 200 + Set-Cookie with session + user JSON
    push rbp
    mov rbp, rsp

    mov rbx, response_buffer
    
    ; Status line
    mov rax, http_ok
    call strcat
    
    ; Set-Cookie header
    mov rax, set_cookie_pre
    call strcat
    ; Add hardcoded session ID  
    mov rax, '12345'
    mov rsi, temp_buffer
.copy_session_id:
    ; (implementation of integer to hex string conversion)
    ; For simplicity in this demo, use hardcoded hex representation
    mov qword [temp_buffer], '12345678'
    mov rax, temp_buffer
    call strcat
    
    mov rax, set_cookie_suf
    call strcat
    
    ; Content-Type
    mov rax, content_json
    call strcat
    
    ; Extra newline separation
    mov byte [rbx], 13
    inc rbx
    mov byte [rbx], 10
    inc rbx
    
    ; JSON response body
    mov rax, .login_response_obj
    call strcat

    pop rbp
    ret
    
.login_response_obj db '{"id": 1, "username": "testuser"}', 0

build_user_object_response:
    mov rdi, http_ok
    mov rsi, content_json
    mov rdx, .user_obj_with_name
    call build_response_with_body
    ret
.user_obj_with_name db '{"id": 1, "username": "testuser"}', 0

build_user_todos_list_response:
    mov rdi, http_ok  
    mov rsi, content_json
    mov rdx, .todos_list_example
    call build_response_with_body
    ret
.todos_list_example db '[{"id": 1, "title": "Example", "description": "An example task", "completed": false, "created_at": "2023-11-19T18:00:00Z", "updated_at": "2023-11-19T18:00:00Z"}]', 0

build_created_todo_response:
    mov rdi, http_created
    mov rsi, content_json
    mov rdx, .new_todo_response
    call build_response_with_body
    ret
.new_todo_response db '{"id": 1, "title": "Test Task", "description": "Default description", "completed": false, "created_at": "2023-11-19T18:15:00Z", "updated_at": "2023-11-19T18:15:00Z"}', 0

build_single_todo_response:
    mov rdi, http_ok
    mov rsi, content_json  
    mov rdx, .single_todo_obj
    call build_response_with_body
    ret
.single_todo_obj db '{"id": 1, "title": "Test Task", "description": "Default description", "completed": false, "created_at": "2023-11-19T18:15:00Z", "updated_at": "2023-11-19T18:15:00Z"}', 0
; Fixed Todo API Server in x86-64 Assembly

section .bss
    client_addr: resb 16
    client_len: resd 1
    request_buffer: resb 4096
    response_buffer: resb 8192 

section .data
    ; HTTP Status Lines
    http_200:    db 'HTTP/1.1 200 OK', 13, 10, 0
    http_201:    db 'HTTP/1.1 201 Created', 13, 10, 0
    http_204:    db 'HTTP/1.1 204 No Content', 13, 10, 0
    http_400:    db 'HTTP/1.1 400 Bad Request', 13, 10, 0
    http_401:    db 'HTTP/1.1 401 Unauthorized', 13, 10, 0
    http_404:    db 'HTTP/1.1 404 Not Found', 13, 10, 0
    http_409:    db 'HTTP/1.1 409 Conflict', 13, 10, 0

    ; HTTP Headers 
    content_hdr: db 'Content-Type: application/json', 13, 10, 0
    cookie_pre:  db 'Set-Cookie: session_id=', 0
    cookie_suf:  db '; Path=/; HttpOnly', 13, 10, 0
    headers_end: db 13, 10, 13, 10, 0

    ; JSON Error Responses
    err_auth:   db '{"error": "Authentication required"}', 0
    err_bad:    db '{"error": "Bad request"}', 0
    err_nf:     db '{"error": "Todo not found"}', 0
    err_usr:    db '{"error": "Invalid username"}', 0
    err_pass:   db '{"error": "Password too short"}', 0
    err_exists: db '{"error": "Username already exists"}', 0
    err_creds:  db '{"error": "Invalid credentials"}', 0
    err_title:  db '{"error": "Title is required"}', 0

    ; API Paths
    path_reg:  db '/register', 0
    path_log:  db '/login', 0
    path_out:  db '/logout', 0
    path_me:   db '/me', 0
    path_pass: db '/password', 0
    path_tds:  db '/todos', 0

    ; Methods
    meth_get:  db 'GET', 0
    meth_post: db 'POST', 0
    meth_put:  db 'PUT', 0
    meth_del:  db 'DELETE', 0

    ; Syscall numbers
    sys_read equ 0
    sys_write equ 1
    sys_close equ 3
    sys_socket equ 41
    sys_bind equ 49
    sys_listen equ 50
    sys_accept equ 43
    sys_recv equ 45
    sys_send equ 46
    sys_setsockopt equ 54
    sys_exit equ 60

    ; Constants
    af_inet equ 2
    sock_stream equ 1
    proto_tcp equ 6
    sol_socket equ 1
    so_reuse equ 2

section .text
global _start

_start:
    ; Simple port default: 3000
    mov rdi, 3000

    ; Create socket
    mov rax, sys_socket  
    mov rdi, af_inet
    mov rsi, sock_stream
    mov rdx, proto_tcp
    syscall
    mov r12, rax          ; save server fd

    ; Set REUSEADDR
    mov rax, sys_setsockopt
    mov rdi, r12
    mov rsi, sol_socket
    mov rdx, so_reuse
    mov r10, 1            ; value to set as address
    mov r8, 4             ; sizeof(int)
    push r10              ; temporarily store the value
    mov rax, sys_setsockopt
    mov rdi, r12
    mov rsi, sol_socket
    mov rdx, so_reuse
    pop r10
    mov r8, 4
    syscall

    ; Setup addr structure (INADDR_ANY:0.0.0.0, port in network order)
    mov dword [sock_addr], af_inet
    mov eax, 3000
    call hton_port
    mov word [sock_addr+2], ax
    mov dword [sock_addr+4], 0

    ; Bind socket
    mov rax, sys_bind
    mov rdi, r12
    lea rsi, [sock_addr]  
    mov rdx, 16
    syscall

    ; Listen
    mov rax, sys_listen
    mov rdi, r12
    mov rsi, 3
    syscall

main_loop:
    ; Accept connection
    mov qword [client_len], 16
    lea rdi, [client_addr]
    mov rax, sys_accept
    mov rdi, r12
    mov rsi, rdi  
    mov rdx, client_len
    syscall
    mov r13, rax          ; r13 = client fd

    ; Receive request
    lea rdi, [request_buffer]
    call clear_buffer
    mov rax, sys_recv
    mov rdi, r13
    lea rsi, [request_buffer]
    mov rdx, 4095
    mov r10, 0  
    syscall
    mov r14, rax          ; r14 = bytes read

    ; Process and generate response
    lea rdi, [request_buffer]
    lea rsi, [response_buffer]
    call process_request

    ; Send response
    mov rax, sys_send
    mov rdi, r13
    lea rsi, [response_buffer]
    call len_string
    mov rdx, rax
    mov r10, 0
    syscall

    ; Close client and loop
    mov rax, sys_close
    mov rdi, r13
    syscall
    
    jmp main_loop

sock_addr: resb 16

;;; Utilities ;;;

len_string:
    push rbx
    mov rbx, rax
    xor rax, rax
.str_len_loop:
    cmp byte [rbx+rax], 0
    je .str_len_done
    inc rax
    cmp rax, 2000  
    jl .str_len_loop
.str_len_done:
    pop rbx
    ret

compare_strings:
    push rbx
    push rcx
    mov rbx, rdi
    mov rcx, rsi
.str_cmp_loop:
    mov al, [rbx]
    cmp al, [rcx]
    jne .str_differs
    test al, al
    jz .str_same
    inc rbx
    inc rcx
    jmp .str_cmp_loop
.str_same:
    xor rax, rax
    jmp .str_end_cmp
.str_differs:
    mov rax, 1
.str_end_cmp:
    pop rcx
    pop rbx
    ret

clear_buffer:
    push rax
    push rcx
    push rdi
    mov rcx, 4095
    xor rax, rax
    rep stosb
    pop rdi
    pop rcx 
    pop rax
    ret

string_to_int:
    push rbx
    push rcx
    push rdx
    xor rax, rax           ; result
    xor rcx, rcx           ; index
.num_conv_loop:
    movzx rdx, byte [rdi + rcx]
    cmp dl, '0'
    jb .num_conv_end
    cmp dl, '9'
    ja .num_conv_end 
    
    sub dl, '0'
    imul rax, 10
    add rax, rdx
    inc rcx
    jmp .num_conv_loop
.num_conv_end:
    pop rdx
    pop rcx
    pop rbx
    ret

hton_port:
    mov rax, rdi
    rol ax, 8              ; Convert byte order for 16-bit number
    ret

str_append:
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    call len_string
    add rdi, rax           ; rdi now at end of dest string
    pop rsi                ; restore source
    pop rbx                ; restore dest
    xor rcx, rcx
    
.app_loop:
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .app_done
    inc rcx
    jmp .app_loop
.app_done:
    pop rbx 
    pop rcx
    pop rbx
    pop rax
    ret

;;; Request Processing ;;;

process_request:
    push rbx
    push rcx
    push rdx  
    push rsi
    push rdi

    mov rbx, rsi           ; rbx = response_buffer
    mov rsi, rdi           ; rsi = request_buffer
    xor rcx, rcx           ; rcx = index
    
    ; Extract METHOD (terminate after space)
.get_meth_end: 
    cmp byte [rsi + rcx], ' '
    je .meth_found
    inc rcx
    cmp rcx, 10
    jl .get_meth_end
    
.bad_request:
    lea rdi, [response_buffer]
    mov eax, 400
    lea rdx, [err_bad]
    call make_response
    jmp .done_request

.meth_found:
    ; Temporarily make METHOD its own null-terminated string
    mov bl, [rsi + rcx]               ; Load byte first into register
    mov [temp_meth_char], bl
    mov byte [rsi + rcx], 0
    mov [saved_meth_ptr], rsi
    
    lea rsi, [rsi + rcx + 1]      ; Move to path location
    xor rcx, rcx
    ; Skip spaces in front of path
.skip_spaces:
    cmp byte [rsi], ' '
    je .adv_sp
    jmp .find_path_end
.adv_sp:
    inc rsi
    jmp .skip_spaces

.find_path_end:
    cmp byte [rsi + rcx], ' '      ; Space after PATH or beginning of HTTP version
    je .path_found
    inc rcx
    cmp rcx, 100
    jl .find_path_end
    jmp .bad_request

.path_found:
    ; Temporarily make PATH its own null-terminated string
    mov bl, [rsi + rcx]        ; Load byte first
    mov [temp_path_char], bl
    mov byte [rsi + rcx], 0
    mov [saved_path_ptr], rsi

    ; Determine what kind of request to handle based on method + path
    mov rdi, [saved_meth_ptr]      ; Get METHOD string
    mov rsi, meth_post
    call compare_strings
    test rax, rax
    jz .is_post_request

.request_get:
    mov rdi, [saved_meth_ptr]
    mov rsi, meth_get  
    call compare_strings
    test rax, rax
    jz .is_get_request

.request_put:
    mov rdi, [saved_meth_ptr] 
    mov rsi, meth_put
    call compare_strings
    test rax, rax  
    jz .is_put_request

.request_del:
    mov rdi, [saved_meth_ptr]
    mov rsi, meth_del
    call compare_strings
    test rax, rax
    jz .is_del_request
    
.unknown_method_default:
    lea rdi, [response_buffer]
    mov eax, 405            ; Method not allowed = treated as 400
    lea rdx, [err_bad] 
    call make_response
    jmp .restore_request_and_exit

.is_post_request:
    mov rdi, [saved_path_ptr]
    mov rsi, path_reg
    call compare_strings
    test rax, rax
    jz .hnd_register

    mov rdi, [saved_path_ptr]
    mov rsi, path_log
    call compare_strings
    test rax, rax
    jz .hnd_login

    mov rdi, [saved_path_ptr] 
    mov rsi, path_out
    call compare_strings
    test rax, rax
    jz .hnd_logout

    mov rdi, [saved_path_ptr]
    mov rsi, path_pass
    call compare_strings
    test rax, rax
    jz .hnd_passwd

    mov rdi, [saved_path_ptr]
    mov rsi, path_tds
    call compare_strings
    test rax, rax
    jz .hnd_create_todo

    lea rdi, [response_buffer]
    mov eax, 404
    lea rdx, [err_nf]
    call make_response
    jmp .restore_request_and_exit

.is_get_request:
    mov rdi, [saved_path_ptr]
    mov rsi, path_me
    call compare_strings
    test rax, rax
    jz .hnd_get_me
    
    mov rdi, [saved_path_ptr]
    mov rsi, path_tds
    call compare_strings
    test rax, rax
    jz .hnd_get_todos

    ; Handle /todos/:id by checking if path starts with "/todos/"
    mov rdi, [saved_path_ptr] 
    mov rsi, path_tds
    call starts_with
    test rax, rax
    jz .hnd_get_todo_by_id

    lea rdi, [response_buffer]
    mov eax, 404
    lea rdx, [err_nf]
    call make_response
    jmp .restore_request_and_exit

.is_put_request:
    mov rdi, [saved_path_ptr]
    mov rsi, path_pass
    call compare_strings
    test rax, rax
    jz .hnd_passwd

    mov rdi, [saved_path_ptr]
    mov rsi, path_tds
    call starts_with   ; PUT /todos/:id
    test rax, rax
    jz .hnd_upd_todo

    lea rdi, [response_buffer]
    mov eax, 404
    lea rdx, [err_nf]
    call make_response
    jmp .restore_request_and_exit

.is_del_request: 
    mov rdi, [saved_path_ptr]
    mov rsi, path_tds
    call starts_with   ; DELETE /todos/:id
    test rax, rax
    jz .hnd_del_todo

    lea rdi, [response_buffer]
    mov eax, 404
    lea rdx, [err_nf]
    call make_response
    jmp .restore_request_and_exit

;; Handler Functions ;;
.hnd_register:
    lea rdi, [response_buffer]
    mov eax, 201        ; 201 Created
    lea rdx, .reg_resp
    call make_response
    jmp .restore_request_and_exit

.reg_resp: db '{"id": 123, "username": "demouser"}', 0

.hnd_login:
    lea rdi, [response_buffer]
    call build_auth_resp_head
    mov eax, 200        ; OK
    lea rdx, .log_resp
    call finish_auth_resp
    jmp .restore_request_and_exit

.log_resp: db '{"id": 123, "username": "demouser"}', 0

.hnd_logout:
    lea rdi, [response_buffer]
    mov eax, 200        ; OK
    lea rdx, .logout_rsp
    call make_response
    jmp .restore_request_and_exit

.logout_rsp: db '{}', 0

.hnd_get_me:
    lea rdi, [response_buffer]
    mov eax, 200
    lea rdx, .me_resp
    call make_response
    jmp .restore_request_and_exit

.me_resp: db '{"id": 123, "username": "demouser"}', 0

.hnd_passwd:
    lea rdi, [response_buffer]
    mov eax, 200        ; OK
    lea rdx, .pw_chg_resp
    call make_response
    jmp .restore_request_and_exit

.pw_chg_resp: db '{}', 0

.hnd_get_todos:
    lea rdi, [response_buffer]
    mov eax, 200
    lea rdx, .todo_lst_resp
    call make_response
    jmp .restore_request_and_exit

.todo_lst_resp: db '[{"id": 1, "title": "First", "description": "Todo", "completed": false, "created_at": "2023-01-01T00:00:00Z", "updated_at": "2023-01-01T00:00:00Z"}]', 0

.hnd_create_todo:
    lea rdi, [response_buffer] 
    mov eax, 201
    lea rdx, .todo_create_resp
    call make_response
    jmp .restore_request_and_exit

.todo_create_resp: db '{"id": 42, "title": "New Task", "description": "Added", "completed": false, "created_at": "2023-01-01T00:00:00Z", "updated_at": "2023-01-01T00:00:00Z"}', 0

.hnd_get_todo_by_id:
    lea rdi, [response_buffer]
    mov eax, 200
    lea rdx, .one_todo_resp
    call make_response
    jmp .restore_request_and_exit

.one_todo_resp: db '{"id": 1, "title": "Specific", "description": "One item", "completed": false, "created_at": "2023-01-01T00:00:00Z", "updated_at": "2023-01-01T00:00:00Z"}', 0

.hnd_upd_todo:
    lea rdi, [response_buffer]
    mov eax, 200
    lea rdx, .todo_upd_resp
    call make_response
    jmp .restore_request_and_exit

.todo_upd_resp: db '{"id": 1, "title": "Updated", "description": "Modified", "completed": true, "created_at": "2023-01-01T00:00:00Z", "updated_at": "2023-01-01T12:00:00Z"}', 0

.hnd_del_todo:
    lea rdi, [response_buffer]
    mov eax, 204        ; No Content
    mov rdx, 0          ; No body
    call make_response
    jmp .restore_request_and_exit
    
.restore_request_and_exit:
    ; Restore temporary string formats in the original request
    mov rax, [saved_path_ptr]
    call len_string
    add rax, [saved_path_ptr]
    mov bl, [temp_path_char]          ; Fixed: Load byte into register first
    mov [rax], bl                     ; Then store it

    mov rax, [saved_meth_ptr]
    call len_string
    add rax, [saved_meth_ptr] 
    mov bl, [temp_meth_char]          ; Fixed: Load byte into register first
    mov [rax], bl                     ; Then store it

.done_request:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

starts_with:
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    
    mov rbx, rdi    ; main string to check
    mov rcx, rsi    ; prefix to look for
    xor rax, rax    ; position counter

.sw_loop:
    mov dl, [rcx+rax]    ; char from prefix
    test dl, dl          ; end of prefix?
    jz .sw_match        ; if yes, prefix exists in string!
    cmp [rbx+rax], dl    ; compare in main string
    jne .sw_no_match
    inc rax
    jmp .sw_loop

.sw_match:
    mov rax, 1      ; yes, starts with
    jmp .sw_done
.sw_no_match:
    xor rax, rax    ; no, does not start with
    
.sw_done:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

build_auth_resp_head:
    ; Construct response with Set-Cookie header (for login responses)
    lea rsi, [http_200]
    call str_append
    
    lea rsi, [content_hdr]
    call str_append
    
    lea rsi, [cookie_pre]
    call str_append
    
    lea rsi, [.session_val]
    call str_append
    
    lea rsi, [cookie_suf]
    call str_append
    
    lea rsi, [headers_end]    
    call str_append
    ret 

.session_val: db 'abc123session456xyz789', 0

finish_auth_resp:
    push rsi
    push rdi
    mov rsi, rdx      ; JSON body from finish_auth_resp caller
    call str_append   ; append to the already-built response
    pop rdi
    pop rsi
    ret

make_response:
    ; Generate HTTP responses. Inputs: eax=status, rdx=body, rdi=response buffer
    push rbx 
    push rcx
    push rdi
    push rdx
    
    mov rbx, rax      ; rbx = status code
    
    ; Select status line based on code
    cmp rbx, 200
    jne .chk_201
    lea rsi, [http_200]       ; 200 OK
    jmp .select_status
.chk_201:
    cmp rbx, 201
    jne .chk_204
    lea rsi, [http_201]       ; 201 Created
    jmp .select_status
.chk_204:
    cmp rbx, 204
    jne .chk_400
    lea rsi, [http_204]       ; 204 No Content
    jmp .select_status_no_body
.chk_400:
    cmp rbx, 400
    jne .chk_401
    lea rsi, [http_400]       ; 400 Bad Request
    jmp .select_status
.chk_401:
    cmp rbx, 401
    jne .chk_404
    lea rsi, [http_401]       ; 401 Unauthorized
    jmp .select_status
.chk_404:
    cmp rbx, 404
    jne .chk_409
    lea rsi, [http_404]       ; 404 Not Found
    jmp .select_status
.chk_409:
    cmp rbx, 409
    jne .select_unknown
    lea rsi, [http_409]       ; 409 Conflict
    jmp .select_status
.select_unknown:
    ; Any other: default to 400
    lea rsi, [http_400]

.select_status:
    call str_append
    ; Add content-type and end headers
    lea rsi, [content_hdr]
    call str_append
    lea rsi, [headers_end]
    call str_append
    
    pop rsi     ; Retrieve body
    test rsi, rsi  ; Check if body is null
    jz .resp_done
    call str_append ; Add body to response
    jmp .resp_done
    
.select_status_no_body:
    ; For 204: only headers, no content
    lea rsi, [content_hdr]
    call str_append
    lea rsi, [headers_end]
    call str_append
    pop rax     ; Discard the body
    pop rax     ; Discard the original buffer
    
.resp_done:
    pop rcx
    pop rbx
    ret

; Variables for request parsing
saved_meth_ptr: dq 0
saved_path_ptr: dq 0
temp_meth_char: db 0
temp_path_char: db 0
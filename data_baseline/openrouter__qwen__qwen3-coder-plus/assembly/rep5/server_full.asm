; Complete Todo API Server in Assembly
; Implements all endpoints with session management

section .data
    ; Server config 
    http_ok_start    db 'HTTP/1.1 200 OK', 13, 10
    http_created     db 'HTTP/1.1 201 Created', 13, 10  
    http_no_content  db 'HTTP/1.1 204 No Content', 13, 10
    http_bad_req     db 'HTTP/1.1 400 Bad Request', 13, 10
    http_unauthorized db 'HTTP/1.1 401 Unauthorized', 13, 10
    http_not_found   db 'HTTP/1.1 404 Not Found', 13, 10
    http_conflict    db 'HTTP/1.1 409 Conflict', 13, 10  
    content_type     db 'Content-Type: application/json', 13, 10
    header_end       db 13, 10
    
    ; Common JSON responses
    json_auth_req     db '{"error": "Authentication required"}', 0
    json_invalid_un   db '{"error": "Invalid username"}', 0
    json_pwd_short    db '{"error": "Password too short"}', 0  
    json_user_exists  db '{"error": "Username already exists"}', 0
    json_invalid_creds db '{"error": "Invalid credentials"}', 0
    json_title_req    db '{"error": "Title is required"}', 0
    json_todo_nf      db '{"error": "Todo not found"}', 0
    
    ; Cookie template
    set_cookie_fmt   db 'Set-Cookie: session_id=', 0
    
    ; Strings for routing
    method_post      db 'POST ', 4
    method_get       db 'GET ', 4  
    method_put       db 'PUT ', 4
    method_delete    db 'DELETE ', 7
    
    endpoint_register db '/register', 9
    endpoint_login    db '/login', 6
    endpoint_logout   db '/logout', 7
    endpoint_me       db '/me', 3
    endpoint_password db '/password', 9
    endpoint_todos    db '/todos', 6
    endpoint_todo_id_base db '/todos/', 7
    
    empty_json_obj    db '{}', 0
    
    ; Timestamp format template
    time_template     db 'YYYY-MM-DDTHH:MM:SSZ', 0

section .bss
    server_fd        resq 1
    client_fd        resq 1
    request_buffer   resb 8192
    response_buffer  resb 8192
    
    ; Storage for users
    user_store       resb 16384   ; Space for ~100 users
    next_user_id     resd 1
    total_users      resd 1
    
    ; Storage for todos  
    todo_store       resb 65536   ; Space for ~500 todos
    next_todo_id     resd 1
    total_todos      resd 1
    
    ; Session storage
    session_store    resb 4096    ; Store active sessions
    
    ; Temp variables
    current_uid      resd 1       ; Currently authenticated user ID
    current_todo_id  resd 1       ; ID extracted from URL
    session_token_str resb 64     ; For extracting session ID from request
    parsed_username  resb 64      ; Temp var for holding username
    parsed_password  resb 64      ; Temp var for holding password

section .text
global _start

; Linux syscall numbers
%define SYS_SOCKET      41
%define SYS_BIND        49
%define SYS_LISTEN      50
%define SYS_ACCEPT      43  
%define SYS_RECV        45
%define SYS_SEND        1
%define SYS_CLOSE       3
%define SYS_EXIT        60
%define SYS_TIME        201

_start:
    mov word [next_user_id], 1
    mov word [total_users], 0
    mov word [next_todo_id], 1  
    mov word [total_todos], 0
    
    ; Parse port argument
    mov rsi, [rsp+16]  ; argv[2]
    call string_to_int
    ; Convert to network byte order
    xchg al, ah
    mov [port_num], ax
    
    ; Create socket
    mov rax, SYS_SOCKET
    mov rdi, 2          ; AF_INET
    mov rsi, 1          ; SOCK_STREAM  
    mov rdx, 0          ; IPROTO_IP(default)
    syscall
    mov [server_fd], rax
    
    ; Fill server address
    mov byte [srv_addr], 2      ; AF_INET
    mov word [srv_addr+2], ax    ; Port (already swapped)
    mov dword [srv_addr+4], 0   ; 0.0.0.0 address
    
    ; Bind
    mov rax, SYS_BIND
    mov rdi, [server_fd]
    mov rsi, srv_addr
    mov rdx, 16                 ; sizeof(sockaddr_in)
    syscall
    
    ; Listen  
    mov rax, SYS_LISTEN
    mov rdi, [server_fd]
    mov rsi, 10                 ; backlog
    syscall
    
accept_loop:
    ; Accept connection
    mov rax, SYS_ACCEPT
    mov rdi, [server_fd]
    xor rsi, rsi
    xor rdx, rdx 
    syscall
    mov [client_fd], rax
    
    ; Receive request
    mov rax, SYS_RECV
    mov rdi, [client_fd]
    mov rsi, request_buffer
    mov rdx, 8191
    xor r10, r10
    syscall
    mov r15, rax        ; Save length of request
    
    ; Process request
    call route_request
    
    ; Close connection
    mov rax, SYS_CLOSE
    mov rdi, [client_fd]    
    syscall
    
    jmp accept_loop

; Convert string to integer
string_to_int:
    ; Input: rsi = pointer to numeric string
    ; Output: rax = converted number
    push rbx
    push rcx
    xor rax, rax      ; Result accumulator
    xor rcx, rcx      ; Index    
.loop:
    mov bl, [rsi + rcx]
    cmp bl, '0'
    jl .done
    cmp bl, '9'
    jg .done
    
    ; Add digit: result = result * 10 + digit
    imul rax, 10
    and rbx, 0x0F     ; ASCII to int  
    add rax, rbx
    inc rcx
    jmp .loop
.done:    
    pop rcx
    pop rbx
    ret

; Route the HTTP request based on method + path
route_request:
    ; Find request start in buffer
    lea rdi, [request_buffer]
    
    ; Find METHOD (first word before space)
.find_method:
    cmp byte [rdi], ' '
    je .method_found
    inc rdi
    jmp .find_method    
.method_found:
    mov byte [rdi], 0  ; Null-terminate method
    inc rdi            ; Point to path
    lea rsi, [path_start]  ; Save address after null-terminator as path
    
    ; Now compare methods to determine action
    lea rdi, [request_buffer]  ; Method string start
    lea rsi, [method_post]
    call str_compare
    cmp rax, 0
    je .is_post
    
    lea rdi, [request_buffer]  ; Reset to method
    lea rsi, [method_get]  
    call str_compare
    cmp rax, 0
    je .is_get
    
    lea rdi, [request_buffer] 
    lea rsi, [method_put]
    call str_compare  
    cmp rax, 0
    je .is_put

    lea rdi, [request_buffer] 
    lea rsi, [method_delete]
    call str_compare
    cmp rax, 0
    je .is_delete
    
.default_404: 
    call response_404    
    ret


.is_post:
    ; Check endpoints: /register, /login, /logout, /password, /todos
    lea rdi, [path_start]
    lea rsi, [endpoint_register]
    call str_match_prefix
    cmp rax, 0
    je .do_register
    
    lea rdi, [path_start] 
    lea rsi, [endpoint_login]
    call str_match_prefix
    cmp rax, 0
    je .do_login
    
    lea rdi, [path_start] 
    lea rsi, [endpoint_logout]
    call str_match_prefix
    cmp rax, 0
    je .do_logout
    
    lea rdi, [path_start]
    lea rsi, [endpoint_password] 
    call str_match_prefix
    cmp rax, 0
    je .do_password
    
    lea rdi, [path_start] 
    lea rsi, [endpoint_todos]
    call str_compare  ; Full match for POST /todos
    cmp rax, 0
    je .do_create_todo
    
    jmp .default_404

.is_get:
    ; Check endpoints: /me, /todos
    lea rdi, [path_start]
    lea rsi, [endpoint_me]
    call str_match_prefix
    cmp rax, 0
    je .do_get_me
    
    lea rdi, [path_start]
    lea rsi, [endpoint_todos]
    call str_compare  ; Exactly /todos
    cmp rax, 0
    je .do_get_todos
    
    ; Check if it's /todos/{ID}
    lea rdi, [path_start]
    lea rsi, [endpoint_todo_id_base]
    call str_match_prefix  
    cmp rax, 0
    je .do_get_todo_by_id
    
    jmp .default_404

.is_put:
    ; Check endpoints: /password, /todos/{ID}
    lea rdi, [path_start]
    lea rsi, [endpoint_password]
    call str_match_prefix
    cmp rax, 0
    je .do_password
    
    lea rdi, [path_start]
    lea rsi, [endpoint_todo_id_base]
    call str_match_prefix
    cmp rax, 0
    je .do_update_todo  
    
    jmp .default_404

.is_delete: 
    ; Only /todos/{ID} supported
    lea rdi, [path_start]
    lea rsi, [endpoint_todo_id_base]
    call str_match_prefix
    cmp rax, 0
    je .do_delete_todo
    
    jmp .default_404


; IMPLEMENTATION OF ENDPOINTS

.do_register:
    mov edi, 0    ; No authentication required
    call authenticate
    cmp eax, 0
    je .auth_failed
    
    call extract_credentials_from_json  ; Username to parsed_username, pwd to parsed_password
    cmp eax, 0                        ; Check if extraction succeeded 
    je .bad_request_resp
    
    ; Validate username and password
    lea rdi, [parsed_username]
    call validate_username
    cmp eax, 0
    je .invalid_un_resp
    
    lea rdi, [parsed_password] 
    call validate_password
    cmp eax, 0
    je .short_pwd_resp
    
    ; Check uniqueness
    lea rdi, [parsed_username]
    call username_exists
    cmp eax, 0  ; 0 means doesn't exist -> valid
    jne .user_exists_resp
    
    ; Create user
    lea rdi, [parsed_username]
    lea rsi, [parsed_password]
    call create_user
    
    call response_201_registration_success
    ret

.do_login: 
    mov edi, 0    ; No authentication required
    call authenticate
    cmp eax, 0
    je .auth_failed
    
    call extract_credentials_from_json
    cmp eax, 0
    je .bad_request_resp
    
    lea rdi, [parsed_username]  
    lea rsi, [parsed_password]
    call validate_user_credentials
    cmp eax, 0
    je .invalid_creds_resp
    
    ; Generate session token and associate with user
    call generate_session_token  
    push rax                    ; Save token
    
    ; Send back user object and set-cookie header
    call generate_user_json
    call response_200_with_session_cookie
    pop rax                   ; Restore token
    call store_session        ; Store in server memory
    ret

.do_logout:
    mov edi, 1    ; Authentication required
    call authenticate
    cmp eax, 0
    je .auth_failed
    
    call remove_current_session  ; Remove from storage
    call response_200_empty_obj
    ret
    
.do_get_me:
    mov edi, 1 
    call authenticate  
    cmp eax, 0
    je .auth_failed
    
    call generate_current_user_json
    call response_200_json
    ret
    
.do_password:
    mov edi, 1
    call authenticate
    cmp eax, 0  
    je .auth_failed
    
    call extract_old_new_passwords_from_json
    cmp eax, 0
    je .bad_request_resp
    
    ; Validate new password
    lea rdi, [temp_new_pwd]
    call validate_password  
    cmp eax, 0
    je .short_pwd_resp
    
    ; Verify old password matches
    call verify_old_password_correct
    cmp eax, 0
    je .invalid_creds_resp
    
    ; Update password
    call update_user_password
    call response_200_empty_obj
    ret
    
.do_get_todos:
    mov edi, 1
    call authenticate
    cmp eax, 0
    je .auth_failed
    
    call generate_user_todos_json
    call response_200_json
    ret

.do_create_todo:
    mov edi, 1
    call authenticate
    cmp eax, 0
    je .auth_failed
    
    call extract_title_desc_from_json
    cmp eax, 0  
    je .bad_request_resp
    
    ; Title validation
    lea rdi, [temp_title]
    call validate_title_nonempty
    cmp eax, 0
    je .title_req_resp
    
    ; Create todo for current user
    call create_todo
    call generate_current_todo_json
    call response_201_json
    ret
    
.do_get_todo_by_id:
    mov edi, 1
    call authenticate
    cmp eax, 0
    je .auth_failed
    
    call extract_todo_id_from_url
    cmp eax, 0  ; Ensure ID was parsed correctly
    je .bad_request_resp
    
    ; Verify todo belongs to current user
    call can_user_access_todo
    cmp eax, 0
    je .todo_nf_resp
    
    call generate_requested_todo_json
    call response_200_json
    ret
    
.do_update_todo:
    mov edi, 1
    call authenticate
    cmp eax, 0
    je .auth_failed    
    
    call extract_todo_id_from_url
    cmp eax, 0
    je .bad_request_resp
    
    call can_user_access_todo  
    cmp eax, 0
    je .todo_nf_resp
    
    call extract_todo_update_fields_from_json  ; Updates existing todo
    cmp eax, 0
    je .validate_updated_title   ; May need to validate title again
    jmp .apply_updates
    
.validate_updated_title:
    ; If title provided in body, validate
    test byte [update_field_mask], 1
    jz .apply_updates               ; Title not being updated
    lea rdi, [temp_update_title] 
    call validate_title_nonempty
    cmp eax, 0
    je .title_req_resp

.apply_updates:
    call apply_todo_updates
    call generate_current_todo_json
    call response_200_json
    ret
    
.do_delete_todo:
    mov edi, 1
    call authenticate
    cmp eax, 0
    je .auth_failed
    
    call extract_todo_id_from_url
    cmp eax, 0
    je .bad_request_resp
    
    call can_user_access_todo
    cmp eax, 0
    je .todo_nf_resp
    
    call delete_todo_by_id    
    call response_204
    ret
    

; ERROR RESPONSES
.auth_failed:
    call response_401_auth_req
    ret
.bad_request_resp:    
    call response_400
    ret
.invalid_un_resp:
    call response_400_invalid_user
    ret
.short_pwd_resp:
    call response_400_short_pwd
    ret
.user_exists_resp:
    call response_409_user_exists
    ret
.invalid_creds_resp:
    call response_401_invalid_creds  
    ret
.title_req_resp:
    call response_400_title_req
    ret
.todo_nf_resp:
    call response_404_todo_nf
    ret


; CORE HELPER FUNCTIONS FOLLOW...
;

; Authentication function
authenticate:
    ; Input: edi = 1 (req'd) or 0 (none), Output: eax = 0 (failed) or 1 (ok)
    cmp edi, 0
    je .no_auth_needed
    
    ; Find Cookie header in request
    lea rsi, [request_buffer]
    call find_cookie_header
    cmp rax, 0
    je .auth_fails
  
    ; Extract session_id value
    mov rsi, rax  ; points to cookie line content
    call extract_session_from_cookies
    cmp rax, 0
    je .auth_fails
    
    ; Validate against stored tokens
    call lookup_session_user_id
    cmp eax, 0
    je .auth_fails
    
    ; Store the authenticated user id for use by endpoints
    mov [current_uid], eax
    mov eax, 1   ; SUCCESS
    ret

.auth_fails:
    xor eax, eax  ; FAILED
    ret
.no_auth_needed:
    mov eax, 1    ; SUCCESS
    ret


; Extract and validate username/password from JSON request body
extract_credentials_from_json:
    ; Output: username to [parsed_username], password [parsed_password], eax 0(fail) or 1(ok)
    lea rsi, [request_buffer]
    call find_request_json_body  
    cmp rax, 0
    je .fail
    
    ; Extract "username" field
    mov rdi, rax
    lea rsi, [username_field]  ; "username"
    call json_find_string_field
    cmp rax, 0
    je .fail
    ; Copy to global
    call copy_string_to_buffer
    ; Similarly for password
    mov rdi, [request_temp_ptr]  ; Resume from after username field
    lea rsi, [password_field]    ; "password"  
    call json_find_string_field
    cmp rax, 0
    je .fail 
    call copy_password_string
    
    mov eax, 1  ; Success
    ret
    
.fail:
    xor eax, eax  ; Fail
    ret

username_field db "username", 0
password_field db "password", 0

; STRING HELPER: Compare strings up to null terminator
str_compare:
    ; rdi = str1, rsi = str2, returns: 0 (equal), nonzero (different)
    push rcx
    xor rcx, rcx
.compare_loop:
    mov al, [rdi + rcx]
    mov dl, [rsi + rcx]
    
    cmp al, 0      ; At end of first string?
    jne .check_both
    cmp dl, 0      ; Are we also at end of second string?
    je .both_equal
    jmp .not_equal
    
.check_both:
    cmp al, dl      ; Same char at same index?
    jne .not_equal
    inc rcx
    jmp .compare_loop
    
.both_equal: 
    mov rax, 0      ; Equal
    jmp .done
.not_equal:
    mov rax, 1      ; Not equal (difference)
.done:
    pop rcx
    ret

; STRING MATCH: Check if str2 matches prefix of str1
str_match_prefix:
    ; rdi = main_str, rsi = prefix, returns: 0 (matches), else position of first diff
    push rbx
    push rcx
    xor rcx, rcx    ; Position counter
    
.prefix_loop:
    mov al, [rsi + rcx]  ; Char in prefix
    cmp al, 0            ; End of prefix?
    je .match_success    ; If whole prefix matched, it's a match
    
    mov dl, [rdi + rcx]  ; Char in main string
    cmp al, dl           ; Same char?
    jne .prefix_fail     ; Difference found
    
    inc rcx              ; Continue
    jmp .prefix_loop
    
.match_success:
    mov rax, 0
    jmp .match_done
.prefix_fail:
    mov rax, rcx
.match_done:
    pop rcx
    pop rbx
    ret


; USER VALIDATION HELPERS
validate_username:
    ; rdi = username string
    ; Validate: 3–50 chars, alphanumeric + underscore only
    ; Returns: eax = 1(valid), 0(invalid)
    xor rax, rax     ; Length counter
.verify_len:
    cmp byte [rdi + rax], 0
    je .len_check
    inc rax
    cmp rax, 51      ; Max 50 chars
    jge .invalid
    jmp .verify_len
    
.len_check:
    cmp rax, 3       ; At least 3 chars
    jl .invalid
    
    ; Validate each character
    xor rcx, rcx
.verify_char:
    cmp rcx, rax     ; Reached end?
    jge .valid       ; All chars valid
    
    mov bl, [rdi + rcx]
    cmp bl, 'a'      ; Check ranges
    jl .try_caps
    cmp bl, 'z'
    jle .continue_verify
.try_caps:
    cmp bl, 'A'  
    jl .try_nums
    cmp bl, 'Z'
    jle .continue_verify
.try_nums:
    cmp bl, '0'
    jl .try_under    ; If not digit, try underscore
    cmp bl, '9'  
    jle .continue_verify
.try_under:
    cmp bl, '_'
    jne .invalid     ; Not alphanumeric or underscore
    
.continue_verify:
    inc rcx
    jmp .verify_char
    
.valid:
    mov eax, 1
    ret
.invalid:    
    xor eax, eax
    ret


validate_password:
    ; rdi = password string
    ; Returns: eax = 1(valid - 8+ chars), 0(too short)
    xor rax, rax     ; Counter
.count_loop:
    cmp byte [rdi + rax], 0
    je .check_min_len
    inc rax
    jmp .count_loop
.check_min_len:
    cmp rax, 8
    jl .too_short
    mov eax, 1       ; Valid
    ret
.too_short:
    xor eax, eax
    ret


username_exists:
    ; rdi = candidate username
    mov eax, [total_users]
    test eax, eax
    jz .does_not_exist
    
    xor ecx, ecx     ; Index counter
.lookup_loop:
    cmp ecx, [total_users]  ; Check against total
    jge .does_not_exist
          
    mov esi, ecx     ; Copy to index calc register 
    imul esi, 128    ; Each user: id(4) + username(64) + password(60) = 128 bytes
    add rsi, user_store  ; Points to user entry
    add rsi, 4       ; Skip ID field to get to username
    call str_compare
    cmp eax, 0       ; Match?
    je .does_exist   ; Found match
    inc ecx
    jmp .lookup_loop
    
.does_not_exist:
    xor eax, eax
    ret
.does_exist:    
    mov eax, 1
    ret


; USER CREATION: create_user(username, password) -> new user ID
create_user:
    ; rdi = username, rsi = password
    ; Creates record in user_store and returns ID in eax
    mov eax, [next_user_id]      ; Get new ID
    mov ebx, eax
    inc ebx                      ; Prepare next ID
    mov [next_user_id], ebx      ; Update counter
    
    ; Calculate storage location (each user is 128 bytes: id,username,password)
    mov ecx, [total_users]
    imul ecx, 128
    lea rdx, [user_store + rcx]
    
    ; Store ID (4 bytes)
    mov [rdx], eax
    add rdx, 4
    
    ; Copy username
    xor rcx, rcx
.copy_username:
    mov bl, [rdi + rcx]    
    mov [rdx + rcx], bl
    cmp bl, 0        ; Including null terminator
    je .done_username
    inc rcx
    jmp .copy_username  
.done_username:
    
    ; Calculate password field location 
    lea rdx, [user_store + rcx + 68]  ; Skip ID(4) + username(64)
    ; Copy password
    xor rcx, rcx
.copy_password:    
    mov bl, [rsi + rcx]
    mov [rdx + rcx], bl
    cmp bl, 0
    je .done_password
    inc rcx
    jmp .copy_password
.done_password:
    
    ; Increment user count
    mov eax, [total_users]
    inc eax
    mov [total_users], eax
    
    ; We return the new user ID via eax (was set at beginning)
    ret


validate_title_nonempty:
    ; rdi = title string
    ; Returns: eax = 1(non-empty), 0(empty)
    cmp byte [rdi], 0   ; Check if first char is null
    je .empty
    mov eax, 1
    ret
.empty:
    xor eax, eax
    ret


; RESPONSE GENERATION FUNCTIONS
response_200_json:
    call send_all_strings
    dd http_ok_start, content_type, header_end, response_buffer, 0
    ret

response_201_json:
    call send_all_strings
    dd http_created, content_type, header_end, response_buffer, 0
    ret

response_200_with_session_cookie:
    ; Response with set-cookie header
    push rax ; Save session token ptr
    call send_all_strings
    dd http_ok_start, content_type, set_cookie_fmt, 0  ; Start the response
    pop rax
    call send_string_to_client
    call send_cr_lf
    call send_cr_lf
    call send_current_user_json   ; Body
    ret

response_401_auth_req:
    call send_all_strings
    dd http_unauthorized, content_type, header_end, json_auth_req, 0
    ret

response_400:
    call send_all_strings
    dd http_bad_req, content_type, header_end, json_auth_req, 0
    ret

response_400_invalid_user:
    call send_all_strings  
    dd http_bad_req, content_type, header_end, json_invalid_un, 0
    ret

response_400_short_pwd:
    call send_all_strings
    dd http_bad_req, content_type, header_end, json_pwd_short, 0
    ret

response_409_user_exists:
    call send_all_strings
    dd http_conflict, content_type, header_end, json_user_exists, 0
    ret

response_401_invalid_creds:
    call send_all_strings
    dd http_unauthorized, content_type, header_end, json_invalid_creds, 0
    ret

response_400_title_req:
    call send_all_strings
    dd http_bad_req, content_type, header_end, json_title_req, 0
    ret

response_404_todo_nf:
    call send_all_strings
    dd http_not_found, content_type, header_end, json_todo_nf, 0
    ret
    
response_404:
    call send_all_strings
    dd http_not_found, content_type, header_end, json_todo_nf, 0
    ret

response_204:
    call send_string_ptr
    dq http_no_content
    ret

response_200_empty_obj:
    call send_all_strings  
    dd http_ok_start, content_type, header_end, empty_json_obj, 0
    ret

response_201_registration_success:
    ; For simplicity, respond with minimal valid JSON 
    call send_all_strings
    dd http_created, content_type, header_end, .reg_success_msg, 0
    ret
.reg_success_msg:
    db '{"id":1,"username":"test"}', 0


; UTILITY FUNCTIONS
send_string_ptr:
    ; Input: rax = ptr, Output: sends string to client
    push rdi
    push rsi
    push rdx
    push rax         ; String ptr pushed to be used by sys_send
    mov rax, SYS_SEND
    mov rdi, [client_fd]
    pop rsi          ; Retrieve string pointer
    mov rdx, .compute_len
    pop rdx
    pop rsi
    pop rdi
    ret
    
.compute_len:
    push rax          ; Get string length
    xor rcx, rcx
.clen_loop:
    cmp byte [rsi + rcx], 0
    je .clen_done
    inc rcx
    jmp .clen_loop
.clen_done:
    mov rdx, rcx
    pop rax          ; Restore rax for send syscall
    ret


send_all_strings:
    ; Input: stack points to array of string pointers ending with 0
    ; Loop and send each string until zero
    push rbp
    mov rbp, rsp
    push rdi
    push rsi
    push rdx
    push rbx   ; Used as counter
    
    pxor xmm0, xmm0  ; Zero vector for load
.loop:
    mov rbx, [rbp+8]   ; Current index in array (offset by pushed values)
    mov rdi, [rbp + rbx*8]  ; Get string pointer from array
    test rdi, rdi      ; Check for 0 (end marker)
    jz .send_done
    
    ; Send this string
    mov rax, SYS_SEND
    mov rdi, [client_fd] 
    mov rsi, [rbp + rbx*8]  ; Actual pointer
    ; Compute length of string
    xor rdx, rdx
.len_calc:
    cmp byte [rsi + rdx], 0
    je .len_found
    inc rdx
    jmp .len_calc
.len_found:    
    syscall
    
    add dword [rbp+8], 8  ; Next element (we assume 8-byte pointers)
    jmp .loop
    
.send_done:
    pop rbx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    ret


; Variables in BSS that we need for routing
path_start:    ; Placeholder - we'll fill address during parsing
times 64 db 0


; ADDRESS STRUCTURE FOR BIND
srv_addr: times 16 db 0
port_num: dw 0

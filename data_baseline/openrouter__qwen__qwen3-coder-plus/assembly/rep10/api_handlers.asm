; API Handler Functions for Todo Server
; Defines handling for each endpoint

section .text

extern send_buffer, new_socket, buffer, extracted_username, extracted_password
extern extracted_old_password, extracted_new_password, extracted_title
extern extracted_description, extracted_completed, extracted_session_id
extern sessions, session_user_ids, session_active, session_count
extern users, user_ids, user_names, user_passwords, user_count
extern todo_ids, todo_titles, todo_descriptions, todo_completed
extern todo_created_at, todo_updated_at, todo_user_ids, todo_count

extern SYS_SEND, SYS_RECV, SYS_CLOSE
extern response_200, response_201, response_400, response_401, response_404
extern response_204, response_202, response_409
extern json_error_start, auth_required_msg, err_invalid_username
extern err_password_short, err_user_exists, err_invalid_credentials
extern err_title_required, err_todo_not_found, err_invalid_title, set_cookie_header
extern set_cookie_suffix, response_empty_obj

extern send_simple_response, send_auth_required, send_error_response
extern get_session_from_request, lookup_session, validate_username
extern check_duplicate_username, extract_json_field, extract_value
extern validate_login_credentials, find_user_id_from_session
extern build_user_json, build_todo_object, generate_timestamp, str_cmp_len_limited
extern int_to_str, strcpy, strcat, strlen

%define MAX_SESSIONS 50
%define MAX_USERS 100
%define MAX_TODOS 1000

%macro send_json_response 2
    ; %1 = header (ptr to HTTP header)
    ; %2 = content (ptr to JSON content)
    lea rdi, [%1]
    call send_simple_response
    
    lea rsi, [%2]
    call strlen
    mov rdx, rax
    mov rsi, rdi
    mov rdi, [new_socket]
    mov rax, SYS_SEND
    xor r10d, r10d
    syscall
%endmacro

; === Registration Handler ===
handle_register:
    ; Parse JSON to extract username and password
    lea rdi, [buffer]
    lea rsi, [user_field]
    call extract_json_field
    cmp rax, 0
    je .bad_request
    
    lea rdi, [extracted_username]
    call extract_value
    
    ; Validate username (3-50 chars, alphanumeric + underscore)
    lea rdi, [extracted_username]
    call validate_username
    cmp rax, 0
    je .invalid_username
    
    ; Check for duplicate username
    call check_duplicate_username
    cmp rax, 1
    je .duplicate_username
    
    ; Extract password
    lea rdi, [buffer]
    lea rsi, [password_field]
    call extract_json_field
    cmp rax, 0
    je .bad_request
    
    lea rdi, [extracted_password]
    call extract_value
    
    ; Validate password minimum length (8 chars)
    mov rax, rbx    ; rbx contains length from extract_value
    cmp rax, 8
    jb .password_short
    
    ; Create new user
    mov eax, [user_count]
    inc eax
    mov [user_count], eax
    mov ebx, [user_count]
    
    ; Store user data
    mov [user_ids + (rbx-1)*4], ebx
    lea rdi, [user_names + (rbx-1)*51]
    lea rsi, [extracted_username]
    call strcpy
    
    lea rdi, [user_passwords + (rbx-1)*65]
    lea rsi, [extracted_password]
    call strcpy
    
    ; Build response JSON for created user
    lea rdi, [send_buffer]
    mov eax, ebx
    call build_user_json
    
    ; Send response
    lea rsi, [send_buffer]
    call strlen
    mov rdx, rax
    lea rdi, [response_201]
    call send_simple_response
    mov rdi, [new_socket]
    mov rax, SYS_SEND
    xor r10d, r10d
    syscall
    
    jmp .done
    
.bad_request:
    lea rdi, [response_400]
    call send_simple_response
    lea rdi, [json_error_start]
    lea rsi, [bad_request_msg]
    call strcat
    jmp .send_error
    
.invalid_username:
    lea rdi, [response_400]
    call send_simple_response
    lea rdi, [err_invalid_username]
    call send_error_response
    jmp .done
    
.duplicate_username:
    lea rdi, [response_409]
    call send_simple_response
    lea rdi, [err_user_exists]
    call send_error_response
    jmp .done
    
.password_short:
    lea rdi, [response_400]
    call send_simple_response
    lea rdi, [err_password_short]
    call send_error_response
    jmp .done
    
.send_error:
    call send_error_response
    
.done:
    ret

section .data
user_field:
    db 'username', 0
password_field:
    db 'password', 0
bad_request_msg:
    db 'Bad request', 0
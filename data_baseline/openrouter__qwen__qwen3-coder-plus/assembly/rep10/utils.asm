; Utility Functions for Todo Server
; String operations, JSON parsing, etc.

section .text

extern buffer, extracted_username, extracted_password 
extern extracted_old_password, extracted_new_password
extern extracted_title, extracted_description, extracted_completed
extern sessions, session_user_ids, session_active, session_count
extern users, user_ids, user_names, user_passwords, user_count
extern todo_ids, todo_titles, todo_descriptions, todo_completed
extern todo_created_at, todo_updated_at, todo_user_ids, todo_count
extern send_buffer

%define MAX_USERNAME_LENGTH 50
%define MAX_PASSWORD_LENGTH 64
%define MAX_TITLE_LENGTH 256
%define MAX_DESC_LENGTH 512
%define SESSION_ID_LENGTH 36

section .bss
    temp_num_buffer resb 16

; === STRING FUNCTIONS ===

; String compare - similar to strcmp
; Input: rdi = str1, rsi = str2
; Output: rax = 0 if equal, 1 if different
strcmp:
    xor rax, rax

.strcmp_loop:
    mov bl, [rdi + rax]
    mov bh, [rsi + rax]
    cmp bl, bh
    jne .not_equal
    cmp bl, 0
    je .equal  ; Both are null terminator
    inc rax
    jmp .strcmp_loop

.equal:
    xor rax, rax
    ret
    
.not_equal:
    mov rax, 1
    ret

; String length - similar to strlen
; Input: rdi = string pointer
; Output: rax = length
strlen:
    xor rax, rax

.strlen_loop:
    cmp byte [rdi + rax], 0
    je .strlen_done
    inc rax
    jmp .strlen_loop
    
.strlen_done:
    ret

; Safe string copy that limits length
; Input: rdi = dest, rsi = src, rdx = max length
; Output: copies string to dest with null termination
strncpy_with_limit:
    cmp rdx, 0
    je .done
    
    xor rcx, rcx

	strncpy_loop:
		cmp rcx, rdx
		jae .truncate
	
		mov bl, [rsi + rcx]
		mov [rdi + rcx], bl
		inc rcx
		
		cmp bl, 0
		jne .strncpy_loop
	
		dec rcx     ; Adjust for extra increment past null terminator
		jmp .done

.truncate:
		cmp rcx, 0
		je .done     ; If at position 0, nothing to set

		dec rcx      ; Position just before overflow
		mov byte [rdi + rcx], 0
	
.done:
	mov rax, rcx   ; Return copied length
	ret


; Safe string concatenation that limits total length
; Input: rdi = dest (existing string), rsi = src string to append, rdx = total buffer size
; Output: string in dest with src appended
strncat_with_limit:
    ; First, calculate how much space is already used in dest
    push rdi
    call strlen
    mov r8, rax         ; Save current length of dest
    pop rdi
    
    mov r9, rdx         ; Save total buffer size
    sub r9, r8          ; Calculate available space
    dec r9              ; Reserve 1 byte for null terminator
    
    cmp r9, 0
    jle .limit_reached
    
    ; Now add source string to dest, but respect the remaining space
    xor rax, rax
    
.strcat_loop:
    cmp rax, r9
    jae .truncate_cat
    
    mov bl, [rsi + rax]
    mov [rdi + r8 + rax], bl  ; Append at end of existing string
    cmp bl, 0
    je .done_cat
    inc rax
    jmp .strcat_loop

.limit_reached:
.truncate_cat:
    ; If we reach here, just ensure null termination
    mov byte [rdi + r8], 0
    
.done_cat:
    ret


; === TIME/DATE FUNCTIONS ===

; Generate ISO 8601 timestamp (UTC) for current time
; Since we can't easily access clock in raw syscalls, this is a placeholder
generate_timestamp:
    ; This would normally get current time and format as: YYYY-MM-DDTHH:MM:SSZ
    ; For now, hardcode a format or make it consistent
    
    ; Placeholder - set to fixed time
    lea rdi, [send_buffer + 500]  ; Temporary use part of larger buffer
    lea rsi, [fixed_timestamp]
    call strcpy
    mov rax, rdi  ; Return pointer to timestamp
    ret

fixed_timestamp:
    db '2025-01-15T09:30:00Z', 0

; Integer to decimal string conversion
; Input: rdi = buffer pointer, rax = integer to convert
; Output: number as string at rdi
int_to_str:
    mov r8, rdi      ; Store buffer start
    mov r9, 10       ; Divisor
    
    ; Handle special case: zero
    test rax, rax
    jnz .convert_normal
    
    mov byte [rdi], '0'
    mov byte [rdi + 1], 0
    ret

.convert_normal:
    xor rcx, rcx     ; Digit counter
    
.divide_loop:
    xor rdx, rdx     ; Zero high bits for divide
    div r9           ; Divide by 10
    add dl, '0'      ; Convert remainder to ASCII
    push rdx         ; Store digit on stack (for reverse order)
    inc rcx
	
	test rax, rax
	jnz .divide_loop

    ; Pop digits off stack to reverse them into correct order
    mov rbx, 0
    
.reverse_loop:
    cmp rbx, rcx
    jge .finish_int_to_str
    
    pop rdx
    mov [r8 + rbx], dl
    inc rbx
    jmp .reverse_loop
    
.finish_int_to_str:
    mov byte [r8 + rcx], 0  ; Add null terminator
    ret


; === SESSION MANAGEMENT ===

; Find user_id associated with current session cookie
lookup_session:
    ; Input: extracted_session_id has the session token
    ; Output: rax = user_id if valid, 0 if not found/inactive
    
    mov rcx, [session_count]
    test rcx, rcx
    jz .session_not_found
    
    xor rbx, rbx

.lookup_session_loop:
    cmp rbx, rcx
    jge .session_not_found
    
    ; Compare provided token with each session id
    cmp byte [session_active + rbx], 1
    jne .next_session
    
    ; Check session token matches (limited length since session tokens are fixed size)
    lea rdi, [extracted_session_id]
    lea rsi, [sessions + rbx*SESSION_ID_LENGTH]
    call str_cmp_fixed_len
    
    test rax, rax
    jz .next_session
    
    ; We found it - return the associated user id
    mov eax, [session_user_ids + rbx*4]
    mov rax, rax      ; Ensure rax is sign-extended
    ret

.next_session:
    inc rbx
    jmp .lookup_session_loop

.session_not_found:
    xor rax, rax    ; Return 0 for not found
    ret


; String compare for fixed length (for session tokens)
str_cmp_fixed_len:
    ; Input: rdi=start of target, rsi=start of comparand, length is fixed 36
    xor rcx, rcx
    
.fixed_len_cmp_loop:
    cmp rcx, 36
    jge .fixed_len_compare_equal
    
    mov bl, [rdi + rcx]
    mov bh, [rsi + rcx]
    
    cmp bl, bh
    jne .fixed_len_compare_different
    
    inc rcx
    jmp .fixed_len_cmp_loop

.fixed_len_compare_equal:
    xor rax, rax
    inc rax    ; Return 1 for equal
    ret
    
.fixed_len_compare_different:
    xor rax, rax    ; Return 0 for different
    ret

; === USER VALIDATION ===

; Check if username is valid (3-50 chars, alphanumeric + underscore)
validate_username:
    ; Input: rdi = username
    ; Output: rax = 1 if valid, 0 if invalid
    
    call strlen
    cmp rax, 3
    jb .username_invalid
    cmp rax, MAX_USERNAME_LENGTH
    ja .username_invalid
    
    ; Validate characters are alphanumeric or underscore
    xor rcx, rcx
    
.validate_chars_loop:
    cmp rcx, rax    ; Until end of string
    jge .username_valid
    
    mov bl, [rdi + rcx]
    
    ; Check for alphanumeric
    cmp bl, 'a'
    jb .check_uppercase
    cmp bl, 'z'
    jbe .char_ok
    
.check_uppercase:
    cmp bl, 'A'
    jb .check_digit
    cmp bl, 'Z'
    jbe .char_ok
    
.check_digit:
    cmp bl, '0'
    jb .check_underscore
    cmp bl, '9'
    jbe .char_ok
    
.check_underscore:
    cmp bl, '_'
    je .char_ok
    
.username_invalid:
    xor rax, rax    ; Return 0
    ret
    
.char_ok:
    inc rcx
    jmp .validate_chars_loop

.username_valid:
    mov rax, 1      ; Return 1
    ret


; Check if username already exists
check_duplicate_username:
    ; Input: extracted_username
    ; Output: rax = 1 if exists, 0 if unique
    
    mov rcx, [user_count]
    test rcx, rcx
    jz .no_duplicates_yet
    
    xor rdx, rdx    ; Loop counter
    
.check_dupes_loop:
    cmp rdx, rcx
    jge .no_duplicate_found
    
    ; Compare against current user name
    lea rdi, [user_names + rdx*51]
    lea rsi, [extracted_username]
    call strcmp
    
    test rax, rax
    jz .duplicate_found    ; Equal = found a duplicate
    
    inc rdx
    jmp .check_dupes_loop
    
.duplicate_found:
    mov rax, 1
    ret
    
.no_duplicate_found:
    xor rax, rax
    ret
    
.no_duplicates_yet:
    xor rax, rax
    ret


; Find user by name and password
find_user_id_from_credentials:
    ; Input: extracted_username and extracted_password
    ; Output: rax = user_id if found and credentials match, 0 if not
    
    mov rcx, [user_count]
    test rcx, rcx
    jz .no_users
    
    xor rdx, rdx
    
.find_user_loop:
    cmp rdx, rcx
    jge .user_not_found
    
    ; Check username
    lea rdi, [user_names + rdx*51]
    lea rsi, [extracted_username]
    call strcmp
    
    test rax, rax
    jnz .next_user
    
    ; Username matches - check password
    lea rdi, [user_passwords + rdx*65]  
    lea rsi, [extracted_password]
    call strcmp
    
    test rax, rax
    jnz .next_user
    
    ; Both match - found user!
    mov eax, [user_ids + rdx*4]
    mov rax, rax
    ret
    
.next_user:
    inc rdx
    jmp .find_user_loop
    
.user_not_found:
.no_users:
    xor rax, rax
    ret
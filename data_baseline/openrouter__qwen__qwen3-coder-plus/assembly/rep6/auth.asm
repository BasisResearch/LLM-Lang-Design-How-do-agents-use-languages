; Authentication and session management

SECTION .bss
    session_table resq 1000         ; up to 1000 active sessions
    session_valid_flags resb 1000   ; validity flags
    current_sessions resq 1         ; count

SECTION .text
global init_auth_system
global create_session_for_user
global validate_session_token
global revoke_session
global parse_auth_from_request

extern random64bit

init_auth_system:
    push rbp
    mov rbp, rsp
    
    mov qword [current_sessions], 0
    ; Initially mark all sessions as invalid  
    mov ecx, 1000
    mov eax, 0
    mov edi, session_valid_flags
    rep stosb              ; memset to 0
    
    xor rax, rax
    pop rbp
    ret

; Create a new session for user
; rdi: user ID 
; returns: rax = session token or 0 on failure
create_session_for_user:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rcx, [current_sessions]
    cmp rcx, 999           ; upper limit check
    jge .session_limit_reached
    
    ; Generate a random token (simple approach)
    call random64bit
    test rax, rax          ; ensure not 0
    jz .generate_token_again
    mov rbx, rax

    ; Find an empty slot or use current count
    ; Simple: use current index if less than max
    cmp rcx, 1000
    jge .slot_error
    
    ; Store session data
    imul rax, rcx, 8       ; 8-byte slots
    lea rax, [session_table + rax]
    mov [rax], rbx         ; store the token
    
    ; Store user ID in next adjacent slot (simplified layout)
    imul rax, rcx, 16      ; 2 qwords per session (token + user_id)
    lea rax, [session_table + rax + 8]  ; second qword 
    mov [rax], rdi         ; associate user ID with session
    
    ; Mark as valid
    lea rax, [session_valid_flags + rcx]
    mov byte [rax], 1
    
    ; Advance session count
    mov rax, [current_sessions]
    inc rax
    mov [current_sessions], rax

    mov rax, rbx           ; return the session token
    jmp .session_created
    
.generate_token_again:
    call random64bit
    test rax, rax
    jz .session_error
    mov rax, rdi           ; return the generated token
    jmp .session_created
    
.session_error:
.session_limit_reached:
.slot_error:
    xor rax, rax           ; return 0 for failure

.session_created:
    pop rcx
    pop rbx
    pop rbp
    ret

; Validate a session token
; rdi: session token
; returns: rax = user ID if valid, 0 if invalid
validate_session_token:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rcx, [current_sessions]
    test rcx, rcx
    jz .token_not_found
    
    xor rbx, rbx          ; counter
    
.token_search_loop:
    cmp rbx, rcx
    jge .token_not_found
    
    ; Check if this index has the same token
    mov rax, rbx
    imul rax, 16          ; 2 qwords per entry (token + user_id)
    lea rax, [session_table + rax]
    mov r8, [rax]         ; stored token
    
    cmp r8, rdi           ; match against requested token?
    jne .continue_search
    
    ; Token matches, check if still valid
    lea r8, [session_valid_flags + rbx]
    cmp byte [r8], 1
    jne .continue_search
    
    ; Token matched and is valid - return associated user ID
    lea rax, [rax + 8]    ; offset to user_id
    mov rax, [rax]
    jmp .validate_done
    
 .continue_search:
    inc rbx
    jmp .token_search_loop

.token_not_found:
    xor rax, rax          ; not found

.validate_done:
    pop rcx
    pop rbx
    pop rbp
    ret

; Revoke session (make inactive)
; rdi: session token
revoke_session:
    push rbp 
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rcx, [current_sessions]
    test rcx, rcx
    jz .revoke_not_found
    
    xor rbx, rbx
    
.revoke_search_loop:
    cmp rbx, rcx
    jge .revoke_not_found
    
    ; Check for token match
    mov rax, rbx
    imul rax, 16
    lea rax, [session_table + rax]
    mov r8, [rax]         ; stored token
    
    cmp r8, rdi
    jne .revoke_continue
    
    ; Match found - mark as invalid
    lea rax, [session_valid_flags + rbx]
    mov byte [rax], 0     ; mark invalid
    
    mov rax, 1            ; return success  
    jmp .revoke_done
    
.revoke_continue:
    inc rbx
    jmp .revoke_search_loop
    
.revoke_not_found:
    xor rax, rax          ; not found, no action

.revoke_done:
    pop rcx
    pop rbx
    pop rbp
    ret

; Extract session from Authorization / Cookie header in request
; rdi: request buffer
; rsi: end of headers section (parsed earlier)
; returns: rax = token if found in request, 0 otherwise
parse_auth_from_request:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rax, rdi          ; request start
    mov rbx, rsi          ; header end
    ; For now, just do a simple search for "session_id="
    ; In practice, would properly parse multiple headers
    
.find_cookie_header:
    ; Look for "Cookie:" or "Authorization:"
    ; Simplified - searching for Cookie specifically
    jmp .find_session_cookie

.find_session_cookie:
    ; Scan until end of headers section for Cookie header
    cmp rax, rbx          ; haven't reached body yet?
    jge .no_cookie_found
    
    ; Look for Cookie: pattern
    cmp dword [rax], 'Cook'  ; "Cook"
    jne .cookie_skip_byte
    
    ; Check complete header
    cmp qword [rax], 'Cookie: '  ; "Cookie: "
    jne .cookie_skip_byte
    
    ; Found Cookie header, now look for session_id=
    add rax, 8            ; skip "Cookie: "
    ; Scan for 'session_id=' in cookie string
    call find_session_in_cookie
    
    ; rax contains either pointer to token or 0
    jmp .auth_parse_done
    
.cookie_skip_byte:
    inc rax
    jmp .find_session_cookie

.no_cookie_found:
    xor rax, rax          ; return 0

.auth_parse_done:
    pop rcx
    pop rbx
    pop rbp
    ret

; Helper to find session_id in cookie string pointed to by rax
; returns: rax pointer to start of token or null if not found
find_session_in_cookie:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rbx, rax
    
.find_session_key: 
    cmp dword [rbx], '_ids'  ; "ssid" backwards to make "session_id"
    jne .session_key_skip
    cmp dword [rbx+2], 'se'  
    jne .session_key_skip
    cmp qword [rbx+4], '_no'  ; "_nosid" backwards to "session_id"
    jne .session_key_skip
    cmp byte [rbx+6], 'm'     ; final "m" to spell "session"
    jne .session_key_skip     
    
    ; Let me fix this - search for "session_id" directly
    call search_actual_sid_text
    jmp .session_cookie_done

; New approach: properly search for "session_id="
search_actual_sid_text:
    push rax               ; save outer rax
    mov rax, rbx
    mov r8, sid_search_text
    
.sid_search_loop:
    mov r9, 0            ; character index in search term
_sid_char_check:
    cmp byte [r8 + r9], 0 ; reached end of search term?
    je .sid_found
    cmp byte [rax + r9], [r8 + r9]
    jne .sid_search_advance
    inc r9
    jmp _sid_char_check
    
.sid_search_advance:
    inc rax
    jmp .sid_search_loop
    
.sid_found:
    ; Token starts after "=" sign
    add rax, 11           ; "session_id=" length is 11
    mov rbx, rax          ; save this position
    pop rax               ; restore original rax
    
    mov rax, rbx          ; return pointer to token
    jmp .actual_search_done

.actual_search_done:
    mov rax, 0             ; dummy return 
    jmp .session_cookie_exit

.sid_found_directly:
    ; Token starts after "session_id="
    add rbx, 11        ; "session_id=" is 11 chars  
    mov rax, rbx       ; return pointer to token data
    jmp .session_cookie_done
      
.session_key_skip:
    inc rbx
    jmp .find_session_key

.session_cookie_done:
    mov rax, 0          ; return 0 for now, will replace with proper code
    pop rcx
.session_cookie_exit:
    pop rbx
    pop rbp
    ret

section .data
    sid_search_text db 'session_id=', 0
</section>

; Generate a random 64-bit value (very simplified version)
; A real implementation would use proper entropy sources
random64bit:
    push rbp
    mov rbp, rsp
    
    ; Using a basic LCG since we can't call time() in pure assembly
    ; This is NOT cryptographically secure but serves as placeholder
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov rdx, 25214903917
    mul rdx
    add rax, 11
    mov rbx, rax
    
    ; Combine with cycle count to add more entropy
    rdtscp
    shl rdx, 32
    or rdx, eax
    xor rbx, rdx
    
    mov rax, rbx
    
    pop rbp

; Data management module for users and todos
; Maintains in-memory user and todo arrays

SECTION .bss
    user_data resq 1000          ; Space for 1000 users (id + username + password storage)  
    todo_data resq 10000         ; Space for 10000 todo items
    
    current_users resq 1         ; Count of registered users
    current_todos resq 1         ; Count of created todos
    next_user_id resq 1          ; Next user ID to assign
    next_todo_id resq 1          ; Next todo ID to assign

SECTION .text
global init_datastore
global datastore_add_user
global datastore_find_user_by_username
global datastore_add_todo  
global datastore_find_todo_by_id
global datastore_remove_todo

extern strcmp
extern strlen

init_datastore:
    push rbp
    mov rbp, rsp
    
    ; Initialize counters
    mov qword [current_users], 0
    mov qword [current_todos], 0  
    mov qword [next_user_id], 1
    mov qword [next_todo_id], 1
    
    xor rax, rax
    mov rsp, rbp
    pop rbp
    ret

; Add new user with given username and password hash
; rdi: pointer to username string
; rsi: pointer to password (will compute & store hash)
; returns: rax = user ID, or 0 on failure
datastore_add_user:
    push rbp
    mov rbp, rsp 
    push rbx
    push rcx
    push r10
    push r11
    
    ; Check if we've reached user limit
    mov rax, [current_users]
    cmp rax, 999           ; leave one slot for safety
    jge .user_add_failure
    
    ; See if username already exists
    mov r8, [current_users]
    test r8, r8
    jz .username_check_passed  ; No existing users, safe to add
    
    ; Loop through existing users to check for duplicates
    mov r9, 0
.username_dup_loop:
    cmp r9, r8
    jge .username_check_passed
    
    ; Get address of this user record
    mov r10, r9
    imul r10, 40         ; assume 40 bytes per user (id + 32-char username + 8-char password hash)
    lea r11, [user_data + r10 + 8]  ; offset past ID to get username area
    
    ; Compare r11 to rdi for username
    mov rdx, rdi
    call strcmp
    test rax, rax
    jz .user_add_duplicate  ; username exists!
    
    inc r9
    jmp .username_dup_loop
    
.username_check_passed:
    ; Get next user ID
    mov rax, [next_user_id]
    mov rbx, rax           ; save user ID for return
    mov [next_user_id], rax    ; increment it
    inc rax
    mov [next_user_id], rax
    
    ; Find available slot (use current_users as index)
    mov r8, [current_users]
    imul r8, 40            ; offset for user array element
    lea r9, [user_data + r8]
    
    ; Store user data:
    ; 0-7 bytes: user ID
    ; 8-39 bytes: username string + password
    mov [r9], rbx          ; store user ID
    lea r10, [r9 + 8]      ; username location
    call copy_string       ; rdi=username, rsi=r10 dest
    
    ; Simple password hash placeholder (just copy for now)
    lea r11, [r9 + 40]     ; password location after username
    mov rdi, rsi           ; rsi had password parameter
    call copy_string_to_r11
    
    ; Increment user count
    mov rax, [current_users]
    inc rax
    mov [current_users], rax
    
    ; Return the user ID that was assigned  
    mov rax, rbx
    jmp .user_add_done

.user_add_duplicate:
    mov rax, 0            ; return 0 for duplication error
    jmp .user_add_done
    
.user_add_failure:
    xor rax, rax          ; return 0 for failures

.user_add_done:
    pop r11
    pop r10  
    pop rcx
    pop rbx
    pop rbp
    ret

; Find user by username string
; rdi: pointer to username to search
; returns: rax = user_id if found, 0 if not found
datastore_find_user_by_username:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rbx, [current_users]
    test rbx, rbx
    jz .no_users_found_return
    
    ; Loop through current users
    xor rcx, rcx           ; index counter
    
.search_user_loop:
    cmp rcx, rbx
    jge .no_users_found_return
    
    ; Calculate address of username in this user record
    imul rax, rcx, 40      ; offset per user record
    lea rax, [user_data + rax + 8]  ; start of username area
    
    ; Compare this username with requested username  
    push rcx               ; preserve loop counter
    mov rsi, rax
    call strcmp
    pop rcx                ; restore counter
      
    test rax, rax
    jz .user_found
    
    inc rcx
    jmp .search_user_loop

.user_found:
    ; Calculate and return the UID of matching user
    imul rax, rcx, 40      ; offset per record
    lea rax, [user_data + rax]   ; start of record
    mov rax, [rax]         ; retrieve the ID (first 8 bytes)
    
    jmp .find_user_done
    
.no_users_found_return:
    xor rax, rax           ; return 0 = not found

.find_user_done:
    pop rcx
    pop rbx
    pop rbp
    ret

; Add new todo item  
; rdi: user ID creating the todo
; rsi: pointer to title string
; rdx: pointer to description string
; r10: completion flag (0 or 1)
; returns: rax = new todo ID, 0 on failure
datastore_add_todo:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push r8
    push r9
    push r11
    
    ; Check todo limit
    mov rax, [current_todos]
    cmp rax, 9999          ; max todos
    jge .todo_add_failure
    
    ; Get new todo ID
    mov r8, [next_todo_id]
    mov rax, r8
    inc r8
    mov [next_todo_id], r8    ; update next ID
    
    ; Calc position in todo array
    mov r9, [current_todos]
    imul r9, 200           ; 200 bytes per todo entry estimate
    lea rbx, [todo_data + r9]  ; destination for our record
    
    ; Store fields:
    ; 0-7 bytes: todo ID
    ; 8-15 bytes: user ID (owner)
    ; 16-79 bytes: title
    ; 80-191 bytes: description
    ; 192-195 bytes: completed flag
    ; 196-199 bytes: timestamps (creation/modification)
    mov [rbx], rax         ; todo ID
    mov [rbx+8], rdi       ; user ID who owns it
    mov [rbx+192], r10d    ; completed flag
    
    ; Simple timestamp - just use current value for now
    mov [rbx+196], qword '2023-11'    ; placeholder
    
    ; Copy title
    lea r11, [rbx+16]      ; location for title
    mov rdi, rsi           ; source
    mov rsi, r11           ; dest  
    call copy_string
    
    ; Copy description
    lea r11, [rbx+80]      ; location for desc  
    mov rdi, rdx           ; source desc
    mov rsi, r11           ; dest
    call copy_string
    
    ; Bump current todo count
    mov rax, [current_todos]
    inc rax
    mov [current_todos], rax
    
    mov rax, r8           ; return newly assigned ID
    jmp .todo_add_done
    
.todo_add_failure:
    xor rax, rax          ; return 0 for failure

.todo_add_done:
    pop r11
    pop r9
    pop r8
    pop rcx
    pop rbx
    pop rbp
    ret

; Find todo by its ID
; rdi: todo ID to find
; returns: rax = user ID that owns the todo, 0 if not found
datastore_find_todo_by_id:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rbx, [current_todos]
    test rbx, rbx
    jz .todo_not_found
    
    xor rcx, rcx          ; index
    
.iterate_todos:
    cmp rcx, rbx
    jge .todo_not_found
    
    ; Get offset to record
    imul rax, rcx, 200    ; bytes per record
    lea rax, [todo_data + rax] ; base address of record
    
    ; See if first 8 bytes match desired ID
    cmp [rax], rdi        ; compare stored ID with requested
    jz .todo_found
    inc rcx
    jmp .iterate_todos
    
.todo_found:
    ; Get user ID of owner (bytes 8-15)  
    mov rax, [rax+8]
    jmp .get_todo_done
    
.todo_not_found:
    xor rax, rax          ; return 0 for not found

.get_todo_done:
    pop rcx
    pop rbx
    pop rbp
    ret

; Remove a todo by ID  
; rdi: todo ID to remove
; returns: rax = 1 if removed, 0 if not found
datastore_remove_todo:
    push rbp
    mov rbp, rsp  
    push rbx
    push rcx
    
    ; This simple implementation just marks as deleted instead of moving others up
    ; More efficient than shifting all elements after deleted
    mov rbx, [current_todos]
    test rbx, rbx
    jz .remove_not_found
    
    xor rcx, rcx          ; index
    
.scan_todos_rem:
    cmp rcx, rbx
    jge .remove_not_found
    
    imul rax, rcx, 200    ; offset
    lea rax, [todo_data + rax] ; record address
    
    cmp [rax], rdi        ; match ID?
    jz .remove_mark_tombstone
    
    inc rcx
    jmp .scan_todos_rem
    
.remove_mark_tombstone:
    ; Instead of removing, mark this entry as deleted by making ID negative
    mov rax, [rax]        ; get position again
    imul rax, rcx, 200
    lea rbx, [todo_data + rax]
    
    mov rax, [rbx]        ; get actual ID
    neg rax
    mov [rbx], rax        ; mark as deleted
    
    mov rax, 1            ; return success
    jmp .remove_done

.remove_not_found:
    xor rax, rax          ; return 0 for not found

.remove_done:
    pop rcx
    pop rbx
    pop rbp
    ret

; Helper to copy null-terminated string from rdi to rsi
copy_string:
    push rbp
    mov rbp, rsp
    push rbx
    mov rbx, 0            ; offset counter

.copy_loop_str:
    mov cl, [rdi + rbx]
    mov [rsi + rbx], cl   ; copy byte
    test cl, cl           ; end reached?
    jz .copy_string_done
    inc rbx
    jmp .copy_loop_str
    
.copy_string_done:
    mov rax, rbx
    pop rbx
    pop rbp
    ret
    
copy_string_to_r11:
    push rbp
    mov rbp, rsp
    push rbx
    mov rbx, 0

.copy_to_r11_loop:
    mov cl, [rdi + rbx]
    mov [r11 + rbx], cl
    test cl, cl
    jz .copy_to_r11_done
    inc rbx
    jmp .copy_to_r11_loop

.copy_to_r11_done:
    pop rbx
    pop rbp
    ret

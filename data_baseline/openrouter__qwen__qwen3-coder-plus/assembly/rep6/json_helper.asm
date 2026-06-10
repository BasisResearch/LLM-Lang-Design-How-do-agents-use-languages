; JSON parsing and generation helpers

SECTION .bss
    json_temp_buffer resb 2048
    parse_state resd 1      ; track parser state

SECTION .text
global build_json_response
global parse_simple_json
global extract_json_value

extern strlen 
extern strcmp

; Build a basic JSON key-value pair or object structure
; rdi: destination buffer pointer
; rsi: format string or control code
; rdx: additional parameters (varies based on format)
build_json_response:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    push r8
    
    mov rbx, rdi          ; dest buf
    
.init_object:
    mov byte [rbx], '{'   ; start object
    inc rbx
    
.append_field:
    ; For now, implement a minimal version for common formats
    ; Simple approach: copy the format or predefined structures
    
    ; Format codes:
    ; 1: { "id": value }
    ; 2: { "id": value, "username": "string" }  
    ; 3: { "error": "message" }
    ; 4: [ ... ] array response
    
    cmp rsi, 1
    je .format_id_only
    cmp rsi, 2
    je .format_id_and_username
    cmp rsi, 3
    je .format_error_message
    cmp rsi, 4
    je .format_empty_object   ; default to empty for unknown
    
.format_id_only:
    mov rax, '"id":'
    call append_to_buffer
    mov rax, rdx           ; user id in rdx
    call append_number_to_buffer
    mov byte [rbx], '}'
    inc rbx
    jmp .done_building
    
.format_id_and_username:
    mov rax, '"id":'
    call append_to_buffer
    mov rax, rdx           ; user id as number
    call append_number_to_buffer
    mov rax, ',"username":"'
    call append_to_buffer
    ; Username comes in r10
    mov rax, r10
    call append_string_to_buffer
    mov rax, '"}'
    call append_to_buffer
    jmp .done_building
    
.format_error_message:
    mov rax, '{"error":"'
    call append_to_buffer
    ; Message comes in r10
    mov rax, r10
    call append_string_to_buffer
    mov rax, '"}'
    call append_to_buffer
    jmp .done_building
    
.format_array_start:
    mov byte [rbx], '['
    inc rbx
    mov rax, rdx           ; first member details perhaps
    jmp .done_building
    
.format_empty_object:
    mov rax, '{}'
    call append_to_buffer

.done_building:
    mov rax, rbx
    pop r8
    pop rcx
    pop rbx
    pop rbp
    ret

append_to_buffer:
    push rbp
    push rbx
    mov rbp, rsp
    mov rbx, rax
    
.length_calc:
    cmp byte [rbx], 0
    je .len_calc_done
    inc rbx
    jmp .length_calc
.len_calc_done:
    sub rbx, rax
    mov rcx, 0
    
.copy_to_dest:
    cmp rcx, rbx
    jge .appended
    mov dl, [rax + rcx]
    mov [rdi], dl
    inc rdi
    inc rcx  
    jmp .copy_to_dest
.appended:
    mov rax, rdi          ; new end position
    mov rdi, rax          ; update global dest
    pop rbx
    pop rbp
    ret

append_number_to_buffer:
    push rbp
    push rbx
    push rcx
    push rdx
    push r10
    mov rbp, rsp
    
    mov r10, rax          ; number to convert
    test r10, r10
    jnz .num_positive
    mov byte [rdi], '0'
    inc rdi
    jmp .number_appended
    
.num_positive:
    mov rbx, 10           ; divisor
    mov rcx, 0            ; digit counter
    mov rax, r10
    mov rdx, 0
    
.div_loop:
    test rax, rax
    jz .div_done
    mov rdx, 0
    div rbx
    push rdx              ; save remainder (digit)
    inc rcx               ; count digits  
    jmp .div_loop

.div_done:
    test rcx, rcx
    jz .number_appended
    
.output_loop:
    pop rdx
    add dl, '0'           ; convert to ASCII  
    mov [rdi], dl
    inc rdi
    loop .output_loop

.number_appended:
    mov rax, rdi          ; return new buffer position
    pop r10
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    ret

append_string_to_buffer:
    push rbp
    push rbx
    push rcx
    mov rbp, rsp
    
    mov rbx, rax          ; string source
    xor rcx, rcx
    
.string_copy_loop:
    mov dl, [rbx + rcx]
    test dl, dl
    jz .string_copy_done
    mov [rdi + rcx], dl
    inc rcx
    jmp .string_copy_loop
    
.string_copy_done:
    add rdi, rcx          ; advance destination
    mov rax, rdi          ; return new position    
    pop rcx
    pop rbx
    pop rbp
    ret

; Naive JSON parser - extracts value by looking for key
; rdi: JSON string to parse
; rsi: key to search for (without quotes)
; returns: pointer to start of value string or NULL if not found  
parse_simple_json:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    mov rax, rdi          ; source
    mov rbx, rsi          ; key to find
    
.parse_loop:
    cmp byte [rax], '"'
    jne .next_byte_search
    ; Check if this is our key
    mov rcx, 1            ; start past the quote
    call match_key
    test rax, rax
    jz .key_match_found
    mov rax, rbx          ; restore key
    add rax, rcx          ; increment past what we matched

.next_byte_search:
    inc rax
    jmp .parse_loop

.key_match_found:
    ; Key matched, now advance to after colon and whitespace
    add rax, 3            ; move past "key":
    jmp .find_val_start   ; continue to extract value

; Extract a value string for given key  
extract_json_value:
    push rbp
    mov rbp, rsp
    push rbx
    push rcx
    
    ; First parse to locate key, then extract value
    mov rax, rdi          ; json source
    mov rbx, rsi          ; key to find
    
.find_val_start:
    ; Look for unquoted colon
    cmp byte [rax], ':'
    jne .find_val_next
    inc rax               ; skip colon
    ; Skip whitespace
.skip_val_ws:
    cmp byte [rax], ' '
    jne .val_no_more_ws
    inc rax
    jmp .skip_val_ws
.val_no_more_ws:
    ; Now determine type of value
    ; String
    cmp byte [rax], '"'  
    je .extract_string_val
    ; Number
    mov cl, [rax]
    cmp cl, '0'
    jb .not_number_start
    cmp cl, '9' 
    ja .not_number_start
    jmp .extract_numeric_val
    
.extract_string_val:
    inc rax               ; go past opening quote
    mov r10, rax          ; save start
.extract_str_loop:
    cmp byte [rax], '"'
    je .extract_str_end
    inc rax
    jmp .extract_str_loop
    
.extract_str_end:
    ; r10 points to start, rax points to end (quote)
    ; Return pointer to start for now
    mov rax, r10
    jmp .done_extract_val
    
.extract_numeric_val:
    mov r10, rax          ; save position
    jmp .done_extract_val 
    
.not_number_start:
    mov rax, 0            ; return NULL if unknown
    jmp .done_extract_val

.find_val_next:
    inc rax
    jmp .find_val_start

.done_extract_val:
    pop rcx
    pop rbx
    pop rbp
    ret

; Helper to check if key starting at rax matches rbx 
match_key:
    push rbp
    mov rbp, rsp
    push rcx
    push rdx
    
    mov rcx, 0
    
.matcher_loop:
    mov dl, [rax + rcx]  
    cmp dl, [rbx + rcx] 
    jne .key_no_match
    ; Check if end
    test dl, dl
    jz .keys_equal
    cmp dl, '"'
    je .keys_equal        ; ends with quote in JSON
    inc rcx
    jmp .matcher_loop

.keys_equal:
    mov rax, 1            ; indicates match
    jmp .done_matcher

.key_no_match:
    xor rax, rax          ; indicates no match

.done_matcher:
    pop rdx
    pop rcx
    pop rbp
    ret

; This is a very basic and incomplete JSON implementation
; For production code, would implement more sophisticated parsing

# asmspeed - Linux x86-64 OS layer: raw syscalls, no libc.
# See common.S for the os_* contract.

.intel_syntax noprefix

.globl _start
.globl os_write, os_exit, os_isatty, os_time_ns, os_sleep_ms, os_resolve
.globl os_connect, os_close, os_send, os_recv, os_nonblock, os_poll

.equ SYS_read,        0
.equ SYS_write,       1
.equ SYS_open,        2
.equ SYS_close,       3
.equ SYS_poll,        7
.equ SYS_ioctl,       16
.equ SYS_socket,      41
.equ SYS_connect,     42
.equ SYS_sendto,      44
.equ SYS_recvfrom,    45
.equ SYS_setsockopt,  54
.equ SYS_fcntl,       72
.equ SYS_clock_gettime, 228
.equ SYS_exit_group,  231

.section .rodata
l_path: .asciz "/etc/resolv.conf"
l_ns:   .asciz "nameserver"

.bss
.balign 16
l_conf: .skip 4096

.text

_start:
    mov rax, [rsp]              # argc
    lea rdx, [rsp+8]            # argv
    mov [rip+g_argc], rax
    mov [rip+g_argv], rdx
    and rsp, -16
    call main_entry
    mov edi, eax
    jmp os_exit

os_exit:
    mov eax, SYS_exit_group
    syscall

os_write:                       # rdi = buf, rsi = len
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    mov eax, SYS_write
    syscall
    ret

os_isatty:                      # ioctl(1, TCGETS) succeeds only on a terminal
    sub rsp, 72
    mov edi, 1
    mov esi, 0x5401
    mov rdx, rsp
    mov eax, SYS_ioctl
    syscall
    test rax, rax
    sete al
    movzx eax, al
    add rsp, 72
    ret

os_time_ns:
    sub rsp, 16
    mov edi, 1                  # CLOCK_MONOTONIC
    mov rsi, rsp
    mov eax, SYS_clock_gettime
    syscall
    mov rax, [rsp]
    imul rax, rax, 1000000000
    add rax, [rsp+8]
    add rsp, 16
    ret

os_sleep_ms:                    # rdi = ms
    mov edx, edi
    xor edi, edi
    xor esi, esi
    mov eax, SYS_poll           # poll(NULL, 0, ms) is a sleep
    syscall
    ret

os_close:
    mov eax, SYS_close
    syscall
    ret

os_nonblock:                    # fcntl(fd, F_SETFL, O_NONBLOCK)
    mov esi, 4
    mov edx, 0x800
    mov eax, SYS_fcntl
    syscall
    ret

# negative errno -> -1 (try again) / -2 (hard error)
l_norm:
    test rax, rax
    jns 1f
    cmp rax, -11                # EAGAIN
    je 2f
    cmp rax, -4                 # EINTR
    je 2f
    mov rax, -2
    ret
2:  mov rax, -1
1:  ret

os_send:                        # rdi = sock, rsi = buf, rdx = len
    mov r10d, 0x4000            # MSG_NOSIGNAL
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_sendto
    syscall
    jmp l_norm

os_recv:
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_recvfrom
    syscall
    jmp l_norm

os_connect:                     # edi = ip (network order), esi = port (host order)
    push rbx
    sub rsp, 32                 # sockaddr_in at [rsp], timeval at [rsp+16]
    mov eax, esi
    rol ax, 8
    mov word ptr [rsp], 2       # AF_INET
    mov [rsp+2], ax
    mov [rsp+4], edi
    mov qword ptr [rsp+8], 0
    mov edi, 2                  # AF_INET
    mov esi, 1                  # SOCK_STREAM
    xor edx, edx
    mov eax, SYS_socket
    syscall
    test rax, rax
    js .oc_fail
    mov rbx, rax
    mov qword ptr [rsp+16], 5   # 5 second connect timeout
    mov qword ptr [rsp+24], 0
    mov rdi, rbx
    mov esi, 1                  # SOL_SOCKET
    mov edx, 21                 # SO_SNDTIMEO
    lea r10, [rsp+16]
    mov r8d, 16
    mov eax, SYS_setsockopt
    syscall
    mov rdi, rbx
    mov rsi, rsp
    mov edx, 16
    mov eax, SYS_connect
    syscall
    test rax, rax
    jnz .oc_closefail
    mov rax, rbx
    jmp .oc_ret
.oc_closefail:
    mov rdi, rbx
    mov eax, SYS_close
    syscall
.oc_fail:
    mov rax, -1
.oc_ret:
    add rsp, 32
    pop rbx
    ret

os_poll:                        # rdi = socks, rsi = n, rdx = flags_out, rcx = events, r8 = timeout_ms
    sub rsp, 72                 # up to 8 struct pollfd
    mov r9, rdx
    mov edx, 1                  # POLLIN
    test ecx, ecx
    jz 1f
    mov edx, 4                  # POLLOUT
1:  xor eax, eax
2:  cmp rax, rsi
    jae 3f
    mov r10, [rdi+rax*8]
    mov [rsp+rax*8], r10d       # fd (-1 entries are ignored by the kernel)
    mov [rsp+rax*8+4], dx       # events
    mov word ptr [rsp+rax*8+6], 0
    inc rax
    jmp 2b
3:  mov rdi, rsp
    mov edx, r8d
    mov eax, SYS_poll
    syscall
    mov r10, rax
    xor ecx, ecx
4:  cmp rcx, rsi
    jae 5f
    xor eax, eax
    cmp word ptr [rsp+rcx*8+6], 0
    setne al
    mov [r9+rcx], al
    inc rcx
    jmp 4b
5:  mov rax, r10
    add rsp, 72
    ret

# ---------------------------------------------------------------------------
# DNS: tiny stub resolver (A record over UDP). Uses the first IPv4 nameserver
# in /etc/resolv.conf, then falls back to 1.1.1.1 and 8.8.8.8.
# ---------------------------------------------------------------------------

os_resolve:                     # rdi = hostname -> eax = ip or 0
    push rbx
    push r12
    mov r12, rdi
    call l_find_ns
    test eax, eax
    jz 1f
    mov edi, eax
    mov rsi, r12
    call l_dns_query
    test eax, eax
    jnz 9f
1:  mov edi, 0x01010101
    mov rsi, r12
    call l_dns_query
    test eax, eax
    jnz 9f
    mov edi, 0x08080808
    mov rsi, r12
    call l_dns_query
9:  pop r12
    pop rbx
    ret

l_prefix:                       # rdi = text, rsi = prefix -> eax = 1 if match (rdi advanced)
1:  mov al, [rsi]
    test al, al
    jz 2f
    cmp al, [rdi]
    jne 3f
    inc rsi
    inc rdi
    jmp 1b
2:  mov eax, 1
    ret
3:  xor eax, eax
    ret

l_parse_ip:                     # rdi = "a.b.c.d" -> eax = ip (network order) or 0
    xor eax, eax
    xor ecx, ecx                # shift
.pi_oct:
    xor edx, edx
    xor r8d, r8d
.pi_dig:
    movzx esi, byte ptr [rdi]
    sub esi, 48
    cmp esi, 9
    ja .pi_end
    imul edx, edx, 10
    add edx, esi
    cmp edx, 255
    ja .pi_bad
    inc r8d
    inc rdi
    jmp .pi_dig
.pi_end:
    test r8d, r8d
    jz .pi_bad
    shl edx, cl
    or eax, edx
    cmp ecx, 24
    je .pi_ret
    cmp byte ptr [rdi], 46
    jne .pi_bad
    inc rdi
    add ecx, 8
    jmp .pi_oct
.pi_bad:
    xor eax, eax
.pi_ret:
    ret

l_find_ns:                      # -> eax = nameserver ip or 0
    push rbx
    push r12
    lea rdi, [rip+l_path]
    xor esi, esi
    xor edx, edx
    mov eax, SYS_open
    syscall
    test rax, rax
    js .fn_none
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip+l_conf]
    mov edx, 4095
    mov eax, SYS_read
    syscall
    mov r12, rax
    mov rdi, rbx
    mov eax, SYS_close
    syscall
    test r12, r12
    jle .fn_none
    lea rbx, [rip+l_conf]
    mov byte ptr [rbx+r12], 0
.fn_line:
    mov rdi, rbx
    lea rsi, [rip+l_ns]
    call l_prefix
    test eax, eax
    jz .fn_next
.fn_skip:
    mov al, [rdi]
    cmp al, 32
    je .fn_sp
    cmp al, 9
    jne .fn_ip
.fn_sp:
    inc rdi
    jmp .fn_skip
.fn_ip:
    call l_parse_ip
    test eax, eax
    jnz .fn_ret
.fn_next:
    mov al, [rbx]
    test al, al
    jz .fn_none
    inc rbx
    cmp al, 10
    jne .fn_next
    jmp .fn_line
.fn_none:
    xor eax, eax
.fn_ret:
    pop r12
    pop rbx
    ret

l_skip_name:                    # rsi = msg, r14 = pos, r12 = len -> r14 advanced, eax = 0 ok / -1 bad
.sn_loop:
    cmp r14, r12
    jae .sn_bad
    movzx eax, byte ptr [rsi+r14]
    test eax, eax
    jz .sn_zero
    mov ecx, eax
    and ecx, 0xC0
    cmp ecx, 0xC0
    je .sn_ptr
    lea r14, [r14+rax+1]
    jmp .sn_loop
.sn_ptr:
    add r14, 2
    xor eax, eax
    ret
.sn_zero:
    inc r14
    xor eax, eax
    ret
.sn_bad:
    mov eax, -1
    ret

l_dns_query:                    # edi = nameserver ip, rsi = hostname -> eax = ip or 0
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 1072               # query [0..511], reply [512..1023], sockaddr [1024], pollfd [1040]
    mov r13d, edi
    mov r14, rsi
    # header: id, RD flag, QDCOUNT = 1
    mov word ptr [rsp], 0x4141
    mov byte ptr [rsp+2], 1
    mov byte ptr [rsp+3], 0
    mov word ptr [rsp+4], 0x0100
    mov dword ptr [rsp+6], 0
    mov word ptr [rsp+10], 0
    # question name as length-prefixed labels
    lea rdi, [rsp+12]
    mov rsi, r14
.q_label:
    mov rbx, rdi
    inc rdi
    xor ecx, ecx
.q_ch:
    mov al, [rsi]
    test al, al
    jz .q_end
    cmp al, 46
    je .q_dot
    mov [rdi], al
    inc rdi
    inc rsi
    inc ecx
    jmp .q_ch
.q_dot:
    mov [rbx], cl
    inc rsi
    jmp .q_label
.q_end:
    mov [rbx], cl
    mov byte ptr [rdi], 0
    inc rdi
    mov word ptr [rdi], 0x0100      # QTYPE  A
    mov word ptr [rdi+2], 0x0100    # QCLASS IN
    add rdi, 4
    mov r12, rdi
    sub r12, rsp                    # query length
    # UDP socket
    mov edi, 2
    mov esi, 2
    xor edx, edx
    mov eax, SYS_socket
    syscall
    test rax, rax
    js .q_fail
    mov rbx, rax
    mov word ptr [rsp+1024], 2
    mov word ptr [rsp+1026], 0x3500 # port 53
    mov [rsp+1028], r13d
    mov qword ptr [rsp+1032], 0
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, r12
    xor r10d, r10d
    lea r8, [rsp+1024]
    mov r9d, 16
    mov eax, SYS_sendto
    syscall
    test rax, rax
    js .q_closefail
    mov [rsp+1040], ebx
    mov dword ptr [rsp+1044], 1     # events = POLLIN, revents = 0
    lea rdi, [rsp+1040]
    mov esi, 1
    mov edx, 3000
    mov eax, SYS_poll
    syscall
    test rax, rax
    jle .q_closefail
    mov rdi, rbx
    lea rsi, [rsp+512]
    mov edx, 512
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_recvfrom
    syscall
    mov r12, rax                    # reply length
    mov rdi, rbx
    mov eax, SYS_close
    syscall
    cmp r12, 12
    jl .q_fail
    lea rsi, [rsp+512]
    movzx eax, byte ptr [rsi+3]
    and eax, 0xF                    # RCODE must be 0
    jnz .q_fail
    movzx r13d, word ptr [rsi+6]
    rol r13w, 8                     # ANCOUNT
    movzx r13d, r13w
    mov r14d, 12
    call l_skip_name                # question name
    test eax, eax
    js .q_fail
    add r14, 4                      # QTYPE + QCLASS
.q_ans:
    test r13d, r13d
    jz .q_fail
    dec r13d
    call l_skip_name
    test eax, eax
    js .q_fail
    lea rax, [r14+10]
    cmp rax, r12
    ja .q_fail
    movzx eax, word ptr [rsi+r14]
    rol ax, 8                       # TYPE
    movzx ecx, word ptr [rsi+r14+8]
    rol cx, 8                       # RDLENGTH
    add r14, 10
    cmp ax, 1
    jne .q_nexta
    cmp cx, 4
    jne .q_nexta
    lea rdx, [r14+4]
    cmp rdx, r12
    ja .q_fail
    mov eax, [rsi+r14]
    jmp .q_ret
.q_nexta:
    movzx ecx, cx
    add r14, rcx
    jmp .q_ans
.q_closefail:
    mov rdi, rbx
    mov eax, SYS_close
    syscall
.q_fail:
    xor eax, eax
.q_ret:
    add rsp, 1072
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.section .note.GNU-stack,"",@progbits

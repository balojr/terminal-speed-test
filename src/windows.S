# asmspeed - Windows x86-64 OS layer (kernel32 + ws2_32).
# See common.S for the os_* contract. Imports are resolved through
# __imp_<name> symbols that tools/mkpe.py places at the IAT slots.

.intel_syntax noprefix

.globl _start
.globl os_write, os_exit, os_isatty, os_time_ns, os_sleep_ms, os_resolve
.globl os_connect, os_close, os_send, os_recv, os_nonblock, os_poll

# Call a Windows API function from any stack alignment. Windows wants rsp
# 16-byte aligned at the call plus 32 bytes of shadow space; the 5th argument
# slot at [rsp+32] is zeroed because WriteFile's lpOverlapped must be NULL.
.macro WCALL name
    push rbp
    mov rbp, rsp
    sub rsp, 64
    and rsp, -16
    mov qword ptr [rsp+32], 0
    call [rip+__imp_\name]
    mov rsp, rbp
    pop rbp
.endm

.section .rodata
.balign 4
w_one:  .long 1

.bss
.balign 16
w_wsadata: .skip 512
w_cmd:     .skip 4096
w_argv:    .skip 16 * 8
w_stdout:  .skip 8
w_written: .skip 8
w_qpc:     .skip 8
w_freq:    .skip 8
w_mode:    .skip 8
w_pfd:     .skip 8 * 16

.text

_start:
    and rsp, -16
    sub rsp, 32
    mov ecx, 0x0202
    lea rdx, [rip+w_wsadata]
    WCALL WSAStartup
    lea rcx, [rip+w_freq]
    WCALL QueryPerformanceFrequency
    # copy the command line and split it into argv[]
    WCALL GetCommandLineA
    mov rsi, rax
    lea rdi, [rip+w_cmd]
    xor ecx, ecx
1:  mov al, [rsi+rcx]
    mov [rdi+rcx], al
    test al, al
    jz 2f
    inc ecx
    cmp ecx, 4090
    jb 1b
    mov byte ptr [rdi+rcx], 0
2:  lea rsi, [rip+w_cmd]
    lea rdi, [rip+w_argv]
    xor ecx, ecx                # argc
.tk_skip:
    mov al, [rsi]
    test al, al
    jz .tk_done
    cmp al, 32
    je .tk_sp
    cmp al, 9
    je .tk_sp
    cmp ecx, 15
    jae .tk_done
    cmp al, 34                  # opening quote
    jne .tk_plain
    inc rsi
    mov [rdi+rcx*8], rsi
    inc ecx
.tk_q:
    mov al, [rsi]
    test al, al
    jz .tk_done
    cmp al, 34
    je .tk_endq
    inc rsi
    jmp .tk_q
.tk_endq:
    mov byte ptr [rsi], 0
    inc rsi
    jmp .tk_skip
.tk_plain:
    mov [rdi+rcx*8], rsi
    inc ecx
.tk_p:
    mov al, [rsi]
    test al, al
    jz .tk_done
    cmp al, 32
    je .tk_endp
    cmp al, 9
    je .tk_endp
    inc rsi
    jmp .tk_p
.tk_endp:
    mov byte ptr [rsi], 0
    inc rsi
    jmp .tk_skip
.tk_sp:
    inc rsi
    jmp .tk_skip
.tk_done:
    mov eax, ecx
    mov [rip+g_argc], rax
    lea rax, [rip+w_argv]
    mov [rip+g_argv], rax
    call main_entry
    mov edi, eax
    # fall through

os_exit:
    mov ecx, edi
    WCALL ExitProcess

os_write:                       # rdi = buf, rsi = len
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rcx, [rip+w_stdout]
    test rcx, rcx
    jnz 1f
    mov ecx, -11                # STD_OUTPUT_HANDLE
    WCALL GetStdHandle
    mov [rip+w_stdout], rax
1:  mov rcx, [rip+w_stdout]
    mov rdx, rbx
    mov r8, r12
    lea r9, [rip+w_written]
    WCALL WriteFile
    pop r12
    pop rbx
    ret

# stdout is a console that accepts ANSI escapes and UTF-8 -> 1, otherwise 0
os_isatty:
    push rbx
    mov rcx, [rip+w_stdout]
    test rcx, rcx
    jnz 1f
    mov ecx, -11
    WCALL GetStdHandle
    mov [rip+w_stdout], rax
1:  mov rcx, [rip+w_stdout]
    lea rdx, [rip+w_mode]
    WCALL GetConsoleMode
    test eax, eax
    jz 2f                       # redirected to a file or pipe
    mov edx, [rip+w_mode]
    or edx, 4                   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
    mov rcx, [rip+w_stdout]
    WCALL SetConsoleMode
    test eax, eax
    jz 2f                       # legacy console without ANSI support
    mov ecx, 65001              # UTF-8 output
    WCALL SetConsoleOutputCP
    mov eax, 1
    pop rbx
    ret
2:  xor eax, eax
    pop rbx
    ret

os_time_ns:
    lea rcx, [rip+w_qpc]
    WCALL QueryPerformanceCounter
    mov rax, [rip+w_qpc]
    mov rcx, 1000000000
    mul rcx
    div qword ptr [rip+w_freq]
    ret

os_sleep_ms:                    # rdi = ms
    mov ecx, edi
    WCALL Sleep
    ret

os_resolve:                     # rdi = hostname -> eax = ip or 0
    mov rcx, rdi
    WCALL gethostbyname
    test rax, rax
    jz 1f
    mov rax, [rax+24]           # hostent.h_addr_list
    test rax, rax
    jz 1f
    mov rax, [rax]              # first address
    test rax, rax
    jz 1f
    mov eax, [rax]
    ret
1:  xor eax, eax
    ret

# eax = int result of send/recv -> bytes | -1 would block | -2 error
w_norm:
    movsxd rax, eax
    test rax, rax
    jns 1f
    WCALL WSAGetLastError
    cmp eax, 10035              # WSAEWOULDBLOCK
    je 2f
    cmp eax, 10004              # WSAEINTR
    je 2f
    mov rax, -2
    ret
2:  mov rax, -1
1:  ret

os_connect:                     # edi = ip (network order), esi = port (host order)
    push rbx
    push r12
    sub rsp, 32
    mov eax, esi
    rol ax, 8
    mov word ptr [rsp], 2       # AF_INET
    mov [rsp+2], ax
    mov [rsp+4], edi
    mov qword ptr [rsp+8], 0
    mov ecx, 2                  # AF_INET
    mov edx, 1                  # SOCK_STREAM
    mov r8d, 6                  # IPPROTO_TCP
    WCALL socket
    cmp rax, -1                 # INVALID_SOCKET
    je .wc_fail
    mov rbx, rax
    mov rcx, rbx
    mov rdx, rsp
    mov r8d, 16
    WCALL connect
    test eax, eax
    jnz .wc_closefail
    mov rax, rbx
    jmp .wc_ret
.wc_closefail:
    mov rcx, rbx
    WCALL closesocket
.wc_fail:
    mov rax, -1
.wc_ret:
    add rsp, 32
    pop r12
    pop rbx
    ret

os_close:
    mov rcx, rdi
    WCALL closesocket
    ret

os_send:                        # rdi = sock, rsi = buf, rdx = len
    mov r8d, edx
    mov rdx, rsi
    mov rcx, rdi
    xor r9d, r9d
    WCALL send
    jmp w_norm

os_recv:
    mov r8d, edx
    mov rdx, rsi
    mov rcx, rdi
    xor r9d, r9d
    WCALL recv
    jmp w_norm

os_nonblock:
    mov rcx, rdi
    mov edx, 0x8004667E         # FIONBIO
    lea r8, [rip+w_one]
    WCALL ioctlsocket
    ret

os_poll:                        # rdi = socks, rsi = n, rdx = flags_out, rcx = events, r8 = timeout_ms
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rsi
    mov r12, rdx
    mov r13d, r8d
    mov eax, 0x100              # POLLRDNORM
    test ecx, ecx
    jz 1f
    mov eax, 0x10               # POLLWRNORM
1:  lea r14, [rip+w_pfd]
    xor ecx, ecx
2:  cmp rcx, rbx
    jae 3f
    mov rdx, [rdi+rcx*8]
    mov r8, rcx
    shl r8, 4
    mov [r14+r8], rdx           # WSAPOLLFD.fd (INVALID_SOCKET entries are skipped)
    mov [r14+r8+8], ax          # events
    mov word ptr [r14+r8+10], 0
    inc rcx
    jmp 2b
3:  mov rcx, r14
    mov edx, ebx
    mov r8d, r13d
    WCALL WSAPoll
    movsxd r13, eax
    xor ecx, ecx
4:  cmp rcx, rbx
    jae 5f
    mov r8, rcx
    shl r8, 4
    xor edx, edx
    cmp word ptr [r14+r8+10], 0
    setne dl
    mov [r12+rcx], dl
    inc rcx
    jmp 4b
5:  mov rax, r13
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

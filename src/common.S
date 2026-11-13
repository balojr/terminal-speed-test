# asmspeed - terminal internet speed test, x86-64 assembly (GNU as, Intel syntax)
#
# Platform independent core. The OS layer (linux.S / windows.S) provides:
#
#   os_write(buf, len)                 stdout
#   os_exit(code)
#   os_isatty() -> 1/0                 stdout is a terminal that understands ANSI/UTF-8
#   os_time_ns() -> ns                 monotonic clock
#   os_sleep_ms(ms)
#   os_resolve(hostname) -> ipv4       network byte order in eax, 0 on failure
#   os_connect(ip, port) -> sock       blocking TCP connect, -1 on failure
#   os_close(sock)
#   os_send(sock, buf, len)            -> bytes | -1 would block | -2 error
#   os_recv(sock, buf, len)            -> bytes | 0 EOF | -1 would block | -2 error
#   os_nonblock(sock)
#   os_poll(socks, n, flags_out, events, timeout_ms)
#                                      events 0 = readable, 1 = writable;
#                                      flags_out[i] = 1 when socks[i] is ready
#
# Arguments go in rdi, rsi, rdx, rcx, r8. rbx, rbp and r12-r15 are preserved.
# The OS layer also fills g_argc / g_argv before calling main_entry.
#
# Output goes through emit(): a string where control bytes 1-8, 11, 12 select
# colours (dropped when colour is off) and byte 14 clears to end of line.

.intel_syntax noprefix

.globl main_entry, g_argc, g_argv

.equ WARM_NS,   2000000000      # ramp-up time that is not measured
.equ DRAW_NS,   100000000       # live line refresh interval
.equ SAMP_NS,   500000000       # throughput sample window (sparkline, peak)
.equ LATS_NS,   1000000000      # loaded-latency probe interval
.equ CHUNK,     131072          # bytes per send/recv
.equ LAT_N,     10              # idle latency samples
.equ BODY_LEN,  100000000       # bytes promised per upload connection
.equ MAX_CONNS, 8
.equ MAX_SAMP,  120             # 60 s of 500 ms samples
.equ SPARK_N,   24
.equ BAR_N,     20
.equ OBUF_SZ,   8192

# ----------------------------------------------------------------------------
.section .rodata

# ANSI colours, selected by control bytes inside emit() strings
c_bcyan:    .asciz "\033[1;36m"     # 1  title
c_dim:      .asciz "\033[2m"        # 2  labels
c_bold:     .asciz "\033[1m"        # 3  values
c_down:     .asciz "[38;5;208m"   # 4  download (orange)
c_up:       .asciz "[38;5;183m"   # 5  upload (lilac)
c_yel:      .asciz "\033[33m"       # 6  warning
c_rst:      .asciz "\033[0m"        # 7  reset
c_grn:      .asciz "\033[32m"       # 8  good
c_red:      .asciz "\033[31m"       # 11 bad
c_bgrn:     .asciz "\033[1;32m"     # 12
c_blue:     .asciz "\033[38;5;75m"    # latency
c_gray:     .asciz "\033[38;5;238m"   # chevrons not reached yet
s_eolseq:   .asciz "\033[K"         # 14 clear to end of line (terminals only)

.balign 8
color_tab:  .quad c_bcyan, c_dim, c_bold, c_down, c_up, c_yel, c_rst, c_grn, c_red, c_bgrn

s_hdr:      .asciz "\n  \001◆ asmspeed\007 \0021.1\007\n  \002──────────────────────────────────────────────────────────────\007\n\n"
t_conn:     .asciz "  \002Connection\007  \003"
t_server:   .asciz "  \002Server    \007  Cloudflare"
t_colo:     .asciz " \003"
t_dot:      .asciz "\007  \002·\007  "
t_as:       .asciz "AS"
t_comma:    .asciz ", "
t_lp:       .asciz " ("
t_rp:       .asciz ")"
t_lat:      .asciz "  \002Latency   \007  \003"
t_lat_j:    .asciz " ms\007   \002jitter\007 "
t_lat_min:  .asciz " ms   \002min\007 "
t_lat_max:  .asciz " ms   \002max\007 "
t_lat_end:  .asciz " ms\016\n\n"
l_down:     .asciz "  \004↓ Download\007  "
l_up:       .asciz "  \005↑ Upload\007    "
s_b:        .asciz "\003"
s_mbps_sp:  .asciz "\007 Mbps   "
s_eol_nl:   .asciz "\007\016\n"
s_peak:     .asciz "              \002peak\007 "
s_mid:      .asciz " Mbps   \002·\007   "
s_mb:       .asciz " MB"
s_load:     .asciz "   \002·\007   \002latency under load\007 "
s_ms:       .asciz " ms"
s_plus:     .asciz " \006(+"
s_plus_end: .asciz " ms)\007"
s_end2:     .asciz "\016\n\n"
s_warm:     .asciz "\002warming up…\007"
s_fail:     .asciz "\013failed (connection lost)\007\016\n\n"
s_cr:       .asciz "\r"
s_nl:       .asciz "\n"
s_dot:      .asciz "."
s_two:      .asciz "  "
s_dnsfail:  .asciz "  \013✗\007 DNS lookup of speed.cloudflare.com failed - are you online?\n\n"
s_latfail:  .asciz "  \013✗\007 cannot reach speed.cloudflare.com:80\016\n\n"
s_qhdr:     .asciz "  \002Network Quality Score\007 \002· estimated from your results\007\n"
q_overall:  .asciz "  \002Overall\007  "
s_box_top:  .asciz "  \002╭────────────────────────────────────────────────────────────╮\007\n"
s_box_bot:  .asciz "  \002╰────────────────────────────────────────────────────────────╯\007\n"
s_box_blank:.asciz "  \002│\007                                                            \002│\007\n"
s_box_l:    .asciz "  \002│\007"
s_box_r:    .asciz "\002│\007\n"
t_q0:       .asciz "Streaming"
t_q1:       .asciz "Gaming"
t_q2:       .asciz "Video Calls"
s_phases:   .asciz "Measuring Latency"
            .asciz "Measuring Download"
            .asciz "Measuring Upload"
s_sepdot:   .asciz " \002·\007 "
s_eolonly:  .asciz "\016"
s_packets:  .asciz " packets"
s_one:      .asciz " "
s_spaces:   .asciz "                                "
s_mbps_only:.asciz "\007 Mbps"
s_usage:    .ascii "Usage: asmspeed [options]\n\n"
            .ascii "  -t SECONDS    measure each direction for SECONDS (1-60, default 8)\n"
            .ascii "  -c N          parallel connections (1-8, default 4)\n"
            .ascii "  -n, --no-color  plain output (also automatic when not a terminal)\n"
            .asciz "  -h, --help    show this help\n"
s_host:     .asciz "speed.cloudflare.com"
a_h:        .asciz "-h"
a_help:     .asciz "--help"
a_t:        .asciz "-t"
a_c:        .asciz "-c"
a_n:        .asciz "-n"
a_nocolor:  .asciz "--no-color"

# 0..7 block elements for the sparkline, filled/empty bar cells, stars
s_blocks:   .ascii "▁▂▃▄▅▆▇█"
s_fullrow:  .ascii "████████████████████"
s_emptyrow: .ascii "░░░░░░░░░░░░░░░░░░░░"
s_chevrow:  .ascii "❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯❯"
s_dotrow:   .ascii "∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙∙"
s_spin:     .ascii "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
.balign 8
seg_len:    .quad 4, 13, 13
seg_col:    .quad c_blue, c_down, c_up
box_titles: .quad t_q0, t_q1, t_q2
box_words:  .quad w_stream, w_game, w_rating
s_star:     .ascii "★"
s_star0:    .ascii "☆"

w_stream:   .asciz "struggles"
            .asciz "SD only"
            .asciz "720p HD"
            .asciz "1080p HD"
            .asciz "4K / UHD"
w_rating:   .asciz "unreliable"
            .asciz "poor"
            .asciz "fair"
            .asciz "good"
            .asciz "excellent"
w_game:     .asciz "unplayable"
            .asciz "laggy"
            .asciz "playable"
            .asciz "good"
            .asciz "excellent"

# Cloudflare edge codes -> location
colo_tab:
    .asciz "MBA", "Mombasa, KE"
    .asciz "NBO", "Nairobi, KE"
    .asciz "DUR", "Durban, ZA"
    .asciz "JNB", "Johannesburg, ZA"
    .asciz "CPT", "Cape Town, ZA"
    .asciz "LOS", "Lagos, NG"
    .asciz "ABV", "Abuja, NG"
    .asciz "ACC", "Accra, GH"
    .asciz "CAI", "Cairo, EG"
    .asciz "DAR", "Dar es Salaam, TZ"
    .asciz "EBB", "Entebbe, UG"
    .asciz "KGL", "Kigali, RW"
    .asciz "ADD", "Addis Ababa, ET"
    .asciz "JIB", "Djibouti, DJ"
    .asciz "MPM", "Maputo, MZ"
    .asciz "LUN", "Lusaka, ZM"
    .asciz "HRE", "Harare, ZW"
    .asciz "TNR", "Antananarivo, MG"
    .asciz "MRU", "Port Louis, MU"
    .asciz "DXB", "Dubai, AE"
    .asciz "BOM", "Mumbai, IN"
    .asciz "DEL", "New Delhi, IN"
    .asciz "MAA", "Chennai, IN"
    .asciz "SIN", "Singapore, SG"
    .asciz "HKG", "Hong Kong, HK"
    .asciz "NRT", "Tokyo, JP"
    .asciz "KIX", "Osaka, JP"
    .asciz "ICN", "Seoul, KR"
    .asciz "SYD", "Sydney, AU"
    .asciz "MEL", "Melbourne, AU"
    .asciz "LHR", "London, GB"
    .asciz "MAN", "Manchester, GB"
    .asciz "FRA", "Frankfurt, DE"
    .asciz "AMS", "Amsterdam, NL"
    .asciz "CDG", "Paris, FR"
    .asciz "MRS", "Marseille, FR"
    .asciz "MAD", "Madrid, ES"
    .asciz "MXP", "Milan, IT"
    .asciz "ARN", "Stockholm, SE"
    .asciz "WAW", "Warsaw, PL"
    .asciz "JFK", "New York, US"
    .asciz "EWR", "Newark, US"
    .asciz "IAD", "Ashburn, US"
    .asciz "ATL", "Atlanta, US"
    .asciz "MIA", "Miami, US"
    .asciz "ORD", "Chicago, US"
    .asciz "DFW", "Dallas, US"
    .asciz "DEN", "Denver, US"
    .asciz "LAX", "Los Angeles, US"
    .asciz "SJC", "San Jose, US"
    .asciz "SEA", "Seattle, US"
    .asciz "YYZ", "Toronto, CA"
    .asciz "GRU", "Sao Paulo, BR"
    .byte 0

req_down:   .ascii "GET /__down?bytes=90000000 HTTP/1.1\r\nHost: speed.cloudflare.com\r\nUser-Agent: asmspeed/1.1\r\nAccept: */*\r\nConnection: close\r\n\r\n"
req_down_end:
req_up:     .ascii "POST /__up HTTP/1.1\r\nHost: speed.cloudflare.com\r\nUser-Agent: asmspeed/1.1\r\nContent-Type: application/octet-stream\r\nContent-Length: 100000000\r\nConnection: close\r\n\r\n"
req_up_end:
req_info:   .ascii "GET /__down?bytes=0 HTTP/1.1\r\nHost: speed.cloudflare.com\r\nUser-Agent: asmspeed/1.1\r\nConnection: close\r\n\r\n"
req_info_end:

h_ip:       .asciz "\ncf-meta-ip: "
h_asn:      .asciz "\nasn: "
h_city:     .asciz "\ncity: "
h_colo:     .asciz "\ncolo: "
h_cc:       .asciz "\ncountry: "
h_end:      .asciz "\r\n\r\n"

.equ REQ_DOWN_LEN, req_down_end - req_down
.equ REQ_UP_LEN,   req_up_end - req_up
.equ REQ_INFO_LEN, req_info_end - req_info

# ----------------------------------------------------------------------------
.bss
.balign 16

g_argc:      .skip 8
g_argv:      .skip 8
g_dur:       .skip 8
g_conns:     .skip 8
g_ip:        .skip 8
g_tty:       .skip 8
g_color:     .skip 8
g_nocolor:   .skip 8
g_olen:      .skip 8
g_total:     .skip 8            # bytes moved so far (all connections)
g_base:      .skip 8            # g_total when the measured window began
g_tmark:     .skip 8            # time the measured window began
g_measuring: .skip 8
g_reopen:    .skip 8
g_lastdraw:  .skip 8
g_t0:        .skip 8
g_sampt:     .skip 8
g_sampb:     .skip 8
g_nsamp_cur: .skip 8
g_peak:      .skip 8
g_lastlat:   .skip 8
g_lsum:      .skip 8
g_ln:        .skip 8
g_tmp:       .skip 8
g_infolen:   .skip 8
g_hasinfo:   .skip 8
g_lat_avg:   .skip 8            # hundredths of a millisecond
g_lat_min:   .skip 8
g_lat_max:   .skip 8
g_lat_jit:   .skip 8
g_q:         .skip 24
g_r_avg:     .skip 16           # per direction: Mbps * 100
g_r_peak:    .skip 16
g_r_bytes:   .skip 16
g_r_lat:     .skip 16           # loaded latency, hundredths of ms (0 = none)
g_nsamp:     .skip 16
g_samp:      .skip 2 * MAX_SAMP * 8
g_bins:      .skip SPARK_N * 8
g_sp:        .skip SPARK_N * 3 + 8
g_socks:     .skip MAX_CONNS * 8
g_rem:       .skip MAX_CONNS * 8   # upload bytes still promised per connection
g_flags:     .skip 16
g_num:       .skip 32
g_fmt:       .skip 32
g_i_ip:      .skip 48
g_i_asn:     .skip 16
g_i_city:    .skip 48
g_i_colo:    .skip 8
g_i_cc:      .skip 8
g_info:      .skip 4096
g_obuf:      .skip OBUF_SZ
g_rbuf:      .skip CHUNK
g_sbuf:      .skip CHUNK        # never written: upload payload is zeros

# ----------------------------------------------------------------------------
.text

# --- output ---------------------------------------------------------------

out_flush:
    mov rsi, [rip+g_olen]
    test rsi, rsi
    jz 1f
    lea rdi, [rip+g_obuf]
    mov qword ptr [rip+g_olen], 0
    jmp os_write
1:  ret

out_write:                      # rdi = buf, rsi = len (buffered)
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rip+g_olen]
    add rax, r12
    cmp rax, OBUF_SZ
    jbe 1f
    call out_flush
1:  lea rdi, [rip+g_obuf]
    add rdi, [rip+g_olen]
    mov rsi, rbx
    mov rcx, r12
    rep movsb
    add [rip+g_olen], r12
    pop r12
    pop rbx
    ret

print_str:                      # rdi = NUL terminated string, printed verbatim
    push rbx
    mov rbx, rdi
    xor ecx, ecx
1:  cmp byte ptr [rbx+rcx], 0
    je 2f
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    mov rsi, rcx
    call out_write
    pop rbx
    ret

cprint:                         # rdi = colour sequence, printed only when colour is on
    cmp qword ptr [rip+g_color], 0
    je 1f
    jmp print_str
1:  ret

emit_code:                      # eax = control byte
    cmp eax, 14
    je .ec_eol
    cmp qword ptr [rip+g_color], 0
    je .ec_ret
    cmp eax, 8
    jbe 1f
    cmp eax, 11
    jne 2f
    mov eax, 9
    jmp 1f
2:  cmp eax, 12
    jne .ec_ret
    mov eax, 10
1:  dec eax
    lea rdx, [rip+color_tab]
    mov rdi, [rdx+rax*8]
    jmp print_str
.ec_eol:
    cmp qword ptr [rip+g_tty], 0
    je .ec_ret
    lea rdi, [rip+s_eolseq]
    jmp print_str
.ec_ret:
    ret

emit:                           # rdi = string with colour control bytes
    push rbx
    push r12
    push r13
    mov rbx, rdi
.em_run:
    mov r12, rbx
.em_scan:
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz .em_end
    cmp eax, 32
    jae .em_adv
    cmp eax, 9
    je .em_adv
    cmp eax, 10
    je .em_adv
    cmp eax, 13
    je .em_adv
    mov r13d, eax
    mov rsi, rbx
    sub rsi, r12
    jz 1f
    mov rdi, r12
    call out_write
1:  inc rbx
    mov eax, r13d
    call emit_code
    jmp .em_run
.em_adv:
    inc rbx
    jmp .em_scan
.em_end:
    mov rsi, rbx
    sub rsi, r12
    jz 2f
    mov rdi, r12
    call out_write
2:  pop r13
    pop r12
    pop rbx
    ret

print_u64:                      # rdi = value
    mov rax, rdi
    lea r8, [rip+g_num+32]
    mov r9, r8
    mov ecx, 10
1:  xor edx, edx
    div rcx
    add dl, 48
    dec r8
    mov [r8], dl
    test rax, rax
    jnz 1b
    mov rdi, r8
    mov rsi, r9
    sub rsi, r8
    jmp out_write

print_hund_w:                   # rdi = hundredths -> "12.34", left-padded to width rsi
    mov r10, rsi
    lea r8, [rip+g_fmt+32]
    mov r9, r8
    mov rax, rdi
    xor edx, edx
    mov ecx, 100
    div rcx
    mov r11, rax
    mov rax, rdx
    xor edx, edx
    mov ecx, 10
    div rcx
    add dl, 48
    dec r8
    mov [r8], dl
    add al, 48
    dec r8
    mov [r8], al
    dec r8
    mov byte ptr [r8], 46
    mov rax, r11
    mov ecx, 10
1:  xor edx, edx
    div rcx
    add dl, 48
    dec r8
    mov [r8], dl
    test rax, rax
    jnz 1b
    mov rdx, r9
    sub rdx, r8
2:  cmp rdx, r10
    jae 3f
    dec r8
    mov byte ptr [r8], 32
    inc rdx
    jmp 2b
3:  mov rdi, r8
    mov rsi, rdx
    jmp out_write

print_hund:                     # rdi = hundredths
    xor esi, esi
    jmp print_hund_w

streq:                          # rdi, rsi -> eax = 1 if equal
1:  mov al, [rdi]
    cmp al, [rsi]
    jne 2f
    test al, al
    jz 3f
    inc rdi
    inc rsi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

parse_uint:                     # rdi = string -> rax = value, -1 if invalid
    xor eax, eax
    cmp byte ptr [rdi], 0
    je 9f
1:  movzx edx, byte ptr [rdi]
    test edx, edx
    jz 3f
    sub edx, 48
    cmp edx, 9
    ja 9f
    imul rax, rax, 10
    add rax, rdx
    cmp rax, 1000000
    ja 9f
    inc rdi
    jmp 1b
3:  ret
9:  mov rax, -1
    ret

calc_hund:                      # rdi = bytes, rsi = ns -> rax = Mbps * 100
    test rsi, rsi
    jz 1f
    mov rax, rdi
    mov rcx, 800000             # bits * 1000 (bits/ns -> Mbit/s) * 100
    mul rcx
    div rsi
    ret
1:  xor eax, eax
    ret

nth_str:                        # rdi = list of NUL strings, rsi = index -> rax = string
1:  test rsi, rsi
    jz 3f
2:  cmp byte ptr [rdi], 0
    je 4f
    inc rdi
    jmp 2b
4:  inc rdi
    dec rsi
    jmp 1b
3:  mov rax, rdi
    ret

ci_find:                        # rdi = haystack, rsi = len, rdx = needle -> rax = match or 0
    push rbx
    mov rbx, rsi
.cf_outer:
    test rbx, rbx
    jz .cf_none
    xor ecx, ecx
.cf_inner:
    movzx eax, byte ptr [rdx+rcx]
    test eax, eax
    jz .cf_found
    cmp rcx, rbx
    jae .cf_none
    movzx r8d, byte ptr [rdi+rcx]
    cmp r8d, 65
    jb 1f
    cmp r8d, 90
    ja 1f
    add r8d, 32
1:  cmp eax, 65
    jb 2f
    cmp eax, 90
    ja 2f
    add eax, 32
2:  cmp eax, r8d
    jne .cf_next
    inc rcx
    jmp .cf_inner
.cf_next:
    inc rdi
    dec rbx
    jmp .cf_outer
.cf_found:
    mov rax, rdi
    pop rbx
    ret
.cf_none:
    xor eax, eax
    pop rbx
    ret

get_hdr:                        # rdi = "\nname: " needle, rsi = dst, rdx = dst size
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip+g_info]
    mov rsi, [rip+g_infolen]
    mov rdx, rbx
    call ci_find
    test rax, rax
    jz .gh_ret
    xor ecx, ecx
1:  cmp byte ptr [rbx+rcx], 0
    je 2f
    inc rcx
    jmp 1b
2:  add rax, rcx                # first byte of the value
    xor ecx, ecx
    dec r13
.gh_cp:
    cmp rcx, r13
    jae .gh_end
    mov dl, [rax+rcx]
    cmp dl, 13
    je .gh_end
    cmp dl, 10
    je .gh_end
    test dl, dl
    jz .gh_end
    mov [r12+rcx], dl
    inc rcx
    jmp .gh_cp
.gh_end:
    mov byte ptr [r12+rcx], 0
.gh_ret:
    pop r13
    pop r12
    pop rbx
    ret

colo_name:                      # rdi = code -> rax = "City, CC" or 0
    push rbx
    push r12
    mov r12, rdi
    lea rbx, [rip+colo_tab]
1:  cmp byte ptr [rbx], 0
    je 9f
    mov rdi, r12
    mov rsi, rbx
    call streq
    test eax, eax
    jnz 7f
3:  cmp byte ptr [rbx], 0
    je 4f
    inc rbx
    jmp 3b
4:  inc rbx
5:  cmp byte ptr [rbx], 0
    je 6f
    inc rbx
    jmp 5b
6:  inc rbx
    jmp 1b
7:  cmp byte ptr [rbx], 0
    je 8f
    inc rbx
    jmp 7b
8:  inc rbx
    mov rax, rbx
    jmp 0f
9:  xor eax, eax
0:  pop r12
    pop rbx
    ret

# --- command line -----------------------------------------------------------

parse_args:                     # eax = 0 ok, 1 help requested, 2 bad usage
    push rbx
    push r12
    mov r12, 1
.pa_loop:
    cmp r12, [rip+g_argc]
    jge .pa_ok
    mov rax, [rip+g_argv]
    mov rbx, [rax+r12*8]
    mov rdi, rbx
    lea rsi, [rip+a_h]
    call streq
    test eax, eax
    jnz .pa_help
    mov rdi, rbx
    lea rsi, [rip+a_help]
    call streq
    test eax, eax
    jnz .pa_help
    mov rdi, rbx
    lea rsi, [rip+a_n]
    call streq
    test eax, eax
    jnz .pa_n
    mov rdi, rbx
    lea rsi, [rip+a_nocolor]
    call streq
    test eax, eax
    jnz .pa_n
    mov rdi, rbx
    lea rsi, [rip+a_t]
    call streq
    test eax, eax
    jnz .pa_t
    mov rdi, rbx
    lea rsi, [rip+a_c]
    call streq
    test eax, eax
    jnz .pa_c
    jmp .pa_bad
.pa_n:
    mov qword ptr [rip+g_nocolor], 1
    inc r12
    jmp .pa_loop
.pa_t:
    inc r12
    cmp r12, [rip+g_argc]
    jge .pa_bad
    mov rax, [rip+g_argv]
    mov rdi, [rax+r12*8]
    call parse_uint
    cmp rax, 1
    jl .pa_bad
    cmp rax, 60
    jg .pa_bad
    mov [rip+g_dur], rax
    inc r12
    jmp .pa_loop
.pa_c:
    inc r12
    cmp r12, [rip+g_argc]
    jge .pa_bad
    mov rax, [rip+g_argv]
    mov rdi, [rax+r12*8]
    call parse_uint
    cmp rax, 1
    jl .pa_bad
    cmp rax, MAX_CONNS
    jg .pa_bad
    mov [rip+g_conns], rax
    inc r12
    jmp .pa_loop
.pa_ok:
    xor eax, eax
    jmp .pa_ret
.pa_help:
    mov eax, 1
    jmp .pa_ret
.pa_bad:
    mov eax, 2
.pa_ret:
    pop r12
    pop rbx
    ret

# --- who am I / which server -----------------------------------------------

fetch_info:                     # fills g_i_* from the headers of a tiny request
    push rbx
    push r12
    mov edi, [rip+g_ip]
    mov esi, 80
    call os_connect
    test rax, rax
    js .fi_ret
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip+req_info]
    mov edx, REQ_INFO_LEN
    call os_send
    mov rdi, rbx
    call os_nonblock
    xor r12d, r12d
.fi_loop:
    cmp r12, 4000
    jae .fi_done
    mov [rip+g_tmp], rbx
    lea rdi, [rip+g_tmp]
    mov esi, 1
    lea rdx, [rip+g_flags]
    xor ecx, ecx
    mov r8d, 3000
    call os_poll
    cmp byte ptr [rip+g_flags], 0
    je .fi_done
    mov rdi, rbx
    lea rsi, [rip+g_info]
    add rsi, r12
    mov edx, 4000
    sub rdx, r12
    call os_recv
    test rax, rax
    jg .fi_add
    cmp rax, -1
    je .fi_loop
    jmp .fi_done
.fi_add:
    add r12, rax
    lea rdi, [rip+g_info]
    mov rsi, r12
    lea rdx, [rip+h_end]
    call ci_find
    test rax, rax
    jz .fi_loop                 # headers not complete yet
.fi_done:
    mov rdi, rbx
    call os_close
    lea rax, [rip+g_info]
    mov byte ptr [rax+r12], 0
    mov [rip+g_infolen], r12
    lea rdi, [rip+h_ip]
    lea rsi, [rip+g_i_ip]
    mov edx, 48
    call get_hdr
    lea rdi, [rip+h_asn]
    lea rsi, [rip+g_i_asn]
    mov edx, 16
    call get_hdr
    lea rdi, [rip+h_city]
    lea rsi, [rip+g_i_city]
    mov edx, 48
    call get_hdr
    lea rdi, [rip+h_colo]
    lea rsi, [rip+g_i_colo]
    mov edx, 8
    call get_hdr
    lea rdi, [rip+h_cc]
    lea rsi, [rip+g_i_cc]
    mov edx, 8
    call get_hdr
    cmp byte ptr [rip+g_i_ip], 0
    je .fi_ret
    mov qword ptr [rip+g_hasinfo], 1
.fi_ret:
    pop r12
    pop rbx
    ret

print_ip:                       # the server's IPv4 address
    push rbx
    push r12
    mov r12d, [rip+g_ip]
    xor ebx, ebx
1:  movzx edi, r12b
    call print_u64
    inc ebx
    cmp ebx, 4
    je 2f
    lea rdi, [rip+s_dot]
    call print_str
    shr r12d, 8
    jmp 1b
2:  pop r12
    pop rbx
    ret

print_info:                     # "Connection" and "Server" lines
    push rbx
    cmp qword ptr [rip+g_hasinfo], 0
    je .pi_server
    lea rdi, [rip+t_conn]
    call emit
    lea rdi, [rip+g_i_ip]
    call print_str
    cmp byte ptr [rip+g_i_asn], 0
    je .pi_city
    lea rdi, [rip+t_dot]
    call emit
    lea rdi, [rip+t_as]
    call print_str
    lea rdi, [rip+g_i_asn]
    call print_str
.pi_city:
    cmp byte ptr [rip+g_i_city], 0
    je .pi_conn_end
    lea rdi, [rip+t_dot]
    call emit
    lea rdi, [rip+g_i_city]
    call print_str
    cmp byte ptr [rip+g_i_cc], 0
    je .pi_conn_end
    lea rdi, [rip+t_comma]
    call print_str
    lea rdi, [rip+g_i_cc]
    call print_str
.pi_conn_end:
    lea rdi, [rip+s_rst_nl]
    call emit
.pi_server:
    lea rdi, [rip+t_server]
    call emit
    cmp byte ptr [rip+g_i_colo], 0
    je .pi_srv_ip
    lea rdi, [rip+t_colo]
    call emit
    lea rdi, [rip+g_i_colo]
    call print_str
    lea rdi, [rip+s_rst]
    call emit
    lea rdi, [rip+g_i_colo]
    call colo_name
    test rax, rax
    jz .pi_srv_ip
    mov rbx, rax
    lea rdi, [rip+t_lp]
    call print_str
    mov rdi, rbx
    call print_str
    lea rdi, [rip+t_rp]
    call print_str
.pi_srv_ip:
    lea rdi, [rip+t_dot]
    call emit
    call print_ip
    lea rdi, [rip+s_rst_nl]
    call emit
    lea rdi, [rip+s_nl]
    call print_str
    pop rbx
    ret

# --- latency ----------------------------------------------------------------

do_latency:                     # eax = 0 ok, 1 unreachable
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                 # [rsp] t0, [rsp+8] sock, [rsp+16] sample, [rsp+24] max
    xor r12d, r12d              # i
    mov r13, 0x7fffffffffffffff # min
    xor r14d, r14d              # sum
    xor r15d, r15d              # sum of |sample - previous|
    xor ebx, ebx                # previous sample
    mov qword ptr [rsp+24], 0
    xor edi, edi
    call lat_draw
.lat_loop:
    cmp r12, LAT_N
    jae .lat_done
    call os_time_ns
    mov [rsp], rax
    mov edi, [rip+g_ip]
    mov esi, 80
    call os_connect
    mov [rsp+8], rax
    call os_time_ns
    sub rax, [rsp]
    mov [rsp+16], rax
    mov rdi, [rsp+8]
    test rdi, rdi
    js .lat_fail
    call os_close
    mov rax, [rsp+16]
    cmp rax, r13
    jae 1f
    mov r13, rax
1:  cmp rax, [rsp+24]
    jbe 4f
    mov [rsp+24], rax
4:  add r14, rax
    test r12, r12
    jz 2f
    mov rcx, rax
    sub rcx, rbx
    jns 3f
    neg rcx
3:  add r15, rcx
2:  mov rbx, rax
    inc r12
    mov rdi, r12
    call lat_draw
    mov edi, 40
    call os_sleep_ms
    jmp .lat_loop
.lat_done:
    mov rax, r14
    xor edx, edx
    mov ecx, LAT_N * 10000      # ns -> hundredths of a millisecond
    div rcx
    mov [rip+g_lat_avg], rax
    mov rax, r13
    xor edx, edx
    mov ecx, 10000
    div rcx
    mov [rip+g_lat_min], rax
    mov rax, [rsp+24]
    xor edx, edx
    div rcx
    mov [rip+g_lat_max], rax
    mov rax, r15
    xor edx, edx
    mov ecx, (LAT_N - 1) * 10000
    div rcx
    mov [rip+g_lat_jit], rax
    cmp qword ptr [rip+g_tty], 0
    je 5f
    lea rdi, [rip+s_cr]
    call print_str
5:  lea rdi, [rip+t_lat]
    call emit
    mov rdi, [rip+g_lat_avg]
    call print_hund
    lea rdi, [rip+t_lat_j]
    call emit
    mov rdi, [rip+g_lat_jit]
    call print_hund
    lea rdi, [rip+t_lat_min]
    call emit
    mov rdi, [rip+g_lat_min]
    call print_hund
    lea rdi, [rip+t_lat_max]
    call emit
    mov rdi, [rip+g_lat_max]
    call print_hund
    lea rdi, [rip+t_lat_end]
    call emit
    call out_flush
    xor eax, eax
    jmp .lat_ret
.lat_fail:
    cmp qword ptr [rip+g_tty], 0
    je 6f
    lea rdi, [rip+s_cr]
    call print_str
6:  lea rdi, [rip+s_latfail]
    call emit
    call out_flush
    mov eax, 1
.lat_ret:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

sample_lat:                     # one TCP handshake timed while the link is busy -> rax = ns or -1
    push rbx
    push r12
    call os_time_ns
    mov r12, rax
    mov edi, [rip+g_ip]
    mov esi, 80
    call os_connect
    mov rbx, rax
    call os_time_ns
    sub rax, r12
    mov r12, rax
    test rbx, rbx
    js 1f
    mov rdi, rbx
    call os_close
    mov rax, r12
    jmp 2f
1:  mov rax, -1
2:  pop r12
    pop rbx
    ret

# --- throughput connections --------------------------------------------------

alive_count:                    # rdi = n -> eax = number of open sockets
    xor eax, eax
    xor ecx, ecx
    lea rdx, [rip+g_socks]
1:  cmp rcx, rdi
    jae 2f
    cmp qword ptr [rdx+rcx*8], 0
    jl 3f
    inc eax
3:  inc rcx
    jmp 1b
2:  ret

close_all:                      # rdi = n
    push rbx
    push r12
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, r12
    jae 3f
    lea rax, [rip+g_socks]
    mov rdi, [rax+rbx*8]
    test rdi, rdi
    js 2f
    call os_close
    lea rax, [rip+g_socks]
    mov qword ptr [rax+rbx*8], -1
2:  inc rbx
    jmp 1b
3:  pop r12
    pop rbx
    ret

open_slot:                      # rdi = slot, rsi = mode (0 down, 1 up)
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    lea rax, [rip+g_socks]
    mov qword ptr [rax+rbx*8], -1
    mov edi, [rip+g_ip]
    mov esi, 80
    call os_connect
    test rax, rax
    js .os_ret
    mov r13, rax
    lea rax, [rip+g_socks]
    mov [rax+rbx*8], r13
    lea rax, [rip+g_rem]
    mov qword ptr [rax+rbx*8], BODY_LEN
    mov rdi, r13
    lea rsi, [rip+req_down]
    mov edx, REQ_DOWN_LEN
    test r12, r12
    jz 1f
    lea rsi, [rip+req_up]
    mov edx, REQ_UP_LEN
1:  call os_send
    mov rdi, r13
    call os_nonblock
.os_ret:
    pop r13
    pop r12
    pop rbx
    ret

reopen_slot:                    # rdi = slot, rsi = mode
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    lea rax, [rip+g_socks]
    mov rdi, [rax+rbx*8]
    test rdi, rdi
    js 1f
    call os_close
1:  lea rax, [rip+g_socks]
    mov qword ptr [rax+rbx*8], -1
    inc qword ptr [rip+g_reopen]
    cmp qword ptr [rip+g_reopen], 400
    ja 2f
    mov rdi, rbx
    mov rsi, r12
    call open_slot
2:  pop r12
    pop rbx
    ret

service_slot:                   # rdi = slot, rsi = mode: do one recv/send
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    lea rax, [rip+g_socks]
    mov rdi, [rax+rbx*8]
    test rdi, rdi
    js .ss_ret
    test r12, r12
    jnz .ss_up
    lea rsi, [rip+g_rbuf]
    mov edx, CHUNK
    call os_recv
    test rax, rax
    jg .ss_cnt
    cmp rax, -1
    je .ss_ret
    jmp .ss_reopen              # EOF (server finished the body) or error
.ss_cnt:
    add [rip+g_total], rax
    jmp .ss_ret
.ss_up:
    lea rax, [rip+g_rem]
    mov rdx, [rax+rbx*8]
    cmp rdx, CHUNK
    jbe 1f
    mov edx, CHUNK
1:  lea rsi, [rip+g_sbuf]
    call os_send
    test rax, rax
    jg .ss_sent
    cmp rax, -1
    je .ss_ret
    jmp .ss_reopen
.ss_sent:
    add [rip+g_total], rax
    lea rcx, [rip+g_rem]
    sub [rcx+rbx*8], rax
    jnz .ss_ret                 # body not finished yet
.ss_reopen:
    mov rdi, rbx
    mov rsi, r12
    call reopen_slot
.ss_ret:
    pop r12
    pop rbx
    ret

# --- live display -------------------------------------------------------------

print_padded:                   # rdi = ASCII string, rsi = field width: print, then pad with spaces
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    xor ecx, ecx
1:  cmp byte ptr [rbx+rcx], 0
    je 2f
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    mov rsi, rcx
    sub r12, rcx
    call out_write
    test r12, r12
    jle 3f
    lea rdi, [rip+s_spaces]
    mov rsi, r12
    call out_write
3:  pop r12
    pop rbx
    ret

# Segmented chevron bar spanning the whole test: latency (blue), download
# (orange), upload (lilac); chevrons not reached yet are grey.
chev_bar:                       # rdi = current phase 0..2, rsi = filled cells in that phase
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
.cb_seg:
    cmp rbx, 3
    jae .cb_end
    lea rax, [rip+seg_len]
    mov r14, [rax+rbx*8]
    cmp rbx, r12
    jb .cb_full
    ja .cb_none
    mov rax, r13
    cmp rax, r14
    jbe .cb_have
    mov rax, r14
    jmp .cb_have
.cb_full:
    mov rax, r14
    jmp .cb_have
.cb_none:
    xor eax, eax
.cb_have:
    mov r15, rax                # filled cells in this segment
    test r15, r15
    jz 2f
    lea rax, [rip+seg_col]
    mov rdi, [rax+rbx*8]
    call cprint
    lea rdi, [rip+s_chevrow]
    lea rsi, [r15+r15*2]
    call out_write
2:  sub r14, r15                # empty cells
    jz .cb_next
    lea rdi, [rip+c_gray]
    call cprint
    lea rdi, [rip+s_chevrow]
    cmp qword ptr [rip+g_color], 0
    jne 3f
    lea rdi, [rip+s_dotrow]     # no colour: dots instead of grey chevrons
3:  lea rsi, [r14+r14*2]
    call out_write
.cb_next:
    inc rbx
    jmp .cb_seg
.cb_end:
    lea rdi, [rip+c_rst]
    call cprint
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

draw_status:                    # rdi = phase (0 latency, 1 download, 2 upload), rsi = filled cells, rdx = packets / Mbps*100 (-1 = warming up)
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip+s_two]
    call print_str
    call os_time_ns
    xor edx, edx
    mov ecx, DRAW_NS
    div rcx
    xor edx, edx
    mov ecx, 10
    div rcx                     # spinner frame = (now / 100 ms) mod 10
    lea r8, [rdx+rdx*2]
    lea rax, [rip+seg_col]
    mov rdi, [rax+rbx*8]
    push r8
    call cprint
    pop r8
    lea rdi, [rip+s_spin]
    add rdi, r8
    mov esi, 3
    call out_write
    lea rdi, [rip+c_rst]
    call cprint
    lea rdi, [rip+s_one]
    call print_str
    mov rdi, rbx
    mov rsi, r12
    call chev_bar
    lea rdi, [rip+s_two]
    call print_str
    lea rax, [rip+seg_col]
    mov rdi, [rax+rbx*8]
    call cprint
    lea rdi, [rip+s_phases]
    mov rsi, rbx
    call nth_str
    mov rdi, rax
    call print_str
    lea rdi, [rip+c_rst]
    call cprint
    lea rdi, [rip+s_sepdot]
    call emit
    test rbx, rbx
    jnz 1f
    mov rdi, r13
    call print_u64
    lea rdi, [rip+s_packets]
    call print_str
    jmp 2f
1:  cmp r13, -1
    jne 3f
    lea rdi, [rip+s_warm]
    call emit
    jmp 2f
3:  lea rdi, [rip+s_b]
    call emit
    mov rdi, r13
    call print_hund
    lea rdi, [rip+s_mbps_only]
    call emit
2:  lea rdi, [rip+s_eolonly]
    call emit
    pop r13
    pop r12
    pop rbx
    ret

lat_draw:                       # rdi = latency packets sent so far: live bar while probing
    cmp qword ptr [rip+g_tty], 0
    je 9f
    push rbx
    mov rbx, rdi
    lea rdi, [rip+s_cr]
    call print_str
    mov rax, rbx
    imul rax, rax, 4
    xor edx, edx
    mov ecx, LAT_N
    div rcx
    xor edi, edi
    mov rsi, rax
    mov rdx, rbx
    call draw_status
    call out_flush
    pop rbx
9:  ret

print_spark:                    # rdi = samples (hundredths Mbps), rsi = count: ▁▂▃▅▇ trend
    push rbx
    push r12
    push r13
    push r14
    push r15
    test rsi, rsi
    jz .sp_ret
    mov r12, rdi
    mov r13, rsi
    mov r14, SPARK_N
    cmp r13, r14
    jae 1f
    mov r14, r13                # m = min(n, SPARK_N) bins
1:  xor ebx, ebx
    xor r15d, r15d              # max bin
.sp_bin:
    cmp rbx, r14
    jae .sp_render
    mov rax, rbx
    mul r13
    div r14
    mov r8, rax                 # lo = i*n/m
    lea rax, [rbx+1]
    mul r13
    div r14
    mov r11, rax                # hi = (i+1)*n/m
    xor r9d, r9d
    mov rcx, r8
.sp_sum:
    cmp rcx, r11
    jae .sp_avg
    add r9, [r12+rcx*8]
    inc rcx
    jmp .sp_sum
.sp_avg:
    mov r10, r11
    sub r10, r8
    mov rax, r9
    xor edx, edx
    div r10
    lea rdx, [rip+g_bins]
    mov [rdx+rbx*8], rax
    cmp rax, r15
    jbe 2f
    mov r15, rax
2:  inc rbx
    jmp .sp_bin
.sp_render:
    xor ebx, ebx
    lea r8, [rip+g_sp]
.sp_r1:
    cmp rbx, r14
    jae .sp_out
    lea rdx, [rip+g_bins]
    mov rax, [rdx+rbx*8]
    imul rax, rax, 7
    test r15, r15
    jz 3f
    xor edx, edx
    div r15
    jmp 4f
3:  xor eax, eax
4:  lea rdi, [rip+s_blocks]
    lea rax, [rax+rax*2]
    add rdi, rax
    mov ax, [rdi]
    mov [r8], ax
    mov al, [rdi+2]
    mov [r8+2], al
    add r8, 3
    inc rbx
    jmp .sp_r1
.sp_out:
    lea rdi, [rip+g_sp]
    lea rsi, [r14+r14*2]
    call out_write
.sp_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

draw_live:                      # rdi = mode, rsi = now: one-line live display, rewritten with \r
    push rbx
    push r12
    cmp qword ptr [rip+g_tty], 0
    je .dl_ret
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip+s_cr]
    call print_str
    mov rdx, -1                 # -1 = still warming up
    cmp qword ptr [rip+g_measuring], 0
    je 1f
    mov rdi, [rip+g_total]
    sub rdi, [rip+g_base]
    mov rsi, r12
    sub rsi, [rip+g_tmark]
    call calc_hund
    mov rdx, rax
1:  push rdx
    mov rax, r12
    sub rax, [rip+g_t0]
    imul rax, rax, 13           # cells in this phase's segment
    mov rcx, [rip+g_dur]
    imul rcx, rcx, 1000000000
    add rcx, WARM_NS
    xor edx, edx
    div rcx
    cmp rax, 13
    jbe 2f
    mov eax, 13
2:  pop rdx
    lea rdi, [rbx+1]
    mov rsi, rax
    call draw_status
    call out_flush
.dl_ret:
    pop r12
    pop rbx
    ret

print_result:                   # rdi = mode: final two-line summary for one direction
    push rbx
    push r12
    mov rbx, rdi
    cmp qword ptr [rip+g_tty], 0
    je 1f
    lea rdi, [rip+s_cr]
    call print_str
1:  lea rdi, [rip+l_down]
    test rbx, rbx
    jz 2f
    lea rdi, [rip+l_up]
2:  call emit
    lea rdi, [rip+s_b]
    call emit
    lea rax, [rip+g_r_avg]
    mov rdi, [rax+rbx*8]
    mov esi, 7
    call print_hund_w
    lea rdi, [rip+s_mbps_sp]
    call emit
    lea rdi, [rip+c_down]
    test rbx, rbx
    jz 3f
    lea rdi, [rip+c_up]
3:  call cprint
    lea rdi, [rip+g_samp]
    mov rcx, rbx
    imul rcx, rcx, MAX_SAMP * 8
    add rdi, rcx
    lea rax, [rip+g_nsamp]
    mov rsi, [rax+rbx*8]
    call print_spark
    lea rdi, [rip+s_eol_nl]
    call emit
    lea rdi, [rip+s_peak]
    call emit
    lea rax, [rip+g_r_peak]
    mov rdi, [rax+rbx*8]
    call print_hund
    lea rdi, [rip+s_mid]
    call emit
    lea rax, [rip+g_r_bytes]
    mov rax, [rax+rbx*8]
    xor edx, edx
    mov ecx, 10000
    div rcx                     # bytes -> hundredths of a (decimal) megabyte
    mov rdi, rax
    call print_hund
    lea rdi, [rip+s_mb]
    call print_str
    lea rax, [rip+g_r_lat]
    mov r12, [rax+rbx*8]
    test r12, r12
    jz 4f
    lea rdi, [rip+s_load]
    call emit
    mov rdi, r12
    call print_hund
    lea rdi, [rip+s_ms]
    call print_str
    sub r12, [rip+g_lat_avg]
    jbe 4f
    lea rdi, [rip+s_plus]
    call emit
    mov rdi, r12
    call print_hund
    lea rdi, [rip+s_plus_end]
    call emit
4:  lea rdi, [rip+s_end2]
    call print_str
    call out_flush
    pop r12
    pop rbx
    ret

# Runs one direction for WARM_NS + g_dur seconds. Speed is measured only after
# the warm-up window, which also hides socket buffer fill on uploads.
run_transfer:                   # rdi = mode (0 download, 1 upload)
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 8
    mov r12, rdi
    mov r13, [rip+g_conns]
    xor eax, eax
    mov [rip+g_total], rax
    mov [rip+g_base], rax
    mov [rip+g_tmark], rax
    mov [rip+g_measuring], rax
    mov [rip+g_reopen], rax
    mov [rip+g_nsamp_cur], rax
    mov [rip+g_peak], rax
    mov [rip+g_lsum], rax
    mov [rip+g_ln], rax
    xor ebx, ebx
.rt_open:
    cmp rbx, r13
    jae .rt_opened
    mov rdi, rbx
    mov rsi, r12
    call open_slot
    inc rbx
    jmp .rt_open
.rt_opened:
    mov rdi, r13
    call alive_count
    test eax, eax
    jz .rt_fail
    call os_time_ns
    mov r14, rax                # start
    mov [rip+g_lastdraw], rax
    mov [rip+g_t0], rax
.rt_loop:
    call os_time_ns
    mov r15, rax                # now
    mov rax, r15
    sub rax, r14                # elapsed
    cmp qword ptr [rip+g_measuring], 0
    jne .rt_chk
    cmp rax, WARM_NS
    jb .rt_chk
    mov qword ptr [rip+g_measuring], 1
    mov rcx, [rip+g_total]
    mov [rip+g_base], rcx
    mov [rip+g_sampb], rcx
    mov [rip+g_tmark], r15
    mov [rip+g_sampt], r15
    mov [rip+g_lastlat], r15
.rt_chk:
    mov rcx, [rip+g_dur]
    imul rcx, rcx, 1000000000
    add rcx, WARM_NS
    cmp rax, rcx
    jae .rt_done
    cmp qword ptr [rip+g_measuring], 0
    je .rt_poll
    mov rax, r15                # throughput sample every SAMP_NS
    sub rax, [rip+g_sampt]
    cmp rax, SAMP_NS
    jb .rt_lat
    mov rsi, rax
    mov rdi, [rip+g_total]
    sub rdi, [rip+g_sampb]
    call calc_hund
    mov rcx, [rip+g_nsamp_cur]
    cmp rcx, MAX_SAMP
    jae 1f
    lea rdx, [rip+g_samp]
    mov r8, r12
    imul r8, r8, MAX_SAMP * 8
    add rdx, r8
    mov [rdx+rcx*8], rax
    inc qword ptr [rip+g_nsamp_cur]
1:  cmp rax, [rip+g_peak]
    jbe 2f
    mov [rip+g_peak], rax
2:  mov [rip+g_sampt], r15
    mov rax, [rip+g_total]
    mov [rip+g_sampb], rax
.rt_lat:
    mov rax, r15                # latency under load every LATS_NS
    sub rax, [rip+g_lastlat]
    cmp rax, LATS_NS
    jb .rt_poll
    mov [rip+g_lastlat], r15
    call sample_lat
    test rax, rax
    js .rt_poll
    add [rip+g_lsum], rax
    inc qword ptr [rip+g_ln]
.rt_poll:
    lea rdi, [rip+g_socks]
    mov rsi, r13
    lea rdx, [rip+g_flags]
    mov rcx, r12
    mov r8d, 50
    call os_poll
    xor ebx, ebx
.rt_proc:
    cmp rbx, r13
    jae .rt_drawchk
    lea rax, [rip+g_flags]
    cmp byte ptr [rax+rbx], 0
    je .rt_next
    mov rdi, rbx
    mov rsi, r12
    call service_slot
.rt_next:
    inc rbx
    jmp .rt_proc
.rt_drawchk:
    mov rdi, r13
    call alive_count
    test eax, eax
    jz .rt_fail
    mov rax, r15
    sub rax, [rip+g_lastdraw]
    cmp rax, DRAW_NS
    jb .rt_loop
    mov [rip+g_lastdraw], r15
    mov rdi, r12
    mov rsi, r15
    call draw_live
    jmp .rt_loop
.rt_done:
    mov rdi, [rip+g_total]
    sub rdi, [rip+g_base]
    mov rsi, r15
    sub rsi, [rip+g_tmark]
    call calc_hund
    lea rcx, [rip+g_r_avg]
    mov [rcx+r12*8], rax
    mov rdx, [rip+g_peak]
    cmp rdx, rax
    jae 1f
    mov rdx, rax
1:  lea rcx, [rip+g_r_peak]
    mov [rcx+r12*8], rdx
    mov rax, [rip+g_total]
    lea rcx, [rip+g_r_bytes]
    mov [rcx+r12*8], rax
    mov rax, [rip+g_nsamp_cur]
    lea rcx, [rip+g_nsamp]
    mov [rcx+r12*8], rax
    xor eax, eax
    cmp qword ptr [rip+g_ln], 0
    je 2f
    mov rax, [rip+g_lsum]
    xor edx, edx
    div qword ptr [rip+g_ln]
    xor edx, edx
    mov ecx, 10000
    div rcx
2:  lea rcx, [rip+g_r_lat]
    mov [rcx+r12*8], rax
    mov rdi, r13
    call close_all
    mov rdi, r12
    call print_result
    xor eax, eax
    jmp .rt_ret
.rt_fail:
    mov rdi, r13
    call close_all
    cmp qword ptr [rip+g_tty], 0
    je 3f
    lea rdi, [rip+s_cr]
    call print_str
3:  lea rdi, [rip+l_down]
    test r12, r12
    jz 4f
    lea rdi, [rip+l_up]
4:  call emit
    lea rdi, [rip+s_fail]
    call emit
    call out_flush
    mov eax, 1
.rt_ret:
    add rsp, 8
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# --- quality ratings -----------------------------------------------------------

stars_hi:                       # rdi = value, rsi/rdx/rcx/r8 = thresholds for 5/4/3/2 stars (higher is better)
    mov eax, 5
    cmp rdi, rsi
    jae 9f
    dec eax
    cmp rdi, rdx
    jae 9f
    dec eax
    cmp rdi, rcx
    jae 9f
    dec eax
    cmp rdi, r8
    jae 9f
    mov eax, 1
9:  ret

stars_lo:                       # same, lower is better
    mov eax, 5
    cmp rdi, rsi
    jb 9f
    dec eax
    cmp rdi, rdx
    jb 9f
    dec eax
    cmp rdi, rcx
    jb 9f
    dec eax
    cmp rdi, r8
    jb 9f
    mov eax, 1
9:  ret

print_stars:                    # edi = 1..5
    push rbx
    push r12
    mov ebx, edi
    lea rdi, [rip+c_grn]
    cmp ebx, 4
    jae 1f
    lea rdi, [rip+c_yel]
    cmp ebx, 3
    jae 1f
    lea rdi, [rip+c_red]
1:  call cprint
    xor r12d, r12d
2:  cmp r12d, 5
    jae 3f
    lea rdi, [rip+s_star]
    cmp r12d, ebx
    jb 4f
    lea rdi, [rip+s_star0]
4:  mov esi, 3
    call out_write
    inc r12d
    jmp 2b
3:  lea rdi, [rip+c_rst]
    call cprint
    pop r12
    pop rbx
    ret

print_row:                      # rdi = label, esi = stars, rdx = word list
    push rbx
    push r12
    mov ebx, esi
    mov r12, rdx
    call emit
    mov edi, ebx
    call print_stars
    lea rdi, [rip+s_two]
    call print_str
    mov rdi, r12
    lea rsi, [rbx-1]
    call nth_str
    mov rdi, rax
    call print_str
    lea rdi, [rip+s_nl]
    call print_str
    pop r12
    pop rbx
    ret

print_quality:
    push rbx
    push r12
    push r13
    # streaming: download speed
    mov rdi, [rip+g_r_avg]
    mov esi, 2500
    mov edx, 1000
    mov ecx, 500
    mov r8d, 300
    call stars_hi
    mov [rip+g_q], rax
    # gaming: latency and jitter - weakest link wins
    mov rdi, [rip+g_lat_avg]
    mov esi, 3000
    mov edx, 6000
    mov ecx, 10000
    mov r8d, 15000
    call stars_lo
    mov ebx, eax
    mov rdi, [rip+g_lat_jit]
    mov esi, 1000
    mov edx, 2000
    mov ecx, 4000
    mov r8d, 8000
    call stars_lo
    cmp eax, ebx
    cmova eax, ebx
    mov [rip+g_q+8], rax
    # video calls: upload speed, latency and jitter
    mov rdi, [rip+g_r_avg+8]
    mov esi, 500
    mov edx, 300
    mov ecx, 150
    mov r8d, 50
    call stars_hi
    mov ebx, eax
    mov rdi, [rip+g_lat_avg]
    mov esi, 5000
    mov edx, 10000
    mov ecx, 15000
    mov r8d, 25000
    call stars_lo
    cmp eax, ebx
    cmova eax, ebx
    mov ebx, eax
    mov rdi, [rip+g_lat_jit]
    mov esi, 1500
    mov edx, 3000
    mov ecx, 5000
    mov r8d, 10000
    call stars_lo
    cmp eax, ebx
    cmova eax, ebx
    mov [rip+g_q+16], rax
    # overall: rounded mean
    mov rax, [rip+g_q]
    add rax, [rip+g_q+8]
    add rax, [rip+g_q+16]
    inc rax
    xor edx, edx
    mov ecx, 3
    div rcx
    mov r13d, eax
    lea rdi, [rip+s_qhdr]
    call emit
    lea rdi, [rip+s_box_top]
    call emit
    lea rdi, [rip+s_box_blank]
    call emit
    # row 1: titles
    lea rdi, [rip+s_box_l]
    call emit
    xor r12d, r12d
1:  cmp r12, 3
    jae 2f
    lea rdi, [rip+s_two]
    call print_str
    lea rdi, [rip+c_dim]
    call cprint
    lea rax, [rip+box_titles]
    mov rdi, [rax+r12*8]
    mov esi, 18
    call print_padded
    lea rdi, [rip+c_rst]
    call cprint
    inc r12
    jmp 1b
2:  lea rdi, [rip+s_box_r]
    call emit
    # row 2: stars
    lea rdi, [rip+s_box_l]
    call emit
    xor r12d, r12d
3:  cmp r12, 3
    jae 4f
    lea rdi, [rip+s_two]
    call print_str
    lea rax, [rip+g_q]
    mov edi, [rax+r12*8]
    call print_stars
    lea rdi, [rip+s_spaces]
    mov esi, 13
    call out_write
    inc r12
    jmp 3b
4:  lea rdi, [rip+s_box_r]
    call emit
    # row 3: verdicts
    lea rdi, [rip+s_box_l]
    call emit
    xor r12d, r12d
5:  cmp r12, 3
    jae 6f
    lea rdi, [rip+s_two]
    call print_str
    lea rax, [rip+box_words]
    mov rdi, [rax+r12*8]
    lea rcx, [rip+g_q]
    mov rsi, [rcx+r12*8]
    dec rsi
    call nth_str
    mov rdi, rax
    mov esi, 18
    call print_padded
    inc r12
    jmp 5b
6:  lea rdi, [rip+s_box_r]
    call emit
    lea rdi, [rip+s_box_blank]
    call emit
    lea rdi, [rip+s_box_bot]
    call emit
    lea rdi, [rip+s_nl]
    call print_str
    lea rdi, [rip+q_overall]
    mov esi, r13d
    lea rdx, [rip+w_rating]
    call print_row
    lea rdi, [rip+s_nl]
    call print_str
    call out_flush
    pop r13
    pop r12
    pop rbx
    ret

# --- entry --------------------------------------------------------------------

main_entry:                     # -> eax = exit code
    push rbx
    push r12
    sub rsp, 8
    mov qword ptr [rip+g_dur], 8
    mov qword ptr [rip+g_conns], 4
    call parse_args
    cmp eax, 1
    je .m_help
    cmp eax, 2
    je .m_bad
    call os_isatty
    mov [rip+g_tty], rax
    cmp qword ptr [rip+g_nocolor], 0
    jne 1f
    mov [rip+g_color], rax
1:  lea rdi, [rip+s_hdr]
    call emit
    call out_flush
    lea rdi, [rip+s_host]
    call os_resolve
    test eax, eax
    jz .m_dns
    mov [rip+g_ip], eax
    call fetch_info
    call print_info
    call out_flush
    call do_latency
    test eax, eax
    jnz .m_net
    xor edi, edi
    call run_transfer
    mov edi, 1
    call run_transfer
    call print_quality
    xor eax, eax
    jmp .m_ret
.m_help:
    lea rdi, [rip+s_usage]
    call print_str
    call out_flush
    xor eax, eax
    jmp .m_ret
.m_bad:
    lea rdi, [rip+s_usage]
    call print_str
    call out_flush
    mov eax, 2
    jmp .m_ret
.m_dns:
    lea rdi, [rip+s_dnsfail]
    call emit
    call out_flush
    mov eax, 1
    jmp .m_ret
.m_net:
    mov eax, 1
.m_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

.section .rodata
s_rst:      .asciz "\007"
s_rst_nl:   .asciz "\007\n"

.section .note.GNU-stack,"",@progbits

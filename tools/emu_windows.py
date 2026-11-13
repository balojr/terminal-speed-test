#!/usr/bin/env python3
"""Run the Windows asmspeed.exe under Unicorn with kernel32/ws2_32 emulated.

A test harness for machines without Windows or Wine. It maps the PE sections,
points every IAT slot at a hooked stub, and services the Win32 calls with
Python (real sockets), asserting the MS x64 calling convention (16-byte stack
alignment at the call) on every call.

    pip install unicorn
    python3 tools/emu_windows.py build/asmspeed.exe [asmspeed args...]
"""
import select
import socket
import struct
import sys
import time

from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE
from unicorn.x86_const import (UC_X86_REG_RAX, UC_X86_REG_RCX, UC_X86_REG_RDX,
                               UC_X86_REG_R8, UC_X86_REG_R9, UC_X86_REG_RSP)

STUB_BASE = 0x70000000
STACK_TOP = 0x7FF00000
HEAP = 0x60000000
PAGE = 0x1000


def up(v, a=PAGE):
    return (v + a - 1) // a * a


def main():
    exe = open(sys.argv[1], "rb").read()
    args = sys.argv[2:]

    pe = struct.unpack_from("<I", exe, 0x3C)[0]
    assert exe[pe:pe + 4] == b"PE\0\0"
    nsec, = struct.unpack_from("<H", exe, pe + 6)
    optsz, = struct.unpack_from("<H", exe, pe + 20)
    opt = pe + 24
    entry, = struct.unpack_from("<I", exe, opt + 16)
    base, = struct.unpack_from("<Q", exe, opt + 24)
    img_size, = struct.unpack_from("<I", exe, opt + 56)
    imp_rva, = struct.unpack_from("<I", exe, opt + 112 + 8)

    uc = Uc(UC_ARCH_X86, UC_MODE_64)
    uc.mem_map(base, up(img_size))
    sec = opt + optsz
    for i in range(nsec):
        name, vsize, rva, rawsz, rawptr = struct.unpack_from("<8sIIII", exe, sec + 40 * i)
        uc.mem_write(base + rva, exe[rawptr:rawptr + min(rawsz, up(vsize))])

    # resolve imports -> stubs
    stubs = {}
    uc.mem_map(STUB_BASE, PAGE)
    n = 0
    d = imp_rva
    while True:
        ilt, _, _, name_rva, iat = struct.unpack("<IIIII", bytes(uc.mem_read(base + d, 20)))
        if not name_rva:
            break
        j = 0
        while True:
            ent, = struct.unpack("<Q", bytes(uc.mem_read(base + ilt + 8 * j, 8)))
            if not ent:
                break
            nm = bytes(uc.mem_read(base + ent + 2, 64)).split(b"\0")[0].decode()
            addr = STUB_BASE + 16 * n
            uc.mem_write(addr, b"\xC3")
            uc.mem_write(base + iat + 8 * j, struct.pack("<Q", addr))
            stubs[addr] = nm
            n += 1
            j += 1
        d += 20

    uc.mem_map(STACK_TOP - 0x100000, 0x100000)
    uc.mem_map(HEAP, 0x10000)
    cmdline = ('"C:\\asmspeed.exe"' + "".join(" " + a for a in args)).encode() + b"\0"
    uc.mem_write(HEAP, cmdline)
    heap_next = [HEAP + 0x1000]

    socks = {}
    state = {"err": 0, "exit": None, "next": 0x100, "calls": 0}

    def rd(reg):
        return uc.reg_read(reg)

    def ret(v):
        uc.reg_write(UC_X86_REG_RAX, v & 0xFFFFFFFFFFFFFFFF)

    def sock_of(h):
        return socks[h]

    def hook(uc_, address, size, _):
        name = stubs.get(address)
        if name is None:
            return
        rsp = rd(UC_X86_REG_RSP)
        assert rsp % 16 == 8, "%s called with misaligned stack (rsp=%#x)" % (name, rsp)
        rcx, rdx, r8, r9 = (rd(r) for r in (UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8, UC_X86_REG_R9))
        state["calls"] += 1
        if name == "WSAStartup":
            uc.mem_write(rdx, b"\0" * 408)
            ret(0)
        elif name == "QueryPerformanceFrequency":
            uc.mem_write(rcx, struct.pack("<Q", 10_000_000))
            ret(1)
        elif name == "QueryPerformanceCounter":
            uc.mem_write(rcx, struct.pack("<Q", time.perf_counter_ns() // 100))
            ret(1)
        elif name == "GetCommandLineA":
            ret(HEAP)
        elif name == "GetStdHandle":
            assert rcx & 0xFFFFFFFF == 0xFFFFFFF5
            ret(7)
        elif name == "WriteFile":
            assert rcx == 7
            assert struct.unpack("<Q", bytes(uc.mem_read(rsp + 0x28, 8)))[0] == 0, "lpOverlapped must be NULL"
            data = bytes(uc.mem_read(rdx, r8 & 0xFFFFFFFF))
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            uc.mem_write(r9, struct.pack("<I", len(data)))
            ret(1)
        elif name == "GetConsoleMode":
            if not sys.stdout.isatty():
                ret(0)
            else:
                uc.mem_write(rdx, struct.pack("<I", 3))
                ret(1)
        elif name == "SetConsoleMode":
            assert rdx & 4, "VT processing flag not requested"
            ret(1)
        elif name == "SetConsoleOutputCP":
            assert rcx == 65001
            ret(1)
        elif name == "Sleep":
            time.sleep((rcx & 0xFFFFFFFF) / 1000)
            ret(0)
        elif name == "gethostbyname":
            host = bytes(uc.mem_read(rcx, 128)).split(b"\0")[0].decode()
            try:
                ip = socket.inet_aton(socket.gethostbyname(host))
            except OSError:
                ret(0)
                return
            he = heap_next[0]
            heap_next[0] += 0x80
            uc.mem_write(he + 0x40, ip)
            uc.mem_write(he + 0x48, struct.pack("<QQ", he + 0x40, 0))
            uc.mem_write(he, struct.pack("<QQHHxxxxQ", 0, 0, 2, 4, he + 0x48))
            ret(he)
        elif name == "socket":
            assert (rcx, rdx, r8) == (2, 1, 6), (rcx, rdx, r8)
            h = state["next"]
            state["next"] += 4
            socks[h] = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            ret(h)
        elif name == "connect":
            s = sock_of(rcx)
            fam, port_be = struct.unpack("<HH", bytes(uc.mem_read(rdx, 4)))
            assert fam == 2 and r8 == 16
            port = ((port_be & 0xFF) << 8) | (port_be >> 8)
            ip = socket.inet_ntoa(bytes(uc.mem_read(rdx + 4, 4)))
            try:
                s.settimeout(10)
                s.connect((ip, port))
                s.setblocking(True)
                ret(0)
            except OSError:
                ret(0xFFFFFFFF)
        elif name == "ioctlsocket":
            assert rdx & 0xFFFFFFFF == 0x8004667E
            val, = struct.unpack("<I", bytes(uc.mem_read(r8, 4)))
            sock_of(rcx).setblocking(not val)
            ret(0)
        elif name == "send":
            try:
                data = bytes(uc.mem_read(rdx, r8 & 0xFFFFFFFF))
                ret(sock_of(rcx).send(data))
            except BlockingIOError:
                state["err"] = 10035
                ret(0xFFFFFFFF)
            except OSError:
                state["err"] = 10054
                ret(0xFFFFFFFF)
        elif name == "recv":
            try:
                data = sock_of(rcx).recv(r8 & 0xFFFFFFFF)
                uc.mem_write(rdx, data)
                ret(len(data))
            except BlockingIOError:
                state["err"] = 10035
                ret(0xFFFFFFFF)
            except OSError:
                state["err"] = 10054
                ret(0xFFFFFFFF)
        elif name == "WSAGetLastError":
            ret(state["err"])
        elif name == "closesocket":
            socks.pop(rcx).close()
            ret(0)
        elif name == "WSAPoll":
            cnt = rdx & 0xFFFFFFFF
            assert cnt >= 1, "WSAPoll with zero sockets fails on Windows"
            timeout = r8 & 0xFFFFFFFF
            p = select.poll()
            slots = []
            for i in range(cnt):
                fd, ev, _rev = struct.unpack("<QHH", bytes(uc.mem_read(rcx + 16 * i, 12)))
                if fd == 0xFFFFFFFFFFFFFFFF:
                    continue
                s = sock_of(fd)
                mask = (select.POLLIN if ev & 0x100 else 0) | (select.POLLOUT if ev & 0x10 else 0)
                p.register(s.fileno(), mask)
                slots.append((i, s.fileno()))
            res = dict(p.poll(timeout))
            ready = 0
            for i in range(cnt):
                uc.mem_write(rcx + 16 * i + 10, b"\0\0")
            for i, fno in slots:
                r = res.get(fno, 0)
                if r:
                    w = (0x100 if r & select.POLLIN else 0) | (0x10 if r & select.POLLOUT else 0) \
                        | (1 if r & select.POLLERR else 0) | (2 if r & select.POLLHUP else 0)
                    uc.mem_write(rcx + 16 * i + 10, struct.pack("<H", w))
                    ready += 1
            ret(ready)
        elif name == "ExitProcess":
            state["exit"] = rcx & 0xFFFFFFFF
            uc.emu_stop()
        else:
            raise RuntimeError("unimplemented import " + name)

    uc.hook_add(UC_HOOK_CODE, hook, begin=STUB_BASE, end=STUB_BASE + PAGE)

    # Process entry convention: rsp % 16 == 8 (a return address is on the stack).
    uc.reg_write(UC_X86_REG_RSP, STACK_TOP - 0x1000 - 8)
    uc.emu_start(base + entry, 0)
    sys.stderr.write("\n[emu] ExitProcess(%s) after %d Win32 calls\n" % (state["exit"], state["calls"]))
    sys.exit(0 if state["exit"] == 0 else 1 if state["exit"] is not None else 99)


if __name__ == "__main__":
    main()

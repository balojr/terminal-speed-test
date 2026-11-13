#!/usr/bin/env python3
"""Build a Windows x64 console .exe from GNU-as object files without mingw.

    mkpe.py OUT.exe BUILD_DIR OBJ [OBJ ...]

1. Lays out an import table (kernel32 + ws2_32) at a fixed RVA and writes
   linker symbols __imp_<name> that point at the IAT slots.
2. Links the objects with GNU ld into an ELF at the PE image addresses.
3. Cuts the .text and .data (rodata + data) output sections out of the ELF and
   wraps them in a PE32+ file: .idata (RW), .text (RX), .data (RW + bss).

The image has a fixed base (no relocations, no ASLR) so the code can use plain
RIP-relative addressing.
"""
import os
import struct
import subprocess
import sys

IMAGE_BASE = 0x140000000
SECT_ALIGN = 0x1000
FILE_ALIGN = 0x200
HDR_SIZE = 0x400
IDATA_RVA = 0x1000
TEXT_RVA = 0x2000

IMPORTS = [
    ("kernel32.dll", [
        "ExitProcess", "GetCommandLineA", "GetStdHandle", "WriteFile",
        "QueryPerformanceCounter", "QueryPerformanceFrequency", "Sleep",
        "GetConsoleMode", "SetConsoleMode", "SetConsoleOutputCP",
    ]),
    ("ws2_32.dll", [
        "WSAStartup", "WSAGetLastError", "WSAPoll", "gethostbyname", "socket",
        "connect", "send", "recv", "closesocket", "ioctlsocket",
    ]),
]


def align(v, a):
    return (v + a - 1) // a * a


def layout_imports():
    """Return (idata_bytes, import_dir_size, iat_rva, iat_size, {func: slot_rva})."""
    ndll = len(IMPORTS)
    off = (ndll + 1) * 20
    ilt = {}
    for dll, funcs in IMPORTS:
        ilt[dll] = off
        off += 8 * (len(funcs) + 1)
    iat_start = off
    iat = {}
    for dll, funcs in IMPORTS:
        iat[dll] = off
        off += 8 * (len(funcs) + 1)
    iat_size = off - iat_start
    hint = {}
    for dll, funcs in IMPORTS:
        for f in funcs:
            hint[f] = off
            off += align(2 + len(f) + 1, 2)
    dllname = {}
    for dll, _ in IMPORTS:
        dllname[dll] = off
        off += len(dll) + 1

    buf = bytearray(off)
    slots = {}
    for i, (dll, funcs) in enumerate(IMPORTS):
        struct.pack_into("<IIIII", buf, i * 20,
                         IDATA_RVA + ilt[dll], 0, 0,
                         IDATA_RVA + dllname[dll], IDATA_RVA + iat[dll])
        for j, f in enumerate(funcs):
            ent = IDATA_RVA + hint[f]
            struct.pack_into("<Q", buf, ilt[dll] + 8 * j, ent)
            struct.pack_into("<Q", buf, iat[dll] + 8 * j, ent)
            slots[f] = IDATA_RVA + iat[dll] + 8 * j
            struct.pack_into("<H", buf, hint[f], 0)
            buf[hint[f] + 2:hint[f] + 2 + len(f)] = f.encode()
        buf[dllname[dll]:dllname[dll] + len(dll)] = dll.encode()
    return bytes(buf), (ndll + 1) * 20, IDATA_RVA + iat_start, iat_size, slots


def run(*cmd):
    subprocess.run(cmd, check=True)


def symbols(elf):
    out = subprocess.run(["nm", elf], check=True, capture_output=True, text=True).stdout
    return {l.split()[2]: int(l.split()[0], 16) for l in out.splitlines() if len(l.split()) == 3}


def section_header(name, vsize, rva, rawsize, rawptr, flags):
    return struct.pack("<8sIIIIIIHHI", name.encode(), vsize, rva, rawsize, rawptr, 0, 0, 0, 0, flags)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    out_exe, build, objs = sys.argv[1], sys.argv[2], sys.argv[3:]
    idata, imp_size, iat_rva, iat_size, slots = layout_imports()

    ld_script = os.path.join(build, "win.ld")
    with open(ld_script, "w") as f:
        f.write("ENTRY(_start)\n")
        for name, rva in slots.items():
            f.write("__imp_%s = 0x%x;\n" % (name, IMAGE_BASE + rva))
        f.write("SECTIONS {\n")
        f.write("  . = 0x%x;\n" % (IMAGE_BASE + TEXT_RVA))
        f.write("  .text : { *(.text .text.*) }\n")
        f.write("  . = ALIGN(0x%x);\n  __data_start = .;\n" % SECT_ALIGN)
        f.write("  .data : { *(.rodata .rodata.*) *(.data .data.*) }\n")
        f.write("  .bss : { *(.bss .bss.*) *(COMMON) }\n  __image_end = .;\n")
        f.write("  /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame) }\n}\n")

    elf = os.path.join(build, "asmspeed-win.elf")
    run("ld", "-T", ld_script, "-o", elf, "-z", "noseparate-code", *objs)
    text_bin = os.path.join(build, "win.text.bin")
    data_bin = os.path.join(build, "win.data.bin")
    run("objcopy", "-O", "binary", "-j", ".text", elf, text_bin)
    run("objcopy", "-O", "binary", "-j", ".data", elf, data_bin)
    sym = symbols(elf)
    text = open(text_bin, "rb").read()
    data = open(data_bin, "rb").read()

    entry_rva = sym["_start"] - IMAGE_BASE
    data_rva = sym["__data_start"] - IMAGE_BASE
    data_vsize = sym["__image_end"] - sym["__data_start"]
    assert data_rva == align(TEXT_RVA + len(text), SECT_ALIGN), "linker/PE layout mismatch"

    idata_raw = align(len(idata), FILE_ALIGN)
    text_raw = align(len(text), FILE_ALIGN)
    data_raw = align(len(data), FILE_ALIGN)
    idata_ptr = HDR_SIZE
    text_ptr = idata_ptr + idata_raw
    data_ptr = text_ptr + text_raw
    size_of_image = align(data_rva + data_vsize, SECT_ALIGN)

    dos = bytearray(0x80)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x80)
    coff = struct.pack("<HHIIIHH", 0x8664, 3, 0, 0, 0, 0xF0, 0x0022)
    opt = struct.pack(
        "<HBBIIIIIQIIHHHHHHIIIIHHQQQQII",
        0x20B, 14, 0, text_raw, idata_raw + data_raw, 0, entry_rva, TEXT_RVA,
        IMAGE_BASE, SECT_ALIGN, FILE_ALIGN, 6, 0, 0, 0, 6, 0, 0,
        size_of_image, HDR_SIZE, 0, 3, 0x8100,
        0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    dirs = bytearray(16 * 8)
    struct.pack_into("<II", dirs, 1 * 8, IDATA_RVA, imp_size)
    struct.pack_into("<II", dirs, 12 * 8, iat_rva, iat_size)
    sections = (
        section_header(".idata", len(idata), IDATA_RVA, idata_raw, idata_ptr, 0xC0000040)
        + section_header(".text", len(text), TEXT_RVA, text_raw, text_ptr, 0x60000020)
        + section_header(".data", data_vsize, data_rva, data_raw, data_ptr, 0xC0000040)
    )
    headers = bytes(dos) + b"PE\0\0" + coff + opt + bytes(dirs) + sections
    assert len(headers) <= HDR_SIZE

    with open(out_exe, "wb") as f:
        f.write(headers.ljust(HDR_SIZE, b"\0"))
        f.write(idata.ljust(idata_raw, b"\0"))
        f.write(text.ljust(text_raw, b"\0"))
        f.write(data.ljust(data_raw, b"\0"))
    print("%s: %d bytes (text %d, data %d, bss %d)" % (
        out_exe, os.path.getsize(out_exe), len(text), len(data), data_vsize - len(data)))


if __name__ == "__main__":
    main()

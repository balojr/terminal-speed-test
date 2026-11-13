#!/usr/bin/env python3
"""Build a .deb without dpkg-deb:  mkdeb.py VERSION BINARY MANPAGE OUT.deb"""
import gzip
import io
import sys
import tarfile
import time

version, binary, manpage, out = sys.argv[1:5]
now = int(time.time())


def tar_bytes(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        for name, data, mode in entries:
            ti = tarfile.TarInfo(name)
            ti.size = len(data) if data is not None else 0
            ti.mode = mode
            ti.mtime = now
            ti.uname = ti.gname = "root"
            if data is None:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            else:
                tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


exe = open(binary, "rb").read()
man = gzip.compress(open(manpage, "rb").read(), 9, mtime=0)
dirs = ["./", "./usr/", "./usr/bin/", "./usr/share/", "./usr/share/man/", "./usr/share/man/man1/"]
data = tar_bytes([(d, None, 0o755) for d in dirs] + [
    ("./usr/bin/asmspeed", exe, 0o755),
    ("./usr/share/man/man1/asmspeed.1.gz", man, 0o644),
])
control = (
    "Package: asmspeed\n"
    "Version: %s\n"
    "Architecture: amd64\n"
    "Maintainer: asmspeed packagers <asmspeed@localhost>\n"
    "Installed-Size: %d\n"
    "Section: net\n"
    "Priority: optional\n"
    "Description: terminal internet speed test written in x86-64 assembly\n"
    " Measures latency, download and upload speed from the terminal. A single\n"
    " static executable with no libc and no dependencies; uses plain HTTP\n"
    " against speed.cloudflare.com.\n"
) % (version, (len(exe) + len(man) + 1023) // 1024)
ctrl = tar_bytes([("./", None, 0o755), ("./control", control.encode(), 0o644)])


def ar_member(name, payload):
    hdr = b"%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name.encode(), now, 0, 0, b"100644", len(payload))
    return hdr + payload + (b"\n" if len(payload) % 2 else b"")


with open(out, "wb") as f:
    f.write(b"!<arch>\n")
    f.write(ar_member("debian-binary", b"2.0\n"))
    f.write(ar_member("control.tar.gz", ctrl))
    f.write(ar_member("data.tar.gz", data))
print("built", out)

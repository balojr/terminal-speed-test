#!/bin/sh
# Install asmspeed. As root: /usr/local. Otherwise: ~/.local (make sure ~/.local/bin is on PATH).
#   ./install.sh              install
#   ./install.sh --uninstall  remove
#   PREFIX=/opt/foo ./install.sh   custom prefix
set -eu
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${PREFIX:-}" ]; then prefix=$PREFIX
elif [ "$(id -u)" -eq 0 ]; then prefix=/usr/local
else prefix=$HOME/.local; fi

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$prefix/bin/asmspeed" "$prefix/share/man/man1/asmspeed.1"
    echo "asmspeed removed from $prefix"
    exit 0
fi

install -d "$prefix/bin" "$prefix/share/man/man1"
install -m 0755 "$here/asmspeed" "$prefix/bin/asmspeed"
install -m 0644 "$here/asmspeed.1" "$prefix/share/man/man1/asmspeed.1"
echo "asmspeed installed to $prefix/bin/asmspeed"
case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "note: $prefix/bin is not on your PATH" ;; esac

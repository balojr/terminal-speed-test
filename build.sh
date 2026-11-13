#!/bin/sh
# Build asmspeed.   ./build.sh [linux|windows|test|dist|clean|all]   (default: all)
# Needs GNU binutils (as, ld, objcopy, nm) and Python 3. `dist` also wants rpmbuild and zip.
set -eu
cd "$(dirname "$0")"
VERSION=1.1.0
B=build
D=dist

linux() {
    mkdir -p $B
    as -o $B/common.o src/common.S
    as -o $B/linux.o src/linux.S
    ld -o $B/asmspeed -e _start -s -z noseparate-code -z noexecstack --build-id=sha1 $B/common.o $B/linux.o
    echo "built $B/asmspeed ($(wc -c < $B/asmspeed) bytes)"
}

windows() {
    mkdir -p $B
    as -o $B/common.o src/common.S
    as -o $B/windows.o src/windows.S
    python3 tools/mkpe.py $B/asmspeed.exe $B $B/common.o $B/windows.o
}

test_() {
    $B/asmspeed -h >/dev/null
    rc=0; $B/asmspeed -t 0 >/dev/null || rc=$?
    [ "$rc" -eq 2 ] || { echo "FAIL: bad-arg exit code $rc"; exit 1; }
    echo "smoke tests passed (run $B/asmspeed -t 3 for a live test)"
}

dist() {
    linux; windows
    mkdir -p $D
    # tarball
    rm -rf $B/pkg; mkdir -p $B/pkg/asmspeed-$VERSION
    cp $B/asmspeed packaging/asmspeed.1 packaging/install.sh README.md LICENSE $B/pkg/asmspeed-$VERSION/
    tar -C $B/pkg --owner=0 --group=0 --sort=name -czf $D/asmspeed-$VERSION-linux-x86_64.tar.gz asmspeed-$VERSION
    # windows zip
    rm -rf $B/winpkg; mkdir -p $B/winpkg/asmspeed-$VERSION
    cp $B/asmspeed.exe packaging/windows/* README.md LICENSE $B/winpkg/asmspeed-$VERSION/
    rm -f $D/asmspeed-$VERSION-windows-x64.zip
    (cd $B/winpkg && zip -qr "../../$D/asmspeed-$VERSION-windows-x64.zip" asmspeed-$VERSION)
    # deb
    python3 tools/mkdeb.py $VERSION $B/asmspeed packaging/asmspeed.1 $D/asmspeed_${VERSION}_amd64.deb
    # rpm
    if command -v rpmbuild >/dev/null; then
        mkdir -p $B/rpm
        cp packaging/asmspeed.1 $B/
        rpmbuild -bb packaging/rpm/asmspeed.spec --define "_topdir $PWD/$B/rpm" \
            --define "_sourcedir $PWD/$B" --define "_rpmdir $PWD/$D" \
            --define "_rpmfilename %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" >/dev/null
        mv $D/asmspeed-$VERSION-1*.rpm $D/asmspeed-$VERSION-1.x86_64.rpm 2>/dev/null || true
    else
        echo "rpmbuild not found, skipping .rpm"
    fi
    ls -l $D
}

case "${1:-all}" in
    linux) linux ;;
    windows) windows ;;
    test) linux; test_ ;;
    dist) dist ;;
    clean) rm -rf $B $D ;;
    all) linux; windows ;;
    *) echo "usage: $0 [linux|windows|test|dist|clean|all]"; exit 2 ;;
esac

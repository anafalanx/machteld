#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: bootstrap-deps.sh TCLTK-SOURCE PREFIX JOBS" >&2
    exit 2
fi

source_root=$1
prefix=$2
jobs=$3
tcl_source="$source_root/tcl9.0.4"
tk_source="$source_root/tk9.0.4"

if [[ ! -x "$tcl_source/win/configure" || ! -x "$tk_source/win/configure" ]]; then
    echo "Tcl/Tk 9.0.4 source directories are incomplete under $source_root" >&2
    exit 2
fi

export PATH="/ucrt64/bin:/usr/bin:$PATH"
export CC=gcc
export AR=ar
export RANLIB=ranlib
export RC=windres

mkdir -p "$prefix"

pushd "$tcl_source/win" >/dev/null
if [[ ! -f Makefile ]]; then
    ./configure --enable-64bit --disable-shared --enable-threads \
        --prefix="$prefix"
fi
# Only the core static runtime, headers, stubs, and script libraries are build
# inputs. Upstream's aggregate `all`/`install` targets also compile bundled
# extension packages and install manuals; neither is linked or packaged here.
mingw32-make -j "$jobs" binaries
mingw32-make install-binaries
mingw32-make install-libraries
mingw32-make install-headers
popd >/dev/null

pushd "$tk_source/win" >/dev/null
if [[ ! -f Makefile ]]; then
    ./configure --enable-64bit --disable-shared --enable-threads \
        --with-tcl="$tcl_source/win" --prefix="$prefix"
fi
mingw32-make -j "$jobs" binaries
mingw32-make install-binaries
mingw32-make install-libraries
popd >/dev/null

# Keep a stable layout independent of minor upstream install-name differences.
if [[ -f "$prefix/bin/tclsh90.exe" && ! -f "$prefix/bin/tclsh90s.exe" ]]; then
    cp "$prefix/bin/tclsh90.exe" "$prefix/bin/tclsh90s.exe"
fi
if [[ -f "$prefix/bin/wish90.exe" && ! -f "$prefix/bin/wish90s.exe" ]]; then
    cp "$prefix/bin/wish90.exe" "$prefix/bin/wish90s.exe"
fi

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

# The static runtime has no physical installation after packaging. Tcl's public
# ::tcl::pkgconfig values therefore describe the paths that really exist in
# every full and wrapped zipfs, rather than leaking this machine's dependency
# cache. The source-prefix map likewise keeps __FILE__ strings reproducible.
runtime_root='//zipfs:/app'
source_root_native=$(cygpath -m "$source_root")
source_root_escaped=${source_root_native// /\\ }
source_prefix_map="-ffile-prefix-map=${source_root_escaped}=tcltk-9.0.4"
tcl_pkgconfig=(
    "LIB_INSTALL_DIR_NATIVE=$runtime_root"
    "BIN_INSTALL_DIR_NATIVE=$runtime_root"
    "SCRIPT_INSTALL_DIR_NATIVE=$runtime_root/tcl_library"
    "INCLUDE_INSTALL_DIR_NATIVE=$runtime_root"
    "MAN_INSTALL_DIR_NATIVE=$runtime_root/reference"
    "libdir_native=$runtime_root"
    "bindir_native=$runtime_root"
    "TCL_LIBRARY_NATIVE=$runtime_root/tcl_library"
    "includedir_native=$runtime_root"
    "mandir_native=$runtime_root/reference"
)

pushd "$tcl_source/win" >/dev/null
if [[ ! -f Makefile ]]; then
    ./configure --enable-64bit --disable-shared --enable-threads \
        --prefix="$prefix"
fi
# Only the core static runtime, headers, stubs, and script libraries are build
# inputs. Upstream's aggregate `all`/`install` targets also compile bundled
# extension packages and install manuals; neither is linked or packaged here.
mingw32-make -j "$jobs" binaries \
    "CFLAGS_OPTIMIZE=-O2 -fomit-frame-pointer $source_prefix_map" \
    "${tcl_pkgconfig[@]}"
# Do not pass the virtual runtime paths to installation: these targets stage
# the already-built files into the real dependency cache.
mingw32-make install-binaries
mingw32-make install-libraries
mingw32-make install-headers
popd >/dev/null

pushd "$tk_source/win" >/dev/null
if [[ ! -f Makefile ]]; then
    ./configure --enable-64bit --disable-shared --enable-threads \
        --with-tcl="$tcl_source/win" --prefix="$prefix"
fi
mingw32-make -j "$jobs" binaries \
    "CFLAGS_OPTIMIZE=-O2 -fomit-frame-pointer $source_prefix_map"
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

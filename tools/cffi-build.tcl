# CFFI's Win64 synchronous-call backend. Sourced by bootstrap.tcl.
namespace eval ::boot {}

proc ::boot::applyCffiPatch {sourceRoot patch} {
    variable root
    set patchPath [file join $root tools [dict get $patch file]]
    assertHash $patchPath [dict get $patch sha256] [dict get $patch id]
    set lines [split [readText $patchPath] \n]
    set sections {}
    foreach i [lsearch -all -glob $lines {--- a/*}] {
        lappend sections $i
    }
    set targets [dict get $patch targets]
    if {[llength $sections] != [llength $targets]} {
        fail "wrong number of file sections in $patchPath"
    }
    set part [file join $sourceRoot cffi-section.patch]
    try {
        foreach target $targets start $sections end [concat [lrange $sections 1 end] [llength $lines]] {
            set relative [dict get $target target]
            set path [file join $sourceRoot $relative]
            assertUnderCache $path
            assertHash $path [dict get $target beforeSha256] "$relative patch input"
            writeText $part [join [lrange $lines $start [expr {$end - 1}]] \n]
            applyPinnedUnifiedPatch $part $path $relative
            assertHash $path [dict get $target afterSha256] "$relative patch output"
        }
    } finally {
        file delete $part
    }
}

proc ::boot::stageCffi {sourceRoot archives patches} {
    variable cache
    variable root
    foreach id {cffi tclh libffi} {
        set entry [dict get $archives $id]
        unpack [getDownload $entry] $sourceRoot
        set source [file join $sourceRoot [dict get $entry directory]]
        set notice [dict get $entry notice]
        assertHash [file join $source LICENSE] [dict get $notice sha256] "$id source notice"
        assertHash [file join $root licenses [dict get $notice file]] [dict get $notice sha256] "$id distributed notice"
    }
    foreach patch $patches {
        if {[string match cffi-* [dict get $patch id]]} {
            applyCffiPatch $sourceRoot $patch
        }
    }
    set man [file join $sourceRoot [dict get $archives cffi directory] doc man man3]
    file mkdir [file join $cache cffi-doc]
    foreach page {cffi.3tcl cffi-cffi.3tcl cffi-Concepts.3tcl cffi-Cookbook.3tcl} {
        file copy -force [file join $man $page] [file join $cache cffi-doc $page]
    }
}

proc ::boot::buildCffi {msys home sourceRoot prefix archives} {
    set cffi [file join $sourceRoot [dict get $archives cffi directory]]
    set ffi [file join $sourceRoot [dict get $archives libffi directory]]
    set tclh [file join $sourceRoot [dict get $archives tclh directory] include]
    set target x86_64-w64-mingw32
    # Generate upstream's ABI and assembler configuration for this exact compiler.
    msysRun $msys $home $ffi "./configure --host=$target --build=$target --disable-shared --enable-static --disable-docs --disable-multi-os-directory --disable-dependency-tracking MAKE=mingw32-make CFLAGS=-O2"
    set config [file join $ffi $target]
    set generated [file join $config include]
    # Depending on MSYS2 symlink support, configure links or copies this header.
    assertHash [file join $generated ffitarget.h] \
        [hash file sha256 [file join $ffi src x86 ffitarget.h]] "configured Win64 ABI header"
    set objdir [file join $sourceRoot cffi-objects]
    file mkdir $objdir
    set bin [file join $msys ucrt64 bin]
    set flags [list -O2 -std=gnu99 -ffunction-sections -fdata-sections -DCFFI_DISABLE_CALLBACKS \
                   "-ffile-prefix-map=[file normalize $sourceRoot]=vendor" -I$generated]
    set ffiFlags [list -I$config -I[file join $ffi include] -I[file join $ffi src]]
    set cffiFlags [list -DSTATIC_BUILD=1 -DCFFI_USE_LIBFFI -DTCL_NO_DEPRECATED \
                       {-DPACKAGE_NAME="cffi"} {-DPACKAGE_VERSION="2.0.3"} -I$tclh -I[file join $prefix include]]
    set sources {tclCffi tclCffiAlias tclCffiArena tclCffiEnum tclCffiFunction
        tclCffiHelp tclCffiInterface tclCffiLibffi tclCffiLoad tclCffiMemory
        tclCffiNames tclCffiPointer tclCffiPrototype tclCffiStruct tclCffiTclh
        tclCffiTypes tclCffiWrapper}
    # Link only the Win64 outbound ABI, types, and cif preparer. The closure,
    # executable allocator and trampoline sources are absent from the archive.
    foreach {name srcDir extra units} [list ffi $ffi $ffiFlags \
            {src/types.c src/prep_cif.c src/x86/ffiw64.c src/x86/win64.S} \
            cffi $cffi $cffiFlags [lmap name $sources {format "generic/%s.c" $name}]] {
        set objects {}
        foreach unit $units {
            set obj [file join $objdir [file rootname [file tail $unit]].o]
            set args [list [file join $bin gcc.exe] {*}$flags {*}$extra -c $unit -o $obj]
            set result [run -dir $srcDir -env [msysEnvironment $msys $home] -- {*}$args]
            if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
                fail "compiling $unit: [encoding convertfrom utf-8 [dict get $result err]]"
            }
            lappend objects $obj
        }
        set lib [file join $prefix lib lib${name}.a]
        set result [run -env [msysEnvironment $msys $home] -- [file join $bin ar.exe] rcsD $lib {*}$objects]
        if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
            fail "archiving $lib: [encoding convertfrom utf-8 [dict get $result err]]"
        }
    }
}

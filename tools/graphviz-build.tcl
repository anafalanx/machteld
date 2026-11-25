# Static dot layout and xdot output, built from the locked upstream sources.
namespace eval ::boot {}

proc ::boot::stageGraphviz {sourceRoot archives} {
    variable root
    foreach id {graphviz expat} {
        set entry [dict get $archives $id]
        set directory [dict get $entry directory]
        # The unneeded Unix packaging directories contain privileged symlinks.
        set members {COPYING lib}
        if {$id eq "graphviz"} { lappend members plugin graphviz_version.h builddate.h }
        unpack [getDownload $entry] $sourceRoot {*}[lmap member $members {file join $directory $member}]
        set notice [dict get $entry notice]
        foreach path [list [file join $sourceRoot $directory COPYING] [file join $root licenses [dict get $notice file]]] {
            assertHash $path [dict get $notice sha256] "$id notice"
        }
    }
}

# Retrieve literal source/header lists from the release's Automake files.
proc ::boot::graphvizFiles {makefile variable} {
    set flat [string map [list "\\\n" " "] $makefile]
    foreach line [split $flat \n] {
        if {[regexp {^([[:alnum:]_]+)[ \t]*=[ \t]*(.*)$} $line -> key items] && $key eq $variable} {
            return [regexp -all -inline {\S+} $items]
        }
    }
    return {}
}

proc ::boot::buildGraphviz {msys home sourceRoot prefix archives jobs} {
    set graphviz [file join .. [dict get $archives graphviz directory]]
    set expat [file join .. [dict get $archives expat directory] lib]
    set work [file join $sourceRoot graphviz-build]
    set include [file join $prefix include graphviz]
    file mkdir $work $include
    # Win64 UCRT feature decisions from the tested dot/ortho/HTML/xdot profile.
    writeText [file join $work config.h] {#pragma once
#define DEFAULT_DPI 96
#include "graphviz_version.h"
#define HAVE_CLOSEDIR 1
#define HAVE_DIRENT_H 1
#define HAVE_DECL_CYGWIN_CONV_PATH 0
#define HAVE_INTTYPES_H 1
#define HAVE_OPENDIR 1
#define HAVE_PRELOADED_SYMBOLS 1
#define HAVE_READDIR 1
#define HAVE_SETMODE 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_EXPAT 1
#define ORTHO 1
#define WITH_CGRAPH 1
#define X_DISPLAY_MISSING 1
#define _FILE_OFFSET_BITS 64
#define __error_t_defined 1
#define error_t int
}
    writeText [file join $work expat_config.h] {#pragma once
#define BYTEORDER 1234
#define XML_CONTEXT_BYTES 1024
#define XML_GE 1
}
    set parts {cdt cgraph common gvc dotgen pack pathplan label xdot util ortho}
    set flags [list -Os -DNDEBUG -DXML_STATIC -ffunction-sections -fdata-sections -I. -I$expat -I$graphviz -I$graphviz/lib]
    foreach part $parts { lappend flags -I$graphviz/lib/$part }
    set units {}
    foreach part [concat $parts gvplugin_dot_layout] {
        set directory [expr {$part eq "gvplugin_dot_layout" ? "$graphviz/plugin/dot_layout" : "$graphviz/lib/$part"}]
        set makefile [readText [file join $work $directory Makefile.am]]
        foreach header [graphvizFiles $makefile pkginclude_HEADERS] {
            file copy -force [file join $work $directory $header] $include
        }
        set files [graphvizFiles $makefile [format lib%s_C_la_SOURCES $part]]
        if {![llength $files]} { fail "missing Graphviz source list for $part" }
        foreach file $files {
            if {[file extension $file] in {.c .y .l}} {
                set stem [file rootname $file]
                dict set units [format %s_%s.o $part $stem] $directory/$stem.c
            }
        }
    }
    # Only register the two upstream DOT-family device and renderer entries.
    writeText [file join $work dot-registry.c] {#include <stddef.h>
#include <gvc/gvplugin.h>
extern gvplugin_installed_t gvdevice_dot_types[];
extern gvplugin_installed_t gvrender_dot_types[];
static gvplugin_api_t apis[] = {
    {API_device, gvdevice_dot_types}, {API_render, gvrender_dot_types}, {(api_t)0, NULL}
};
gvplugin_library_t gvplugin_core_LTX_library = {"core", apis};
}
    dict set units core_registry.o dot-registry.c
    dict set units core_dot.o $graphviz/plugin/core/gvrender_core_dot.c
    foreach name {xmlparse xmlrole xmltok random_rand_s} { dict set units expat_$name.o $expat/$name.c }
    # Relative input paths and ordered archive members are identical on both hosts.
    set makefile "all: libmachteldgraphviz.a\nlibmachteldgraphviz.a: [join [dict keys $units]]\n\tar rcsD \$@ \$^\n"
    dict for {obj src} $units {
        append makefile "$obj: $src\n\tgcc [join $flags] -c \$< -o \$@\n"
    }
    writeText [file join $work Makefile] $makefile
    set make [file join $msys ucrt64 bin mingw32-make.exe]
    set result [run -timeout 30m -dir $work -env [msysEnvironment $msys $home] -- $make -j$jobs]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
        fail "building static Graphviz: [encoding convertfrom utf-8 [dict get $result err]]"
    }
    file copy -force [file join $work libmachteldgraphviz.a] [file join $prefix lib]
}

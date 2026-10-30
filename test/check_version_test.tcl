# Standalone regression gate: bundled static Tcl 9; no runtime/build needed.
# machteld's version is one natural number (22 the first); the releases before
# it were dotted (0.21 the last), so a stale claim can have either form.
set ROOT [file dirname [file dirname [file normalize [info script]]]]
set checker [file join $ROOT tools check_version.tcl]
set checks 0
set failures 0

proc bytes {path value} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    try { puts -nonewline $channel $value } finally { close $channel }
}
proc text {path value} {
    bytes $path [encoding convertto -profile strict utf-8 $value]
}
proc check {name pass {detail {}}} {
    incr ::checks
    if {$pass} { puts "ok $name" } else {
        incr ::failures
        puts "FAIL $name: $detail"
    }
}
proc fixture {changes {current 22}} {
    incr ::serial
    set root [file join $::work case-$::serial]
    set files [dict create \
        src/machteld.h "#define MACHTELD_VERSION \"$current\"\n" \
        tcl/machteld.tcl "namespace eval ::machteld \{\n    variable version $current\n\}\n" \
        README.md "# Machteld\nMachteld $current is the runtime.\n" \
        docs/roadmap.md "---\ndescription: Current Machteld $current development.\n---\n\n## $current development\n"]
    dict for {name value} [dict merge $files $changes] { text [file join $root $name] $value }
    return $root
}
proc run {root} {
    set code [catch {exec [info nameofexecutable] $::checker --root $root 2>@1} result options]
    if {$code} {
        set status [dict get $options -errorcode]
        if {[llength $status] != 3 || [lindex $status 0] ne "CHILDSTATUS" || [lindex $status 2] ne "1"} {
            error "checker did not exit normally with status 1: $result"
        }
    }
    return [list $code $result]
}
proc case {name changes expected {current 22}} {
    lassign [run [fixture $changes $current]] code result
    if {$expected eq {}} {
        check $name [expr {!$code}] $result
    } else {
        check $name [expr {$code && [string match $expected $result]}] $result
    }
}

set marker [file tempfile claim [file join $env(TEMP) machteld-version-gate-]]
set work ${claim}.d
if {[file exists $work]} { close $marker; error "test namespace collision: $work" }
file mkdir $work
set serial 0
set begin {<!-- machteld-version-history: begin -->}
set end {<!-- machteld-version-history: end -->}
set currentMarker {<!-- machteld-version-current -->}
try {
    case "current minimal checkout" {} {}
    case "single-digit natural versions are supported" {} {} 9
    case "longer natural versions are supported" {} {} 105
    case "dotted header version is refused" [dict create src/machteld.h "#define MACHTELD_VERSION \"0.22\"\n"] {*one canonical MACHTELD_VERSION*}
    case "zero-padded header version is refused" [dict create src/machteld.h "#define MACHTELD_VERSION \"022\"\n"] {*one canonical MACHTELD_VERSION*}
    case "dotted prelude version is refused" [dict create tcl/machteld.tcl "variable version 22.0\n"] {*one canonical version variable*}
    case "stale named README claim" [dict create README.md {Machteld 21 is current.}] {*README.md:1 claims 21*}
    case "stale dotted claim" [dict create README.md {Machteld 0.21 is current.}] {*claims 0.21*}
    case "stale longer number" [dict create README.md {Machteld 220 is current.}] {*claims 220*}
    case "stale three-part claim" [dict create README.md {Machteld 0.20.1 is current.}] {*claims 0.20.1*}
    case "stale formatted named claim" [dict create README.md {Machteld version `21` is current.}] {*claims 21*}
    case "stale exact package requirement" [dict create README.md {package require -exact machteld 21}] {*claims 21*}
    case "stale package floor" [dict create README.md {package require machteld 21-}] {*claims 21*}
    case "stale package range" [dict create README.md {package require machteld 21-23}] {*claims 21*}
    case "current floor and range agree" [dict create README.md "package require machteld 22-\npackage require machteld 22-24\n"] {}
    case "stale standalone Version prose" [dict create README.md {Version 21 is the runtime.}] {*claims 21*}
    case "stale runtime version prose" [dict create README.md {The runtime version 21 is embedded.}] {*claims 21*}
    case "stale numeric heading" [dict create README.md {## 21 consolidation}] {*claims 21*}
    case "stale v-prefixed heading" [dict create README.md {## v21 consolidation}] {*claims 21*}
    case "stale version-labelled heading" [dict create README.md {## Version 21 consolidation}] {*claims 21*}
    case "stale dotted heading" [dict create README.md {## 0.21 consolidation}] {*claims 0.21*}
    case "numbered headings enumerate, they claim no version" [dict create README.md "### 1. Typed JSON\n### 2) Redirects\n"] {}
    case "a numbered roadmap heading is not the current section" [dict create docs/roadmap.md {## 22. development}] {*no current-version heading*}
    case "roadmap metadata is checked" [dict create docs/roadmap.md "---\ndescription: Machteld 21 plans.\n---\n## 22 development\n"] {*docs/roadmap.md:2 claims 21*}
    case "nested documentation is checked" [dict create docs/deep/nested/page.md {Machteld 21}] {*docs/deep/nested/page.md:1 claims 21*}
    case "root handoff is checked" [dict create HANDOFF.md {Machteld 0.21}] {*HANDOFF.md:1 claims 0.21*}
    case "nested example README is checked" [dict create examples/deep/tool/README.md {package require machteld 21-}] {*examples/deep/tool/README.md:1 claims 21*}
    case "dependency and link versions are not runtime claims" [dict create README.md {Tcl/Tk 9.0.4, yyjson 0.12.0, SQLite 3.53.4, [license](yyjson-0.12.0.txt).}] {}
    case "app versions and measured numbers are not runtime claims" [dict create README.md {The sample uses -appversion 0.42 and application version 7. It takes 25 seconds on build 26200, x64.}] {}
    case "example version-first heading belongs to the application" [dict create examples/tool/README.md "## 0.42 sample application\n## 7 sample application\n"] {}
    case "fenced inert app manifest version is not runtime prose" [dict create README.md "```tcl\nversion 1.0\nversion 7\n```\n"] {}
    case "fenced package requirements remain runtime claims" [dict create README.md "```tcl\npackage require machteld 21-\n```\n"] {*claims 21*}
    case "tilde-fenced app version is not runtime prose" [dict create README.md "~~~~tcl\nversion 1.0\n~~~~\n"] {}
    case "short inner fence cannot turn app value into prose" [dict create README.md "````tcl\n```\nversion 1.0\n````\n"] {}
    case "claims after a matching fence remain checked" [dict create README.md "```tcl\nversion 1.0\n```\nVersion 21 is current.\n"] {*claims 21*}
    case "annotation examples inside code are inert" [dict create README.md "```html\n$begin\n```\nMachteld 22\n"] {}
    case "roadmap heading inside code is not current section" [dict create docs/roadmap.md "```markdown\n## 22 development\n```\n"] {*no current-version heading outside history*}
    case "dependency does not exempt same-line stale claim" [dict create README.md {yyjson 0.12.0 is built into Machteld 21.}] {*claims 21*}
    case "app version does not exempt same-line stale claim" [dict create README.md {Use -appversion 0.42 with Machteld 21.}] {*claims 21*}
    case "one matching claim does not hide another stale claim" [dict create README.md {Machteld 22 supersedes Machteld 0.21.}] {*claims 0.21*}
    case "explicit historical prose retains old releases" [dict create docs/history.md "$begin\n## 0.21 consolidation\nMachteld 0.11.0 preceded Machteld 0.21.\n$end\nMachteld 22 is current.\n"] {}
    case "history does not exempt following current prose" [dict create docs/history.md "$begin\nMachteld 0.11.0 was released.\n$end\nMachteld 0.21 is current.\n"] {*docs/history.md:4 claims 0.21*}
    case "history cannot supply the current roadmap heading" [dict create docs/roadmap.md "$begin\n## 22 released\n$end\n"] {*no current-version heading outside history*}
    case "roadmap heading matches the exact version" [dict create docs/roadmap.md {## 0x22 development}] {*no current-version heading*}
    case "roadmap heading number joined to a word is not a version" [dict create docs/roadmap.md {## 22x development}] {*no current-version heading*}
    case "missing roadmap is rejected" [dict create docs/roadmap.md {}] {*no current-version heading*}
    case "current marker checks otherwise ambiguous values" [dict create README.md "Returns 21. $currentMarker"] {*claims 21*}
    case "current marker accepts matching bare value" [dict create README.md "Returns 22; $currentMarker"] {}
    case "current marker checks every version on its line" [dict create README.md "22 / 0.21 $currentMarker"] {*claims 0.21*}
    case "current marker ignores numbers inside words" [dict create README.md "Returns 22 on x64; $currentMarker"] {}
    case "empty current marker is rejected" [dict create README.md "No version here. $currentMarker"] {*current annotation has no version*}
    case "duplicate current marker is rejected" [dict create README.md "22 $currentMarker $currentMarker"] {*malformed version annotation*}
    case "current marker is forbidden inside history" [dict create README.md "$begin\n22 $currentMarker\n$end\n"] {*current annotation inside version history*}
    case "unclosed history is rejected" [dict create README.md "$begin\nMachteld 0.21\n"] {*unterminated version history*}
    case "unmatched history end is rejected" [dict create README.md $end] {*unmatched version history end*}
    case "nested history is rejected" [dict create README.md "$begin\n$begin\n$end\n$end\n"] {*nested version history*}
    case "misspelled history annotation is rejected" [dict create README.md {<!-- machteld-version-history: start -->}] {*malformed version annotation*}
    case "miscased history annotation is rejected" [dict create README.md {<!-- Machteld-version-history: begin -->}] {*malformed version annotation*}
    case "inline history annotation is rejected" [dict create README.md "Machteld 21 $begin"] {*malformed version annotation*}
    case "front matter cannot be marked history" [dict create docs/roadmap.md "---\n$begin\ndescription: Machteld 21\n---\n$end\n## 22 development\n"] {*annotations are forbidden in front matter*}
    case "unclosed front matter is rejected" [dict create README.md "---\ntitle: Current\n"] {*unterminated front matter*}
    case "prelude mismatch is rejected" [dict create tcl/machteld.tcl {variable version 21}] {*declares 21 but src/machteld.h declares 22*}
    case "literal launcher pin is rejected" [dict create tcl/machteld.tcl "variable version 22\npackage require machteld 22\n"] {*literal launcher pin*}
    case "literal exact launcher pin is rejected" [dict create tcl/machteld.tcl "variable version 22\npackage require -exact machteld 22\n"] {*literal launcher pin*}
    case "derived launcher pin remains allowed" [dict create tcl/machteld.tcl {variable version 22
package require machteld $::machteld::version}] {}
    case "duplicate header declarations are rejected" [dict create src/machteld.h "#define MACHTELD_VERSION \"22\"\n#define MACHTELD_VERSION \"22\"\n"] {*one canonical MACHTELD_VERSION*}
    case "duplicate prelude declarations are rejected" [dict create tcl/machteld.tcl "variable version 22\nvariable version 22\n"] {*one canonical version variable*}
    case "non-ASCII UTF-8 prose is accepted" [dict create README.md "Machteld 22 — Vincent Vercauteren; héél duidelijk.\n"] {}
    case "CRLF claims remain checked" [dict create README.md "# Machteld\r\nMachteld 21\r\n"] {*README.md:2 claims 21*}
    foreach name {README.md docs/roadmap.md docs/deep/page.md examples/tool/README.md src/machteld.h tcl/machteld.tcl} {
        set root [fixture {}]
        bytes [file join $root $name] [binary format H* ff]
        lassign [run $root] code result
        check "strict UTF-8 in $name" [expr {$code && [string match {*not valid UTF-8*} $result]}] $result
    }
} finally {
    close $marker
    # These exact paths were reserved by tempfile in this test. Never delete a
    # caller-supplied checkout; only the owned fixture directory and marker.
    file delete -force $work
    file delete $claim
}
puts "check_version_test: $checks checks, $failures failures"
if {$failures} { exit 1 }

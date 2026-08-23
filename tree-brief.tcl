package require machteld 0.10.0

# A compact, read-only folder summary built with Machteld's documented
# command-line parser and deterministic tree walker.
set spec {
    --depth {type int default 3 min 0 max 32 help "maximum directory depth to inspect"}
    --top   {type int default 5 min 0 max 50 help "number of largest files to show"}
    path    {type string default . help "folder to survey"}
}

set options [cli parse $argv $spec]
if {[dict get $options help]} {
    puts [cli usage $spec tree-brief]
    exit 0
}

set root [file normalize [dict get $options path]]
if {![file isdirectory $root]} {
    puts stderr "tree-brief: not a directory: $root"
    exit 2
}

proc human_bytes {value} {
    set units {B KiB MiB GiB TiB}
    set amount [expr {double($value)}]
    set unit 0
    while {$amount >= 1024.0 && $unit < 4} {
        set amount [expr {$amount / 1024.0}]
        incr unit
    }
    if {$unit == 0} {
        return "$value B"
    }
    return [format "%.1f %s" $amount [lindex $units $unit]]
}

set depth [dict get $options depth]
set survey [dirs $root -depth $depth -prune {.git node_modules .venv __pycache__ out build dist}]

set files 0
set bytes 0
set largest {}
set folders [lsort -unique [linsert [dict get $survey paths] 0 $root]]
foreach folder $folders {
    if {[catch {glob -nocomplain -directory $folder -types f *} paths]} {
        continue
    }
    foreach path $paths {
        incr files
        if {![catch {file size $path} size]} {
            incr bytes $size
            lappend largest [list $size $path]
        }
    }
}

puts "Tree brief"
puts "Root:        $root"
puts "Depth:       $depth (walk reached [dict get $survey maxdepth])"
puts "Directories: [dict get $survey dirs]"
puts "Files:       $files"
puts "Total size:  [human_bytes $bytes] ($bytes bytes)"

set errors [dict get $survey errors]
if {[llength $errors] > 0} {
    puts "Warnings:    [llength $errors] unreadable path(s)"
}
if {[dict get $survey pruned]} {
    puts "Note:        common generated and dependency folders were skipped"
}
if {[dict get $survey depthlimited]} {
    puts "Note:        deeper content was omitted by --depth"
}

set top [dict get $options top]
if {$top > 0 && [llength $largest] > 0} {
    puts ""
    puts "Largest files:"
    set ordered [lsort -integer -decreasing -index 0 $largest]
    foreach row [lrange $ordered 0 [expr {$top - 1}]] {
        lassign $row size path
        puts "  [human_bytes $size]\t$path"
    }
}

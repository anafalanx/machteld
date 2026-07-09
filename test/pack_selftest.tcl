# pack_selftest.tcl -- run under machteld.exe to exercise the SELF-CONTAINED wrap
# verb: the Tcl/Tk libraries and both basekits ride inside machteld.exe, so this
# needs no external toolchain or --basekit. Produces console + GUI exes of the
# throwaway hello tool next to machteld.exe; running one confirms the mechanism.
#   machteld.exe test/pack_selftest.tcl
set here   [file dirname [file normalize [info script]]]
set outdir [file dirname [info nameofexecutable]]
foreach {kind flag} {console --console gui --gui} {
    set out [file join $outdir hello_self_$kind.exe]
    ::machteld::wrap [file join $here hello_tool] -o $out $flag
    puts "wrapped $kind -> [file tail $out] ([file size $out] bytes)"
}
puts "self-contained wrap OK"

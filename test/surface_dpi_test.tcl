package require machteld 30-
package require cffi
if {[llength $argv] ni {1 2}} {error "usage: surface_dpi_test.tcl monitorFixture ?--per-monitor?"}
lassign $argv fixture mode
if {$mode ni {{} --per-monitor}} {error "unknown display mode $mode"}
set user [cffi::Wrapper new user32.dll]
# The supported runtime is x64. These two Win32 pseudo-handle APIs require
# native pointer-sized integers, including the negative DPI context constant.
$user function SetThreadDpiAwarenessContext longlong {ctx longlong}
$user function SetWindowPos int {window longlong anchor longlong x int y int w int h int flags uint}
if {$mode eq "--per-monitor"} {
    set initial [SetThreadDpiAwarenessContext -4]
    if {!$initial} {error "Windows could not enable per-monitor awareness on the test thread"}
}
package require Tk
try {
    set s [::machteld::surface d2d .drawing -width 220 -height 140]
    set t [::machteld::surface d3d .triangle -width 220 -height 140]
    pack $s $t -side left
    update
    set hwnd [wm frame .]
    set displays [split [string trim [exec -- $fixture]] \n]
    foreach display $displays {
        lassign $display left top right bottom dpiX dpiY
        # Position only our own hidden-desktop window using physical desktop
        # coordinates. Restore the Tk thread's DPI context immediately.
        set previous [SetThreadDpiAwarenessContext -4]
        try {
            if {![SetWindowPos $hwnd 0 [expr {($left+$right)/2-220}] [expr {($top+$bottom)/2-70}] 0 0 21]} {
                error "Windows could not move the test window"
            }
        } finally {SetThreadDpiAwarenessContext $previous}
        update
        set delay [after 32 {set ::settled 1}]
        try {vwait ::settled} finally {after cancel $delay}
        if {[string trim [exec -- $fixture $hwnd]] ne $display} {error "test window did not reach monitor $display"}
        $s draw #102030 {{rect 10 10 16 16 #ee4433}}
        $t draw #405060 {}
        set info [$s info]
        set dpi [dict get $info dpi]
        set p [expr {round(16*$dpi/96.)}]
        if {[$s pixels [list {0 0} [list $p $p]]] ne {{#102030ff} #ee4433ff} ||
            [$t pixels {{0 0}}] ne {{#405060ff}}} {error "incorrect back-buffer pixels on monitor $display"}
        if {$mode eq "--per-monitor" && ($dpi != $dpiX || [dict get [$t info] dpi] != $dpiX)} {
            error "aware surface DPI $dpi disagrees with the monitor $dpiX"
        }
        puts "surface monitor DPI $dpiX x $dpiY, window DPI $dpi, mode [expr {$mode eq {} ? {default} : {per-monitor}}], pixels verified"
    }
    puts "surface DPI passed on [llength $displays] display(s)"
} finally {
    destroy .
    if {[info exists initial]} {SetThreadDpiAwarenessContext $initial}
    $user destroy
}

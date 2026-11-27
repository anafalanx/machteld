namespace eval ::cards {}

proc ::cards::fieldName {field} {
    set names [dict create shelf Shelf id {Inventory ID}]
    if {![dict exists $names $field]} {
        return -code error -errorcode {CARDS FIELD UNKNOWN} "unknown field '$field'"
    }
    return [dict get $names $field]
}
package provide cards::fields 1.0

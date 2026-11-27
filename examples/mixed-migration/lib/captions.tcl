namespace eval ::cards {}
proc ::cards::caption {field value} {
    tailcall ::application::captions::caption $field $value
}
package provide cards::captions 1.0

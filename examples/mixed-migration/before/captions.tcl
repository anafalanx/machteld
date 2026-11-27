package require cards::fields 1.0
proc ::cards::caption {field value} {
    return "[::cards::fieldName $field]: $value"
}
package provide cards::captions 1.0

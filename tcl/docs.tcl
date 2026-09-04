# docs.tcl -- immutable, agent-oriented access to the reference in this exe.
#
# Catalogs are inert Tcl dict serializations, never programs.  Every path is
# resolved below the identity-checked payload root supplied by the native host.

namespace eval ::machteld {
    variable DOCS_CATALOG {}
    variable DOCS_SEARCH {}
    variable DOCS_LOADED 0
    variable DOCS_SEARCH_LOADED 0
}

proc ::machteld::DocsFail {code message} {
    return -code error -errorcode [list MACHTELD DOCS $code] $message
}

proc ::machteld::DocsReadUtf8 {path {label "reference data"}} {
    set channel ""
    if {[catch {
        set channel [open $path rb]
        set bytes [read $channel]
        close $channel
        set channel ""
        set text [encoding convertfrom -profile strict utf-8 $bytes]
    } message]} {
        if {$channel ne ""} { catch {close $channel} }
        DocsFail corrupt "docs: cannot read embedded $label: $message"
    }
    return $text
}

proc ::machteld::DocsRoot {} {
    if {[info commands ::machteld::PayloadRoot] eq ""} {
        DocsFail unsupported "docs: this host has no trusted embedded reference root"
    }
    if {[catch {::machteld::PayloadRoot} root]} {
        DocsFail unsupported "docs: the trusted embedded reference root is unavailable"
    }
    set reference [file join $root reference]
    if {[catch {file system $reference} filesystem] || $filesystem ne "zipfs zip" ||
            ![file isdirectory $reference]} {
        DocsFail unsupported "docs: this executable carries no embedded reference pack"
    }
    return $reference
}

proc ::machteld::DocsSafeRelative {path} {
    if {$path eq "" || [string length $path] > 32767} { return 0 }
    if {[catch {file pathtype $path} pathType] || $pathType ne "relative"} { return 0 }
    if {[regexp {[\x00-\x1f\x7f]} $path] ||
            [string first "\\" $path] >= 0 || [string first ":" $path] >= 0 ||
            [string first "//" $path] >= 0 || [string index $path end] eq "/"} { return 0 }
    if {[catch {file split $path} parts] ||
            [catch {file join {*}$parts} joined] ||
            $path ne [string map {\\ /} $joined]} { return 0 }
    if {![llength $parts]} { return 0 }
    foreach part $parts {
        if {$part in {. .. ""}} { return 0 }
    }
    return 1
}

proc ::machteld::DocsValidateHash {value where} {
    if {![regexp {^[0-9a-f]{64}$} $value]} {
        DocsFail corrupt "docs: invalid SHA-256 in $where"
    }
}

proc ::machteld::DocsNonnegative {value where} {
    if {[string length $value] > 10 || ![regexp {^(0|[1-9][0-9]*)$} $value] ||
            $value > 2147483647} {
        DocsFail corrupt "docs: invalid nonnegative integer in $where"
    }
}

proc ::machteld::DocsNormalizeAlias {value} {
    set value [string tolower [string trim $value]]
    regsub -all {\s+} $value { } value
    return $value
}

proc ::machteld::DocsUniqueDict {value where} {
    if {[catch {llength $value} length] || $length % 2} {
        DocsFail corrupt "docs: $where is not an inert dict"
    }
    set seen {}
    foreach {key ignored} $value {
        if {[dict exists $seen $key]} { DocsFail corrupt "docs: duplicate key in $where" }
        dict set seen $key 1
    }
    return [expr {$length / 2}]
}

proc ::machteld::DocsJoin {relative} {
    if {![DocsSafeRelative $relative]} {
        DocsFail corrupt "docs: unsafe reference path in catalog"
    }
    return [file join [DocsRoot] {*}[file split $relative]]
}

proc ::machteld::DocsLoad {} {
    variable DOCS_CATALOG
    variable DOCS_LOADED
    if {$DOCS_LOADED} { return $DOCS_CATALOG }

    set path [file join [DocsRoot] catalog.dict]
    if {![file isfile $path]} { DocsFail corrupt "docs: embedded catalog.dict is missing" }
    if {[catch {file size $path} catalogBytes] || $catalogBytes <= 0 || $catalogBytes > 67108864} {
        DocsFail corrupt "docs: embedded catalog is too large"
    }
    set catalog [string trim [DocsReadUtf8 $path catalog]]
    DocsUniqueDict $catalog catalog
    if {[catch {dict size $catalog}]} { DocsFail corrupt "docs: catalog is not an inert Tcl dict" }
    set catalogKeys {aliases auxiliary corpus_sha256 documents fragments generator inventory machteld_version products schema search}
    if {[lsort [dict keys $catalog]] ne $catalogKeys} {
        DocsFail corrupt "docs: catalog fields do not match schema 1"
    }
    foreach key {schema generator machteld_version corpus_sha256 products documents aliases fragments inventory search auxiliary} {
        if {![dict exists $catalog $key]} { DocsFail corrupt "docs: catalog has no $key field" }
    }
    if {[dict get $catalog schema] ne "1"} { DocsFail corrupt "docs: unsupported catalog schema" }
    if {[dict get $catalog generator] eq "" || [string length [dict get $catalog generator]] > 256} {
        DocsFail corrupt "docs: invalid catalog generator identity"
    }
    if {[dict get $catalog machteld_version] ne [::machteld::version]} {
        DocsFail corrupt "docs: catalog version disagrees with the runtime"
    }
    DocsValidateHash [dict get $catalog corpus_sha256] catalog
    foreach key {products documents aliases fragments inventory search} {
        if {[catch {DocsUniqueDict [dict get $catalog $key] "catalog $key"}]} {
            DocsFail corrupt "docs: catalog $key field is not a dict"
        }
    }
    foreach {key maximum} {documents 10000 aliases 100000 fragments 100000 inventory 100000} {
        if {[dict size [dict get $catalog $key]] > $maximum} {
            DocsFail corrupt "docs: catalog $key inventory is too large"
        }
    }
    if {[catch {llength [dict get $catalog auxiliary]} auxiliaryCount] || $auxiliaryCount > 100000} {
        DocsFail corrupt "docs: catalog auxiliary field is not a list"
    }
    if {[lsort [dict keys [dict get $catalog products]]] ne {machteld tcl tk}} {
        DocsFail corrupt "docs: catalog products must be exactly machteld, tcl, and tk"
    }
    dict for {product facts} [dict get $catalog products] {
        if {[catch {DocsUniqueDict $facts "product $product"}] ||
                [lsort [dict keys $facts]] ne {documents manual_pages version}} {
            DocsFail corrupt "docs: invalid product facts for $product"
        }
        if {[dict get $facts version] eq "" || [string length [dict get $facts version]] > 64} {
            DocsFail corrupt "docs: invalid product version for $product"
        }
        DocsNonnegative [dict get $facts documents] "$product document count"
        DocsNonnegative [dict get $facts manual_pages] "$product manual-page count"
        if {[dict get $facts manual_pages] > [dict get $facts documents]} {
            DocsFail corrupt "docs: manual-page count exceeds document count for $product"
        }
        if {$product eq "machteld"} {
            set expectedVersion [::machteld::version]
        } else {
            set expectedVersion 9.0.4
        }
        if {[dict get $facts version] ne $expectedVersion} {
            DocsFail corrupt "docs: $product reference version disagrees with the runtime"
        }
    }

    # Validate the complete trust inventory before any representation record
    # dereferences its nested fields.
    set inventoryBytes 0
    dict for {relative facts} [dict get $catalog inventory] {
        if {![DocsSafeRelative $relative] || [catch {DocsUniqueDict $facts "inventory $relative"}] ||
                [lsort [dict keys $facts]] ne {bytes sha256}} {
            DocsFail corrupt "docs: invalid inventory entry"
        }
        DocsValidateHash [dict get $facts sha256] "inventory $relative"
        DocsNonnegative [dict get $facts bytes] "inventory $relative"
        incr inventoryBytes [dict get $facts bytes]
        if {$inventoryBytes > 2147483647} {
            DocsFail corrupt "docs: embedded reference inventory is too large"
        }
    }

    set ids {}
    set productCounts [dict create machteld 0 tcl 0 tk 0]
    set manualCounts [dict create machteld 0 tcl 0 tk 0]
    set represented {}
    dict for {id record} [dict get $catalog documents] {
        if {$id eq "" || $id ne [string tolower $id] ||
                ![regexp {^[a-z0-9][a-z0-9._/-]*$} $id] ||
                [catch {DocsUniqueDict $record "document $id"}]} {
            DocsFail corrupt "docs: invalid document id or record"
        }
        set recordKeys {bytes content_sha256 formats id names path product raw_path sections source_file source_sha256 summary title type version}
        if {[lsort [dict keys $record]] ne $recordKeys} {
            DocsFail corrupt "docs: $id fields do not match schema 1"
        }
        if {[dict get $record id] ne $id} { DocsFail corrupt "docs: document id mismatch for $id" }
        set product [dict get $record product]
        set type [dict get $record type]
        set idParts [split $id /]
        set stableSpecial [expr {$id eq "machteld/agent" && $type eq "guide" ||
            $id eq "machteld/index" && $type eq "index" ||
            $id eq "$product/license" && $type eq "license"}]
        if {![dict exists [dict get $catalog products] $product] ||
                (($stableSpecial && [llength $idParts] != 2) ||
                    (!$stableSpecial && [llength $idParts] != 3)) ||
                [lindex $idParts 0] ne $product ||
                (!$stableSpecial && [lindex $idParts 1] ne $type) || $type eq "" ||
                $type ne [string tolower $type]} {
            DocsFail corrupt "docs: unknown product for $id"
        }
        foreach part $idParts {
            if {$part in {. .. ""}} { DocsFail corrupt "docs: noncanonical document id $id" }
        }
        if {[dict get $record version] ne [dict get $catalog products $product version]} {
            DocsFail corrupt "docs: product version disagrees for $id"
        }
        foreach scalar {product version type title summary path raw_path source_file content_sha256 source_sha256 bytes} {
            if {[string length [dict get $record $scalar]] > 262144} {
                DocsFail corrupt "docs: oversized $scalar field for $id"
            }
        }
        if {[catch {llength [dict get $record names]} nameCount] || !$nameCount} {
            DocsFail corrupt "docs: invalid names for $id"
        }
        if {[catch {DocsUniqueDict [dict get $record sections] "$id sections"}] ||
                [catch {DocsUniqueDict [dict get $record formats] "$id formats"}]} {
            DocsFail corrupt "docs: invalid sections or formats for $id"
        }
        if {[string length [dict get $record title]] > 65536 ||
                [string length [dict get $record summary]] > 262144 ||
                $nameCount > 1024 ||
                [dict size [dict get $record sections]] > 4096 ||
                [dict size [dict get $record formats]] > 3 ||
                [string length [dict get $record source_file]] > 32767} {
            DocsFail corrupt "docs: oversized document metadata for $id"
        }
        foreach name [dict get $record names] {
            if {$name eq "" || [string length $name] > 65536} {
                DocsFail corrupt "docs: invalid document name for $id"
            }
        }
        dict for {slug heading} [dict get $record sections] {
            if {$slug eq "" || $slug ne [string tolower $slug] ||
                    ![regexp {^[[:alnum:]][[:alnum:]-]*$} $slug] ||
                    [string first -- $slug] >= 0 || $heading eq "" ||
                    [string length $heading] > 65536} {
                DocsFail corrupt "docs: invalid section metadata for $id"
            }
        }
        set formatCount 0
        dict for {format facts} [dict get $record formats] {
            if {$format ni {markdown html source} || [catch {DocsUniqueDict $facts "$id $format"}] ||
                    [lsort [dict keys $facts]] ne {bytes characters path sections sha256}} {
                DocsFail corrupt "docs: invalid representation for $id"
            }
            foreach field {path sha256 bytes characters sections} {
                if {![dict exists $facts $field]} { DocsFail corrupt "docs: incomplete $format representation for $id" }
            }
            set relative [dict get $facts path]
            if {![DocsSafeRelative $relative]} { DocsFail corrupt "docs: unsafe $format path for $id" }
            DocsValidateHash [dict get $facts sha256] "$id $format"
            DocsNonnegative [dict get $facts bytes] "$id $format"
            DocsNonnegative [dict get $facts characters] "$id $format characters"
            if {[dict get $facts bytes] > 67108864 || [dict get $facts characters] > 67108864} {
                DocsFail corrupt "docs: oversized $format representation for $id"
            }
            if {![dict exists [dict get $catalog inventory] $relative] ||
                    [dict get [dict get $catalog inventory] $relative sha256] ne [dict get $facts sha256] ||
                    [dict get [dict get $catalog inventory] $relative bytes] != [dict get $facts bytes]} {
                DocsFail corrupt "docs: $id $format disagrees with the inventory"
            }
            dict set represented $relative 1
            set ranges [dict get $facts sections]
            if {[catch {DocsUniqueDict $ranges "$id $format ranges"}]} {
                DocsFail corrupt "docs: invalid section ranges for $id"
            }
            set priorStart 0
            dict for {slug range} $ranges {
                if {![dict exists [dict get $record sections] $slug] ||
                        [catch {DocsUniqueDict $range "$id#$slug range"}] ||
                        [lsort [dict keys $range]] ne {end start}} {
                    DocsFail corrupt "docs: invalid section range for $id#$slug"
                }
                set start [dict get $range start]; set end [dict get $range end]
                DocsNonnegative $start "$id#$slug start"
                DocsNonnegative $end "$id#$slug end"
                # H2 spans intentionally contain their H3 spans.  Starts are
                # ordered and every individual range remains bounded.
                if {$start > $end || $start < $priorStart || $end > [dict get $facts characters]} {
                    DocsFail corrupt "docs: invalid section range ordering for $id"
                }
                set priorStart $start
            }
            incr formatCount
        }
        if {!$formatCount || ![dict exists [dict get $record formats] markdown]} {
            DocsFail corrupt "docs: $id carries no Markdown representation"
        }
        DocsValidateHash [dict get $record content_sha256] "$id content compatibility"
        DocsNonnegative [dict get $record bytes] "$id byte compatibility"
        set markdown [dict get $record formats markdown]
        if {[dict get $record path] ne [dict get $markdown path] ||
                [dict get $record content_sha256] ne [dict get $markdown sha256] ||
                [dict get $record bytes] ne [dict get $markdown bytes]} {
            DocsFail corrupt "docs: $id compatibility fields disagree with Markdown"
        }
        if {[dict exists [dict get $record formats] source]} {
            set source [dict get $record formats source]
            DocsValidateHash [dict get $record source_sha256] "$id source compatibility"
            if {[dict get $record raw_path] ne [dict get $source path] ||
                    [dict get $record source_sha256] ne [dict get $source sha256]} {
                DocsFail corrupt "docs: $id compatibility fields disagree with source"
            }
        } elseif {[dict get $record raw_path] ne "" || [dict get $record source_sha256] ne ""} {
            DocsFail corrupt "docs: $id has source compatibility facts without source"
        }
        dict set ids $id 1
        dict incr productCounts $product
        if {$type ne "license"} { dict incr manualCounts $product }
    }

    dict for {product facts} [dict get $catalog products] {
        if {[dict get $facts documents] != [dict get $productCounts $product] ||
                [dict get $facts manual_pages] != [dict get $manualCounts $product]} {
            DocsFail corrupt "docs: declared counts disagree for $product"
        }
    }
    set auxiliary {}
    if {[lsort [dict get $catalog auxiliary]] ne [dict get $catalog auxiliary]} {
        DocsFail corrupt "docs: auxiliary inventory is not ordinally sorted"
    }
    foreach relative [dict get $catalog auxiliary] {
        if {![DocsSafeRelative $relative] || ![dict exists $catalog inventory $relative] ||
                [dict exists $auxiliary $relative] || [dict exists $represented $relative]} {
            DocsFail corrupt "docs: invalid auxiliary inventory entry"
        }
        dict set auxiliary $relative 1
    }
    dict for {relative facts} [dict get $catalog inventory] {
        if {![dict exists $represented $relative] && ![dict exists $auxiliary $relative]} {
            DocsFail corrupt "docs: unclassified inventory entry $relative"
        }
    }

    dict for {alias candidates} [dict get $catalog aliases] {
        if {$alias eq "" || $alias ne [DocsNormalizeAlias $alias] || [string length $alias] > 4096 ||
                [catch {llength $candidates} candidateCount] || !$candidateCount} {
            DocsFail corrupt "docs: invalid alias entry"
        }
        if {[lsort -unique $candidates] ne [lsort $candidates]} {
            DocsFail corrupt "docs: duplicate alias target"
        }
        foreach id $candidates {
            if {![dict exists $ids $id]} { DocsFail corrupt "docs: alias points to unknown document $id" }
        }
    }
    dict for {fragment target} [dict get $catalog fragments] {
        if {[string length $fragment] > 32767 || $fragment ne [string tolower $fragment] ||
                [catch {DocsUniqueDict $target "fragment $fragment"}] ||
                [lsort [dict keys $target]] ne {id section}} {
            DocsFail corrupt "docs: invalid fragment entry"
        }
        set id [dict get $target id]; set section [dict get $target section]
        if {$fragment ne "$id#$section" || [dict exists $ids $fragment] || ![dict exists $ids $id] ||
                ![dict exists [dict get $catalog documents $id sections] $section]} {
            DocsFail corrupt "docs: fragment points outside the catalog"
        }
    }
    set DOCS_CATALOG $catalog
    set DOCS_LOADED 1
    return $catalog
}

proc ::machteld::DocsStrictBoolean {value option} {
    if {$value ni {0 1}} { DocsFail badvalue "docs: $option must be exactly 0 or 1" }
    return $value
}

proc ::machteld::DocsInteger {value option minimum maximum} {
    if {[string length $value] > 10 || ![regexp {^(0|[1-9][0-9]*)$} $value] ||
            $value < $minimum || $value > $maximum} {
        DocsFail badvalue "docs: $option must be an integer from $minimum through $maximum"
    }
    return $value
}

proc ::machteld::DocsOptions {args defaults allowed} {
    set result $defaults
    set supplied {}
    while {[llength $args]} {
        set option [lindex $args 0]
        if {$option ni $allowed} { DocsFail usage "docs: unknown option \"$option\"" }
        if {[llength $args] < 2} { DocsFail usage "docs: $option needs a value" }
        if {[dict exists $supplied $option]} { DocsFail usage "docs: repeated option \"$option\"" }
        dict set result [string range $option 1 end] [lindex $args 1]
        dict set supplied $option 1
        set args [lrange $args 2 end]
    }
    dict set result _supplied $supplied
    return $result
}

proc ::machteld::DocsResolve {requested} {
    set catalog [DocsLoad]
    if {[string length $requested] > 32767} {
        DocsFail badvalue "docs: document id is too long"
    }
    set key [string tolower [string trim $requested]]
    if {$key eq ""} { DocsFail badvalue "docs: document id must not be empty" }
    set section ""
    if {[dict exists $catalog documents $key]} {
        return [list $key ""]
    }
    if {[dict exists $catalog fragments $key]} {
        set target [dict get $catalog fragments $key]
        return [list [dict get $target id] [dict get $target section]]
    }
    if {[regexp {^([^#]+)#(.+)$} $key -> base fragment]} {
        set key $base
        set section $fragment
    }
    if {[dict exists $catalog documents $key]} {
        set candidates [list $key]
    } elseif {[dict exists $catalog aliases [set alias [DocsNormalizeAlias $key]]]} {
        set candidates [lsort -unique [dict get $catalog aliases $alias]]
    } else {
        DocsFail notfound "docs: no document matches \"$requested\""
    }
    if {[llength $candidates] != 1} {
        DocsFail ambiguous "docs: \"$requested\" is ambiguous; candidates: [join $candidates {, }]"
    }
    set id [lindex $candidates 0]
    if {$section ne "" && ![dict exists $catalog documents $id sections $section]} {
        DocsFail notfound "docs: $id has no section \"$section\""
    }
    return [list $id $section]
}

proc ::machteld::DocsSummary {record} {
    set item {}
    foreach field {id product version type title summary names sections} {
        dict set item $field [dict get $record $field]
    }
    return $item
}

proc ::machteld::DocsPage {items offset limit} {
    set total [llength $items]
    set selected [lrange $items $offset [expr {$offset + $limit - 1}]]
    set returned [llength $selected]
    set next [expr {$offset + $returned < $total ? $offset + $returned : ""}]
    return [dict create items $selected total $total offset $offset limit $limit \
        returned $returned truncated [expr {$next ne ""}] next $next]
}

proc ::machteld::DocsFilterOptions {args} {
    set options [DocsOptions $args [dict create scope all type all offset 0 limit 50] \
        {-scope -type -offset -limit}]
    set catalog [DocsLoad]
    set scope [string tolower [dict get $options scope]]
    set type [string tolower [dict get $options type]]
    if {$scope eq ""} { set scope all }
    if {$type eq ""} { set type all }
    if {$scope ne "all" && ![dict exists $catalog products $scope]} {
        DocsFail badvalue "docs: unknown scope \"[dict get $options scope]\""
    }
    set knownTypes {}
    dict for {id record} [dict get $catalog documents] { dict set knownTypes [dict get $record type] 1 }
    if {$type ne "all" && ![dict exists $knownTypes $type]} {
        DocsFail badvalue "docs: unknown type \"[dict get $options type]\""
    }
    dict set options scope $scope
    dict set options type $type
    dict set options offset [DocsInteger [dict get $options offset] -offset 0 2147483647]
    dict set options limit [DocsInteger [dict get $options limit] -limit 1 200]
    return $options
}

proc ::machteld::DocsStatus {args} {
    if {[llength $args]} { DocsFail usage {docs: wrong # args: should be "docs status"} }
    set catalog [DocsLoad]
    set formats {}
    dict for {id record} [dict get $catalog documents] {
        foreach format [dict keys [dict get $record formats]] { dict set formats $format 1 }
    }
    return [dict create schema 1 generator [dict get $catalog generator] \
        machteld [::machteld::version] root self \
        corpus_sha256 [dict get $catalog corpus_sha256] products [dict get $catalog products] \
        documents [dict size [dict get $catalog documents]] aliases [dict size [dict get $catalog aliases]] \
        fragments [expr {[dict exists $catalog fragments] ? [dict size [dict get $catalog fragments]] : 0}] \
        formats [lsort [dict keys $formats]]]
}

proc ::machteld::DocsSchema {args} {
    if {[llength $args]} { DocsFail usage {docs: wrong # args: should be "docs schema"} }
    return [dict create schema 1 catalog_schema 1 command docs \
        subcommands [dict create \
            status {} schema {} verify {} \
            list {?-scope product? ?-type type? ?-offset n? ?-limit n?} \
            get {id ?-section slug? ?-format markdown|html|source? ?-offset n? ?-limit n? ?-all 0|1?} \
            outline {id} \
            search {query ?-scope product? ?-type type? ?-offset n? ?-limit n?} \
            extract {nonexistent-directory}] \
        identifiers [dict create canonical {product/type/name; stable product/license, machteld/agent, and machteld/index exceptions} fragments {id#section} \
            aliases {unicode-lowercase, trim, and whitespace-collapse}] \
        pagination [dict create list_search [dict create default_limit 50 maximum_limit 200] \
            get [dict create unit characters default_limit 32768 maximum_limit 1048576]] \
        host [dict create full {{docs ...} {--docs ...}} wrapped {{--machteld-docs ...}} \
            options {{--json} {--output FILE}} gui {--output FILE required except for extract}] \
        formats [dict create content {markdown html source} host {text json} \
            json_envelope [dict create success {ok true result value} failure {ok false error {domain DOCS code code message message}}]] \
        errorcode {MACHTELD DOCS code}]
}

proc ::machteld::DocsList {args} {
    set options [DocsFilterOptions {*}$args]
    set catalog [DocsLoad]
    set items {}
    dict for {id record} [dict get $catalog documents] {
        if {[dict get $options scope] ne "all" && [dict get $record product] ne [dict get $options scope]} continue
        if {[dict get $options type] ne "all" && [dict get $record type] ne [dict get $options type]} continue
        lappend items [DocsSummary $record]
    }
    set items [lsort -command {apply {{a b} {string compare [dict get $a id] [dict get $b id]}}} $items]
    return [DocsPage $items [dict get $options offset] [dict get $options limit]]
}

proc ::machteld::DocsOutline {args} {
    if {[llength $args] != 1} { DocsFail usage {docs: wrong # args: should be "docs outline id"} }
    set id [lindex $args 0]
    lassign [DocsResolve $id] canonical fragment
    set record [dict get [DocsLoad] documents $canonical]
    return [dict create id $canonical requested_id $id title [dict get $record title] \
        section $fragment sections [dict get $record sections]]
}

proc ::machteld::DocsGet {args} {
    if {![llength $args]} { DocsFail usage {docs: wrong # args: should be "docs get id ?options?"} }
    set id [lindex $args 0]
    set optionArgs [lrange $args 1 end]
    set options [DocsOptions $optionArgs [dict create section "" format markdown offset 0 limit 32768 all 0] \
        {-section -format -offset -limit -all}]
    set supplied [dict get $options _supplied]
    set all [DocsStrictBoolean [dict get $options all] -all]
    if {$all && ([dict exists $supplied -offset] || [dict exists $supplied -limit])} {
        DocsFail usage "docs: -all cannot be combined with -offset or -limit"
    }
    set offset [DocsInteger [dict get $options offset] -offset 0 2147483647]
    set limit [DocsInteger [dict get $options limit] -limit 1 1048576]
    set format [string tolower [dict get $options format]]
    if {$format ni {markdown html source}} { DocsFail badvalue "docs: -format must be markdown, html, or source" }
    lassign [DocsResolve $id] canonical fragment
    set section [string tolower [dict get $options section]]
    if {[string length $section] > 32767} { DocsFail badvalue "docs: section is too long" }
    if {$fragment ne "" && $section ne "" && $fragment ne $section} {
        DocsFail usage "docs: the id fragment and -section select different sections"
    }
    if {$section eq ""} { set section $fragment }
    set record [dict get [DocsLoad] documents $canonical]
    if {![dict exists $record formats $format]} {
        DocsFail unsupported "docs: $canonical has no $format representation"
    }
    set representation [dict get $record formats $format]
    set path [DocsJoin [dict get $representation path]]
    if {![file isfile $path]} { DocsFail corrupt "docs: $format representation for $canonical is missing" }
    set text [DocsReadUtf8 $path "$format representation for $canonical"]
    set actualBytes [string length [encoding convertto utf-8 $text]]
    if {[catch {hash sum sha256 [encoding convertto utf-8 $text]} actualHash] ||
            $actualBytes != [dict get $representation bytes] ||
            [string length $text] != [dict get $representation characters] ||
            $actualHash ne [dict get $representation sha256]} {
        DocsFail corrupt "docs: $format representation for $canonical failed integrity validation"
    }
    if {$section ne ""} {
        if {![dict exists $record sections $section]} { DocsFail notfound "docs: $canonical has no section \"$section\"" }
        if {![dict exists $representation sections $section]} {
            DocsFail unsupported "docs: section \"$section\" is unavailable in $format form"
        }
        set range [dict get $representation sections $section]
        set start [dict get $range start]; set end [dict get $range end]
        if {$start < 0 || $end < $start || $end > [string length $text]} {
            DocsFail corrupt "docs: invalid section bounds for $canonical#$section"
        }
        set text [string range $text $start [expr {$end - 1}]]
    }
    set total [string length $text]
    if {$all} {
        set page $text; set effectiveOffset 0; set effectiveLimit $total; set next ""
    } else {
        set page [string range $text $offset [expr {$offset + $limit - 1}]]
        set effectiveOffset $offset; set effectiveLimit $limit
        set next [expr {$offset + [string length $page] < $total ? $offset + [string length $page] : ""}]
    }
    return [dict create id $canonical requested_id $id product [dict get $record product] \
        version [dict get $record version] type [dict get $record type] title [dict get $record title] \
        summary [dict get $record summary] names [dict get $record names] format $format section $section \
        path [dict get $representation path] sha256 [dict get $representation sha256] \
        bytes [dict get $representation bytes] text $page total $total offset $effectiveOffset \
        limit $effectiveLimit returned [string length $page] truncated [expr {$next ne ""}] next $next]
}

proc ::machteld::DocsLoadSearch {} {
    variable DOCS_SEARCH
    variable DOCS_SEARCH_LOADED
    if {$DOCS_SEARCH_LOADED} { return $DOCS_SEARCH }
    set path [file join [DocsRoot] search.dict]
    if {![file isfile $path]} { DocsFail corrupt "docs: embedded search index is missing" }
    set catalog [DocsLoad]
    if {![dict exists $catalog search] || [catch {dict size [dict get $catalog search]}] ||
            ![dict exists $catalog search path] || ![dict exists $catalog search sha256] ||
            ![dict exists $catalog search bytes] || [dict get $catalog search path] ne "search.dict"} {
        DocsFail corrupt "docs: catalog has no valid search identity"
    }
    set searchFacts [dict get $catalog search]
    if {[lsort [dict keys $searchFacts]] ne {bytes path sha256}} {
        DocsFail corrupt "docs: invalid search identity fields"
    }
    DocsValidateHash [dict get $searchFacts sha256] search
    DocsNonnegative [dict get $searchFacts bytes] search
    if {[dict get $searchFacts bytes] <= 0 || [dict get $searchFacts bytes] > 268435456} {
        DocsFail corrupt "docs: embedded search index is too large"
    }
    if {[catch {file size $path} searchBytes] || $searchBytes != [dict get $searchFacts bytes] ||
            [catch {hash file sha256 $path} searchHash] || $searchHash ne [dict get $searchFacts sha256]} {
        DocsFail corrupt "docs: embedded search index failed integrity validation"
    }
    set index [string trim [DocsReadUtf8 $path {search index}]]
    if {[catch {DocsUniqueDict $index {search index}}] ||
            [lsort [dict keys $index]] ne {documents normalization schema} ||
            [dict get $index schema] ne "1" ||
            [dict get $index normalization] ne "unicode-lower-whitespace-v1" ||
            [catch {DocsUniqueDict [dict get $index documents] {search documents}}]} {
        DocsFail corrupt "docs: embedded search index is malformed"
    }
    if {[dict size [dict get $index documents]] != [dict size [dict get $catalog documents]]} {
        DocsFail corrupt "docs: search index document inventory disagrees with the catalog"
    }
    dict for {id record} [dict get $index documents] {
        if {![dict exists $catalog documents $id] ||
                [catch {DocsUniqueDict $record "search record $id"}]} {
            DocsFail corrupt "docs: search index contains an unknown document"
        }
        if {[lsort [dict keys $record]] ne {aliases body display_snippets priority snippets summary title}} {
            DocsFail corrupt "docs: search record fields disagree for $id"
        }
        foreach field {priority title aliases summary body snippets display_snippets} {
            if {![dict exists $record $field]} { DocsFail corrupt "docs: incomplete search record for $id" }
        }
        if {[string length [dict get $record priority]] > 10 ||
                ![regexp {^(0|[1-9][0-9]*)$} [dict get $record priority]] ||
                [dict get $record priority] > 2147483647} {
            DocsFail corrupt "docs: invalid search priority for $id"
        }
        set document [dict get $catalog documents $id]
        switch -- "[dict get $document product]/[dict get $document type]" {
            machteld/command { set expectedPriority 400 }
            tcl/command      { set expectedPriority 300 }
            tk/command       { set expectedPriority 250 }
            machteld/guide - machteld/index { set expectedPriority 220 }
            tcl/application  { set expectedPriority 200 }
            tk/application   { set expectedPriority 200 }
            tcl/c-api        { set expectedPriority 100 }
            tk/c-api         { set expectedPriority 90 }
            default          { set expectedPriority 180 }
        }
        if {[dict get $record priority] != $expectedPriority ||
                [dict get $record title] ne [DocsNormalizeAlias [dict get $document title]] ||
                [dict get $record aliases] ne [DocsNormalizeAlias [join [dict get $document names] " "]] ||
                [dict get $record summary] ne [DocsNormalizeAlias [dict get $document summary]]} {
            DocsFail corrupt "docs: search metadata disagrees for $id"
        }
        foreach field {title aliases summary} {
            if {[string length [dict get $record $field]] > 65536 ||
                    [dict get $record $field] ne [DocsNormalizeAlias [dict get $record $field]]} {
                DocsFail corrupt "docs: oversized search field for $id"
            }
        }
        if {[string length [dict get $record body]] > 8388608 ||
                [dict get $record body] ne [DocsNormalizeAlias [dict get $record body]]} {
            DocsFail corrupt "docs: invalid search body for $id"
        }
        if {[catch {DocsUniqueDict [dict get $record snippets] "$id search snippets"}] ||
                [catch {DocsUniqueDict [dict get $record display_snippets] "$id display snippets"}] ||
                [dict keys [dict get $record snippets]] ne [dict keys [dict get $record display_snippets]]} {
            DocsFail corrupt "docs: invalid search snippets for $id"
        }
        dict for {slug snippet} [dict get $record snippets] {
            if {![dict exists $catalog documents $id sections $slug] ||
                    [string length $snippet] > 4096 || $snippet ne [DocsNormalizeAlias $snippet] ||
                    [string length [dict get $record display_snippets $slug]] > 4096} {
                DocsFail corrupt "docs: invalid search snippet for $id#$slug"
            }
        }
    }
    set DOCS_SEARCH $index
    set DOCS_SEARCH_LOADED 1
    return $index
}

proc ::machteld::DocsNormalizeQuery {query} {
    if {[string length $query] > 4096} { DocsFail badvalue "docs: search query is too long" }
    set query [string tolower [string trim $query]]
    regsub -all {[^[:alnum:]_./#-]+} $query { } query
    regsub -all {\s+} $query { } query
    set query [string trim $query]
    set terms [split $query]
    if {[llength $terms] > 64} { DocsFail badvalue "docs: search query has too many terms" }
    foreach term $terms {
        if {[string length $term] < 2} {
            DocsFail badvalue "docs: search terms must contain at least two characters"
        }
    }
    return $query
}

proc ::machteld::DocsLiteralCount {needle haystack} {
    set count 0; set from 0; set length [string length $needle]
    while {$length && $count < 20 && [set found [string first $needle $haystack $from]] >= 0} {
        incr count; set from [expr {$found + $length}]
    }
    return $count
}

proc ::machteld::DocsSearchCompare {a b} {
    set byScore [expr {[dict get $b _score] - [dict get $a _score]}]
    if {$byScore} { return $byScore }
    return [string compare [dict get $a id] [dict get $b id]]
}

proc ::machteld::DocsSearch {args} {
    if {![llength $args]} { DocsFail usage {docs: wrong # args: should be "docs search query ?options?"} }
    set query [lindex $args 0]
    set optionArgs [lrange $args 1 end]
    set normalized [DocsNormalizeQuery $query]
    if {$normalized eq ""} { DocsFail badvalue "docs: search query must contain a word" }
    set options [DocsFilterOptions {*}$optionArgs]
    set catalog [DocsLoad]
    set index [DocsLoadSearch]
    set terms [split $normalized]
    set matches {}
    dict for {id search} [dict get $index documents] {
        set record [dict get $catalog documents $id]
        if {[dict get $options scope] ne "all" && [dict get $record product] ne [dict get $options scope]} continue
        if {[dict get $options type] ne "all" && [dict get $record type] ne [dict get $options type]} continue
        set joined "[dict get $search title] [dict get $search aliases] [dict get $search summary] [dict get $search body]"
        set matched 1; set score [dict get $search priority]
        foreach term $terms {
            if {[string first $term $joined] < 0} { set matched 0; break }
            if {[string first $term [dict get $search title]] >= 0} { incr score 120 }
            if {[string first $term [dict get $search aliases]] >= 0} { incr score 100 }
            if {[string first $term [dict get $search summary]] >= 0} { incr score 40 }
            incr score [DocsLiteralCount $term $joined]
        }
        if {!$matched} continue
        if {[string first $normalized $joined] >= 0} { incr score 80 }
        set item [DocsSummary $record]
        dict set item score $score
        set snippet [dict get $record summary]
        dict for {slug normalizedSnippet} [dict get $search snippets] {
            set relevant 1
            foreach term $terms {
                if {[string first $term $normalizedSnippet] < 0} { set relevant 0; break }
            }
            if {$relevant} {
                set snippet [dict get $search display_snippets $slug]
                break
            }
        }
        dict set item snippet $snippet
        dict set item _score $score
        lappend matches $item
    }
    set matches [lsort -command ::machteld::DocsSearchCompare $matches]
    set clean {}
    foreach item $matches { dict unset item _score; lappend clean $item }
    return [DocsPage $clean [dict get $options offset] [dict get $options limit]]
}

proc ::machteld::DocsVerify {args} {
    if {[llength $args]} { DocsFail usage {docs: wrong # args: should be "docs verify"} }
    set catalog [DocsLoad]
    set packFiles [DocsPackFiles]
    set files 0; set bytes 0; set corpusInput ""
    foreach relative [lsort [dict keys [dict get $catalog inventory]]] {
        set facts [dict get $catalog inventory $relative]
        if {![dict exists $packFiles $relative]} {
            DocsFail corrupt "docs: inventory file $relative is absent from the verified pack"
        }
        set actualBytes [dict get $packFiles $relative bytes]
        set actualHash [dict get $packFiles $relative sha256]
        if {$actualBytes != [dict get $facts bytes]} { DocsFail corrupt "docs: byte count mismatch for $relative" }
        if {$actualHash ne [dict get $facts sha256]} { DocsFail corrupt "docs: hash mismatch for $relative" }
        append corpusInput $relative \0 $actualHash \0
        incr files; incr bytes $actualBytes
    }
    # Tcl's internal string representation uses a modified UTF-8 encoding for
    # embedded NULs.  The corpus identity is explicitly defined over external
    # UTF-8 bytes with literal NUL separators, matching the generator.
    if {[catch {hash sum sha256 [encoding convertto utf-8 $corpusInput]} actualCorpus]} {
        DocsFail corrupt "docs: cannot recompute the embedded corpus identity"
    }
    if {$actualCorpus ne [dict get $catalog corpus_sha256]} { DocsFail corrupt "docs: corpus identity mismatch" }
    set files [dict size $packFiles]
    set bytes 0
    dict for {relative facts} $packFiles { incr bytes [dict get $facts bytes] }
    return [dict create ok 1 documents [dict size [dict get $catalog documents]] files $files \
        bytes $bytes corpus_sha256 $actualCorpus]
}

proc ::machteld::DocsNativeChildren {directory} {
    set result {}
    foreach item [concat [glob -nocomplain -directory $directory *] [glob -nocomplain -types hidden -directory $directory *]] {
        if {[file tail $item] in {. ..}} continue
        dict set result [file normalize $item] $item
    }
    return [lsort [dict values $result]]
}

proc ::machteld::DocsTreeFiles {root {relative ""} {depth 0}} {
    if {$depth > 64} { DocsFail corrupt "docs: reference tree is too deep" }
    set files {}
    set directory [expr {$relative eq "" ? $root : [file join $root {*}[file split $relative]]}]
    foreach item [DocsNativeChildren $directory] {
        set child [expr {$relative eq "" ? [file tail $item] : "$relative/[file tail $item]"}]
        set type [file type $item]
        if {$type eq "directory"} {
            dict for {path facts} [DocsTreeFiles $root $child [expr {$depth + 1}]] {
                dict set files $path $facts
                if {[dict size $files] > 100000} { DocsFail corrupt "docs: reference tree has too many files" }
            }
        } elseif {$type eq "file"} {
            if {[catch {file size $item} bytes] || [catch {hash file sha256 $item} sha256]} {
                DocsFail oserror "docs: cannot inspect reference file $child"
            }
            dict set files $child [dict create sha256 $sha256 bytes $bytes]
            if {[dict size $files] > 100000} { DocsFail corrupt "docs: reference tree has too many files" }
        } else {
            DocsFail corrupt "docs: reference pack contains an unsupported path type"
        }
    }
    return $files
}

proc ::machteld::DocsManifest {} {
    set path [file join [DocsRoot] manifest.sha256]
    if {![file isfile $path] || [catch {file size $path} bytes] ||
            $bytes <= 0 || $bytes > 16777216} {
        DocsFail corrupt "docs: reference manifest is missing or too large"
    }
    set text [DocsReadUtf8 $path manifest]
    if {[string first "\r" $text] >= 0 || [string index $text end] ne "\n" ||
            [string range $text end-1 end] eq "\n\n"} {
        DocsFail corrupt "docs: reference manifest is not canonical LF text"
    }
    set lines [split [string range $text 0 end-1] \n]
    if {![llength $lines] || [lindex $lines 0] ne
            {# machteld reference pack v1; SHA-256 consistency manifest (self excluded)} ||
            [llength $lines] > 100000} {
        DocsFail corrupt "docs: malformed reference manifest"
    }
    set manifest {}
    set previous ""
    foreach line [lrange $lines 1 end] {
        if {![regexp {^([0-9a-f]{64})  (.+)$} $line -> sha256 relative] ||
                ![DocsSafeRelative $relative] || $relative eq "manifest.sha256" ||
                [dict exists $manifest $relative]} {
            DocsFail corrupt "docs: malformed reference manifest entry"
        }
        if {$previous ne "" && [string compare $previous $relative] >= 0} {
            DocsFail corrupt "docs: reference manifest is not ordinally sorted"
        }
        dict set manifest $relative $sha256
        set previous $relative
    }
    if {![dict size $manifest]} { DocsFail corrupt "docs: reference manifest is empty" }
    return $manifest
}

proc ::machteld::DocsPackFiles {} {
    set catalog [DocsLoad]
    if {[catch {DocsTreeFiles [DocsRoot]} files options]} {
        set errorcode [expr {[dict exists $options -errorcode] ? [dict get $options -errorcode] : {}}]
        if {[lrange $errorcode 0 1] eq {MACHTELD DOCS} && [lindex $errorcode 2] eq "corrupt"} {
            return -options $options $files
        }
        DocsFail corrupt "docs: cannot inspect the embedded reference pack"
    }
    set manifest [DocsManifest]
    foreach control {catalog.dict catalog.json search.dict} {
        if {![dict exists $files $control] || ![dict exists $manifest $control]} {
            DocsFail corrupt "docs: reference control file $control is missing"
        }
    }
    set declared [dict keys $manifest]
    lappend declared manifest.sha256
    if {[lsort [dict keys $files]] ne [lsort $declared]} {
        DocsFail corrupt "docs: reference pack contains an undeclared or missing file"
    }
    dict for {relative sha256} $manifest {
        if {[dict get $files $relative sha256] ne $sha256 ||
                [dict get $files $relative bytes] > 268435456} {
            DocsFail corrupt "docs: manifest hash mismatch for $relative"
        }
    }
    dict for {relative facts} [dict get $catalog inventory] {
        if {![dict exists $manifest $relative] ||
                [dict get $files $relative sha256] ne [dict get $facts sha256] ||
                [dict get $files $relative bytes] != [dict get $facts bytes]} {
            DocsFail corrupt "docs: reference inventory file $relative failed integrity validation"
        }
    }
    set searchFacts [dict get $catalog search]
    if {[dict get $files search.dict sha256] ne [dict get $searchFacts sha256] ||
            [dict get $files search.dict bytes] != [dict get $searchFacts bytes]} {
        DocsFail corrupt "docs: search index failed integrity validation"
    }
    return $files
}

proc ::machteld::DocsCopyTree {source destination statsVariable} {
    upvar 1 $statsVariable stats
    file mkdir $destination
    foreach item [DocsNativeChildren $source] {
        set target [file join $destination [file tail $item]]
        set type [file type $item]
        if {$type eq "directory"} {
            DocsCopyTree $item $target stats
        } elseif {$type eq "file"} {
            file copy $item $target
            dict incr stats files
            dict incr stats bytes [file size $item]
        } else {
            DocsFail corrupt "docs: reference pack contains an unsupported path type"
        }
    }
}

proc ::machteld::DocsExtract {args} {
    if {[llength $args] != 1} { DocsFail usage {docs: wrong # args: should be "docs extract directory"} }
    set destination [lindex $args 0]
    if {$destination eq "" || [string length $destination] > 32767} {
        DocsFail badvalue "docs: extraction destination must be a nonempty Windows path"
    }
    if {[file exists $destination]} { DocsFail exists "docs: extraction destination already exists" }
    if {[catch {file normalize $destination} normalized]} {
        DocsFail badvalue "docs: invalid extraction destination: $normalized"
    }
    set destination $normalized
    set parent [file dirname $destination]
    if {![file isdirectory $parent]} { DocsFail notfound "docs: extraction parent does not exist" }
    if {[catch {links $parent -depth 0} parentSurvey] || [llength [dict get $parentSurvey errors]] ||
            [llength [dict get $parentSurvey links]] || [llength [dict get $parentSurvey entered]]} {
        DocsFail badvalue "docs: extraction parent must be a readable link-free directory"
    }
    if {[catch {canon $parent} parentIdentity] || [dict get $parentIdentity kind] ne "directory"} {
        DocsFail badvalue "docs: extraction parent cannot be identified"
    }
    set parent [dict get $parentIdentity path]
    set destination [file join $parent [file tail $destination]]
    if {[file exists $destination]} { DocsFail exists "docs: extraction destination already exists" }
    set sourceFiles [DocsPackFiles]
    set stage ""
    for {set tries 0} {$tries < 32} {incr tries} {
        if {[catch {binary encode hex [hash random 16]} suffix]} {
            DocsFail oserror "docs: cannot generate an extraction staging identity"
        }
        set candidate [file join $parent .machteld-docs-$suffix]
        if {![file exists $candidate]} { set stage $candidate; break }
    }
    if {$stage eq ""} { DocsFail oserror "docs: cannot reserve an extraction staging path" }
    set expectedBytes 0
    dict for {relative facts} $sourceFiles { incr expectedBytes [dict get $facts bytes] }
    set stats [dict create files 0 bytes 0]
    set stagedIdentity ""
    try {
        file mkdir $stage
        set stagedIdentity [canon $stage]
        if {[catch {links $stage -depth 0} stageSurvey] ||
                [llength [dict get $stageSurvey errors]] ||
                [llength [dict get $stageSurvey links]] ||
                [llength [dict get $stageSurvey entered]] ||
                [dict get $stagedIdentity kind] ne "directory" ||
                [dict get $stagedIdentity volume] ne [dict get $parentIdentity volume] ||
                [catch {canon [file dirname $stage]} stageParentIdentity] ||
                [list [dict get $stageParentIdentity volume] [dict get $stageParentIdentity file]] ne
                    [list [dict get $parentIdentity volume] [dict get $parentIdentity file]]} {
            DocsFail oserror "docs: extraction staging identity is unsafe"
        }
        DocsCopyTree [DocsRoot] $stage stats
        if {[catch {canon $stage} currentStage] ||
                [list [dict get $currentStage volume] [dict get $currentStage file]] ne
                    [list [dict get $stagedIdentity volume] [dict get $stagedIdentity file]] ||
                [catch {canon $parent} currentParent] ||
                [list [dict get $currentParent volume] [dict get $currentParent file]] ne
                    [list [dict get $parentIdentity volume] [dict get $parentIdentity file]]} {
            DocsFail oserror "docs: extraction staging identity changed"
        }
        set stagedFiles [DocsTreeFiles $stage]
        if {[catch {links $stage} stageSurvey] || [llength [dict get $stageSurvey errors]] ||
                [llength [dict get $stageSurvey links]] || [llength [dict get $stageSurvey entered]] ||
                [lsort [dict keys $stagedFiles]] ne [lsort [dict keys $sourceFiles]] ||
                [dict get $stats files] != [dict size $sourceFiles] ||
                [dict get $stats bytes] != $expectedBytes} {
            DocsFail corrupt "docs: staged extraction inventory changed"
        }
        dict for {relative facts} $sourceFiles {
            if {[dict get $stagedFiles $relative sha256] ne [dict get $facts sha256] ||
                    [dict get $stagedFiles $relative bytes] != [dict get $facts bytes]} {
                DocsFail corrupt "docs: staged extraction failed verification for $relative"
            }
        }
        if {[file exists $destination]} { DocsFail exists "docs: extraction destination appeared during staging" }
        file rename $stage $destination
        set stage ""
    } on error {message options} {
        if {[lrange [dict get $options -errorcode] 0 1] eq {MACHTELD DOCS}} {
            return -options $options $message
        }
        DocsFail oserror "docs: extraction failed: $message"
    } finally {
        if {$stage ne "" && $stagedIdentity ne "" && ![catch {canon $stage} cleanupIdentity] &&
                [list [dict get $cleanupIdentity volume] [dict get $cleanupIdentity file]] eq
                    [list [dict get $stagedIdentity volume] [dict get $stagedIdentity file]]} {
            catch {file delete -force $stage}
        }
    }
    return [dict create path $destination files [dict get $stats files] bytes [dict get $stats bytes] \
        corpus_sha256 [dict get [DocsLoad] corpus_sha256]]
}

proc ::machteld::DocsUnknown {ensemble subcommand args} {
    DocsFail usage "docs: unknown subcommand \"$subcommand\""
}

proc ::machteld::DocsJString {value} {
    set output "\""
    foreach character [split $value ""] {
        scan $character %c code
        switch -- $character {
            \" { append output {\"} }
            \\ { append output {\\} }
            \b { append output {\b} }
            \f { append output {\f} }
            \n { append output {\n} }
            \r { append output {\r} }
            \t { append output {\t} }
            default {
                if {$code < 32} { append output [format {\u%04x} $code] } else { append output $character }
            }
        }
    }
    append output "\""
    return $output
}
proc ::machteld::DocsJNumber {value} {
    if {![regexp {^(0|[1-9][0-9]*)$} $value]} { error "internal docs JSON number error" }
    return $value
}
proc ::machteld::DocsJBool {value} { return [expr {$value ? "true" : "false"}] }
proc ::machteld::DocsJNext {value} { return [expr {$value eq "" ? "null" : [DocsJNumber $value]}] }
proc ::machteld::DocsJObject {pairs} {
    set fields {}
    foreach {key encoded} $pairs { lappend fields "[DocsJString $key]:$encoded" }
    return "\{[join $fields ,]\}"
}
proc ::machteld::DocsJArray {encodedValues} { return "\[[join $encodedValues ,]\]" }
proc ::machteld::DocsJStringArray {values} {
    set encoded {}
    foreach value $values { lappend encoded [DocsJString $value] }
    return [DocsJArray $encoded]
}
proc ::machteld::DocsJStringDict {value} {
    set fields {}
    dict for {key item} $value { lappend fields $key [DocsJString $item] }
    return [DocsJObject $fields]
}
proc ::machteld::DocsJProductDict {value} {
    set products {}
    dict for {product facts} $value {
        if {[catch {dict size $facts}]} {
            lappend products $product [DocsJString $facts]
            continue
        }
        set fields {}
        dict for {key item} $facts {
            if {$key in {documents manual_pages pages count}} {
                lappend fields $key [DocsJNumber $item]
            } elseif {$key in {types formats}} {
                lappend fields $key [DocsJStringArray $item]
            } else {
                lappend fields $key [DocsJString $item]
            }
        }
        lappend products $product [DocsJObject $fields]
    }
    return [DocsJObject $products]
}
proc ::machteld::DocsJSummary {item} {
    set pairs [list \
        id [DocsJString [dict get $item id]] \
        product [DocsJString [dict get $item product]] \
        version [DocsJString [dict get $item version]] \
        type [DocsJString [dict get $item type]] \
        title [DocsJString [dict get $item title]] \
        summary [DocsJString [dict get $item summary]] \
        names [DocsJStringArray [dict get $item names]] \
        sections [DocsJStringDict [dict get $item sections]]]
    if {[dict exists $item score]} { lappend pairs score [DocsJNumber [dict get $item score]] }
    if {[dict exists $item snippet]} { lappend pairs snippet [DocsJString [dict get $item snippet]] }
    return [DocsJObject $pairs]
}

# Schema-aware JSON construction avoids Tcl's intentionally representation-based
# native inference turning an empty list into an object or a numeric-looking
# version/title into a number.
proc ::machteld::DocsJsonResult {subcommand result} {
    switch -- $subcommand {
        status {
            return [DocsJObject [list \
                schema [DocsJNumber [dict get $result schema]] \
                generator [DocsJString [dict get $result generator]] \
                machteld [DocsJString [dict get $result machteld]] \
                root [DocsJString [dict get $result root]] \
                corpus_sha256 [DocsJString [dict get $result corpus_sha256]] \
                products [DocsJProductDict [dict get $result products]] \
                documents [DocsJNumber [dict get $result documents]] \
                aliases [DocsJNumber [dict get $result aliases]] \
                fragments [DocsJNumber [dict get $result fragments]] \
                formats [DocsJStringArray [dict get $result formats]]]]
        }
        list - search {
            set items {}
            foreach item [dict get $result items] { lappend items [DocsJSummary $item] }
            return [DocsJObject [list items [DocsJArray $items] \
                total [DocsJNumber [dict get $result total]] offset [DocsJNumber [dict get $result offset]] \
                limit [DocsJNumber [dict get $result limit]] returned [DocsJNumber [dict get $result returned]] \
                truncated [DocsJBool [dict get $result truncated]] next [DocsJNext [dict get $result next]]]]
        }
        get {
            set pairs {}
            foreach key {id requested_id product version type title summary format section path sha256 text} {
                lappend pairs $key [DocsJString [dict get $result $key]]
            }
            lappend pairs names [DocsJStringArray [dict get $result names]]
            foreach key {bytes total offset limit returned} { lappend pairs $key [DocsJNumber [dict get $result $key]] }
            lappend pairs truncated [DocsJBool [dict get $result truncated]] next [DocsJNext [dict get $result next]]
            return [DocsJObject $pairs]
        }
        outline {
            return [DocsJObject [list id [DocsJString [dict get $result id]] \
                requested_id [DocsJString [dict get $result requested_id]] title [DocsJString [dict get $result title]] \
                section [DocsJString [dict get $result section]] sections [DocsJStringDict [dict get $result sections]]]]
        }
        verify {
            return [DocsJObject [list ok [DocsJBool [dict get $result ok]] \
                documents [DocsJNumber [dict get $result documents]] files [DocsJNumber [dict get $result files]] \
                bytes [DocsJNumber [dict get $result bytes]] corpus_sha256 [DocsJString [dict get $result corpus_sha256]]]]
        }
        extract {
            return [DocsJObject [list path [DocsJString [dict get $result path]] \
                files [DocsJNumber [dict get $result files]] bytes [DocsJNumber [dict get $result bytes]] \
                corpus_sha256 [DocsJString [dict get $result corpus_sha256]]]]
        }
        schema {
            # This response is fixed API metadata; use explicitly typed nested
            # objects rather than exposing catalog-derived types.
            set subcommands {}
            dict for {name grammar} [dict get $result subcommands] {
                lappend subcommands $name [DocsJString $grammar]
            }
            set identifiers {}; dict for {key value} [dict get $result identifiers] {
                lappend identifiers $key [DocsJString $value]
            }
            set pagination [DocsJObject [list \
                list_search [DocsJObject [list default_limit 50 maximum_limit 200]] \
                get [DocsJObject [list unit [DocsJString characters] default_limit 32768 maximum_limit 1048576]]]]
            set successEnvelope [DocsJObject [list \
                ok [DocsJBool 1] result [DocsJString value]]]
            set failureError [DocsJObject [list \
                domain [DocsJString DOCS] code [DocsJString code] message [DocsJString message]]]
            set failureEnvelope [DocsJObject [list \
                ok [DocsJBool 0] error $failureError]]
            set envelope [DocsJObject [list \
                success $successEnvelope failure $failureEnvelope]]
            set formats [DocsJObject [list content [DocsJStringArray {markdown html source}] \
                host [DocsJStringArray {text json}] json_envelope $envelope]]
            set host [DocsJObject [list full [DocsJStringArray {{docs ...} {--docs ...}}] \
                wrapped [DocsJStringArray {{--machteld-docs ...}}] \
                options [DocsJStringArray {{--json} {--output FILE}}] \
                gui [DocsJString {--output FILE required except for extract}]]]
            return [DocsJObject [list schema 1 catalog_schema 1 command [DocsJString docs] \
                subcommands [DocsJObject $subcommands] identifiers [DocsJObject $identifiers] \
                pagination $pagination host $host formats $formats errorcode [DocsJString {MACHTELD DOCS code}]]]
        }
        default { error "internal docs JSON subcommand error" }
    }
}

proc ::machteld::DocsHostTranslate {args} {
    set translated {}
    foreach arg $args {
        if {[regexp {^--(scope|type|offset|limit|section|format|all)$} $arg -> name]} {
            lappend translated -$name
        } else {
            lappend translated $arg
        }
    }
    return $translated
}

proc ::machteld::DocsHostCommand {kept} {
    if {![llength $kept]} {
        return [list get [list ::machteld::docs get machteld/agent -all 1]]
    }
    set subcommand [lindex $kept 0]
    if {$subcommand ni {status schema verify list get outline search extract}} {
        DocsFail usage "docs: unknown subcommand \"$subcommand\""
    }
    return [list $subcommand [list ::machteld::docs {*}[DocsHostTranslate {*}$kept]]]
}

proc ::machteld::DocsHostText {subcommand result} {
    switch -- $subcommand {
        get {
            set output [dict get $result text]
            if {[dict get $result truncated]} {
                append output "\n\n-- truncated; continue with --offset [dict get $result next] --"
            }
            return $output
        }
        list - search {
            set output ""
            foreach item [dict get $result items] {
                append output "[dict get $item id]\t[dict get $item title]\t[dict get $item summary]\n"
            }
            if {[dict get $result truncated]} { append output "-- more at offset [dict get $result next] --\n" }
            return [string trimright $output \n]
        }
        outline {
            set output "[dict get $result id] -- [dict get $result title]\n"
            dict for {slug heading} [dict get $result sections] { append output "  $slug\t$heading\n" }
            return [string trimright $output \n]
        }
        schema - status - verify - extract { return $result }
        default { return $result }
    }
}

proc ::machteld::DocsPublishText {destination text} {
    if {$destination eq "" || [string length $destination] > 32767} {
        DocsFail badvalue "docs: --output must be a nonempty Windows path"
    }
    if {[catch {file normalize $destination} normalized]} {
        DocsFail badvalue "docs: invalid --output path: $normalized"
    }
    set destination $normalized
    if {[file isdirectory $destination]} { DocsFail badvalue "docs: --output is a directory" }
    set parent [file dirname $destination]
    if {![file isdirectory $parent]} { DocsFail notfound "docs: --output parent does not exist" }
    if {![catch {canon [info nameofexecutable]} running] && [file exists $destination] &&
            ![catch {canon $destination} target] &&
            [list [dict get $running volume] [dict get $running file]] eq
            [list [dict get $target volume] [dict get $target file]]} {
        DocsFail badvalue "docs: --output cannot replace the running executable"
    }
    set claim ""
    set claimChannel ""
    set candidate ""
    set channel ""
    if {[catch {file tempfile claim [file join $parent .machteld-docs-output-]} claimChannel]} {
        DocsFail oserror "docs: cannot claim --output candidate: $claimChannel"
    }
    set candidateIdentity ""
    try {
        set candidate "${claim}.candidate"
        if {[catch {open $candidate {WRONLY CREAT EXCL}} channel]} {
            DocsFail oserror "docs: cannot create --output candidate: $channel"
        }
        if {[catch {canon $candidate} candidateIdentity] ||
                [dict get $candidateIdentity kind] ne "file"} {
            DocsFail oserror "docs: cannot identify --output candidate"
        }
        if {[catch {
            fconfigure $channel -translation binary
            puts -nonewline $channel [encoding convertto utf-8 $text]
            close $channel
        } message]} {
            catch {close $channel}
            set channel ""
            DocsFail oserror "docs: cannot write --output candidate: $message"
        }
        set channel ""
        if {[catch {::machteld::Publish $candidate $destination} message options]} {
            set nativeCode [expr {[dict exists $options -errorcode] ? [lindex [dict get $options -errorcode] 2] : ""}]
            set code [expr {$nativeCode in {badvalue notfound} ? "badvalue" : "oserror"}]
            DocsFail $code "docs: cannot publish --output: $message"
        }
        set candidate ""
    } finally {
        if {$channel ne ""} { catch {close $channel} }
        if {$candidate ne "" && $candidateIdentity ne "" && ![catch {canon $candidate} cleanupIdentity] &&
                [list [dict get $cleanupIdentity volume] [dict get $cleanupIdentity file]] eq
                    [list [dict get $candidateIdentity volume] [dict get $candidateIdentity file]]} {
            catch {file delete -force $candidate}
        }
        if {$claimChannel ne ""} { catch {close $claimChannel} }
        if {$claim ne ""} { catch {file delete -force $claim} }
    }
}

proc ::machteld::DocsHostCore {args} {
    set json 0; set jsonSeen 0; set output ""; set outputSeen 0; set kept {}
    for {set index 0} {$index < [llength $args]} {incr index} {
        set arg [lindex $args $index]
        if {$arg eq "--json"} {
            if {$jsonSeen} { DocsFail usage "docs: repeated --json option" }
            set json 1; set jsonSeen 1; continue
        }
        if {$arg eq "--output"} {
            if {$outputSeen || $index + 1 >= [llength $args]} { DocsFail usage "docs: --output needs one value" }
            set output [lindex $args [incr index]]
            if {$output eq "" || [string length $output] > 32767} {
                DocsFail badvalue "docs: --output must be a nonempty Windows path"
            }
            set outputSeen 1
            continue
        }
        lappend kept $arg
    }
    lassign [DocsHostCommand $kept] subcommand call

    set status [catch {uplevel #0 $call} result options]
    if {$status} {
        set errorcode [expr {[dict exists $options -errorcode] ? [dict get $options -errorcode] : {}}]
        if {[lrange $errorcode 0 1] ne {MACHTELD DOCS}} {
            set errorcode {MACHTELD DOCS oserror}
            set options [dict replace $options -errorcode $errorcode]
            set result "docs: $result"
        }
        set code [lindex $errorcode 2]
        if {$json} {
            set encodedError [DocsJObject [list domain [DocsJString DOCS] \
                code [DocsJString $code] message [DocsJString $result]]]
            set rendered [DocsJObject [list ok false error $encodedError]]
        } else {
            set rendered $result
        }
        if {$output ne ""} {
            if {[catch {DocsPublishText $output $rendered} publishMessage publishOptions]} {
                dict set publishOptions -machteld-docs-output-attempted 1
                return -options $publishOptions $publishMessage
            }
            dict set options -machteld-docs-output-attempted 1
        }
        return -options $options $rendered
    }

    if {$json} {
        set encodedResult [DocsJsonResult $subcommand $result]
        set rendered [DocsJObject [list ok true result $encodedResult]]
    } else {
        set rendered [DocsHostText $subcommand $result]
    }
    if {$output ne ""} {
        if {[catch {DocsPublishText $output $rendered} publishMessage publishOptions]} {
            dict set publishOptions -machteld-docs-output-attempted 1
            return -options $publishOptions $publishMessage
        }
        return ""
    }
    return $rendered
}

proc ::machteld::DocsHostIntent {args} {
    set json 0; set outputs {}
    for {set index 0} {$index < [llength $args]} {incr index} {
        set arg [lindex $args $index]
        if {$arg eq "--output"} {
            if {$index + 1 < [llength $args]} {
                lappend outputs [lindex $args [incr index]]
            } else {
                lappend outputs ""
            }
        } elseif {$arg eq "--json"} {
            set json 1
        }
    }
    set output [expr {[llength $outputs] == 1 ? [lindex $outputs 0] : ""}]
    return [dict create json $json output $output]
}

proc ::machteld::DocsHost {args} {
    # Detect a well-formed --json request before parsing the rest, so even an
    # unknown operation or missing option value receives the JSON error contract.
    set intent [DocsHostIntent {*}$args]
    set jsonRequested [dict get $intent json]
    set output [dict get $intent output]
    if {![catch {DocsHostCore {*}$args} result options]} { return $result }
    set errorcode [expr {[dict exists $options -errorcode] ? [dict get $options -errorcode] : {}}]
    if {[lrange $errorcode 0 1] ne {MACHTELD DOCS}} {
        set errorcode {MACHTELD DOCS oserror}
        set options [dict replace $options -errorcode $errorcode]
        set result "docs: $result"
    }
    if {$jsonRequested && ![string match {\{"ok":false,*} $result]} {
        set code [lindex $errorcode 2]
        set encodedError [DocsJObject [list domain [DocsJString DOCS] \
            code [DocsJString $code] message [DocsJString $result]]]
        set result [DocsJObject [list ok false error $encodedError]]
    }
    # Parse/dispatch failures (plain or JSON) are published consistently.
    # Operation failures and failed publication attempts carry the marker.
    if {$output ne "" && ![dict exists $options -machteld-docs-output-attempted]} {
        if {[catch {DocsPublishText $output $result} publishMessage publishOptions]} {
            return -options $publishOptions $publishMessage
        }
    }
    return -options $options $result
}

proc ::machteld::DocsGuiCommand {args} {
    set kept {}
    for {set index 0} {$index < [llength $args]} {incr index} {
        set arg [lindex $args $index]
        if {$arg eq "--output"} {
            if {$index + 1 < [llength $args]} { incr index }
            continue
        }
        if {$arg eq "--json"} continue
        lappend kept $arg
    }
    return [expr {[llength $kept] ? [lindex $kept 0] : ""}]
}

proc ::machteld::DocsHostGui {args} {
    set intent [DocsHostIntent {*}$args]
    set hasOutput [expr {[dict get $intent output] ne ""}]
    set command [DocsGuiCommand {*}$args]
    if {!$hasOutput && $command ne "extract"} {
        set message "docs: GUI tools require --output FILE for documentation queries"
        if {[dict get $intent json]} {
            set error [DocsJObject [list domain [DocsJString DOCS] code [DocsJString usage] message [DocsJString $message]]]
            return -code error -errorcode {MACHTELD DOCS usage} [DocsJObject [list ok false error $error]]
        }
        DocsFail usage $message
    }
    return [DocsHost {*}$args]
}

namespace ensemble create -command ::machteld::DocsEnsemble -prefixes 0 -unknown ::machteld::DocsUnknown -map {
    status  ::machteld::DocsStatus
    schema  ::machteld::DocsSchema
    verify  ::machteld::DocsVerify
    list    ::machteld::DocsList
    get     ::machteld::DocsGet
    outline ::machteld::DocsOutline
    search  ::machteld::DocsSearch
    extract ::machteld::DocsExtract
}

proc ::machteld::docs {args} {
    if {![llength $args]} {
        DocsFail usage {docs: wrong # args: should be "docs subcommand ?arg ...?"}
    }
    tailcall ::machteld::DocsEnsemble {*}$args
}

::machteld::MetaDefine docs [dict create kind tcl args args domain DOCS \
    doc machteld/command/docs codes {ambiguous badvalue corrupt exists notfound oserror unsupported usage} \
    options {-all -format -limit -offset -scope -section -type} subcommands [dict create \
        status [dict create options {} doc machteld/command/docs#status] \
        schema [dict create options {} doc machteld/command/docs#schema] \
        verify [dict create options {} doc machteld/command/docs#verify] \
        list [dict create options {-limit -offset -scope -type} doc machteld/command/docs#list] \
        get [dict create options {-all -format -limit -offset -section} doc machteld/command/docs#get] \
        outline [dict create options {} doc machteld/command/docs#outline] \
        search [dict create options {-limit -offset -scope -type} doc machteld/command/docs#search] \
        extract [dict create options {} doc machteld/command/docs#extract]]]

# Human shorthand deliberately returns text.  Exact ids/aliases are preferred;
# otherwise the words become one bounded search query.
proc ::machteld::DocsHelpError {message options {discovery 0}} {
    set code ""
    if {[dict exists $options -errorcode] &&
            [lrange [dict get $options -errorcode] 0 1] eq {MACHTELD DOCS}} {
        set code [lindex [dict get $options -errorcode] 2]
    }
    if {$code eq "unsupported"} { set helpCode unsupported
    } elseif {$discovery && $code in {badvalue notfound ambiguous}} { set helpCode notfound
    } else { set helpCode oserror }
    Fail HELP $helpCode "help: $message"
}

proc ::machteld::help {args} {
    if {![llength $args]} {
        return "machteld [::machteld::version] complete offline reference\n\nThis executable contains the complete, exact-version documentation for:\n  Machteld [::machteld::version] — commands, contracts, and guides\n  Tcl 9.0.4 — applications, language commands, and C API\n  Tk 9.0.4 — applications, widgets, and C API\n\nHost routes:\n  machteld.exe --docs ...\n  wrapped-tool.exe --machteld-docs ...\n\nProgrammatic routes:\n  docs status\n  docs list -scope machteld\n  docs get machteld/command/run\n  docs get tcl/command/dict -section examples\n  docs search {channel binary encoding}\n  docs extract DIRECTORY\n\nUse `docs schema` for the complete machine contract."
    }
    set query [join $args " "]
    if {![catch {DocsGet $query} result options]} {
        set text [dict get $result text]
        if {[dict get $result truncated]} {
            append text "\n\n[Page truncated; continue with: docs get [dict get $result id] -offset [dict get $result next]]"
        }
        return $text
    }
    set code [expr {[dict exists $options -errorcode] ? [lindex [dict get $options -errorcode] 2] : ""}]
    if {$code ni {notfound ambiguous}} {
        DocsHelpError $result $options
    }
    if {[catch {DocsSearch $query -limit 10} matches searchOptions]} {
        DocsHelpError $matches $searchOptions 1
    }
    if {![dict get $matches returned]} { Fail HELP notfound "help: no reference matches \"$query\"" }
    set output "Reference matches for \"$query\":\n"
    foreach item [dict get $matches items] {
        append output "  [dict get $item id]  -- [dict get $item summary]\n"
    }
    append output "\nUse: docs get ID"
    return $output
}

::machteld::MetaDefine help [dict create kind tcl args args domain HELP \
    doc machteld/command/help codes {notfound oserror unsupported}]

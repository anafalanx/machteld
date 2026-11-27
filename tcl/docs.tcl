# docs.tcl -- immutable, agent-oriented access to the reference in this exe.
#
# The read-only SQLite database is opened on the first content query.
namespace eval ::machteld {
    variable DOCS_IDENTITY {}
}

proc ::machteld::DocsFail {code message} {
    return -code error -errorcode [list MACHTELD DOCS $code] $message
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

proc ::machteld::DocsNormalizeAlias {value} {
    set value [string tolower [string trim $value]]
    regsub -all {\s+} $value { } value
    return $value
}

proc ::machteld::DocsDatabaseFile {directory} {
    set database [file join $directory reference.db]
    if {[DocsNativeChildren $directory] ne [list $database] || [file type $database] ne "file"} {
        DocsFail corrupt "docs: expected a single reference.db in the reference directory"
    }
    return $database
}

proc ::machteld::DocsLoad {} {
    variable DOCS_IDENTITY
    variable reference_sha256
    if {$DOCS_IDENTITY ne "" && [llength [info commands ::machteld::ReferenceDb]]} {return $DOCS_IDENTITY}
    set root [DocsRoot]
    if {[catch {
        set database [DocsDatabaseFile $root]
        set size [file size $database]
        if {$size < 4096 || $size > 67108864} {error "unexpected reference database size"}
        set ch [open $database rb]
        try {set bytes [read $ch $size]} finally {close $ch}
        if {![info exists reference_sha256] || ![regexp {^[0-9a-f]{64}$} $reference_sha256] ||
                [string length $bytes] != $size || [hash sum sha256 $bytes] ne $reference_sha256} {
            error "reference database digest mismatch"
        }
        package require sqlite3
        sqlite3 ::machteld::ReferenceDb :memory: -defensive 1
        ReferenceDb deserialize -readonly 1 $bytes
        unset bytes
        ReferenceDb eval {PRAGMA query_only=ON; PRAGMA trusted_schema=OFF}
        if {[ReferenceDb onecolumn {PRAGMA application_id}] != 1296323122 ||
                [ReferenceDb onecolumn {PRAGMA user_version}] != 2 ||
                [ReferenceDb onecolumn {SELECT value FROM metadata WHERE key='machteld_version'}] ne [::machteld::version]} {
            error "reference database version disagrees with the runtime"
        }
    } reason]} {
        catch {ReferenceDb close}
        DocsFail corrupt "docs: cannot open the embedded reference: $reason"
    }
    set DOCS_IDENTITY [dict create corpus_sha256 $reference_sha256 bytes $size]
    return $DOCS_IDENTITY
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
    DocsLoad
    if {[string length $requested] > 32767} {DocsFail badvalue "docs: document id is too long"}
    set key [DocsNormalizeAlias $requested]
    if {$key eq ""} {DocsFail badvalue "docs: document id must not be empty"}
    set direct [ReferenceDb eval {SELECT id,slug FROM fragment WHERE name=$key}]
    if {[llength $direct]} {return $direct}
    set section ""
    if {[regexp {^([^#]+)#(.+)$} $key -> base section]} {set key $base}
    set id [ReferenceDb onecolumn {SELECT id FROM page WHERE id=$key}]
    if {$id eq ""} {
        set alias [DocsNormalizeAlias $key]
        set choices [ReferenceDb eval {SELECT id FROM alias WHERE name=$alias ORDER BY id}]
        if {![llength $choices]} {DocsFail notfound "docs: no document matches \"$requested\""}
        if {[llength $choices] > 1} {DocsFail ambiguous "docs: \"$requested\" is ambiguous; candidates: [join $choices {, }]"}
        set id [lindex $choices 0]
    }
    if {$section ne "" && ![ReferenceDb exists {SELECT 1 FROM section WHERE id=$id AND slug=$section}]} {
        DocsFail notfound "docs: $id has no section \"$section\""
    }
    return [list $id $section]
}

proc ::machteld::DocsSummary {id} {
    set record {}
    ReferenceDb eval {SELECT id, product, version, kind AS type, title, summary, names FROM page WHERE id=$id} row {
        foreach key $row(*) {dict set record $key $row($key)}
    }
    dict set record sections [ReferenceDb eval {SELECT slug,heading FROM section WHERE id=$id ORDER BY start,slug}]
    return $record
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
    DocsLoad
    set scope [string tolower [dict get $options scope]]
    set type [string tolower [dict get $options type]]
    if {$scope eq ""} { set scope all }
    if {$type eq ""} { set type all }
    if {$scope ne "all" && ![ReferenceDb exists {SELECT 1 FROM product WHERE name=$scope}]} {
        DocsFail badvalue "docs: unknown scope \"[dict get $options scope]\""
    }
    if {$type ne "all" && ![ReferenceDb exists {SELECT 1 FROM page WHERE kind=$type}]} {
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
    set identity [DocsLoad]
    set products {}
    ReferenceDb eval {SELECT name,version,documents,manual_pages FROM product ORDER BY name} {
        dict set products $name [dict create version $version documents $documents manual_pages $manual_pages]
    }
    return [dict create schema 2 generator [ReferenceDb onecolumn {SELECT value FROM metadata WHERE key='generator'}] \
        machteld [::machteld::version] root self corpus_sha256 [dict get $identity corpus_sha256] products $products \
        documents [ReferenceDb onecolumn {SELECT count(*) FROM page}] aliases [ReferenceDb onecolumn {SELECT count(DISTINCT name) FROM alias}] \
        fragments [ReferenceDb onecolumn {SELECT count(*) FROM fragment}] formats {markdown}]
}

proc ::machteld::DocsSchema {args} {
    if {[llength $args]} { DocsFail usage {docs: wrong # args: should be "docs schema"} }
    return [dict create schema 2 catalog_schema 2 command docs \
        subcommands [dict create \
            status {} schema {} verify {} \
            list {?-scope product? ?-type type? ?-offset n? ?-limit n?} \
            get {id ?-section slug? ?-format markdown? ?-offset n? ?-limit n? ?-all 0|1?} \
            outline {id} \
            search {query ?-scope product? ?-type type? ?-offset n? ?-limit n?} \
            extract {nonexistent-directory}] \
        identifiers [dict create canonical {product/type/name; stable product/license, machteld/agent, and machteld/index exceptions} fragments {id#section} \
            aliases {unicode-lowercase, trim, and whitespace-collapse}] \
        pagination [dict create list_search [dict create default_limit 50 maximum_limit 200] \
            get [dict create unit characters default_limit 32768 maximum_limit 1048576]] \
        host [dict create full {{docs ...} {--docs ...}} \
            options {{--json} {--output FILE}}] \
        formats [dict create content {markdown} host {text json} \
            json_envelope [dict create success {ok true result value} failure {ok false error {domain DOCS code code message message}}]] \
        errorcode {MACHTELD DOCS code}]
}

proc ::machteld::DocsList {args} {
    set options [DocsFilterOptions {*}$args]
    dict with options {
        set ids [ReferenceDb eval {SELECT id FROM page WHERE ($scope='all' OR product=$scope)
                                  AND ($type='all' OR kind=$type) ORDER BY id}]
        set result [DocsPage $ids $offset $limit]
    }
    dict set result items [lmap id [dict get $result items] {DocsSummary $id}]
    return $result
}

proc ::machteld::DocsOutline {args} {
    if {[llength $args] != 1} { DocsFail usage {docs: wrong # args: should be "docs outline id"} }
    set id [lindex $args 0]
    lassign [DocsResolve $id] canonical fragment
    set record [DocsSummary $canonical]
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
    if {$format in {html source}} {DocsFail unsupported "docs: schema 2 provides Markdown"}
    if {$format ne "markdown"} {DocsFail badvalue "docs: -format must be markdown"}
    lassign [DocsResolve $id] canonical fragment
    set section [string tolower [dict get $options section]]
    if {[string length $section] > 32767} { DocsFail badvalue "docs: section is too long" }
    # Plain Machteld subcommands were page aliases before section lookup.
    # Keep an explicit -section on those spellings selecting from that page.
    if {$fragment ne "" && $section ne "" && $fragment ne $section &&
            ([string first # $id] >= 0 || ![string match machteld/command/* $canonical])} {
        DocsFail usage "docs: the id fragment and -section select different sections"
    }
    if {$section eq ""} { set section $fragment }
    set record [DocsSummary $canonical]
    lassign [ReferenceDb eval {SELECT path,sha256,bytes,characters FROM page WHERE id=$canonical}] path sha bytes total
    set start 0
    if {$section ne ""} {
        set span [ReferenceDb eval {SELECT start,end FROM section WHERE id=$canonical AND slug=$section}]
        if {![llength $span]} {DocsFail notfound "docs: $canonical has no section \"$section\""}
        lassign $span start end
        set total [expr {$end-$start}]
    }
    set effectiveLimit [expr {$all ? $total : $limit}]
    set effectiveOffset [expr {$all ? 0 : $offset}]
    set count [expr {max(0,min($effectiveLimit,$total-$effectiveOffset))}]
    set from [expr {1+$start+$effectiveOffset}]
    set page [ReferenceDb onecolumn {SELECT substr(body,$from,$count) FROM page WHERE id=$canonical}]
    set next [expr {$effectiveOffset+$count < $total ? $effectiveOffset+$count : ""}]
    return [dict create id $canonical requested_id $id product [dict get $record product] \
        version [dict get $record version] type [dict get $record type] title [dict get $record title] \
        summary [dict get $record summary] names [dict get $record names] format $format section $section \
        path $path sha256 $sha \
        bytes $bytes text $page total $total offset $effectiveOffset \
        limit $effectiveLimit returned [string length $page] truncated [expr {$next ne ""}] next $next]
}

proc ::machteld::DocsSearch {args} {
    if {![llength $args]} {DocsFail usage {docs: wrong # args: should be "docs search query ?options?"}}
    set query [lindex $args 0]
    if {[string length $query] > 4096} {DocsFail badvalue "docs: search query is too long"}
    set terms [regexp -all -inline {[[:alnum:]]+} $query]
    if {![llength $terms] || [llength $terms] > 64} {DocsFail badvalue "docs: search requires one to 64 terms"}
    # Quote every token before prefix matching. FTS operators supplied by the
    # caller are words. Bound parameters also keep SQL and query text separate.
    set expression [join [lmap term $terms {format {"%s"*} $term}] { AND }]
    set exact [DocsNormalizeAlias $query]
    # Some upstream spellings (for example tclsh90.exe) occur only in the
    # alias index. Sections can also have a qualified command/method name.
    set exactPages {
        WITH exact_page(id) AS (
            SELECT id FROM alias WHERE name=$exact
            UNION SELECT id FROM fragment WHERE name=$exact
        )
    }
    set options [DocsFilterOptions {*}[lrange $args 1 end]]
    lassign [ReferenceDb eval {SELECT id,slug FROM fragment WHERE name=$exact}] exactId exactSlug
    dict with options {
        set total [ReferenceDb onecolumn [string cat $exactPages {
            SELECT count(*) FROM page p
             WHERE ($scope='all' OR p.product=$scope) AND ($type='all' OR p.kind=$type)
               AND (p.id IN (SELECT id FROM exact_page) OR
                    p.rowid IN (SELECT rowid FROM search WHERE search MATCH $expression))
        }]]
        set items {}
        ReferenceDb eval [string cat $exactPages {
            SELECT p.id AS id, bm25(search,8,10,6,3,1) AS relevance,
                   snippet(search,4,'','',' ... ',20) AS sample, e.id IS NOT NULL AS direct
              FROM search JOIN page p ON p.rowid=search.rowid
              LEFT JOIN exact_page e ON e.id=p.id
             WHERE search MATCH $expression AND ($scope='all' OR p.product=$scope) AND ($type='all' OR p.kind=$type)
            UNION ALL
            SELECT p.id, 0.0, p.summary, 1 FROM exact_page e JOIN page p ON p.id=e.id
             WHERE ($scope='all' OR p.product=$scope) AND ($type='all' OR p.kind=$type)
               AND NOT EXISTS (SELECT 1 FROM search WHERE rowid=p.rowid AND search MATCH $expression)
             ORDER BY direct DESC, relevance, id
             LIMIT $limit OFFSET $offset
        }] {
            set record [DocsSummary $id]
            dict set record doc_ref [expr {$id eq $exactId ? "$id#$exactSlug" : $id}]
            dict set record score [expr {round(-1000000*$relevance)}]
            dict set record snippet [string range $sample 0 239]
            lappend items $record
        }
        set returned [llength $items]
        set next [expr {$offset+$returned < $total ? $offset+$returned : ""}]
        return [dict create items $items total $total offset $offset limit $limit returned $returned truncated [expr {$next ne ""}] next $next]
    }
}

proc ::machteld::DocsVerify {args} {
    if {[llength $args]} {DocsFail usage {docs: wrong # args: should be "docs verify"}}
    set identity [DocsLoad]
    set database [DocsDatabaseFile [DocsRoot]]
    if {[hash file sha256 $database] ne [dict get $identity corpus_sha256] ||
            [ReferenceDb onecolumn {PRAGMA integrity_check}] ne "ok" ||
            [ReferenceDb eval {PRAGMA foreign_key_check}] ne ""} {
        DocsFail corrupt "docs: reference database failed verification"
    }
    return [dict create ok 1 documents [ReferenceDb onecolumn {SELECT count(*) FROM page}] files 1 \
        bytes [dict get $identity bytes] corpus_sha256 [dict get $identity corpus_sha256]]
}

proc ::machteld::DocsNativeChildren {directory} {
    set result {}
    foreach item [concat [glob -nocomplain -directory $directory *] [glob -nocomplain -types hidden -directory $directory *]] {
        if {[file tail $item] in {. ..}} continue
        dict set result [file normalize $item] $item
    }
    return [lsort [dict values $result]]
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
    set identity [DocsLoad]
    set database [DocsDatabaseFile [DocsRoot]]
    set stage ""
    for {set tries 0} {$tries < 32} {incr tries} {
        if {[catch {binary encode hex [hash random 16]} suffix]} {
            DocsFail oserror "docs: cannot generate an extraction staging identity"
        }
        set candidate [file join $parent .machteld-docs-$suffix]
        if {![catch {DirectoryStage create $candidate} message options]} {
            set stage $candidate
            break
        }
        if {[dict get $options -errorcode] ne {MACHTELD PUBLISH exists}} {
            DocsFail oserror "docs: cannot create extraction staging directory: $message"
        }
    }
    if {$stage eq ""} { DocsFail oserror "docs: cannot reserve an extraction staging path" }
    set stagedIdentity ""
    try {
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
        file copy $database [file join $stage reference.db]
        if {[catch {canon $stage} currentStage] ||
                [list [dict get $currentStage volume] [dict get $currentStage file]] ne
                    [list [dict get $stagedIdentity volume] [dict get $stagedIdentity file]] ||
                [catch {canon $parent} currentParent] ||
                [list [dict get $currentParent volume] [dict get $currentParent file]] ne
                    [list [dict get $parentIdentity volume] [dict get $parentIdentity file]]} {
            DocsFail oserror "docs: extraction staging identity changed"
        }
        if {[catch {links $stage} stageSurvey] || [llength [dict get $stageSurvey errors]] ||
                [llength [dict get $stageSurvey links]] || [llength [dict get $stageSurvey entered]]} {
            DocsFail corrupt "docs: staged extraction inventory changed"
        }
        set staged [DocsDatabaseFile $stage]
        if {[file size $staged] != [dict get $identity bytes] ||
                [hash file sha256 $staged] ne [dict get $identity corpus_sha256]} {
            DocsFail corrupt "docs: staged reference database failed verification"
        }
        try {
            DirectoryStage publish $stage $destination
        } trap {MACHTELD PUBLISH exists} {message options} {
            DocsFail exists "docs: extraction destination appeared during staging"
        }
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
    return [dict create path $destination files 1 bytes [dict get $identity bytes] \
        corpus_sha256 [dict get $identity corpus_sha256]]
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
    if {[dict exists $item doc_ref]} { lappend pairs doc_ref [DocsJString [dict get $item doc_ref]] }
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
            set formats [DocsJObject [list content [DocsJStringArray {markdown}] \
                host [DocsJStringArray {text json}] json_envelope $envelope]]
            set host [DocsJObject [list full [DocsJStringArray {{docs ...} {--docs ...}}] \
                options [DocsJStringArray {{--json} {--output FILE}}]]]
            return [DocsJObject [list schema 2 catalog_schema 2 command [DocsJString docs] \
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
                set ref [expr {$subcommand eq "search" ? [dict get $item doc_ref] : [dict get $item id]}]
                append output "$ref\t[dict get $item title]\t[dict get $item summary]\n"
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
    if {[catch {::machteld::publish bytes $destination [encoding convertto utf-8 $text]} message options]} {
        set nativeCode [lindex [dict get $options -errorcode] 2]
        set code [expr {$nativeCode in {badvalue notfound} ? "badvalue" : "oserror"}]
        DocsFail $code "docs: cannot publish --output: $message"
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
        if {[catch {DocsGet machteld/start-here -all 1} page options]} {
            if {![dict exists $options -errorcode] ||
                    [dict get $options -errorcode] ne {MACHTELD DOCS unsupported}} {
                DocsHelpError $page $options
            }
            return "Machteld [version -product]\n\nThis executable carries no embedded reference pack.\nUse the full Machteld [version -product] executable for offline documentation.\n\nRuntime commands remain available. Use `manifest` for command metadata\nand `docs schema` for the documentation query contract."
        }
        return [dict get $page text]
    }
    set query [join $args " "]
    if {![catch {DocsGet $query} result options]} {
        set text [dict get $result text]
        if {[dict get $result truncated]} {
            append text "\n\n\[Page truncated; continue with: docs get [dict get $result id] -offset [dict get $result next]\]"
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

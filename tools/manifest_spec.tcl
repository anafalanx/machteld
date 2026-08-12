# Explicit public contract for commands implemented in C.
#
# This is authored metadata, not a source-code parser.  tools/genmanifest.tcl
# verifies that its command set is exactly the set registered by src/*.c and
# emits the packaged `set ::machteld::MANIFEST` assignment.

namespace eval ::machteld::manifest {}

# Internal commands are registered for cooperation with the Tcl prelude, but
# are intentionally absent from the public manifest.
set ::machteld::manifest::private {EntryCheck Publish}

set ::machteld::manifest::native {
    canon {
        kind c domain DIRS codes {badvalue dangling notfound oserror} options {}
        returns {file kind links path volume}
    }
    child {
        kind c domain CHILD
        codes {badvalue launch nohandle notfound oserror usage}
        options {-arg0 -channels -cpu -dir -env -mem -stdin -timeout}
        subcommands {
            start {options {-arg0 -channels -cpu -dir -env -mem -stdin -timeout}}
            wait  {options -timeout returns {err exit out pid status truncated}}
            kill  {options {}}
            info  {options {}}
            list  {options {}}
            close {options {}}
        }
    }
    detach {
        kind c domain DETACH codes {badvalue launch notfound oserror usage}
        options {-arg0 -dir -env}
    }
    dirs {
        kind c domain DIRS codes {badvalue notfound oserror usage}
        options {-depth -prune}
        returns {depthlimited dirs errors links maxdepth paths pruned root}
    }
    hash {
        kind c domain HASH codes {badvalue nohandle notfound oserror usage}
        options -binary
        subcommands {
            sum        {options -binary}
            file       {options -binary}
            hmac       {options -binary}
            start      {options {}}
            update     {options {}}
            final      {options -binary}
            list       {options {}}
            algorithms {options {}}
            random     {options {}}
        }
    }
    http {
        kind c domain HTTP
        codes {badvalue notfound oserror timeout tls toobig usage}
        options {-agent -headers -maxbody -timeout -type}
        subcommands {
            get  {options {-agent -headers -maxbody -timeout}}
            post {options {-agent -headers -maxbody -timeout -type}}
        }
        returns {body bytes headers rawheaders status}
    }
    json {
        kind c domain JSON codes {depth parse usage} options {-dict -list}
        subcommands {decode {options {}} encode {options {-dict -list}}}
    }
    links {
        kind c domain DIRS codes {badvalue notfound oserror usage}
        options {-depth -hardlinks -prune}
        returns {depthlimited dirs entered errors files links maxdepth multilinked pruned root}
    }
    mtps {
        kind c domain MTPS codes {badvalue denied notfound oserror usage}
        options -tree
        subcommands {
            list {options {}}
            info {options {} returns {access cpu exe mem name pid ppid private started threads}}
            kill {options -tree returns {killed failed}}
        }
    }
    pty {
        kind c domain PTY
        codes {badvalue launch nohandle notfound oserror usage}
        options {-arg0 -cpu -dir -env -mem -timeout}
        subcommands {
            spawn {options {-arg0 -cpu -dir -env -mem}}
            send  {options {}}
            read  {options -timeout}
            close {options {}}
            list  {options {}}
            info  {options {} returns {pending pid running token}}
        }
    }
    run {
        kind c domain RUN codes {badvalue launch notfound oserror usage}
        options {-arg0 -cpu -dir -env -inherit -mem -onerr -onout -stdin -timeout}
        returns {err exit out pid status truncated}
    }
    store {
        kind c domain STORE codes {badvalue notfound notopen sqlite} options {}
        subcommands {
            open {options {}} put {options {}} get {options {}}
            keys {options {}} del {options {}} close {options {}}
            version {options {}}
        }
    }
    wait {
        kind c domain WAIT codes {badvalue nohandle oserror usage} options -any
    }
    watch {
        kind c domain WATCH codes {badvalue nohandle notfound oserror usage}
        options {-raw -recursive -timeout}
        subcommands {
            start {options -recursive}
            read  {options {-raw -timeout}}
            close {options {}}
            list  {options {}}
            info  {options {} returns {armed directory dropped failed pending recursive token win32}}
        }
    }
}

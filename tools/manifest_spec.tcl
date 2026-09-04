# Explicit public contract for commands implemented in C.
#
# This is authored metadata, not a source-code parser.  tools/genmanifest.tcl
# verifies that its command set is exactly the set registered by src/*.c and
# emits the packaged `set ::machteld::MANIFEST` assignment.

namespace eval ::machteld::manifest {}

# Internal commands are registered for cooperation with the Tcl prelude, but
# are intentionally absent from the public manifest.
set ::machteld::manifest::private {EntryCheck PayloadRoot Publish}

set ::machteld::manifest::native {
    canon {
        kind c domain DIRS codes {badvalue dangling notfound oserror} options {}
        doc machteld/command/canon
        returns {file kind links path volume}
    }
    child {
        kind c domain CHILD
        doc machteld/command/child
        codes {badvalue launch nohandle notfound oserror usage}
        options {-arg0 -channels -cpu -dir -env -mem -stdin -timeout}
        subcommands {
            start {options {-arg0 -channels -cpu -dir -env -mem -stdin -timeout} doc machteld/command/child#start}
            wait  {options -timeout returns {err exit out pid status truncated} doc machteld/command/child#wait}
            kill  {options {} doc machteld/command/child#kill}
            info  {options {} doc machteld/command/child#info}
            list  {options {} doc machteld/command/child#list}
            close {options {} doc machteld/command/child#close}
        }
    }
    detach {
        kind c domain DETACH codes {badvalue launch notfound oserror usage}
        doc machteld/command/detach
        options {-arg0 -dir -env}
    }
    dirs {
        kind c domain DIRS codes {badvalue notfound oserror usage}
        doc machteld/command/dirs
        options {-depth -prune}
        returns {depthlimited dirs errors links maxdepth paths pruned root}
    }
    hash {
        kind c domain HASH codes {badvalue nohandle notfound oserror usage}
        doc machteld/command/hash
        options -binary
        subcommands {
            sum        {options -binary doc machteld/command/hash#sum}
            file       {options -binary doc machteld/command/hash#file}
            hmac       {options -binary doc machteld/command/hash#hmac}
            start      {options {} doc machteld/command/hash#start}
            update     {options {} doc machteld/command/hash#update}
            final      {options -binary doc machteld/command/hash#final}
            list       {options {} doc machteld/command/hash#list}
            algorithms {options {} doc machteld/command/hash#algorithms}
            random     {options {} doc machteld/command/hash#random}
        }
    }
    http {
        kind c domain HTTP
        doc machteld/command/http
        codes {badvalue notfound oserror timeout tls toobig usage}
        options {-agent -headers -maxbody -redirect -timeout -type}
        subcommands {
            get  {options {-agent -headers -maxbody -redirect -timeout} doc machteld/command/http#get}
            post {options {-agent -headers -maxbody -redirect -timeout -type} doc machteld/command/http#post}
        }
        returns {body bytes headers rawheaders status}
    }
    json {
        kind c domain JSON codes {absent depth limit parse strict type usage}
        options {-dict -list -maxbytes -plain -typed}
        doc machteld/command/json
        subcommands {
            decode {options {-maxbytes -typed} doc machteld/command/json#decode}
            encode {options {-dict -list -plain} doc machteld/command/json#encode}
            value  {options {} doc machteld/command/json#value}
            type   {options {} doc machteld/command/json#type}
            unwrap {options {} doc machteld/command/json#unwrap}
            get    {options {} doc machteld/command/json#get}
            exists {options {} doc machteld/command/json#exists}
        }
    }
    links {
        kind c domain DIRS codes {badvalue notfound oserror usage}
        doc machteld/command/links
        options {-depth -hardlinks -prune}
        returns {depthlimited dirs entered errors files links maxdepth multilinked pruned root}
    }
    mtps {
        kind c domain MTPS codes {badvalue denied notfound oserror usage}
        doc machteld/command/mtps
        options -tree
        subcommands {
            list {options {} doc machteld/command/mtps#list}
            info {options {} returns {access cpu exe mem name pid ppid private started threads} doc machteld/command/mtps#info}
            kill {options -tree returns {killed failed} doc machteld/command/mtps#kill}
        }
    }
    pty {
        kind c domain PTY
        doc machteld/command/pty
        codes {badvalue launch limit nohandle notfound oserror usage}
        options {-arg0 -cpu -dir -env -mem -timeout}
        subcommands {
            spawn {options {-arg0 -cpu -dir -env -mem} doc machteld/command/pty#spawn}
            send  {options {} doc machteld/command/pty#send}
            read  {options -timeout doc machteld/command/pty#read}
            close {options {} doc machteld/command/pty#close}
            list  {options {} doc machteld/command/pty#list}
            info  {options {} returns {pending pid running token} doc machteld/command/pty#info}
        }
    }
    run {
        kind c domain RUN codes {badvalue launch notfound oserror usage}
        doc machteld/command/run
        options {-arg0 -cpu -dir -env -inherit -mem -onerr -onout -stdin -timeout}
        returns {err exit out pid status truncated}
    }
    store {
        kind c domain STORE codes {badvalue notfound notopen sqlite} options {}
        doc machteld/command/store
        subcommands {
            open {options {} doc machteld/command/store#open}
            put {options {} doc machteld/command/store#put}
            get {options {} doc machteld/command/store#get}
            keys {options {} doc machteld/command/store#keys}
            del {options {} doc machteld/command/store#del}
            close {options {} doc machteld/command/store#close}
            version {options {} doc machteld/command/store#version}
        }
    }
    wait {
        kind c domain WAIT codes {badvalue nohandle oserror usage} options -any
        doc machteld/command/wait
    }
    watch {
        kind c domain WATCH codes {badvalue nohandle notfound oserror usage}
        doc machteld/command/watch
        options {-raw -recursive -timeout}
        subcommands {
            start {options -recursive doc machteld/command/watch#start}
            read  {options {-raw -timeout} doc machteld/command/watch#read}
            close {options {} doc machteld/command/watch#close}
            list  {options {} doc machteld/command/watch#list}
            info  {options {} returns {armed directory dropped failed pending recursive token win32} doc machteld/command/watch#info}
        }
    }
}

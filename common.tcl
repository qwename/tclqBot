# common.tcl --
#
#       This file implements the Tcl code for common procedures using the
#       discord.tcl library. Ideally, the procedures are evaluated inside a safe
#       interpreter for each server, and also saved into a database for
#       retrieval later.
#
# Copyright (c) 2016, Yixin Zhang
#
# See the file "LICENSE" for information on usage and redistribution of this
# file.

proc say { msg } {
    sendMessage $::channel_id $msg
}

proc display_proc { name } {
    if {[llength [info proc $name]] == 0} {
        return
    }
    set args [list]
    foreach arg [info args $name] {
        if {[info default $name $arg default]} {
            lappend args "{$arg {$default}}"
        } else {
            lappend args $arg
        }
    }
    set procStr "proc $name { [join $args] } {[info body $name]}"
    say "```tcl\n$procStr```"
}

proc purge { {number {1}} } {
    if {![string is integer -strict $number] || $number < 1 || $number > 100} {
        return
    }
    deleteMessage $::channel_id [dict get $::data id]
    set messageIds [list]
    foreach message [getMessages $::channel_id [dict create limit $number] 1] {
        lappend messageIds [dict get $message id]
    }
    if {$number == 1} {
        deleteMessage $::channel_id [lindex $messageIds 0]
    } else {
        bulkDeleteMessages $::channel_id $messageIds
    }
}

proc coin { {count 1} } {
    if {![string is integer -strict $count] || $count <= 0} {
        return
    }
    set heads 0
    set tails 0
    for {set i 0} {$i < $count} {incr i} {
        if {[expr {rand() < 0.5}]} {
            incr heads
        } else {
            incr tails
        }
    }
    set headsPercent [expr {double($heads)/$count * 100.0}]
    set tailsPercent [expr {double($tails)/$count * 100.0}]
    say "$count flips\n$heads heads (${headsPercent}%)\n$tails tails (${tailsPercent}%)"
}

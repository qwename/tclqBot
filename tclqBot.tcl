#!/bin/sh
# This line and the trailing backslash  is required so that tclsh ignores the next line \
exec tclsh8.6 "$0" "${1+"$@"}"

# tclqBot.tcl --
#
#       This file implements the Tcl code for a Discord bot written with the
#       discord.tcl library.
#
# Copyright (c) 2016, Yixin Zhang
#
# See the file "LICENSE" for information on usage and redistribution of this
# file.

package require Tcl 8.6
package require sqlite3
package require logger

set scriptDir [file dirname [info script]]
# Add parent directory to auto_path so that Tcl can find the discord package.
lappend ::auto_path "${scriptDir}/../"
package require discord

source "${scriptDir}/sandbox_procs.tcl"
# Set ownerId and token variables
source "${scriptDir}/private.tcl"

set log [logger::init tclqBot]
${log}::setlevel debug

# Open sqlite3 database
sqlite3 infoDb "${scriptDir}/info.sqlite3"
infoDb eval { CREATE TABLE IF NOT EXISTS
    procs(guildId TEXT, name BLOB, args BLOB, body BLOB,
            UNIQUE(guildId, name) ON CONFLICT REPLACE)
}
infoDb eval { CREATE TABLE IF NOT EXISTS
    bot(guildId TEXT PRIMARY KEY, trigger BLOB)
}
infoDb eval { CREATE INDEX IF NOT EXISTS procsGuildIdIdx ON procs(guildId) }


proc logDebug { text } {
    variable debugFile
    variable debugLog
    variable maxSize
    if {[file size $debugFile] >= $maxSize} {
        close $debugLog
        set fileName "${debugFile}.[clock milliseconds]"
        if {[catch {file copy $debugFile $fileName} res]} {
            puts stderr $res
            set suffix 0
            while {$suffix < 10} {
                if {[catch {file copy $debugFile ${fileName}.${suffix}} res]} {
                    puts stderr $res
                } else {
                    break
                }
            }
        }
        if {[catch {open $debugFile "w"} debugLog]} {
            puts stderr $debugLog
            set debugLog {}
        }
    }
    if {$debugLog eq {}} {
        return
    }
    puts $debugLog \
            "[clock format [clock seconds] -format {[%Y-%m-%d %T]}] $text"
    flush $debugLog
}

# Lambda for "unique" number
coroutine id apply { { } {
    set x 0
    while 1 {
        yield $x
        incr x
    }
}}

proc setupSandboxEval { sandbox sessionNs data } {
    set channel_id [dict get $data channel_id]
    set guild_id [dict get [set ${sessionNs}::channels] $channel_id]
    set guild [dict get [set ${sessionNs}::guilds] $guild_id]
    set channels [dict get $guild channels]
    set channel {}
    foreach chan $channels {
        if {[dict get $chan id] eq $channel_id} {
            set channel $chan
            break
        }
    }
    foreach varName [list data channel_id guild_id guild channel] {
        $sandbox eval [list set ::$varName [set $varName]]
    }
    foreach varName [list author content] {
        $sandbox eval [list set ::$varName [dict get $data $varName]]
    }
}

proc getTrigger { guildId } {
    return [dict get $::guildBotTriggers $guildId]
}

proc setTrigger { guildId pattern } {
    dict set ::guildBotTriggers $guildId $pattern
    infoDb eval {INSERT OR REPLACE INTO bot
            VALUES($guildId, $pattern)
    }
}

proc handlePlease { sessionNs data text } {
    variable log
    set channelId [dict get $data channel_id]
    switch -regexp -matchvar match -- $text {
        {^pmhelp$} -
        {^help$} {
            set guildId [dict get [set ${sessionNs}::channels] $channelId]
            set trigger [getTrigger $guildId]
            set helpMsg "
**tclqBot**, made with discord.tcl $discord::version.
Default trigger (always enabled): `$::defaultTrigger`
Current trigger: `$trigger`
**% Please pmhelp**
    DM this message to yourself.

**% Please help**
    Display this message in the current channel.

**% Please change_trigger** *?pattern?*
    Changes the regex expression for matching message content to *pattern*. If
    no *pattern* is specified, this outputs the current regex to the channel.
    Only the string in the first capture group, if any, will be parsed.

**% Please eval** *script*
    Evaluates *script* in Tcl's safe interpreter.

**% Please** *command ?arg ...?*
    If *command* is a proc in the safe interpreter, it will be called with the
    *arg* arguments, if any.
"
            set cmd [lindex $match 0]
            if {$cmd eq "help"} {
                discord sendMessage $sessionNs $channelId $helpMsg
            } elseif {$cmd eq "pmhelp"} {
                set userId [dict get [dict get $data author] id]
                if {[catch {discord sendDM $sessionNs $userId $helpMsg}]} {
                    set resCoro [discord createDM $sessionNs $userId 1]
                    yield
                    set response [$resCoro]
                    set data [lindex $response 0]
                    if {$data ne {} && [dict $data exists recipients]} {
                        discord createDM $sessionNs $userId $helpMsg
                    }
                }
            }
        }
        {^change_trigger(?: ```(.*)```)?$} -
        {^change_trigger(?: `(.*)`)?$} -
        {^change_trigger(?: (.*))?$} {
            set pattern [lindex $match 1]
            set guildId [dict get [set ${sessionNs}::channels] $channelId]
            set msg ""
            if {$pattern ne {}} {
                setTrigger $guildId $pattern
                set msg "Trigger changed to ```$pattern```"
            } else {
                set trigger [getTrigger $guildId]
                set msg "Current trigger: ```$trigger```"
            }
            discord sendMessage $sessionNs $channelId $msg
        }
        {^eval ```(.*)```$} -
        {^eval `(.*)`$} -
        {^eval (.*)$} {
            set script [lindex $match 1]
            set guildId [dict get [set ${sessionNs}::channels] $channelId]
            set sandbox [dict get $::guildInterps $guildId]
            $sandbox limit time -seconds {}
            setupSandboxEval $sandbox $sessionNs $data
            $sandbox limit time -seconds [expr {[clock seconds] + 2}]
            catch {
                $sandbox eval [list uplevel #0 $script]
            } res
            if {[string length $res] > 0} {
                ${log}::debug "sandbox eval return: $res"
                set resCoro [discord sendMessage $sessionNs $channelId $res 1]
                yield $resCoro
                set response [$resCoro]
                set data [lindex $response 0]
                if {$data eq {} || ![dict exists $data id]} {
                    ${log}::error [lindex $response 1]
                } else {
                    set messageId [dict get $data id]
                    ${log}::debug "handlePlease: Sent message ID: $messageId"
                }
            }
        }
        {^([^ ]+)(?: (.*))?$} {
            set guildId [dict get [set ${sessionNs}::channels] $channelId]
            set sandbox [dict get $::guildInterps $guildId]
            set command [lindex $match 1]
            # Check if command is in sandbox
            $sandbox limit time -seconds {}
            if {[llength [$sandbox eval [list info procs $command]]] > 0} {
                set args [lindex $match 2]
                setupSandboxEval $sandbox $sessionNs $data
                $sandbox limit time -seconds [expr {[clock seconds] + 2}]
                # Only send the result if an error occurred.
                if {[catch {$sandbox eval [list uplevel #0 $command $args]} \
                        res] && [string length $res] > 0} {
                    ${log}::debug "sandbox eval return: $res"
                    set resCoro [discord sendMessage $sessionNs $channelId \
                            $res 1]
                    yield $resCoro
                    set response [$resCoro]
                    set data [lindex $response 0]
                    if {$data eq {}} {
                        ${log}::error [lindex $response 1]
                    } else {
                        set messageId [dict get $data id]
                        ${log}::debug \
                                "handlePlease: Sent message ID: $messageId"
                    }
                }
            }
        }
    }
}

proc messageCreate { sessionNs event data } {
    set id [dict get $data author id]
    if {$id eq [dict get [set ${sessionNs}::self] id]} {
        return
    }
    if {[dict exists $data bot] && [dict get $data bot] eq "true"} {
        return
    }
    if {![catch {dict get [set ${sessionNs}::users] $id} user]} {
        if {[dict exists $user bot] && [dict get $user bot] eq "true"} {
            return
        }
    }
    set content [dict get $data content]
    set channelId [dict get $data channel_id]
    if {$channelId in [dict keys [set ${sessionNs}::dmChannels]]} {
        return
    }
    set guildId [dict get [set ${sessionNs}::channels] $channelId]
    set trigger [dict get $::guildBotTriggers $guildId]
    if {[regexp $::defaultTrigger $content -> text] \
            || [regexp $trigger $content -> text]} {
        coroutine handlePlease[::id] handlePlease $sessionNs $data $text
    }
}

proc guildCreate { sessionNs event data } {
    # Setup safe interp for "Please eval"
    set guildId [dict get $data id]
    dict set ::guildInterps $guildId [interp create -safe]
    set sandbox [dict get $::guildInterps $guildId]

    # Restore saved bot trigger regex
    set savedTriggers [infoDb eval {SELECT trigger FROM bot WHERE
            guildId IS $guildId}]
    set numTriggers [llength $savedTriggers]
    if {$numTriggers > 0} {
        if {$numTriggers > 1} {
            ${log}::error "More than one trigger found for guild $guildId!"
        }
        dict set ::guildBotTriggers $guildId [lindex $savedTriggers 0]
    } else {
        dict set ::guildBotTriggers $guildId $::defaultTrigger
        infoDb eval {INSERT INTO bot VALUES($guildId, $::defaultTrigger)}
    }

    foreach call [list sendMessage createDM sendDM] {
        $sandbox alias $call discord $call $sessionNs
    }
    set protectCmds [$sandbox eval info commands]
    # Restore saved procs
    infoDb eval {SELECT * FROM procs WHERE guildId IS $guildId} proc {
        $sandbox eval [list proc $proc(name) $proc(args) $proc(body)]
    }
    foreach cmd [list proc rename after] {
        $sandbox hide $cmd
    }
    $sandbox alias proc procSave $sandbox $guildId $protectCmds
    $sandbox alias rename renameSave $sandbox $guildId $protectCmds

}

proc registerCallbacks { sessionNs } {
    discord setCallback $sessionNs GUILD_CREATE ::guildCreate
    discord setCallback $sessionNs MESSAGE_CREATE ::messageCreate
}

# For console stdin eval
proc asyncGets {chan {callback ""}} {
    if {[gets $chan line] >= 0} {
        if {[string trim $line] ne ""} {
            catch {uplevel #0 $line} out
            puts $out
        }
    }
    if [eof $chan] { 
        set ::forever 0
        return
    }
    puts -nonewline "% "
    flush stdout
}

# Ad-hoc log file size limiting follows
set debugFile "${scriptDir}/debug"
set debugLog {}
set maxSize [expr {4 * 1024**2}]

if {[catch {open $debugFile "a"} debugLog]} {
    puts stderr $debugLog
} else {
    ${discord::log}::logproc debug ::logDebug
}

# Set to 0 for a cleaner debug log.
discord::gateway logWsMsg 1
${discord::log}::setlevel debug

puts -nonewline "% "
flush stdout
fconfigure stdin -blocking 0 -buffering line
fileevent stdin readable [list asyncGets stdin]

set defaultTrigger {^% Please (.*)$}
set guildBotTriggers [dict create]
set guildInterps [dict create]

set startTime [clock seconds]
set session [discord connect $token ::registerCallbacks]

vwait forever

if {[catch {discord disconnect $session} res]} {
    puts stderr $res
}
close $debugLog
${log}::delete
infoDb close

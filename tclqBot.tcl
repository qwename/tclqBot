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
infoDb eval {CREATE INDEX IF NOT EXISTS procsGuildIdIdx ON procs(guildId)}

proc procSave { sandbox guildId name args body } {
    # Don't allow redefining these procs!
    if {[regexp {^:*(?:proc|rename)$} $name]} {
        return
    }
    if {![catch {$sandbox invokehidden -global proc $name $args $body} res]} {
        infoDb eval {INSERT OR REPLACE INTO procs
            VALUES($guildId, $name, $args, $body)
        }
        return
    } else {
        return -code error $res
    }
}

proc renameSave { sandbox guildId oldName newName } {
    # Don't allow renaming of these!
    if {[regexp {^:*(?:proc|rename)$} $oldName]} {
        return
    }
    if {![catch {$sandbox invokehidden -global rename $oldName $newName} res]} {
        if {$newName eq {}} {
            infoDb eval {DELETE FROM procs WHERE name IS $oldName}
        } else {
            infoDb eval {UPDATE procs SET name = $newName WHERE
                    name IS $oldName}
        }
        return
    } else {
        return -code error $res
    }
}

# Set ownerId and token variables
source "${scriptDir}/private.tcl"

# Ad-hoc log file size limiting follows
set debugFile "${scriptDir}/debug"
set debugLog {}
set maxSize [expr {4 * 1024**2}]
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

if {[catch {open $debugFile "a"} debugLog]} {
    puts stderr $debugLog
} else {
    ${discord::log}::logproc debug ::logDebug
}

# Set to 0 for a cleaner debug log.
discord::gateway logWsMsg 1
${discord::log}::setlevel debug

# Lambda for "unique" number
coroutine id apply { { } {
    set x 0
    while 1 {
        yield $x
        incr x
    }
}}

proc handlePlease { sessionNs data text } {
    variable log
    set channelId [dict get $data channel_id]
    switch -regexp -matchvar match -- $text {
        {^eval ```(.*)```$} -
        {^eval `(.*)`$} -
        {^eval (.*)$} {
            set code [lindex $match 1]
            set guildId [dict get [set ${sessionNs}::channels] $channelId]
            set sandbox [dict get $::guildInterps $guildId]
            $sandbox limit time -seconds [expr {[clock seconds] + 2}]
            catch {
                $sandbox eval [list set ::data $data]
                $sandbox eval [list uplevel #0 $code]
            } res
            if {[string length $res] > 0} {
                set resCoro [discord sendMessage $::session $channelId $res]
                yield $resCoro
                set response [$resCoro]
                set data [lindex $response 0]
                if {$data eq {}} {
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
            $sandbox limit time -seconds [expr {[clock seconds] + 2}]
            set cmd [lindex $match 1]
            set args [lindex $match 2]
            if {[llength [$sandbox eval [list uplevel #0 info proc $cmd]]] \
                    > 0} {

                # Only send the result if an error occurred.
                if {[catch { $sandbox eval [list set ::data $data]
                             $sandbox eval [list uplevel #0 $cmd {*}$args]
                        } res] && [string length $res] > 0} {
                    set resCoro [discord sendMessage $::session $channelId $res]
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
    set guildId [dict get [set ${sessionNs}::channels] $channelId]
    set botTrigger [dict get $::guildBotTriggers $guildId]
    if {[regexp $botTrigger $content -> text]} {
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
    # Restore saved procs
    infoDb eval {SELECT * FROM procs WHERE guildId IS $guildId} proc {
        $sandbox eval [list proc $proc(name) $proc(args) $proc(body)]
    }
    # Use procSave to save proc by guildId
    $sandbox hide proc
    $sandbox hide rename
    $sandbox alias proc procSave $sandbox $guildId
    $sandbox alias rename renameSave $sandbox $guildId

    $sandbox alias self getSession self
    $sandbox alias guilds getSession guilds
    $sandbox alias users getSession users
    $sandbox alias dmChannels getSession dmChannels
    $sandbox alias send discord sendMessage $sessionNs
    #$sandbox limit command -value 100
}

proc registerCallbacks { sessionNs } {
    discord setCallback $sessionNs GUILD_CREATE ::guildCreate
    discord setCallback $sessionNs MESSAGE_CREATE ::messageCreate
}

proc getSession { varName } {
    return [set ${::session}::${varName}]
}

set defaultTrigger {^Please (.*)$}
set guildBotTriggers [dict create]
set guildInterps [dict create]
set session [discord connect $token ::registerCallbacks]

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

puts -nonewline "% "
flush stdout
fconfigure stdin -blocking 0 -buffering line
fileevent stdin readable [list asyncGets stdin]

vwait forever

if {[catch {discord disconnect $session} res]} {
    puts stderr $res
}
close $debugLog
${log}::delete
infoDb close

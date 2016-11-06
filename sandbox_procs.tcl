proc procSave { sandbox guildId protectCmds name args body } {
    if {[regexp "^:*(?:[join $protectCmds |])$" $name]} {
        return
    }
    set currentSize [dict get $::guildSavedProcsSize $guildId]
    set newProc(name) $name
    set newProc(args) $args
    set newProc(body) $body
    set size [string length [array get newProc]]
    if {[expr {$currentSize + $size > $::maxSavedProcsSize}]} {
        return -code error "Max size for procs reached: $::maxSavedProcsSize"
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

proc renameSave { sandbox guildId protectCmds oldName newName } {
    if {[regexp "^:*(?:[join $protectCmds |])$" $oldName]} {
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

proc setMemberPermissions { sessionNs guildId userId permList } {
    foreach member [dict get [set ${sessionNs}::guilds] $guildId members] {
        if {[dict get $member user id] eq $userId} {
            dict set ::guildPermissions $guildId $userId $permList
            infoDb eval {INSERT OR REPLACE INTO perms
                        VALUES($guildId, $userId, $permList)
                    }
            return
        }
    }
    return -code error "No such member in guild."
}

proc getMemberPermissions { sessionNs guildId userId } {
    if {[catch {dict get $::guildPermissions $guildId $userId} permList]} {
        return {}
    } else {
        return $permList
    }
}

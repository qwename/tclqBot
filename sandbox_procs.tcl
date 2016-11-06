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
    lassign [discord getMessageFormat $userId] type id
    if {$type in [list user nickname]} {
        set userId $id
    }
    foreach member [dict get [set ${sessionNs}::guilds] $guildId members] {
        if {[dict get $member user id] eq $userId} {
            dict set ::guildPermissions $guildId $userId $permList
            infoDb eval {INSERT OR REPLACE INTO perms
                        VALUES($guildId, $userId, $permList)
                    }
            return $permList
        }
    }
    return -code error "No such member in guild."
}

proc getMemberPermissions { sessionNs guildId userId } {
    lassign [discord getMessageFormat $userId] type id
    if {$type in [list user nickname]} {
        set userId $id
    }
    if {[catch {dict get $::guildPermissions $guildId $userId} permList]} {
        return {}
    } else {
        return $permList
    }
}

proc addMemberPermissions { sessionNs guildId userId permList } {
    lassign [discord getMessageFormat $userId] type id
    if {$type in [list user nickname]} {
        set userId $id
    }
    foreach member [dict get [set ${sessionNs}::guilds] $guildId members] {
        if {[dict get $member user id] eq $userId} {
            if {[catch {dict get $::guildPermissions $guildId $userId} \
                    currentPermList]} {
                set currentPermList [list]
            }
            lappend currentPermList {*}$permList
            dict set ::guildPermissions $guildId $userId $currentPermList
            infoDb eval {INSERT OR REPLACE INTO perms
                        VALUES($guildId, $userId, $currentPermList)
                    }
            return $currentPermList
        }
    }
    return -code error "No such member in guild."
}

proc delMemberPermissions { sessionNs guildId userId permList } {
    lassign [discord getMessageFormat $userId] type id
    if {$type in [list user nickname]} {
        set userId $id
    }
    foreach member [dict get [set ${sessionNs}::guilds] $guildId members] {
        if {[dict get $member user id] eq $userId} {
            if {[catch {dict get $::guildPermissions $guildId $userId} \
                    currentPermList]} {
                set currentPermList [list]
            }
            foreach perm $permList {
                set currentPermList \
                        [lsearch -all -inline -not $currentPermList $perm]
            }
            dict set ::guildPermissions $guildId $userId $currentPermList
            infoDb eval {INSERT OR REPLACE INTO perms
                        VALUES($guildId, $userId, $currentPermList)
                    }
            return $currentPermList
        }
    }
    return -code error "No such member in guild."
}

proc getGuildCallbacks { guildId } {
    if {[catch {dict get $::guildCallbacks $guildId} callbacks]} {
        return
    } else {
        return $callbacks
    }
}

proc addGuildCallback { sessionNs guildId event callback } {
    if {![discord setCallback $sessionNs $event ::mainCallbackHandler]} {
        return -code error "Unable to set callback for event: $event"
    }
    dict set ::guildCallbacks $guildId $event $callback
    set callbacks [dict get $::guildCallbacks $guildId]
    infoDb eval {INSERT OR REPLACE INTO callbacks
                VALUES($guildId, $callbacks)
            }
    return $callbacks
}

proc delGuildCallback { guildId event callback } {
    if {![dict exists $::guildCallbacks $guildId]} {
        return
    }
    if {![catch {dict unset ::guildCallbacks $guildId $event}]} {
        set callbacks [dict get $::guildCallbacks $guildId]
        infoDb eval {INSERT OR REPLACE INTO callbacks
                    VALUES($guildId, $callbacks)
                }
    }
    return $callbacks
}

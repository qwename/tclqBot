proc procSave { sandbox guildId protectCmds name args body } {
    if {[regexp "^:*(?:[join $protectCmds |])$" $name]} {
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

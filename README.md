# tclqBot
Discord bot written in Tcl with
[discord.tcl](https://github.com/qwename/discord.tcl).

Find tclqBot on [Discord](https://discord.gg/rMyNmUq).

### Status

- Safe interpreter for every guild ID to *eval* scripts.
- Save procs, vars from each guild ID in a local sqlite3 database.
- Permissions in the form of list of commands allowed to execute.
- Modifiable callback in sandbox for certain Gateway events
  - MESSAGE\_CREATE
  - GUILD\_MEMBER\_ADD
  - GUILD\_MEMBER\_REMOVE

### Callbacks in sandbox

To add a callback for an event, e.g. MESSAGE\_CREATE, type the following
command in chat:

```
% Please addCallback MESSAGE_CREATE myCallback

Or with additional arguments
% Please addCallback MESSAGE_CREATE [list myCallback arg1]
```

The last argument passed to the callback will be `data`, a dictionary
representing the JSON object for the event.

### TODO

- ~~Individual safe interps within sandbox interp for each guild.~~
- ~~Restrict built-in commands to bot owner and other specified users.~~
- Use *trace* command for easier callbacks.
- Threads or other methods to avoid blocking from sandbox.
 

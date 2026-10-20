# Known issues

myln-diagnose reads this file on every run (no rebuild). A matching log line is
reported under "Known issues" with the note below and is never sent to the model.
First matching rule wins, and the Nix `myln.knownIssues` rules are checked first.

Rule format, one bullet per issue (the pattern is a Python regex searched against
`unit: message`, with PIDs, store hashes and 4+ digit numbers already normalized):

    - `<regex>` benign: what it is and why it's fine
    - `<regex>` watch: only matters if it keeps happening
    - `<regex>` action: what to do
      cleared by `<regex>`

Anything that isn't a rule bullet is ignored, so add notes freely.

## Shutdown

- `^systemd: Failed unmounting RPC Pipe File System` benign: NFSv4-only server with rpcbind off; rpc_pipefs stays busy at shutdown. Harmless.

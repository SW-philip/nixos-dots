# Fleet identity, one entry per flake attr (the short name used for ssh
# aliases and `nrs`). nick = networking.hostName, ts = Tailscale MagicDNS
# label (device name, lowercased). The data lives in inventory.json so shell
# and python tooling read the same file (/etc/fleet.json on a deployed host).
builtins.fromJSON (builtins.readFile ./inventory.json)

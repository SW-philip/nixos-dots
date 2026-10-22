# Every TCP/UDP port a service of ours listens on, fleet-wide. NixOS and
# home-manager services share one network namespace but no option tree, so
# this plain file is the one place both read from. Two names on one port
# throw at eval time, which fails every host (and scripts/check-hosts.sh).
# Add the port here first, then reference `ports.<name>`.
let
  ports = {
    ssh = 22;
    go-librespot = 3678;
    jellyfin = 8096;
    ersatztv = 8409;
    iptv-serve = 8765;
    sqlch-http-bridge = 8766;
    myln-inference = 8767; # systemd socket clients connect to
    myln-embedding = 8768;
    myln-inference-backend = 8769; # llama-server behind the socket
    ersatztv-logos = 8770;
    syncthing-sync = 22000;
    sunshine = 47989; # base port; the derived ones are below
    kid-dashboard = 47823;
  };

  # Ports a service takes implicitly. Not referenced elsewhere; listed so a
  # new entry can't land on top of them.
  derived = {
    sunshine = [ 47984 47990 48010 47998 47999 48000 48002 ];
  };

  claims =
    map (name: { inherit name; port = ports.${name}; }) (builtins.attrNames ports)
    ++ builtins.concatMap
      (name: map (port: { name = "${name} (derived)"; inherit port; }) derived.${name})
      (builtins.attrNames derived);

  byPort = builtins.groupBy (c: toString c.port) claims;
  clashes = builtins.filter (p: builtins.length byPort.${p} > 1) (builtins.attrNames byPort);
in
if clashes == [ ] then ports
else throw "hosts/ports.nix: port clash — ${
  builtins.concatStringsSep "; " (map (p: "${p}: ${builtins.concatStringsSep ", " (map (c: c.name) byPort.${p})}") clashes)
}"

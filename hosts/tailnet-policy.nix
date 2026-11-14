# Tailscale access policy, generated from the inventory so IPs and ports have
# one source. Tailscale stores the live copy in its admin console, not here:
#   nix eval --json -f hosts/tailnet-policy.nix | jq   → paste at
#   https://login.tailscale.com/admin/acls/file
# Workstations reach everything; every other node gets only what it uses, so a
# stolen retro (TPM-unlocked, Moonlight-paired) can't ssh or mount anything.
let
  inventory = import ./inventory.nix;
  ports = import ./ports.nix;
  # Same offsets as modules/sunshine.nix's firewall rule.
  sunshine = map (o: "tcp:${toString (ports.sunshine + o)}") [ (-5) 0 1 21 ]
          ++ map (o: "udp:${toString (ports.sunshine + o)}") [ 9 10 11 13 ];
  dns = [ "tcp:${toString ports.adguard-dns}" "udp:${toString ports.adguard-dns}" ];
  # Not in inventory.json: fleet tooling would try to ssh it. Services only, no
  # shells — a lost phone is the likeliest stolen device.
  phone = "100.124.252.124"; # iphone-13-pro
in
{
  hosts = builtins.mapAttrs (_: h: h.ip) inventory
    // (if phone == null then { } else { iphone = phone; });

  grants = [
    { src = [ "desktop" "surface" ]; dst = [ "*" ]; ip = [ "*" ]; }
    { src = [ "retro" ]; dst = [ "desktop" ]; ip = sunshine; }
    # querylog pull (key-restricted to the reader on the pi side) + MagicDNS upstream.
    { src = [ "retro" ]; dst = [ "pi" ]; ip = [ "tcp:${toString ports.ssh}" ] ++ dns; }
  ] ++ (if phone == null then [ ] else [
    { src = [ "iphone" ]; dst = [ "desktop" ]; ip = [ "tcp:${toString ports.tailscale-serve-https}" ]; }
    { src = [ "iphone" ]; dst = [ "pi" ]; ip = dns; }
  ]);
}

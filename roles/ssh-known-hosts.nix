{ lib, ... }:
let
  tailnet = "example.ts.net";
  fleet = {
    desktop = {
      ts = "swphil";
      ip = "100.64.0.1";
      key = "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY";
    };
    surface = {
      ts = "swsurface";
      ip = "100.64.0.2";
      key = "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY";
    };
    retro = {
      ts = "swretro";
      ip = "100.64.0.3";
      key = "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY";
    };
    pi = {
      ts = "swpi";
      ip = "100.64.0.4";
      key = "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY";
    };
  };
in
{
  # System-wide, so it covers every user and root: /root and ~/.ssh are wiped
  # each boot by impermanence, which made `sudo nixos-rebuild --build-host`
  # die with "Host key verification failed".
  programs.ssh.knownHosts = lib.mapAttrs (name: h: {
    # ts = the Tailscale MagicDNS label (device name, lowercased); `name` is only our short alias
    hostNames = [ h.ip name "${name}.${tailnet}" "${h.ts}.${tailnet}" ];
    publicKey = h.key;
  }) fleet;

  # Hosts pin their nameservers to Cloudflare ahead of tailscale's
  # 100.100.100.100; Cloudflare NXDOMAINs bare names and glibc never falls
  # through, so `ssh desktop` / `ssh retro` fail intermittently.
  networking.hosts = lib.mapAttrs' (name: h: lib.nameValuePair h.ip [ name ]) fleet;
}

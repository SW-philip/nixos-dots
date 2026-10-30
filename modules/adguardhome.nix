{ config, pkgs, ... }:
let
  ports = import ../hosts/ports.nix;
  querylogDir = "/run/AdGuardHome";
  # AdGuard writes the log 0600 as its DynamicUser, so the reader needs root.
  querylogRead = pkgs.writeShellScript "querylog-read" ''
    cd ${querylogDir} || exit 0
    for f in querylog.json.1 querylog.json; do
      [ -f "$f" ] && cat "$f"
    done
  '';
in
{
  services.adguardhome = {
    enable = true;
    mutableSettings = true;
    # UI stays on loopback (no auth configured): reach it with `ssh -L 3080:localhost:3080 pi` (ports.adguard-ui).
    host = "127.0.0.1";
    port = ports.adguard-ui;
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = ports.adguard-dns;
        upstream_dns = [
          # tailnet names must keep resolving through MagicDNS
          "[/ts.net/]100.100.100.100"
          "https://cloudflare-dns.com/dns-query"
        ];
        bootstrap_dns = [ "1.1.1.1" "1.0.0.1" ];
      };
      filters = [{
        enabled = true;
        id = 1;
        name = "AdGuard DNS filter";
        url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
      } {
        # Samsung TV ads/telemetry, so the TV can sit on the LAN for the local remote
        enabled = true;
        id = 2;
        name = "Perflyst SmartTV";
        url = "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt";
      }];
      # The SD card is the live disk: the file lives on tmpfs and retro pulls it
      # (hosts/retro/dns-querylog.nix). Rotation keeps two intervals, so retro has
      # to sync at least once per interval or lines drop out before it sees them.
      querylog = {
        enabled = true;
        file_enabled = true;
        dir_path = querylogDir;
        # entries reach the file only when this buffer flushes; keep the lag short
        size_memory = 100;
        interval = "24h";
      };
      statistics.interval = "24h";
    };
  };

  # Fixed address outside the gateway's DHCP pool (10.0.0.20-250). Only tailnet
  # hosts reach this resolver (via MagicDNS): the XB7 can't hand out a custom DNS
  # server, so LAN-only devices get Comcast's from its DHCP.
  networking.networkmanager.ensureProfiles.profiles.pi-ethernet = {
    connection = {
      id = "pi-ethernet";
      type = "ethernet";
      uuid = "b7d2f0c4-3a91-4e68-8c15-6f2a9d4e1b73";
      interface-name = "enu1u1";
      autoconnect-priority = 20;
    };
    ipv4 = {
      method = "manual";
      address1 = "10.0.0.13/24,10.0.0.1";
      # upstream directly: this host's own resolver can't depend on itself
      dns = "1.1.1.1;1.0.0.1;";
    };
    ipv6.method = "auto";
  };

  # A deploy restarts the service; don't let that wipe what retro hasn't pulled yet.
  systemd.services.adguardhome.serviceConfig.RuntimeDirectoryPreserve = "yes";

  # retro logs in with its host key and can only run the reader.
  users.groups.querylog = { };
  users.users.querylog = {
    isSystemUser = true;
    group = "querylog";
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      ''restrict,command="/run/wrappers/bin/sudo -n ${querylogRead}" ${config.programs.ssh.knownHosts.retro.publicKey}''
    ];
  };
  services.openssh.settings.AllowUsers = [ "querylog" ];
  security.sudo.extraRules = [{
    users = [ "querylog" ];
    commands = [{ command = "${querylogRead}"; options = [ "NOPASSWD" ]; }];
  }];

  networking.firewall.allowedUDPPorts = [ ports.adguard-dns ];
  networking.firewall.allowedTCPPorts = [ ports.adguard-dns ];
}

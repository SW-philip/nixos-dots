{ config, lib, pkgs, ports, ... }:
let
  cfg = config.services.qbittorrent;
  tunnels = map (r: "protonvpn-${r}") config.protonvpn.regions;
  api = "http://127.0.0.1:${toString ports.qbittorrent-webui}/api/v2";
  engines = "${cfg.profileDir}/qBittorrent/data/nova3/engines";
  jackettConfig = "${config.services.jackett.dataDir}/ServerConfig.json";

  jackettPlugin = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/qbittorrent/search-plugins/b67ae21eee8ed26715f31c0c33619dc606dd5f8e/nova3/engines/jackett.py";
    hash = "sha256-ZQttJLaOdaKxoX21tiD5SYCaUgHmgjs4j3Bp/mymjWY=";
  };

  # Runs as root before the sandbox. The plugin reads jackett.json from next to
  # its realpath, so it is copied in rather than linked to the store. Jackett
  # writes its API key on first start, so wait for it.
  prestart = pkgs.writeShellScript "qbittorrent-prestart" ''
    set -eu
    up=""
    for t in ${lib.concatStringsSep " " tunnels}; do
      [ -e "/sys/class/net/$t" ] && up=1
    done
    if [ -z "$up" ]; then
      echo "no ProtonVPN tunnel is up; connect one before starting qbittorrent" >&2
      exit 1
    fi

    # Upstream makes the profile dirs with tmpfiles, which can run before the
    # /persist bind mount lands on a first activation. One level at a time,
    # since install -d leaves created parents root-owned.
    for d in qBittorrent qBittorrent/config qBittorrent/data qBittorrent/data/nova3 qBittorrent/data/nova3/engines; do
      install -d -o ${cfg.user} -g ${cfg.group} -m 755 "${cfg.profileDir}/$d"
    done
    install -o ${cfg.user} -g ${cfg.group} -m 644 ${jackettPlugin} ${engines}/jackett.py
    for _ in $(seq 1 30); do [ -s ${jackettConfig} ] && break; sleep 1; done
    key=$(${lib.getExe pkgs.jq} -r '.APIKey // empty' ${jackettConfig} 2>/dev/null || true)
    if [ -n "$key" ]; then
      ${lib.getExe pkgs.jq} -n --arg key "$key" \
        '{api_key: $key, url: "http://127.0.0.1:${toString ports.jackett}", tracker_first: false, thread_count: 20}' \
        | install -o ${cfg.user} -g ${cfg.group} -m 600 /dev/stdin ${engines}/jackett.json
    fi
  '';

  # Proton's gateway hands out one public port per tunnel, only on configs
  # generated with NAT-PMP on (P2P servers). The mapping lives 60s, so renew
  # well inside that, push the port into qbittorrent, and open it on the
  # tunnel only. Set elements time out, so a stopped loop closes the hole.
  natpmp = pkgs.writeShellApplication {
    name = "qbittorrent-natpmp";
    runtimeInputs = with pkgs; [ libnatpmp curl nftables gnugrep coreutils ];
    text = ''
      current=""
      while true; do
        if out=$(natpmpc -g 10.2.0.1 -a 1 0 udp 60 && natpmpc -g 10.2.0.1 -a 1 0 tcp 60); then
          port=$(grep -oP 'Mapped public port \K[0-9]+' <<<"$out" | tail -1)
          nft add element inet nixos-fw torrent-port "{ tcp . $port timeout 2m, udp . $port timeout 2m }"
          if [ "$port" != "$current" ] && curl -fsS ${api}/app/setPreferences \
               --data "json={\"listen_port\":$port,\"random_port\":false,\"upnp\":false}"; then
            echo "forwarding public port $port"
            current=$port
          fi
        elif [ "$current" != "none" ]; then
          echo "tunnel has no port forwarding (non-P2P region or NAT-PMP off); retrying"
          current=none
        fi
        sleep 45
      done
    '';
  };
in
{
  services.qbittorrent = {
    enable = true;
    # prepko and jellyfin are both in `users`; downloads land group-writable.
    group = "users";
    webuiPort = ports.qbittorrent-webui;
    # Rewritten on every start: settings changed in the web UI revert unless
    # they are set here.
    serverConfig = {
      LegalNotice.Accepted = true;
      BitTorrent.Session = {
        DefaultSavePath = lib.mkDefault "${cfg.profileDir}/downloads";
        TempPathEnabled = true;
        TempPath = lib.mkDefault "${cfg.profileDir}/downloads/.incomplete";
      };
      # UPnP/NAT-PMP here would ask the LAN router, not Proton.
      Network.PortForwardingEnabled = false;
      Preferences.WebUI = {
        Address = "127.0.0.1";
        # Bound to loopback only, so no login for local clients (the web UI,
        # the natpmp loop, `torrent`).
        LocalHostAuth = false;
      };
    };
  };

  services.jackett.enable = true;

  # Idle torrenting keeps network and disk out of low-power states; start it
  # by hand (`torrent`, or a magnet link) when there is something to transfer.
  systemd.services.jackett = {
    wantedBy = lib.mkForce [ ];
    # Same tmpfiles-vs-/persist race as the qbittorrent profile dirs; systemd
    # creates (and owns) these itself before setting up the sandbox.
    serviceConfig.StateDirectory = [ "jackett" "jackett/.config" "jackett/.config/Jackett" ];
    # With a v4-only Proton tunnel up, IPv6 routes into the tunnel and dies
    # there. curl falls back to v4 at once; .NET waits out its 100s timeout.
    environment.DOTNET_SYSTEM_NET_DISABLEIPV6 = "1";
  };

  systemd.services.qbittorrent = {
    wantedBy = lib.mkForce [ ];
    wants = [ "jackett.service" ];
    after = [ "jackett.service" ];
    # Kill switch: lo (web UI, Jackett) and the Proton tunnels are the only
    # interfaces it can use, so a dropped tunnel stalls it instead of leaking
    # onto the LAN. systemd resolves these names to ifindexes at start, and a
    # reconnected tunnel gets a new one, so stop with any tunnel rather than
    # sit blocked.
    partOf = map (t: "wg-quick-${t}.service") tunnels;
    # search plugins run under python3
    path = [ pkgs.python3 ];
    serviceConfig = {
      RestrictNetworkInterfaces = [ "lo" ] ++ tunnels;
      ExecStartPre = lib.mkBefore [ "+${prestart}" ];
      # The host resolv.conf points at Tailscale's resolver on tailscale0, which
      # the kill switch blocks. Proton's resolver sits inside the tunnel, so
      # lookups don't leak off it either.
      BindReadOnlyPaths = [
        "${pkgs.writeText "qbittorrent-resolv.conf" "nameserver 10.2.0.1\n"}:/etc/resolv.conf"
      ];
      UMask = "0002";
    };
  };

  systemd.services.qbittorrent-natpmp = {
    description = "Renew ProtonVPN port forwarding for qbittorrent";
    wantedBy = [ "qbittorrent.service" ];
    partOf = [ "qbittorrent.service" ];
    after = [ "qbittorrent.service" ];
    serviceConfig = {
      ExecStart = lib.getExe natpmp;
      Restart = "on-failure";
      RestartSec = 10;
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  networking.nftables.tables.nixos-fw.content = lib.mkAfter ''
    set torrent-port {
      type inet_proto . inet_service
      flags timeout
    }
  '';
  networking.firewall.extraInputRules = ''
    iifname { ${lib.concatMapStringsSep ", " (t: ''"${t}"'') tunnels} } meta l4proto . th dport @torrent-port accept
  '';

  # Magnet links start qbittorrent without a password prompt.
  security.sudo.extraRules = [{
    users = [ config.myConfig.user ];
    commands = [{
      command = "/run/current-system/sw/bin/systemctl start qbittorrent.service";
      options = [ "NOPASSWD" ];
    }];
  }];

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/qBittorrent"; user = cfg.user; group = cfg.group; mode = "0750"; }
    { directory = "/var/lib/jackett"; user = "jackett"; group = "jackett"; mode = "0750"; }
  ];
}

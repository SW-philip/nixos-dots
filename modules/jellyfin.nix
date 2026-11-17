{ config, pkgs, lib, ports, ... }:
let
  https = toString ports.tailscale-serve-https;
  ts = "${config.services.tailscale.package}/bin/tailscale";
  transcodes = "${config.services.jellyfin.cacheDir}/transcodes";
in
{
  services.jellyfin = {
    enable = true;
    openFirewall = false;
    dataDir = "/srv/jellyfin/data";
  };

  users.users.jellyfin.extraGroups = [ "video" "render" "users" ];

  systemd.tmpfiles.rules = [
    "d /srv/jellyfin       0750 jellyfin jellyfin -"
    "d /srv/jellyfin/data  0750 jellyfin jellyfin -"
    # "Save artwork into media folders" + the Nfo saver: ErsatzTV only sees
    # artwork and metadata sitting next to the media, so the guide's
    # thumbnails depend on Jellyfin writing poster.jpg/tvshow.nfo there.
    # The default ACL covers folders added later. The masks are explicit:
    # tmpfiles keeps an existing mask, and the hand-set r-x ones clamp the grant.
    "A+ /srv/Videos - - - - group:jellyfin:rwX,mask::rwX,default:group:jellyfin:rwX,default:mask::rwX"
    # tmpfs uid= needs a number and jellyfin's is dynamic, so own it here.
    "d ${transcodes} 0750 jellyfin jellyfin -"
  ];

  # Transcode segments are ~100G/day of write-once churn; on disk they wore the
  # QLC root SSD and Live TV's shared-stream buffers (8 Mbps, unbounded while a
  # stream stays open) filled it. In RAM a runaway hits the cap and dies alone.
  # Needs "Allow stream sharing" off on the M3U tuner, or every Live TV session
  # buffers here and gets cut off around 2h.
  fileSystems.${transcodes} = {
    device  = "tmpfs";
    fsType  = "tmpfs";
    options = [ "size=8G" "mode=0750" "nosuid" "nodev" "noexec" ];
  };

  systemd.services.jellyfin = {
    after = lib.mkForce [ "network.target" "srv.mount" ];
    wants = lib.mkForce [ "network.target" ];
    unitConfig.RequiresMountsFor = [ transcodes ];
    # keep retrying indefinitely — /srv may be slow on cold boot (TPM2 unlock)
    startLimitIntervalSec = 0;

    environment = {
      DOTNET_GCHeapHardLimitPercent = "10";
    };

    serviceConfig = {
      ProtectHome = false;
      ReadWritePaths = [ "/srv/Videos" "/srv/jellyfin" ];
      RestartSec = "15s";
      # Throttle writes to the spinning /srv disk (by-id: sdX letters aren't stable).
      IOWriteBandwidthMax = "/dev/disk/by-id/ata-ST3000DM008-2DM166_Z505GAGT 20000000";
    };
  };

  # HTTPS for clients (sqlch sends the API key in every request): tailscale
  # terminates TLS with a Let's Encrypt cert for swphil.<tailnet>.ts.net and
  # proxies to jellyfin on loopback. Needs "HTTPS Certificates" enabled in the
  # tailnet admin console (DNS page). Config persists in /var/lib/tailscale.
  systemd.services.jellyfin-tailscale-serve = {
    description = "Serve Jellyfin over HTTPS on the tailnet";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" "jellyfin.service" ];
    wants = [ "tailscaled.service" ];
    serviceConfig = {
      # tailscaled is "started" before its backend leaves NoState, which serve rejects at boot.
      # The wait lives in ExecStart, not ExecStartPre, and Type=exec rather than oneshot,
      # so it doesn't hold multi-user.target (and graphical) for ~5s every boot.
      Type = "exec";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/sh -c '${pkgs.coreutils}/bin/timeout 2m ${ts} wait && exec ${ts} serve --bg --https=${https} http://127.0.0.1:${toString ports.jellyfin}'";
      ExecStop = "${ts} serve --https=${https} off";
      Restart = "on-failure";
      RestartSec = "30s";

      # Talks to tailscaled's LocalAPI socket; `tailscale wait` also reads the
      # interface's IPs over netlink and hangs forever without AF_NETLINK. Stays root
      # (no capabilities): the LocalAPI grants serve config by peer uid.
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" ];
      IPAddressDeny = "any";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged @resources" ];
      UMask = "0077";
    };
  };
}

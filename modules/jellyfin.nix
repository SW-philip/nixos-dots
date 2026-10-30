{ config, pkgs, lib, ... }:
let
  ports = import ../hosts/ports.nix;
  https = toString ports.tailscale-serve-https;
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
  ];

  systemd.services.jellyfin = {
    after = lib.mkForce [ "network.target" "srv.mount" ];
    wants = lib.mkForce [ "network.target" ];
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
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --bg --https=${https} http://127.0.0.1:${toString ports.jellyfin}";
      ExecStop = "${config.services.tailscale.package}/bin/tailscale serve --https=${https} off";
      Restart = "on-failure";
      RestartSec = "30s";
    };
  };
}

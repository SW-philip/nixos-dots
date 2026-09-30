{ config, pkgs, lib, ... }:

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
      ProtectHome = lib.mkForce false;
      ReadWritePaths = [ "/srv/Videos" "/srv/jellyfin" ];
      RestartSec = "15s";
      # Throttle writes to the spinning /srv disk (by-id: sdX letters aren't stable).
      IOWriteBandwidthMax = "/dev/disk/by-id/ata-ST3000DM008-2DM166_Z505GAGT 20000000";
    };
  };
}

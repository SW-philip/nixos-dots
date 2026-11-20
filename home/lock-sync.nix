{ pkgs, lib, config, inventory, ... }:
let
  lockSync = pkgs.writeShellApplication {
    name = "lock-sync";
    runtimeInputs = with pkgs; [ openssh iproute2 procps systemd coreutils gawk util-linux ];
    text = builtins.readFile ../scripts/lock-sync.sh;
  };
in
{
  home.packages = [ lockSync ];

  systemd.user.services.lock-sync = lib.mkIf (!config.myConfig.isDesktop) {
    Unit = config.lib.niri.unit { } { Description = "Mirror surface's hyprlock lock/unlock to desktop on the same LAN"; };
    Service = {
      ExecStart = "${lockSync}/bin/lock-sync watch";
      Environment = [ "LOCK_SYNC_PEER=${inventory.desktop.ip}" ];
      Restart = "on-failure";
      Nice = 10;
      # Only needs: read ~/.ssh, ssh out, netlink for `ip neigh`, the journal socket.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}

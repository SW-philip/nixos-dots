{ config, pkgs, lib, ... }:
let
  isDesktop = config.myConfig.isDesktop;
  # ssh alias per hosts/*/config.nix -- from surface it's "desktop", from
  # desktop it's "swsurface" (tailscale's registered device name, not the
  # nixos hostname "SWsurface"). Confirmed both directions work passwordless.
  remoteHost = if isDesktop then "swsurface" else "desktop";

  # Surface holds the curated library; it wins when the same station id
  # differs on both hosts.
  isAuthority = if isDesktop then "0" else "1";

  # Bare invocation (systemd ExecStart) uses the baked-in host/authority; an
  # explicit `sqlch-sync <host> <0|1>` overrides both -- the script reads argv
  # positionally, so the override has to replace the args, not follow them.
  syncScript = pkgs.writeShellScriptBin "sqlch-sync" ''
    if [ "$#" -gt 0 ]; then
      exec ${pkgs.python3}/bin/python3 ${./sqlch/sqlch-sync.py} "$@"
    fi
    exec ${pkgs.python3}/bin/python3 ${./sqlch/sqlch-sync.py} ${remoteHost} ${isAuthority}
  '';
in
{
  home.packages = [ syncScript ];

  systemd.user.services.sqlch-sync = {
    Unit = {
      Description = "Union-merge sqlch station library with ${remoteHost}";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/sqlch-sync";
    };
  };

  systemd.user.timers.sqlch-sync = {
    Unit.Description = "sqlch library sync timer";
    Timer = {
      OnStartupSec = "2min";
      OnUnitActiveSec = "30min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}

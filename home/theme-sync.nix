{ config, pkgs, ... }:
let
  peer = if config.myConfig.isDesktop then "surface" else "desktop";
  themeSync = pkgs.writeShellApplication {
    name = "theme-sync";
    runtimeInputs = with pkgs; [ openssh coreutils ];
    text = builtins.readFile ../scripts/theme-sync.sh;
  };
in
{
  home.packages = [ themeSync ];

  systemd.user.services.theme-sync = {
    Unit.Description = "Follow the other host's drmis theme when it changed more recently";
    Service = {
      Type = "oneshot";
      ExecStart = "${themeSync}/bin/theme-sync";
      Nice = 19;
      # drmis and tree-sync come from the user profile, not writeShellApplication's PATH
      Environment = [
        "THEME_SYNC_PEER=${peer}"
        "PATH=/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
      ];
    };
  };

  systemd.user.timers.theme-sync = {
    Unit.Description = "theme-sync timer";
    Timer = { OnStartupSec = "3min"; OnUnitActiveSec = "2min"; };
    Install.WantedBy = [ "timers.target" ];
  };
}

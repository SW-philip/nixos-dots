{ config, pkgs, ... }:
{
  # No desktop environment here, so nothing else shows polkit's password dialog
  # (pkexec in home/tunnel.nix's port list needs one).
  systemd.user.services.polkit-agent = {
    Unit = config.lib.niri.unit { wayland = true; } {
      Description = "Polkit authentication agent";
    };
    Service = {
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}

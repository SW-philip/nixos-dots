{ config, pkgs, ... }:
{
  # No desktop environment here, so nothing else shows polkit's password dialog
  # (pkexec in home/tunnel.nix's port list needs one). Ours (pkgs/auth-agent) labels each dialog
  # with who asked; its journal is the prompt history.
  systemd.user.services.polkit-agent = {
    Unit = config.lib.niri.unit { wayland = true; } {
      Description = "Polkit authentication agent";
    };
    Service = {
      ExecStart = "${pkgs.auth-agent}/bin/auth-agent";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Same for gnome-keyring and gcr-ssh-agent's password prompts: owning the prompter's bus name
  # first replaces the D-Bus-activated gcr-prompter. If a gcr-prompter got the name first, this
  # exits and retries; gcr-prompter quits after 10 s idle.
  systemd.user.services.keyring-prompter = {
    Unit = config.lib.niri.unit { wayland = true; } {
      Description = "Keyring password prompter that names the process asking";
    };
    Service = {
      ExecStart = "${pkgs.auth-agent}/bin/keyring-prompter";
      Restart = "always";
      RestartSec = 15;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}

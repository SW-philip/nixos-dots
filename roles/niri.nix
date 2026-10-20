{ config, pkgs, ... }:
{
  ############################################################
  # Niri compositor (system-level)
  ############################################################
  programs.niri = {
    enable = true;
  };

  ############################################################
  # XWayland
  ############################################################
  programs.xwayland.enable = true;

  ############################################################
  # XDG portal
  ############################################################
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  ############################################################
  # GPU Screen Recorder
  ############################################################
  programs.gpu-screen-recorder.enable = true;
  environment.systemPackages = with pkgs; [
    xwayland-satellite
    config.programs.gpu-screen-recorder.package
  ];

  # graphical-desktop.nix mkDefaults speechd on for any graphical session;
  # nothing here speaks, and it drags a 1.2 GB closure into the system path.
  services.speechd.enable = false;

  ############################################################
  # Gnome Keyring
  ############################################################
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.greetd.enableGnomeKeyring = true;
  security.pam.services.niri.enableGnomeKeyring = true;
  # No pam.d/hyprlock without this — hyprlock falls back to /etc/pam.d/su's
  # stack (confirmed live: "Pam module /etc/pam.d/hyprlock does not exist!
  # Falling back to /etc/pam.d/su" in the hypridle journal).
  security.pam.services.hyprlock = {};

  # Session restore
  ############################################################
  services.nirinit = {
    enable = true;
    settings = {
      # Apps that restore their own windows/tabs on relaunch.
      skip.apps = [ "firefox" "thunderbird" "spotify" ];
      # app-id -> launch command, for apps whose app-id isn't their binary.
      launch = {
        "com.mitchellh.ghostty"          = "ghostty";
        "dev.zed.Zed"                    = "zeditor";
        "com.github.xournalpp.xournalpp" = "xournalpp";
        "element"                        = "element-desktop";
        "org.kde.kdenlive"               = "kdenlive";
        "org.kde.easyeffects"            = "easyeffects";
        "libreoffice-writer"             = "libreoffice --writer";
      };
    };
  };
  # Upstream module ships no ConditionEnvironment guard, so it starts under
  # graphical-session.target with no niri IPC socket (e.g. an SSH-only login)
  # and loops on Restart=always. Same guard as kanshi.service.
  systemd.user.services.nirinit.unitConfig.ConditionEnvironment =
    [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];

}

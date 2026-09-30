{ pkgs, ... }:
{
  ############################################################
  # GVfs — needed for Nemo to mount network shares (SMB etc.)
  ############################################################
  services.gvfs.enable = true;
  environment.systemPackages = with pkgs; [ gvfs ];

  ############################################################
  # Steam
  ############################################################
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
  };

  # Scale Steam UI to match eDP-1's 2.0 compositor scale (2736x1824 → 1368x912 logical).
  # Baked into the package wrapper, not environment.sessionVariables — greetd's PAM stack
  # uses pam_env.so readenv=0, so NixOS session variables never reach the graphical session.
  programs.steam.package = pkgs.steam.override {
    extraEnv.STEAM_FORCE_DESKTOPUI_SCALING = "2";
  };
}

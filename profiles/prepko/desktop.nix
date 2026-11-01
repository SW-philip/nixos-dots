{ inputs, pkgs, lib, config, ... }:

{
  imports = [
    ../base.nix
    ../../home/openrgb/rgb-moon.nix
    ../../home/openrgb/rgb-reactive.nix
    ../../home/ps-controller-colors.nix
    ../../home/niri-bridge
    ../../home/claude-tidy.nix
    ../../home/tree-sync.nix
    ../../home/theme-sync.nix
    ../../home/fleet-status.nix
    ../../home/whats-new.nix
    ../../home/goodnight.nix
    ../../home/nixfetch.nix
    ../../home/pi-git-mirror.nix
    ../../home/flake-check.nix
    ../../home/reaper.nix
    ../../home/sync-status.nix
    ../../home/pass-through.nix
    ../../home/quivr.nix
    ../../home/go-librespot.nix
    ../../home/on.nix
    ../../home/settings.nix
    ../../home/commands.nix
    ../../home/snark.nix
    ../../home/tunnel.nix
    ../../home/dnslog.nix
    ../../home/polkit-agent.nix
    ../../home/shared-apps
    ../../home/pegasus
    ../../home/bluetooth-idle-notify.nix
    ../../home/archive.nix
    ../../home/overnight-notify.nix
  ];

  home.pointerCursor.size = lib.mkForce 24;

  goodnight.deploy.enable = true;
  goodnight.reboot.enable = true;

  # archive.nix wires icloud-pull and drive-pull itself (they carry a failure hint)
  overnight.notify = {
    enable = true;
    units = [ "goodnight" "claude-tidy" "flake-check" "pi-git-mirror" ];
  };

  ########################################
  # Fix nrs alias — hostname SWphil != flake attr desktop.
  # Keeps base.nix's -e /run/wrappers/bin/sudo elevation pin (dropping it
  # reintroduces the non-setuid /run/current-system/sw/bin/sudo activation
  # failure base.nix's comment warns about).
  ########################################
  programs.zsh.shellAliases = {
    nrs = lib.mkForce "nh os switch -e /run/wrappers/bin/sudo --hostname desktop ${config.home.homeDirectory}/nixos && whats-new";
    nrb = lib.mkForce "nh os boot -e /run/wrappers/bin/sudo --hostname desktop ${config.home.homeDirectory}/nixos";
    nrt = lib.mkForce "nh os test -e /run/wrappers/bin/sudo --hostname desktop ${config.home.homeDirectory}/nixos";
  };

  myConfig.isDesktop = true;

  ########################################
  # Keyring auto-unlock
  ########################################
  # greetd's initial_session (hosts/desktop/config.nix) auto-logs prepko into
  # niri without ever going through PAM's password step, so there's no
  # password left for pam_gnome_keyring to hand gnome-keyring-daemon at
  # session-open — the login keyring just sits locked until something
  # prompts for it. Requires the login keyring's password to be blank (set
  # once via Seahorse: Passwords and Keys -> Login -> right-click -> Change
  # Password -> leave the new password fields empty) — this mirrors exactly
  # what pam_gnome_keyring does on a normal password login, just with an
  # empty token instead of a real one.
  systemd.user.services.gnome-keyring-unlock = {
    Unit = config.lib.niri.unit { wayland = false; } {
      Description = "Unlock the (blank-password) login keyring for greetd's autologin session";
    };
    Service = {
      Type = "oneshot";
      # systemd feeds this an immediate EOF (empty stdin) instead of a shell
      # redirect — gnome-keyring-daemon --unlock reads the unlock password
      # from stdin, and an empty read is exactly the blank password.
      StandardInput = "null";
      ExecStart = "${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --unlock";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # pasted YouTube URLs carry ? and &, which zsh would glob
  programs.zsh.shellAliases.tv-add = "noglob tv-add";
  programs.zsh.shellAliases.tv-ads = "noglob tv-ads";

  home.packages = with pkgs; [
    orch
    kdePackages.kdenlive
    wayland-utils
    ydotool
    vulkan-tools
    mesa-demos
    drm_info
    dig
    vmpk qsynth fluidsynth soundfont-fluid
    helio-workstation hydrogen
    (writeShellScriptBin "tv-add" ''
      exec ~/nixos/scripts/tv-add.sh "$@"
    '')
    (writeShellScriptBin "tv-ads" ''
      exec ~/nixos/scripts/tv-ads.sh "$@"
    '')
  ];
}

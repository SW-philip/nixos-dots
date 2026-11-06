{ inputs, pkgs, lib, config, ... }:

{
  imports = [
    ../base.nix
    ../../home/openrgb/rgb-moon.nix
    ../../home/openrgb/rgb-reactive.nix
    ../../home/ps-controller-colors.nix
    ../../home/goodnight.nix
    ../../home/pi-git-mirror.nix
    ../../home/flake-check.nix
    ../../home/reaper.nix
    ../../home/pegasus
    ../../home/bluetooth-idle-notify.nix
    ../../home/archive.nix
    ../../home/overnight-notify.nix
  ];

  home.pointerCursor.size = lib.mkForce 24;

  # Double-clicked .exes go through this entry, so they get the same caps as the
  # Pegasus PC collection (hosts/desktop/pegasus-pc.nix). A self-launching loader
  # opened from Nemo got past those caps on 2026-11-05.
  xdg.desktopEntries.wine = {
    name = "Wine Windows Program Loader";
    exec = "${pkgs.systemd}/bin/systemd-run --user --scope --collect --quiet -p TasksMax=256 -p MemoryMax=12G -p MemorySwapMax=4G wine start /unix %f";
    icon = "wine";
    noDisplay = true;
    startupNotify = true;
    mimeType = [
      "application/vnd.microsoft.portable-executable"
      "application/x-ms-dos-executable"
      "application/x-msi"
      "application/x-ms-shortcut"
      "application/x-bat"
      "application/x-mswinurl"
    ];
  };

  goodnight.deploy.enable = true;
  goodnight.reboot.enable = true;
  goodnight.jobs = {
    icloud-pull = { every = "day"; stage = "data"; };
    drive-pull = { every = "day"; stage = "data"; };
    pi-git-mirror = { every = "day"; stage = "data"; };
    flake-check.every = "week";
  };

  # archive.nix wires icloud-pull and drive-pull itself (they carry a failure hint)
  overnight.notify = {
    enable = true;
    popups = false;
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
  systemd.user.services.protonmail-bridge = {
    Unit = {
      Description = "Proton Mail Bridge";
      After = [ "network-online.target" "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.protonmail-bridge}/bin/protonmail-bridge --noninteractive";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

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
    thunderbird
    orch
    wayland-utils
    ydotool
    vulkan-tools
    mesa-demos
    drm_info
    dig              # bind's dnsutils output; the system bind has no dig
    tor-browser
    # Standalone Wine for running Windows installers (e.g. FitGirl setup.exe)
    # outside Steam's process reaper, which kills Inno Setup's setup.tmp worker
    # when the bootstrapper exits mid-extraction.
    wineWow64Packages.stable   # 64-bit wine with 32-bit (WoW64) support
    winetricks
    (writeShellScriptBin "tv-add" ''
      exec ~/nixos/scripts/tv-add.sh "$@"
    '')
    (writeShellScriptBin "tv-ads" ''
      exec ~/nixos/scripts/tv-ads.sh "$@"
    '')
  ];
}

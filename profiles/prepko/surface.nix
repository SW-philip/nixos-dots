{ inputs, pkgs, lib, config, ... }:
let
  mugConsumer = import ../../home/niri/theme-consumer.nix { inherit lib; } {
    name = "ember-mug";
    description = "Sync the Ember mug LED to the drmis theme ROOT color";
    exec = "${config.myConfig.drmisBin} mug-sync";
    environment.PATH = lib.makeBinPath [ pkgs.python-ember-mug ];
  };
in
{
  imports = [
    ../base.nix
    ../surface-tablet.nix
    ../../home/pegasus-surface
    ../../home/moonlight
    ../../home/niri-bridge
    ../../home/reader-warmth
    ../../home/battery-low-notify.nix
    ../../home/claude-tidy.nix
    ../../home/tree-sync.nix
    ../../home/fleet-status.nix
    ../../home/sync-status.nix
    ../../home/pass-through.nix
    ../../home/quivr.nix
    ../../home/on.nix
    ../../home/shared-apps
    ../../home/network-notify.nix
  ];

  ########################################
  # Surface HiDPI cursor override (base sets 48px; Surface needs 32px at 1.5x scale)
  ########################################
  home.pointerCursor.size = lib.mkForce 32;

  ########################################
  # KDE Connect — hosts/surface/services.nix installs the package + opens
  # the firewall system-wide. Deliberately NOT services.kdeconnect.enable
  # (that forces kdeconnectd on at login via a WantedBy=graphical-session.target
  # unit — pure idle draw when no phone is even in range). The package ships
  # its own D-Bus activation file (org.kde.kdeconnect.service), so kdeconnectd
  # starts itself the moment anything actually calls kdeconnect-cli/kdeconnect-app
  # — no systemd unit needed for that. The Hidden=true override below kills the
  # *other* auto-start path: the package's /etc/xdg/autostart .desktop entry,
  # which systemd-xdg-autostart-generator would otherwise turn into a second
  # always-on unit regardless of this option.
  # home/waybar/scripts/kdeconnect-status.sh checks bus ownership before
  # calling kdeconnect-cli, so the waybar poll itself doesn't activate it.
  ########################################
  xdg.configFile."autostart/org.kde.kdeconnect.daemon.desktop".text = ''
    [Desktop Entry]
    Hidden=true
  '';

  ########################################
  # Fix nrs alias — hostname SWsurface != flake attr surface.
  # --build-host offloads the actual build to desktop over SSH (surface's
  # own CPU is the bottleneck otherwise); nix.distributedBuilds was tried
  # for this and abandoned — see hosts/surface/config.nix history — Lix's
  # machines-file SSH client is libssh2-in-process (confirmed via strace,
  # never spawns a real ssh, never reads known_hosts) and silently falls
  # back to local. --build-host uses a real ssh subprocess as the invoking
  # user instead, which just works with the existing ~/.ssh/id_ed25519.
  # The Tailscale IP, not the MagicDNS name: surface's resolv.conf can list
  # the DHCP resolvers ahead of 100.100.100.100, which NXDOMAIN *.ts.net.
  ########################################
  systemd.user.services.drmis-mug = mugConsumer.service;
  systemd.user.paths.drmis-mug = mugConsumer.path;

  programs.zsh.shellAliases = {
    nrs = lib.mkForce "nh os switch -e /run/wrappers/bin/sudo -H surface --build-host prepko@100.64.0.1";
    nrb = lib.mkForce "nh os boot -e /run/wrappers/bin/sudo -H surface --build-host prepko@100.64.0.1";
    nrt = lib.mkForce "nh os test -e /run/wrappers/bin/sudo -H surface --build-host prepko@100.64.0.1";

    # `ember-mug set/get` without -m scans and can grab a stale, unpaired
    # BlueZ device object (from a prior BLE address rotation) instead of the
    # already-bonded 00:00:00:00:00:01 — connects then gets aborted locally.
    # Pinning -m skips the scan-match and goes straight to the known device.
    ember-mug = "ember-mug -m 00:00:00:00:00:01";
  };

  ########################################
  # Claude settings.json: ~/nixos here is an NFS mount from desktop, and a stale
  # handle turns the usual symlink into nothing (no settings, no Bash perms).
  # Keep a real local copy, refreshed from desktop's shared one on every nrs.
  ########################################
  home.activation.claudeSettingsCopy = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    CLAUDE_SYNC_COPY_SETTINGS=1 run ${pkgs.bash}/bin/bash ${../../scripts/claude-sync.sh} || true
  '';

  ########################################
  # Surface-only packages
  ########################################
  home.packages = with pkgs; [
    pandora
    xournalpp       # stylus note-taking
    koreader        # ebooks + comics; warm-screen mode via home/reader-warmth
    kdePackages.kdenlive krita uniremote
    spotify
    python-ember-mug
    vmpk qsynth fluidsynth soundfont-fluid
    helio-workstation hydrogen

    # element-desktop's Electron backend picks a secret-storage backend by
    # checking XDG_CURRENT_DESKTOP, not by probing D-Bus — niri isn't in its
    # known-desktop list, so it reports "unsupported keyring" even though
    # gnome-keyring (roles/niri.nix) is running and unlocked.
    (symlinkJoin {
      name = "element-desktop-wrapped";
      paths = [ element-desktop ];
      buildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/element-desktop --add-flags '--password-store=gnome-libsecret'
      '';
    })
  ];

}

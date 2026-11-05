{ config, pkgs, lib, ... }:
let
  ports = import ../hosts/ports.nix;
in
{
  imports = [ ./common.nix ../cachix.nix ../modules/host-options.nix ];

  ############################################################
  # Secrets (SOPS) + login password
  ############################################################
  sops = {
    # Not the SSH host key: a 0644 copy of it sat in ~ for months, and regenerating
    # host keys would orphan every secret. Empty, not unset: the default derives
    # from services.openssh.hostKeys, i.e. that same key.
    age.keyFile = "/persist/var/lib/sops-nix/key.txt";
    # A missing key must fail loudly, not mint a new one that decrypts nothing.
    age.generateKey = false;
    age.sshKeyPaths = [ ];
    # neededForUsers: decrypted before user creation, since mutableUsers = false.
    secrets."${config.myConfig.user}_password_hash" = { sopsFile = ../secrets/passwords.yaml; neededForUsers = true; };
  };
  users.mutableUsers = false;
  users.users.${config.myConfig.user}.hashedPasswordFile =
    config.sops.secrets."${config.myConfig.user}_password_hash".path;

  ############################################################
  # Documentation
  ############################################################
  documentation.doc.enable = false;

  i18n = {
    extraLocaleSettings.LC_ALL = "en_US.UTF-8";
    inputMethod.enable = false;
  };

  ############################################################
  # Shell
  ############################################################
  programs.zsh.enable = true;

  ############################################################
  # Networking / SSH
  ############################################################
  networking.networkmanager.enable = true;
  systemd.services.NetworkManager-wait-online.enable = false;

  # Wifi radio off while any ethernet is connected, back on when the last one
  # drops. Recomputes from nmcli state on every event (a vanished USB NIC can't
  # be identified by interface name); the marker means we only re-enable wifi
  # we turned off ourselves, never one the user disabled by hand.
  networking.networkmanager.dispatcherScripts = [{
    type = "basic";
    source = pkgs.writeShellScript "wifi-off-on-ethernet" ''
      nmcli=${pkgs.networkmanager}/bin/nmcli
      marker=/run/wifi-off-by-ethernet

      case "$2" in up|down) ;; *) exit 0 ;; esac

      if $nmcli -t -f TYPE,STATE device | ${pkgs.gnugrep}/bin/grep -qx 'ethernet:connected'; then
        if [ "$($nmcli radio wifi)" = enabled ]; then
          $nmcli radio wifi off && touch "$marker"
        fi
      elif [ -e "$marker" ]; then
        $nmcli radio wifi on
        rm -f "$marker"
      fi
    '';
  }];

  # nsncd (Rust nscd reimplementation) is a longstanding source of bugs
  # (https://github.com/NixOS/nixpkgs/issues/344901) — it SIGTERM-flaps
  # 6x at every boot on this system and permanently hits start-limit-hit,
  # leaving NSS module loading (mdns, systemd nss) unserved. Fall back to
  # glibc's real nscd binary instead.
  services.nscd.enableNsncd = false;

  # nscd already ships hardened (NoNewPrivileges/PrivateTmp/ProtectSystem=strict/
  # unprivileged User=nscd) — only adding what's still missing. Deliberately NOT
  # touching RestrictAddressFamilies/network here: nscd's "hosts" cache runs the
  # real NSS stack in-process (including nss-mdns), which is the exact thing that
  # was fragile enough to rule out nsncd above — don't risk a repeat.
  systemd.services.nscd.serviceConfig = {
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    CapabilityBoundingSet = [ ];
  };
  services.openssh = {
    # `waypipe ssh` needs a -R unix-socket forward and sshd refuses it under
    # AllowTcpForwarding no (AllowStreamLocalForwarding can't override). Tailnet only;
    # -L is limited by PermitOpen to ErsatzTV's loopback-only web UI.
    extraConfig = ''
      Match Address 100.64.0.0/10
        AllowTcpForwarding yes
        PermitOpen 127.0.0.1:${toString ports.ersatztv}
    '';
  };
  ############################################################
  # Journal limits
  ############################################################
  services.journald.settings.Journal = {
    SystemMaxUse = "500M";
    RuntimeMaxUse = "64M";
    MaxFileSec = "1month";
  };



  ############################################################
  # Base system packages
  ############################################################
  environment.systemPackages = with pkgs; [
    pciutils
    usbutils
    sbctl
    sysstat
    lm_sensors
    brightnessctl
    smartmontools
    waypipe          # remote end of `on`: a non-interactive ssh only sees the system profile

    btrfs-progs     # btrfs maintenance (balance, scrub, subvolume ops)
    cryptsetup       # LUKS runtime management / recovery
    nvme-cli         # NVMe diagnostics

    tpm2-tools       # TPM2 diagnostics (used in boot, needed in userspace)
    efibootmgr       # EFI boot entry management (lanzaboote debugging)

    age
    sops

    iotop            # Disk I/O monitoring
    lsof             # List open files

    iw               # nl80211 wireless configuration
  ];

  ############################################################
  # Fonts
  ############################################################
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    nerd-fonts.hack
    nerd-fonts.jetbrains-mono
    nerd-fonts.symbols-only
    eb-garamond
    # Josefin Sans (waybar + hyprlock clock/date) — variable TTF (wght 100..700) from google/fonts.
    (callPackage ../pkgs/josefin-sans.nix { })
  ];

  ############################################################
  # Wayland session environment
  ############################################################
  environment.sessionVariables = {
    NIXOS_OZONE_WL     = "1";
    GDK_BACKEND        = "wayland,x11";
    QT_QPA_PLATFORM    = "wayland;xcb";
    SDL_VIDEODRIVER    = "wayland,x11";
    MOZ_ENABLE_WAYLAND = "1";
    GTK_USE_PORTAL     = "1";
    GDK_SCALE          = "1";
    GDK_DPI_SCALE      = "1";
  };

  ############################################################
  # GTK / GI introspection
  ############################################################
  environment.sessionVariables.GI_TYPELIB_PATH =
    lib.makeSearchPath "lib/girepository-1.0" [
      pkgs.glib.out
      pkgs.gobject-introspection.out
      pkgs.atk.out
      pkgs.pango.out
      pkgs.gdk-pixbuf.out
      pkgs.gtk3.out
    ];

  ############################################################
  # Nix hygiene
  ############################################################
  # The "usual lecture" is tracked in /var/db/sudo, which a wiped root forgets every boot.
  security.sudo.extraConfig = "Defaults lecture = never";

  nix.settings = {
    http-connections = 25;
    connect-timeout = 10;
    stalled-download-timeout = 90;
    min-free = 2 * 1024 * 1024 * 1024;
    max-free = 8 * 1024 * 1024 * 1024;
    trusted-users = [ config.myConfig.user ];
    # GitHub redirects archive downloads to codeload.github.com; Nix blocks cross-host redirects by default
    allowed-uris = [
      "https://github.com"
      "https://codeload.github.com"
    ];
  };

  services.avahi.enable = false;

  nix.optimise.automatic = true;

  programs.nh = {
    enable = true;
    flake  = "/home/${config.myConfig.user}/nixos";
    # Replaces nix.gc (the two assert against each other). Not persistent:
    # laptops are usually off at the weekly slot and a catch-up GC at boot
    # costs minutes of I/O.
    clean = {
      enable = true;
      dates = "weekly";
      extraArgs = "--keep 5 --keep-since 14d";
    };
  };
  systemd.timers.nh-clean.timerConfig = {
    Persistent = lib.mkForce false;
    RandomizedDelaySec = "1h";
  };

  # No blanket NOPASSWD: sudo asks for the password (nh prompts through
  # /run/wrappers/bin/sudo). Narrow NOPASSWD rules live next to the service
  # they serve (tailscale.nix, protonvpn.nix).


  ############################################################
  # Bluetooth
  ############################################################
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  ############################################################
  # Audio (PipeWire) — base stack; hosts add their own extraConfig/jack
  ############################################################
  services.pipewire = {
    enable = true;
    pulse.enable = true;
    alsa.enable = true;
    wireplumber.enable = true;
    # x11-bell's X IO-error handler segfaults pipewire whenever xwayland-satellite's :0 drops.
    extraConfig.pipewire."99-no-x11-bell"."context.properties"."module.x11.bell" = false;
  };

  ############################################################
  # Firmware, phone, drives, games — hosts add smartd devices and their own tweaks
  ############################################################
  services.fwupd.enable = true;
  # Upstream timer is hourly + Persistent, so it also fires right after boot.
  systemd.timers.fwupd-refresh.timerConfig = {
    OnCalendar = [ "" "monthly" ];
    RandomizedDelaySec = "1d";
  };

  # KDE Connect pairs with the S21+; opens TCP+UDP 1714-1764 on every interface.
  programs.kdeconnect.enable = true;

  services.smartd = {
    enable = true;
    autodetect = false;
    notifications.wall.enable = true;
  };

  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
  };
}

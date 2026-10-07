{ config, pkgs, lib, options, ... }:
{
  imports = [ ../cachix.nix ];

  options.myConfig.user = lib.mkOption {
    type        = lib.types.str;
    default     = "prepko";
    description = "Primary user account name, used wherever a literal username is needed.";
  };

  config = {
  ############################################################
  # Documentation
  ############################################################
  documentation.doc.enable = false;

  time.timeZone = "America/New_York";

  i18n = {
    defaultLocale = "en_US.UTF-8";
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
    enable = true;
    settings = {
      UseDns = lib.mkForce false;
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      X11Forwarding = false;
      AllowTcpForwarding = false;
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
    };
    # `waypipe ssh` needs a -R unix-socket forward and sshd refuses it under
    # AllowTcpForwarding no (AllowStreamLocalForwarding can't override). Tailnet only;
    # -L pivots stay blocked.
    extraConfig = ''
      Match Address 100.64.0.0/10
        AllowTcpForwarding remote
    '';
  };
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  ############################################################
  # Journal limits
  ############################################################
  # desktop tracks nixos-unstable (journald.settings.Journal) and surface
  # tracks nixos-26.05 (journald.extraConfig only) — this repo shares one
  # nixpkgs-version-straddling profile across both, so branch on whichever
  # form the pinned channel actually declares instead of hardcoding one.
  services.journald = if options.services.journald ? settings
    then {
      settings.Journal = {
        SystemMaxUse = "500M";
        RuntimeMaxUse = "64M";
        MaxFileSec = "1month";
      };
    }
    else {
      extraConfig = ''
        SystemMaxUse=500M
        RuntimeMaxUse=64M
        MaxFileSec=1month
      '';
    };



  ############################################################
  # Base system packages
  ############################################################
  environment.systemPackages = with pkgs; [
    curl
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

    iputils          # ping, tracepath, etc.
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
    (runCommand "josefin-sans" { } ''
      install -Dm644 ${fetchurl {
        url    = "https://github.com/google/fonts/raw/main/ofl/josefinsans/JosefinSans%5Bwght%5D.ttf";
        sha256 = "sha256-klWr2185O8UeEBq70Hpxapd/0+FUcrG4SyYPQmo0K/0=";
      }} $out/share/fonts/truetype/JosefinSans-Variable.ttf
    '')
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
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    sandbox = false;
    http-connections = 25;
    connect-timeout = 10;
    stalled-download-timeout = 90;
    trusted-users = [ config.myConfig.user ];
    # GitHub redirects archive downloads to codeload.github.com; Nix blocks cross-host redirects by default
    allowed-uris = [
      "https://github.com"
      "https://codeload.github.com"
    ];
  };

  services.avahi.enable = false;

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
    persistent = true;
  };

  programs.nh = {
    enable = true;
    flake  = "/home/${config.myConfig.user}/nixos";
  };

  # No blanket NOPASSWD: sudo asks for the password (nh prompts through
  # /run/wrappers/bin/sudo). Narrow NOPASSWD rules live next to the service
  # they serve (tailscale.nix, protonvpn.nix).

  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
  };

  hardware.enableRedistributableFirmware = true;

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
  };
  }; # end config
}

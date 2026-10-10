{ config, pkgs, lib, ... }:

let
  sandbox = import ../../lib/sandbox.nix;
  netOnly = [ "AF_INET" "AF_INET6" ];
in
{
  ############################################################
  # Services
  ############################################################
  services = {
    fwupd.enable = true;
    deluge = {
      enable = true;
      openFirewall = false;
      web.enable = false;
    };
  };

  # deluged ships with zero sandboxing upstream; bittorrent/DHT need open outbound.
  systemd.services.deluged.serviceConfig = sandbox // {
    ReadWritePaths = [ "/var/lib/deluge" ];
    RestrictAddressFamilies = netOnly ++ [ "AF_UNIX" ];
  };

  # Start manually (`systemctl start deluged`), same as surface.
  systemd.services.deluged.wantedBy = lib.mkForce [ ];

  # acpid is switched on unconditionally by the nvidia driver module and has no
  # handlers here; keep it to its unix socket + acpi netlink events. No
  # ProtectSystem/syscall filter: a future handler script would need a normal
  # root environment.
  systemd.services.acpid.serviceConfig = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectControlGroups = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" ];
  };

  ############################################################
  # btrfs scrub
  # Root (NVMe) and backup-vault (HDD) are separate filesystems — one mount
  # per filesystem is enough since subvolumes share the underlying device.
  # backup-vault uses nofail so the scrub service has to tolerate it being absent.
  ############################################################
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };

  ############################################################
  # Smartd (drive monitoring)
  # sda: ST3000DM008 HDD  sdb: ADATA SU630 SSD
  ############################################################
  services.smartd = {
    enable = true;
    autodetect = false;
    notifications.wall.enable = true;
    devices = let
      hddOpts = lib.concatStringsSep " " [
        "-a" "-n standby"
        "-s S/../.././02"
        "-s L/../../7/02"
        "-W 4,50,55"
        "-l error" "-l selftest"
      ];
      ssdOpts = lib.concatStringsSep " " [
        "-a"
        "-s S/../.././02"
        "-s L/../../7/02"
        "-W 4,55,65"
        "-l error" "-l selftest"
      ];
    in [
      { device = "/dev/sda"; options = hddOpts; }
      { device = "/dev/sdb"; options = ssdOpts; }
    ];
  };

  ############################################################
  # Packages
  ############################################################
  environment.systemPackages = with pkgs; [
    wireguard-tools
    nvtopPackages.nvidia
  ];

  ############################################################
  # CPU power management
  ############################################################
  powerManagement.cpuFreqGovernor = "powersave";

  # Disable APM head-parking on the HDD (ST3000DM008/sda).
  # Load_Cycle_Count was accumulating rapidly (141k+) due to aggressive
  # APM spinning down heads during writes, causing btrfs write_io_errs.
  # APM level 255 = fully disabled; drive handles its own spindown on idle.
  systemd.services.hdparm-apm-disable = {
    description = "Disable APM head-parking on HDD (sda)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.hdparm}/bin/hdparm -B 255 /dev/sda";
    };
  };

  ############################################################
  # Firewall
  # Port 8096 (Jellyfin) is NOT in global allowedTCPPorts — access is via:
  #   tailscale0 (trusted interface, all ports open)
  #   enp4s0 (LAN, explicit allow below)
  ############################################################
  networking.firewall.allowedTCPPorts = lib.optional config.iptv.enable 8765;
  networking.firewall.interfaces."enp4s0".allowedTCPPorts = [ 8096 ];

  ############################################################
  # PS4/PS5 controller lightbar LED permissions
  # hid-playstation exposes the lightbar as three LED class devices
  # (red/green/blue) under the controller's uhid node — confirmed live at
  # /sys/devices/virtual/misc/uhid/0005:054C:.../leds/. TAG+="uaccess" is a
  # no-op here: it only grants ACL on a device's /dev/<node> (via udevd's
  # uaccess builtin / logind's session-device manager), and LED class
  # devices have no devnode — there is nothing for either mechanism to
  # chmod, so the sysfs brightness file stayed root:root 0644 (confirmed
  # live: TAGS db showed "uaccess" set, ACL never applied). Explicit
  # chgrp/chmod on the sysfs attribute — same pattern as nixpkgs'
  # brightnessctl rules — actually works. "input" because prepko is
  # already in that group for /dev/input access; scoped to Sony's vendor
  # ID (054C) so it never touches unrelated LEDs (kbd backlight, etc).
  # Consumed by home/ps-controller-colors.nix.
  ############################################################
  services.udev.extraRules = ''
    SUBSYSTEM=="leds", DEVPATH=="*/uhid/*054C*/leds/*", RUN+="${pkgs.coreutils}/bin/chgrp input /sys%p/brightness", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys%p/brightness"
  '';

}

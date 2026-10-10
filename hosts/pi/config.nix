{ inputs, config, pkgs, lib, modulesPath, ... }:
let
  gitBackup = false;
in
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    ../../identities/prepko.nix
    ../../roles/ssh-known-hosts.nix
    ../../roles/wifi-home.nix
    inputs.sops-nix.nixosModules.sops
  ];

  networking.hostName = "SWpi";
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  hardware.enableRedistributableFirmware = true;

  # DHCP on Ethernet comes from NetworkManager too. The home Wi-Fi profile is
  # declared in roles/wifi-home.nix; its PSK comes from sops, never the store.
  networking.networkmanager.enable = true;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # 1 GB of RAM and a microSD: swap in RAM, logs in RAM.
  zramSwap.enable = true;
  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=32M
  '';
  documentation.enable = false;
  services.udisks2.enable = false;
  boot.loader.timeout = 1;
  # bcm2835_wdt caps at ~15s; a wedged headless Pi would otherwise stay down.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "15s";
    RebootWatchdogSec = "2min";
  };

  nix.settings = {
    min-free = 256 * 1024 * 1024;
    max-free = 1024 * 1024 * 1024;
    # nixos-rebuild --build-host copies unsigned closures from desktop.
    trusted-users = [ "root" "prepko" ];
    allowed-users = [ "prepko" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
  environment.defaultPackages = [ ];
  boot.tmp.cleanOnBoot = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 3;

  boot.kernel.sysctl = {
    "vm.swappiness" = 100;
    "vm.page-cluster" = 0;
  };

  systemd.services.git-maintain = {
    path = [ pkgs.git ];
    serviceConfig = {
      Type = "oneshot";
      User = "git";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    startAt = "weekly";
    script = ''
      for r in /srv/git/*.git; do
        git -C "$r" gc --prune=1.day
        # fsck reads the whole repo off the SD card: first week of the month only
        if [ "$(date +%-d)" -le 7 ]; then
          git -C "$r" fsck --connectivity-only
        fi
      done
    '';
  };

  # identities/prepko.nix lists groups that don't exist here and sets zsh.
  users.users.prepko = {
    shell = lib.mkForce pkgs.bash;
    extraGroups = lib.mkForce [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.tailscale.enable = true;
  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    checkReversePath = "loose";
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "prepko" "git" ];
      X11Forwarding = false;
      MaxAuthTries = 3;
      LoginGraceTime = 20;
    };
  };

  ############################################################
  # Git hub: bare repos under /srv/git, reachable only as the
  # git-shell-restricted `git` user with prepko's keys.
  ############################################################
  users.groups.git = { };
  users.users.git = {
    isSystemUser = true;
    group = "git";
    home = "/srv/git";
    shell = "${pkgs.git}/bin/git-shell";
    openssh.authorizedKeys.keys = config.users.users.prepko.openssh.authorizedKeys.keys;
  };

  systemd.tmpfiles.rules = [ "d /srv/git 0750 git git -" ];

  ############################################################
  # Backup thumb drive: weekly git bundles, mounted only while a run needs
  # it. The SD stays the live home of /srv/git: a cheap USB stick is no
  # sturdier, and a mid-push dropout would corrupt a bare repo.
  ############################################################
  # Off until the stick survives a sustained write: it dropped off the bus
  # twice (usb -110 enumeration timeouts), likely power on the 3B+.
  fileSystems."/mnt/gitbak" = lib.mkIf gitBackup {
    device = "/dev/disk/by-label/gitbak";
    fsType = "ext4";
    options = [
      "noatime" "nofail" "noauto"
      "x-systemd.automount" "x-systemd.idle-timeout=60" "x-systemd.device-timeout=5"
    ];
  };

  systemd.services.git-backup = lib.mkIf gitBackup {
    unitConfig.RequiresMountsFor = "/mnt/gitbak";
    path = [ pkgs.git pkgs.coreutils pkgs.findutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "git";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    startAt = "daily";
    script = ''
      dest=/mnt/gitbak/repos
      [ -w "$dest" ] || { echo "$dest missing or not writable" >&2; exit 1; }
      stamp=$(date +%F)
      for r in /srv/git/*.git; do
        name=$(basename "$r" .git)
        out="$dest/$name-$stamp.bundle"
        git -C "$r" bundle create "$out.tmp" --all
        git bundle verify "$out.tmp"
        mv "$out.tmp" "$out"
        # keep the newest 14 per repo
        ls -1t "$dest/$name"-*.bundle | tail -n +15 | xargs -r rm --
      done
      sync
    '';
  };

  systemd.services.git-init-repos = {
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    path = [ pkgs.git ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "git";
    };
    script = ''
      for r in nixos claude-shared; do
        [ -d /srv/git/$r.git ] || git init --bare -b main /srv/git/$r.git
      done
    '';
  };
}

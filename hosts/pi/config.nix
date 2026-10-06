{ config, pkgs, lib, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    ../../identities/prepko.nix
    ../../roles/ssh-known-hosts.nix
  ];

  networking.hostName = "SWpi";
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  hardware.enableRedistributableFirmware = true;

  # DHCP on Ethernet comes from NetworkManager too. The Wi-Fi profile is added
  # by hand with nmcli (lives on the card, not in the repo): a PSK in the flake
  # would land in the world-readable store.
  networking.networkmanager.enable = true;

  # 1 GB of RAM and a microSD: swap in RAM, logs in RAM.
  zramSwap.enable = true;
  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=32M
  '';
  documentation.enable = false;

  nix.settings = {
    auto-optimise-store = true;
    # nixos-rebuild --build-host copies unsigned closures from desktop.
    trusted-users = [ "root" "prepko" ];
    allowed-users = [ "prepko" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
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

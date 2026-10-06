{ inputs, pkgs, lib, ... }:
{
  imports = [
    ./hardware.nix
    ./kiosk.nix
    ./idle-blank.nix
    ../../identities/prepko.nix
    ../../roles/secure-boot.nix
    ../../roles/ssh-known-hosts.nix
  ];

  networking.hostName = "SWretro";
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  hardware.enableRedistributableFirmware = true;

  ############################################################
  # Boot (lanzaboote via roles/secure-boot.nix) + LUKS (TPM2 auto-unlock; enrolled by hand, see plan Task 4)
  ############################################################
  environment.systemPackages = [ pkgs.sbctl ];

  # A headless box can't sit at a passphrase prompt. The crypttab option is
  # inert until a TPM2 keyslot is enrolled; the passphrase slot stays as recovery.
  boot.initrd.systemd.enable = true;
  boot.initrd.luks.devices."luks-a852db3d-1e7f-44c1-951e-7ff87edcffe6".crypttabExtraOpts = [ "tpm2-device=auto" ];
  security.tpm2.enable = true;

  ############################################################
  # Users
  ############################################################
  # identities/prepko.nix lists groups that don't exist here and sets zsh.
  users.users.prepko = {
    shell = lib.mkForce pkgs.bash;
    extraGroups = lib.mkForce [ "wheel" "networkmanager" ];
  };
  security.sudo.wheelNeedsPassword = false;

  # No password, no keys: only ever autologged-in by cage.
  users.users.retro = {
    isNormalUser = true;
    extraGroups = [ "audio" "video" "input" ];
  };

  nix.settings = {
    allowed-users = [ "prepko" ];
    # nixos-rebuild --build-host copies unsigned closures from desktop.
    trusted-users = [ "root" "prepko" ];
  };

  ############################################################
  # Network
  ############################################################
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = false;

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
      AllowUsers = [ "prepko" ];
      X11Forwarding = false;
    };
  };

  ############################################################
  # Power: docked on a TV; power button suspends, BT pad wakes
  ############################################################
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "suspend";
    IdleAction = "ignore";
  };

  # The adapter's wakeup attr defaults to disabled and drops back to it across resume; a udev
  # "add" rule only catches boot, so re-arm it right before every sleep.
  environment.etc."systemd/system-sleep/retro-resume".source = pkgs.writeShellScript "retro-resume" ''
    case "$1" in
      pre)
        for d in /sys/bus/usb/devices/*; do
          [ "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" = "0cf3:e007" ] \
            && echo enabled > "$d/power/wakeup"
        done
        ;;
      post)
        # ath10k and the BT dongle come back wedged after resume.
        ${pkgs.util-linux}/bin/rfkill unblock all
        ${pkgs.systemd}/bin/systemctl restart bluetooth.service idle-blank.service
        ;;
    esac
  '';
  services.thermald.enable = true;

  ############################################################
  # Hardening (light)
  ############################################################
  security.protectKernelImage = true;
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.unprivileged_bpf_disabled" = 1;
  };
}

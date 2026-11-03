{ inputs, pkgs, lib, ... }:
{
  imports = [
    ../../modules/nixfetch.nix
    ./hardware.nix
    ./kiosk.nix
    ./idle-blank.nix
    ./dns-querylog.nix
    ../../identities/prepko.nix
    ../../roles/secure-boot.nix
    ../../roles/wifi-home.nix
    inputs.sops-nix.nixosModules.sops
    ../../roles/headless.nix
    ../../roles/goodnight-activate.nix
    ../../roles/ssh-known-hosts.nix
  ];

  networking.hostName = "SWretro";
  ############################################################
  # Boot (lanzaboote via roles/secure-boot.nix) + LUKS (TPM2 auto-unlock; enrolled by hand, see plan Task 4)
  ############################################################
  environment.systemPackages = [ pkgs.sbctl ];

  # A headless box can't sit at a passphrase prompt. The crypttab option is
  # inert until a TPM2 keyslot is enrolled; the passphrase slot stays as recovery.
  boot.initrd.systemd.enable = true;
  boot.initrd.luks.devices."luks-a852db3d-1e7f-44c1-951e-7ff87edcffe6".crypttabExtraOpts = [ "tpm2-device=auto" ];
  security.tpm2.enable = true;

  # Holding a key at power-on still opens the menu.
  boot.loader.timeout = 0;

  ############################################################
  # Users
  ############################################################
  # No password, no keys: only ever autologged-in by cage.
  users.users.retro = {
    isNormalUser = true;
    extraGroups = [ "audio" "video" "input" ];
  };

  nix.optimise.automatic = true;
  services.fstrim.enable = true;

  ############################################################
  # Network
  ############################################################
  networking.networkmanager.wifi.powersave = false;

  # ath10k stalls on 2.4 GHz while Bluetooth is active.
  homeWifi.band = "a";

  services.openssh.settings.AllowUsers = [ "prepko" ];

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
        ${pkgs.systemd}/bin/systemctl restart bluetooth.service idle-blank.service retro-epp.service
        ;;
    esac
  '';
  services.thermald.enable = true;
  # Kernel default is balance_performance (= PPD "balanced") and the i5 sat at 79-80 C
  # idling a thin client. Moonlight decodes on the GPU, so the CPU can ramp lazily.
  systemd.services.retro-epp = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        echo balance_power > "$f"
      done
    '';
  };
  # roles/secure-boot.nix keeps 10 signed UKIs on the ESP; this box needs 3.
  boot.loader.systemd-boot.configurationLimit = 3;

  # Every fleet-status probe used to log in over ssh and journal a user-manager start/stop; keep
  # the journal small and in RAM so idle chatter doesn't hit the SSD.
  services.journald.extraConfig = ''
    RuntimeMaxUse=64M
  '';


  # goodnight runs these instead of their timers (modules/goodnight-jobs.nix)
  goodnight.jobs = {
    nix-optimise.every = "day";
    nix-gc.every = "week";
    fstrim.every = "week";
  };
}

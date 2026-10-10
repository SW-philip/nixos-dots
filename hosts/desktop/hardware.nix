{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  ############################################################
  # Initrd / Kernel modules
  ############################################################
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "tpm_tis" "tpm_crb" ];
  boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.extraModulePackages = [ ];
  # No native USB-C port; this driver probes a non-existent CCG controller and
  # logs i2c_transfer errors on every boot.
  boot.blacklistedKernelModules = [ "ucsi_ccg" ];

  ############################################################
  # LUKS
  ############################################################
  boot.initrd.luks.devices."luks-d8543351-206f-4b3e-884f-9d0ea8c2eebd" = {
    device = "/dev/disk/by-uuid/d8543351-206f-4b3e-884f-9d0ea8c2eebd";
    allowDiscards = true;
    crypttabExtraOpts = [ "tpm2-device=auto" "tpm2-pcrs=7" ];
  };

  boot.initrd.luks.devices."luks-ef5a92e1-47b4-44e1-bfe0-e8d03f437369" = {
    device = "/dev/disk/by-uuid/ef5a92e1-47b4-44e1-bfe0-e8d03f437369";
    allowDiscards = false;
    crypttabExtraOpts = [ "tpm2-device=auto" "tpm2-pcrs=7" ];
  };

  ############################################################
  # TPM2
  ############################################################
  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  ############################################################
  # Filesystems
  ############################################################
  fileSystems."/" = {
    device = "/dev/mapper/luks-d8543351-206f-4b3e-884f-9d0ea8c2eebd";
    fsType = "btrfs";
    options = [ "subvol=@" "compress=zstd:1" "noatime" ];
  };

  fileSystems."/home" = {
    device = "/dev/mapper/luks-d8543351-206f-4b3e-884f-9d0ea8c2eebd";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd:1" "noatime" ];
  };

  fileSystems."/nix" = {
    device = "/dev/mapper/luks-d8543351-206f-4b3e-884f-9d0ea8c2eebd";
    fsType = "btrfs";
    options = [ "subvol=@nix" "compress=zstd" "noatime" ];
    neededForBoot = true;
  };

  fileSystems."/persist" = {
    device = "/dev/mapper/luks-d8543351-206f-4b3e-884f-9d0ea8c2eebd";
    fsType = "btrfs";
    options = [ "subvol=@persist" "compress=zstd" "noatime" ];
    neededForBoot = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/2FA5-FDF9";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  fileSystems."/mnt/backup" = {
    device = "/dev/mapper/luks-ef5a92e1-47b4-44e1-bfe0-e8d03f437369";
    fsType = "btrfs";
    options = [ "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10" ];
  };

  fileSystems."/srv" = {
    device = "/dev/mapper/luks-ef5a92e1-47b4-44e1-bfe0-e8d03f437369";
    fsType = "btrfs";
    options = [ "subvol=srv" "compress=zstd" "noatime" "nofail" "x-systemd.device-timeout=10" ];
  };

  ############################################################
  # Swap
  ############################################################
  swapDevices = [ ];

  ############################################################
  # SATA link power management
  # sda (ADATA SU630) causes CommWake link resets with DiPM enabled,
  # resulting in btrfs write_io_errs and EIO on sync. max_performance
  # disables both HIPM and DiPM to keep the link always active.
  ############################################################
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="scsi_host", KERNEL=="host*", ATTR{link_power_management_policy}="max_performance"
  '';

  ############################################################
  # Platform
  ############################################################
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

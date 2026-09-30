{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

############################################################
  # Initrd / Kernel modules
  ############################################################
  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];

  boot.kernelModules = [ "kvm-intel" "coretemp" ];

  ############################################################
  # Kernel (linux-surface forced in features.nix)
  ############################################################
  hardware.cpu.intel.updateMicrocode = true;

  ############################################################
  # TPM2
  ############################################################
  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  ############################################################
  # LUKS
  ############################################################
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/de445ba9-d179-4470-a560-6c06f52a6481";
    allowDiscards = true;
    crypttabExtraOpts = [
      "tpm2-device=auto"
      "tpm2-pcrs=7"
    ];
  };

  ############################################################
  # Filesystems
  ############################################################
  fileSystems."/" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@" "compress=zstd" "noatime" ];
  };

  fileSystems."/home" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd" "noatime" ];
  };

  fileSystems."/nix" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@nix" "compress=zstd" "noatime" ];
    neededForBoot = true;
  };

  fileSystems."/persist" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@persist" "compress=zstd" "noatime" ];
    neededForBoot = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/7139-F250";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  ############################################################
  # Swap
  ############################################################
  swapDevices = [ ];

  ############################################################
  # Platform
  ############################################################
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

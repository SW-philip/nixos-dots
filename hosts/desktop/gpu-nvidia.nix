{ config, pkgs, lib, ... }:

{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics = {
    enable      = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      intel-media-driver   # iHD — VA-API for UHD 630+
      intel-vaapi-driver   # i965 — fallback for older content paths
    ];
  };

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  boot.kernelParams = lib.mkAfter [
    "nvidia-drm.modeset=1"
    "nvidia.NVreg_PreserveVideoMemoryAllocations=1"
    "nvidia.NVreg_EnableGpuFirmware=0"   # disable GSP — fixes Turing Wayland stalls
  ];

  boot.initrd.kernelModules = [ "i915" ];

  services.udev.extraRules = ''
    KERNEL=="card*", KERNELS=="0000:01:00.0", SUBSYSTEM=="drm", SUBSYSTEMS=="pci", SYMLINK+="dri/nvidia-gpu"
  '';

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    NVD_BACKEND               = "auto";
  };

  programs.steam.enable = true;
  programs.steam.remotePlay.openFirewall = true;
  programs.steam.extraCompatPackages = [ pkgs.proton-ge-bin ];

  # Standalone Wine for running Windows installers (e.g. FitGirl setup.exe)
  # outside Steam's process reaper, which kills Inno Setup's setup.tmp worker
  # when the bootstrapper exits mid-extraction.
  environment.systemPackages = with pkgs; [
    wineWow64Packages.stable   # 64-bit wine with 32-bit (WoW64) support
    winetricks
  ];
}

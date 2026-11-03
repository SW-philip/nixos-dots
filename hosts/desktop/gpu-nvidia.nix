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
    # Keeps the driver initialised between clients so NVENC sessions (Sunshine,
    # Jellyfin) start without a cold-load delay.
    nvidiaPersistenced = true;
    open = false;
    nvidiaSettings = true;
    # patchelf 0.19.2 setting interpreter and rpath in one call leaves .dynamic read-only, so
    # nvidia-smi/powerd/mps-control segfault in ld.so. Re-patch from origBin in two calls.
    # Drop once nixpkgs-unstable is past nixpkgs issue 576397.
    package = config.boot.kernelPackages.nvidiaPackages.stable.overrideAttrs (old: {
      postFixup = (old.postFixup or "") + ''
        for orig in $bin/origBin/*; do
          b=$bin/bin/$(basename "$orig")
          rpath=$(patchelf --print-rpath "$b")
          interp=$(patchelf --print-interpreter "$b")
          install -m755 "$orig" "$b"
          patchelf --set-rpath "$rpath" "$b"
          patchelf --interpreter "$interp" "$b"
        done
      '';
    });
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
}

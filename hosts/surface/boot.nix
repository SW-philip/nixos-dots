{ lib, ... }:

{
  boot.plymouth.enable = false;
  boot.consoleLogLevel = 0;
  boot.initrd.verbose = false;

  boot.loader.timeout = 0;

  boot.initrd.systemd.enable = true;
  boot.initrd.kernelModules = [ "i915" ];

  boot.kernelParams = lib.mkAfter [
    "quiet" "loglevel=0"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "vt.handoff=7"
    "delayacct"
    "pcie_aspm.policy=powersupersave"
    # Prevent simpledrm (EFI framebuffer) from claiming card0.
    # Without this, i915 lands on card1 and Plymouth (which tries card0 first) misses it.
    "video=efifb:off"
  ];

  # Boot menu entry (hold Space at POST): Secure Boot off, plaintext LUKS
  # prompt, usb_storage/uas loaded early so enclosure drive is visible.
  specialisation.enclosure-recovery.configuration = {
    boot.lanzaboote.enable          = lib.mkForce false;
    boot.loader.systemd-boot.enable = lib.mkForce true;
    boot.plymouth.enable            = lib.mkForce false;
    boot.initrd.kernelModules       = [ "usb_storage" "uas" ];
  };
}

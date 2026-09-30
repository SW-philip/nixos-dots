{ lib, ... }:

{
  # Plymouth is off (a black screen beats stalling on the splash). The theme
  # module is kept in modules/plymouth.nix but deliberately not imported.
  boot.plymouth.enable = false;
  boot.consoleLogLevel = 0;
  boot.initrd.verbose = false;

  boot.loader.timeout = 0;
  boot.initrd.systemd.enable = true;
  boot.kernelParams = lib.mkAfter [
    "8250.nr_uarts=0"
    "quiet" "loglevel=0"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "vt.handoff=7"
    "delayacct"
  ];
}

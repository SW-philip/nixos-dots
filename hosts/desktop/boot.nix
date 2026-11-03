{ lib, ... }:

{
  # Plymouth is off (a black screen beats stalling on the splash). The old
  # themes are in ~/archive/nixos/plymouth-2026-11-02.
  boot.plymouth.enable = false;
  boot.consoleLogLevel = 0;

  boot.loader.timeout = 0;
  boot.kernelParams = lib.mkAfter [
    "8250.nr_uarts=0"
    "quiet" "loglevel=0"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "vt.handoff=7"
    "delayacct"
  ];
}

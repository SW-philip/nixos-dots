{ pkgs, ... }:

{
  boot.consoleLogLevel = 0;
  boot.initrd.verbose = false;

  boot.plymouth = {
    enable = true;
    theme = "dsa-rose";
    themePackages = [ pkgs.dsa-plymouth ];
  };
  # Fallback: revert to the ice-cream splash by swapping the two lines above to
  #   theme = "lix-icecream"; themePackages = [ pkgs.lix-plymouth ];
  # or to the silent-film splash with
  #   theme = "silent-splash"; themePackages = [ pkgs.plymouth-silent-splash ];
  # (both packages are kept in the overlay for exactly this.)

  # i915 probes hardware asynchronously after insmod returns; wait for udev-settle
  # so Plymouth's initial scan finds card1 (i915) instead of card0 (simpledrm).
  boot.initrd.systemd.services.plymouth-start = {
    overrideStrategy = "asDropin";
    after = [ "systemd-modules-load.service" "systemd-udev-settle.service" ];
    wants = [ "systemd-udev-settle.service" ];
  };

  # Keep the last rendered frame on-screen after Plymouth exits so there's no
  # flash of text between the card and greetd taking over the display.
  systemd.services.plymouth-quit = {
    overrideStrategy = "asDropin";
    serviceConfig.ExecStart = [
      ""
      "-${pkgs.plymouth}/bin/plymouth quit --retain-splash"
    ];
  };
}

{ config, pkgs, lib, ... }:
{
  ############################################################
  # Audio stack (PipeWire)
  ############################################################
  # Without rtkit, PipeWire's audio thread runs at normal scheduling
  # priority and can miss its deadline under CPU/GPU load, causing xruns
  # that RetroArch's audio-driven sync (and similar sync-to-audio modes in
  # most standalone emulators) turns into visible video stutter.
  security.rtkit.enable = true;

  services.pipewire = { # grade:host-specific
    jack.enable = true;
    wireplumber = {
      extraConfig = {

        "99-bt-priority" = {
          "monitor.bluez.rules" = [
            {
              matches = [{ "node.name" = "~bluez_output.*"; }];
              actions.update-props = {
                "priority.session" = 2000;
                "priority.driver"  = 2000;
              };
            }
          ];
        };
      };
    };
  };

  ############################################################
  # Bluetooth
  ############################################################
  services.blueman.enable = true;
  hardware.enableAllFirmware = true;
  # DualShock 4 (and some other older HID controllers) fail L2CAP
  # connection with "br-connection-create-socket" under ERTM.
  # btusb autosuspend: the cheap 33fa:0010 "USB2.0-BT" dongle wedges
  # HCI_Reset (0x0c03 -> -12) when its port autosuspends mid-init.
  boot.extraModprobeConfig = ''
    options bluetooth disable_ertm=1
    options btusb enable_autosuspend=0
  '';

  # rfkill block state must not survive a reboot on an always-on desktop:
  # blueman soft-blocks the radio when it sees no adapter, systemd-rfkill
  # persists that per USB-port, and every boot restores it. Let powerOnBoot
  # + main.conf AutoEnable start from a clean slate instead.
  systemd.services.systemd-rfkill.enable = false;
  systemd.sockets.systemd-rfkill.enable = false;

  ############################################################
  # Power & policy
  ############################################################
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;
  security.polkit.enable = true;
  # fwupd-refresh runs as the system user "fwupd-refresh" with no active
  # session, so polkit falls through to allow_any=auth_admin and fails.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id === "org.freedesktop.fwupd.refresh-remote" &&
          subject.user === "fwupd-refresh") {
        return polkit.Result.YES;
      }
    });
  '';

  ############################################################
  # i2c + OpenRGB — required for RGB and hardware sensor access
  ############################################################
  hardware.i2c.enable = true;
  boot.kernelModules = [ "i2c-dev" "i2c-i801" ];
  boot.kernelParams = [ "acpi_enforce_resources=lax" ];
  environment.systemPackages = [ pkgs.openrgb-with-all-plugins pkgs.tor-browser ];
  services.udev.packages = [ pkgs.openrgb-with-all-plugins ];

}

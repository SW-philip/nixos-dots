{ pkgs, ... }:
let
  watcher = pkgs.writeTextFile {
    name = "kid-controller-home-watch";
    executable = true;
    destination = "/bin/kid-controller-home-watch";
    text = ''
      #!${pkgs.python3.withPackages (ps: [ ps.evdev ])}/bin/python3
      import subprocess
      import time

      import evdev
      from evdev import ecodes

      # ASSUMED, NOT YET VERIFIED — no physical controller available during
      # implementation. Confirm the real PS/Home button code via `evtest` on
      # the actual hardware (see Task 5 Step 4 / Task 7 Step 5 of
      # docs/superpowers/plans/2026-07-20-kid-pegasus-dashboard.md)
      # before considering this done. Adjust if evtest shows a different code.
      HOME_BUTTON = ecodes.BTN_MODE

      def find_controller():
          # hid-sony/hid-playstation register multiple evdev nodes per pad
          # (gamepad, touchpad, motion sensors), all matching "Wireless
          # Controller" — filter to the one that actually has our button so
          # we don't silently bind to a sub-device that never sees it.
          for path in evdev.list_devices():
              dev = evdev.InputDevice(path)
              if "Wireless Controller" in dev.name and HOME_BUTTON in dev.capabilities().get(ecodes.EV_KEY, []):
                  return dev
          return None

      def go_home():
          subprocess.run(["${pkgs.niri}/bin/niri", "msg", "action", "close-window"])
          subprocess.run(["${pkgs.niri}/bin/niri", "msg", "action", "focus-workspace", "home"])

      def watch(dev):
          for event in dev.read_loop():
              if event.type == ecodes.EV_KEY and event.code == HOME_BUTTON and event.value == 1:
                  go_home()

      def main():
          while True:
              dev = find_controller()
              if dev is None:
                  time.sleep(5)
                  continue
              try:
                  watch(dev)
              except OSError:
                  pass

      if __name__ == "__main__":
          main()
    '';
  };
in
{
  systemd.user.services.kid-controller-home = {
    Unit = {
      Description = "Watch PS4 controller Home button, return to dashboard";
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
      # WantedBy alone only pulls this unit in when graphical-session.target
      # starts; it doesn't order it after the target. Without After/PartOf,
      # systemd dispatches it in the same transaction as the target — often
      # a full second before niri.service (Before=graphical-session.target,
      # Type=notify) actually goes ready, so ConditionEnvironment sees no
      # XDG_CURRENT_DESKTOP yet and permanently skips (unmet conditions
      # aren't retried). Confirmed via journalctl: the skip landed right
      # after graphical-session-pre.target, a full second before niri
      # started. Mirrors waybar.service/kanshi.service's own units.
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = "${watcher}/bin/kid-controller-home-watch";
      Restart = "always";
      RestartSec = 2;
    };
  };
}

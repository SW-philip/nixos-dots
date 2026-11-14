# PS/Home button on any gamepad: start Pegasus if it isn't running, focus it if
# it is, and from a focused Pegasus jump back to the previous window (the game).
# Kid's dashboard version is home/kid/controller-home.nix.
{ config, pkgs, ... }:
let
  niri = "${pkgs.niri}/bin/niri";
  watcher = pkgs.writers.writePython3Bin "pegasus-controller-home" {
    libraries = [ pkgs.python3Packages.evdev ];
    flakeIgnore = [ "E501" ];
  } ''
    import json
    import selectors
    import subprocess

    import evdev
    from evdev import ecodes

    NIRI = "${niri}"


    def is_pad(dev):
        # libvirtualhid's keyboard also advertises BTN_MODE; real pads have sticks
        caps = dev.capabilities()
        axes = [code for code, _ in caps.get(ecodes.EV_ABS, [])]
        return ecodes.BTN_MODE in caps.get(ecodes.EV_KEY, []) and ecodes.ABS_X in axes


    def niri(*args):
        return subprocess.run([NIRI, "msg", *args], capture_output=True, text=True)


    def home():
        try:
            windows = json.loads(niri("--json", "windows").stdout)
        except json.JSONDecodeError:
            return
        peg = [w for w in windows if "pegasus" in (w.get("app_id") or "").lower()]
        if not peg:
            niri("action", "spawn", "--", "${pkgs.pegasus-frontend}/bin/pegasus-fe")
        elif peg[0].get("is_focused"):
            niri("action", "focus-window-previous")
        else:
            niri("action", "focus-window", "--id", str(peg[0]["id"]))


    def main():
        sel = selectors.DefaultSelector()
        watched = {}
        last = set()
        while True:
            # rescan only when the device list changes: pads come and go over Bluetooth
            paths = set(evdev.list_devices())
            new, last = paths - last, paths
            for path in new:
                if path in watched:
                    continue
                try:
                    dev = evdev.InputDevice(path)
                except OSError:
                    last.discard(path)  # uaccess can land after the node appears; retry
                    continue
                if is_pad(dev):
                    watched[path] = dev
                    sel.register(dev, selectors.EVENT_READ)
                else:
                    dev.close()
            for key, _ in sel.select(timeout=5):
                dev = key.fileobj
                try:
                    events = list(dev.read())
                except OSError:
                    sel.unregister(dev)
                    del watched[dev.path]
                    dev.close()
                    continue
                for ev in events:
                    if ev.type == ecodes.EV_KEY and ev.code == ecodes.BTN_MODE and ev.value == 1:
                        home()


    main()
  '';
in
{
  systemd.user.services.pegasus-controller-home = {
    Unit = config.lib.niri.unit { wayland = false; } {
      Description = "PS button opens or focuses Pegasus";
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = "${watcher}/bin/pegasus-controller-home";
      Restart = "always";
      RestartSec = 2;
    };
  };
}

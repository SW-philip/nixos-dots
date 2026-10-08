{ pkgs, ... }:
let
  # cage has no output power management, so "display sleep" is wlr-randr
  # disabling the output: the TV drops to no signal, cage keeps running.
  idleBlank = pkgs.writers.writePython3Bin "idle-blank" { flakeIgnore = [ "E501" ]; } ''
    import glob
    import os
    import pwd
    import select
    import subprocess
    import time

    IDLE_SECS = 11 * 60
    SUSPEND_SECS = 20 * 60  # further idle time after the blank point
    SYSTEMCTL = "${pkgs.systemd}/bin/systemctl"
    EVENT_SIZE = 24  # struct input_event on 64-bit
    WLR_RANDR = "${pkgs.wlr-randr}/bin/wlr-randr"
    RUNUSER = "${pkgs.util-linux}/bin/runuser"

    fds = {}
    last_activity = time.monotonic()
    last_stream_check = 0.0
    blanked = False
    blank_tried = False


    def randr(*args):
        uid = pwd.getpwnam("retro").pw_uid
        return subprocess.run(
            [RUNUSER, "-u", "retro", "--", "env",
             f"XDG_RUNTIME_DIR=/run/user/{uid}", "WAYLAND_DISPLAY=wayland-0",
             WLR_RANDR, *args],
            capture_output=True, text=True,
        )


    def set_output(on):
        listing = randr().stdout.splitlines()
        names = [ln.split()[0] for ln in listing if ln[:1].isalpha()]
        for name in names:
            randr("--output", name, "--on" if on else "--off")
        return bool(names)


    def rescan():
        for path in glob.glob("/dev/input/event*"):
            if path not in fds:
                try:
                    fds[path] = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                except OSError:
                    pass


    def streaming():
        out = subprocess.run(
            ["ss", "-uHnp"], capture_output=True, text=True
        ).stdout
        return "moonlight" in out


    while True:
        rescan()
        if fds:
            ready, _, _ = select.select(list(fds.values()), [], [], 5)
            for fd in ready:
                try:
                    data = os.read(fd, EVENT_SIZE * 64)
                except OSError:
                    data = b""
                if data:
                    last_activity = time.monotonic()
                    blank_tried = False
                    if blanked:
                        blanked = not set_output(True)
                else:
                    for p, f in list(fds.items()):
                        if f == fd:
                            os.close(fd)
                            del fds[p]
        else:
            time.sleep(5)
        now = time.monotonic()
        if now - last_stream_check > 5:
            last_stream_check = now
            if streaming():
                last_activity = now
        idle = now - last_activity
        if idle > IDLE_SECS + SUSPEND_SECS:
            # Not gated on blanked: with the kiosk stopped there is no output to blank, but the
            # machine should still sleep. Resume restarts this service (system-sleep hook in
            # config.nix), which re-lights the output.
            subprocess.run([SYSTEMCTL, "suspend"])
            last_activity = time.monotonic()
        elif not blank_tried and idle > IDLE_SECS:
            blank_tried = True
            blanked = set_output(False)
  '';
in
{
  systemd.services.idle-blank = {
    description = "Blank the display after 11 minutes without input or a Moonlight stream, suspend 20 minutes after that, display or not";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.iproute2 ];
    serviceConfig = {
      ExecStart = "${idleBlank}/bin/idle-blank";
      Restart = "on-failure";
      # A stopped service must not leave the TV on no signal.
      ExecStopPost = "-${pkgs.writeShellScript "idle-blank-restore" ''
        uid=$(${pkgs.coreutils}/bin/id -u retro)
        for o in $(${pkgs.util-linux}/bin/runuser -u retro -- env XDG_RUNTIME_DIR=/run/user/$uid WAYLAND_DISPLAY=wayland-0 ${pkgs.wlr-randr}/bin/wlr-randr | ${pkgs.gawk}/bin/awk '/^[A-Za-z]/{print $1}'); do
          ${pkgs.util-linux}/bin/runuser -u retro -- env XDG_RUNTIME_DIR=/run/user/$uid WAYLAND_DISPLAY=wayland-0 ${pkgs.wlr-randr}/bin/wlr-randr --output "$o" --on
        done
      ''}";
    };
  };
}

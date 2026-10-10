{ pkgs, lib, ... }:

let
  # niri spawns xwayland-satellite itself, on demand, the moment any X11
  # client tries to connect — confirmed live, no launcher wrapper needed
  # for that half. What niri never does is tear it back down once the
  # last XWayland window closes, regardless of which app triggered it —
  # this is the generic idle sweep for that gap.
  idleCleanupScript = pkgs.writeShellScript "xwayland-satellite-idle-cleanup" ''
    export PATH="${lib.makeBinPath [
      pkgs.niri
      pkgs.jq
      pkgs.procps
      pkgs.gnugrep
      pkgs.coreutils
    ]}:$PATH"

    satellite_pids=$(pgrep -f '^xwayland-satellite' || true)
    [[ -z "$satellite_pids" ]] && exit 0

    still_in_use=0
    while IFS= read -r wpid; do
        if grep -qx "$wpid" <<<"$satellite_pids"; then
            still_in_use=1
            break
        fi
    done < <(niri msg --json windows 2>/dev/null | jq -r '.[].pid')

    # The real xwayland-satellite worker gets reparented to niri itself
    # the moment it's ready, outside any systemd unit's cgroup — killing
    # the matched pid(s) directly is the only thing that actually works.
    if [[ "$still_in_use" -eq 0 ]]; then
        kill $satellite_pids
    fi
    exit 0
  '';
in
{
  systemd.user.services.xwayland-satellite-idle-cleanup = {
    Unit.Description = "Kill xwayland-satellite once no XWayland windows remain";
    Service = {
      Type = "oneshot";
      ExecStart = "${idleCleanupScript}";
    };
  };

  systemd.user.timers.xwayland-satellite-idle-cleanup = {
    Unit.Description = "Periodic idle check for xwayland-satellite";
    Timer = {
      OnUnitActiveSec = "2min";
      AccuracySec = "1min";
      OnActiveSec = "2min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}

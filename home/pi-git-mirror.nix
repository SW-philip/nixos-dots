{ pkgs, ... }:
let
  piGitMirror = pkgs.writeShellApplication {
    name = "pi-git-mirror";
    runtimeInputs = with pkgs; [ bash git openssh coreutils ];
    text = builtins.readFile ../scripts/pi-git-mirror.sh;
  };
in
{
  home.packages = [ piGitMirror ];

  systemd.user.services.pi-git-mirror = {
    Unit.Description = "Mirror the pi's git hub to ~/.local/share/pi-git-mirror";
    Service = {
      Type = "oneshot";
      ExecStart = "${piGitMirror}/bin/pi-git-mirror";
      Nice = 19;
    };
  };

  # Persistent: a desktop that was off at the usual hour catches up on next boot.
  systemd.user.timers.pi-git-mirror = {
    Unit.Description = "pi-git-mirror timer";
    Timer = { OnCalendar = "daily"; Persistent = true; RandomizedDelaySec = "30min"; };
    Install.WantedBy = [ "timers.target" ];
  };
}

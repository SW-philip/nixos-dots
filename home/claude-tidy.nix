{ pkgs, ... }:
let
  tidy = pkgs.writeShellApplication {
    name = "claude-tidy";
    runtimeInputs = with pkgs; [ coreutils findutils gnugrep gnused ];
    text = builtins.readFile ../scripts/claude-tidy.sh;
  };
in
{
  home.packages = [ tidy ];

  systemd.user.services.claude-tidy = {
    Unit.Description = "Prune old Claude Code transcripts and redact leaked tokens";
    Service = {
      Type = "oneshot";
      ExecStart = "${tidy}/bin/claude-tidy";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  # Persistent: a surface that was asleep at the OnCalendar time catches up on wake.
  systemd.user.timers.claude-tidy = {
    Unit.Description = "Daily Claude Code state tidy";
    Timer = { OnCalendar = "daily"; RandomizedDelaySec = "1h"; Persistent = true; };
    Install.WantedBy = [ "timers.target" ];
  };
}

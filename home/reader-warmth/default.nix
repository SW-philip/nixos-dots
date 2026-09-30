# E-reader mode: warm + slightly dim the screen only while KOReader is focused.
# KOReader's own warmth control drives frontlight hardware, which a laptop
# panel doesn't have, so this does it at the compositor (niri exposes
# wlr-gamma-control) and restores as soon as focus leaves. Surface-only:
# gamma is per-output, so on the two-monitor desktop it would tint both.
# Tune TEMP_K / BRIGHTNESS below; `systemctl --user stop reader-warmth` to disable.
{ pkgs, lib, ... }:
let
  readerWarmth = pkgs.writeShellApplication {
    name = "reader-warmth";
    runtimeInputs = [ pkgs.gammastep pkgs.jq pkgs.coreutils ];
    text = ''
      TEMP_K=3400
      BRIGHTNESS=0.9
      NIRI=/run/current-system/sw/bin/niri
      pid=""

      warm_on() {
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
        gammastep -m wayland -O "$TEMP_K" -b "$BRIGHTNESS" >/dev/null 2>&1 &
        pid=$!
      }
      warm_off() {
        if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pid=""; fi
      }
      check() {
        app=$($NIRI msg --json focused-window 2>/dev/null | jq -r '.app_id // ""' | tr '[:upper:]' '[:lower:]')
        case $app in *koreader*) warm_on ;; *) warm_off ;; esac
      }

      trap warm_off EXIT
      trap 'exit 0' TERM INT
      check
      # Process substitution, not a pipe: a piped loop runs in a subshell and
      # would lose $pid, leaving gammastep orphaned on exit.
      while read -r line; do
        case $line in *WindowFocusChanged*|*WindowClosed*) check ;; esac
      done < <($NIRI msg --json event-stream)
    '';
  };
in
{
  home.packages = [ readerWarmth ];

  systemd.user.services.reader-warmth = {
    Unit = {
      Description = "Warm the screen while KOReader is focused";
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${readerWarmth}/bin/reader-warmth";
      Restart = "always";
      RestartSec = "3s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}

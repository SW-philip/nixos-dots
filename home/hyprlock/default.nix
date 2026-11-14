{ pkgs, ... }:
let
  # Shared with the greeter (pkgs/greeter/default.nix) — edit
  # ../../assets/snark-lines.txt to change the wording everywhere.
  snarkLinesFile = ../../assets/snark-lines.txt;

  # Picks a random line from the shared snark pool (../../assets/snark-lines.txt,
  # also read by the greeter) and substitutes it into a throwaway copy of
  # the currently-deployed hyprlock.conf (drmis-managed, never written to
  # here), then execs hyprlock against that copy. Falls back to plain
  # hyprlock whenever anything here can't be done, so a wrong password never
  # risks leaving the screen unlockable. HYPRLOCK_SNARK_DRY_RUN=1 short-
  # circuits before exec'ing hyprlock, for scripted verification.
  lockScreenBin = pkgs.writeShellScript "hyprlock-snark-launcher" ''
    snark_file="${snarkLinesFile}"
    conf="$HOME/.config/hypr/hyprlock.conf"
    tmp="''${XDG_RUNTIME_DIR:-/tmp}/hyprlock-active.conf"

    render() {
      [[ -r "$snark_file" && -r "$conf" ]] || return 1
      mapfile -t lines < "$snark_file"
      [[ ''${#lines[@]} -gt 0 ]] || return 1
      local line="''${lines[RANDOM % ''${#lines[@]}]}"
      # `snark off` creates this file (see waybar-lib.sh snark_quiet)
      [[ -e "''${XDG_STATE_HOME:-$HOME/.local/state}/snark-off" ]] && line=""
      local content
      content="$(cat "$conf")" || return 1
      content="''${content//@@SNARK@@/$line}"
      printf '%s\n' "$content" > "$tmp" 2>/dev/null
    }

    if render; then
      if [[ -n "''${HYPRLOCK_SNARK_DRY_RUN:-}" ]]; then
        echo "$tmp"
        exit 0
      fi
      exec hyprlock -c "$tmp"
    fi

    [[ -n "''${HYPRLOCK_SNARK_DRY_RUN:-}" ]] && { echo "FALLBACK"; exit 0; }
    exec hyprlock
  '';
in
{
  myConfig.lockScreenScript = lockScreenBin;
}

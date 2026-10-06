{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "rgb-moon" ''
      # waybar/palette.sh: the file drmis actually keeps live on every
      # "drmis set" — theme/palette.sh is a stale, unrelated file frozen
      # to whatever theme was hardcoded into home/waybar/default.nix.
      PALETTE="$HOME/.config/waybar/palette.sh"
      [[ -f "$PALETTE" ]] || { printf 'rgb-moon: no palette at %s\n' "$PALETTE" >&2; exit 1; }
      # shellcheck source=/dev/null
      source "$PALETTE"

      DEVICES=(0 1 2 3)
      hex() { printf '%s' "''${1:1}"; }  # strip leading #

      direct() { openrgb --device "$1" --mode Direct --color "$2"; }

      case "''${1:-aurora}" in
        aurora)
          # each stick gets a different palette accent — follows active theme
          direct 0 "$(hex "$FORTE")"
          direct 1 "$(hex "$SEVENTH")"
          direct 2 "$(hex "$FIFTH")"
          direct 3 "$(hex "$ROOT")"
          ;;
        pulse)
          for d in "''${DEVICES[@]}"; do
            openrgb --device "$d" --mode "Color Pulse" --color "$(hex "$FIFTH"),$(hex "$SEVENTH")"
          done
          ;;
        wave)
          COLORS="$(hex "$FORTE"),$(hex "$FIFTH"),$(hex "$SEVENTH"),$(hex "$ROOT"),$(hex "$PIANO")"
          for d in "''${DEVICES[@]}"; do
            openrgb --device "$d" --mode "Color Wave" --color "$COLORS"
          done
          ;;
        static)
          for d in "''${DEVICES[@]}"; do
            direct "$d" "''${2:-$(hex "$ROOT")}"
          done
          ;;
        off)
          for d in "''${DEVICES[@]}"; do direct "$d" 000000; done
          ;;
        *)
          printf 'Usage: rgb-moon [aurora|pulse|wave|static [HEX]|off]\n' >&2
          exit 1
          ;;
      esac
    '')
  ];
}

# `menu` — the one place that talks to rofi. Takes fuzzel's flags (--dmenu,
# --prompt, --width <chars>, --lines, --index, --placeholder) so callers keep
# one vocabulary; no --dmenu shows the drun list. Exit status: 1 on Esc, like fuzzel.
{ pkgs }:
pkgs.writeShellApplication {
  name = "menu";
  runtimeInputs = [ pkgs.rofi ];
  text = ''
    dmenu=0 prompt="" width=38 lines=8 ph="" idx=0
    while [ $# -gt 0 ]; do
      case $1 in
        --dmenu) dmenu=1 ;;
        --index) idx=1 ;;
        --prompt) prompt=$2; shift ;;
        --width) width=$2; shift ;;
        --lines) lines=$2; shift ;;
        --placeholder) ph=$2; shift ;;
        *) ;;
      esac
      shift
    done

    [ "$width" -ge 28 ] || width=28

    esc() { local s=$1; s=''${s//\\/\\\\}; printf '%s' "''${s//\"/\\\"}"; }
    theme="window { width: ''${width}ch; } listview { lines: ''${lines}; }"
    [ -n "$ph" ] && theme="$theme entry { placeholder: \"$(esc "$ph")\"; }"

    args=(-theme-str "$theme")
    if [ "$dmenu" = 1 ]; then
      [ "$idx" = 1 ] && args+=(-format i)
      exec rofi -dmenu -p "''${prompt:-> }" "''${args[@]}"
    fi
    exec rofi -show drun -p "''${prompt:-󰀻  }" "''${args[@]}"
  '';
}

# Rofi static theme — palette-independent, home-manager-managed symlink
# (xdg.configFile."rofi/config.rasi" in home/niri/default.nix). Colors come from
# colors.rasi, regenerated per-theme by drmis. Josefin leaf, same as lix-logout:
# big round corners on one diagonal, small sharp ones on the other
# (window 24/6, rows 16/4). Wrapper: home/rofi/menu.nix.
''
  @import "colors"

  configuration {
      modi:              "drun";
      show-icons:        true;
      matching:          "fuzzy";
      case-sensitive:    false;
      drun-display-format: "{name}";
      me-select-entry:   "";
      me-accept-entry:   "MousePrimary";
  }

  * {
      font: "Josefin Sans 15, JetBrainsMono Nerd Font 13";
      background-color: transparent;
      text-color: @fg;
  }

  window {
      location: center;
      anchor: center;
      width: 38ch;
      background-color: @bg;
      border: 2px;
      border-color: @bd;
      border-radius: 24px 6px 24px 6px;
  }

  mainbox {
      padding: 20px 28px;
      spacing: 14px;
      children: [ inputbar, listview ];
  }

  inputbar {
      spacing: 8px;
      children: [ prompt, entry ];
  }

  entry {
      placeholder-color: @fg;
  }

  listview {
      lines: 8;
      fixed-height: false;
      scrollbar: false;
      spacing: 4px;
  }

  element {
      padding: 6px 14px;
      spacing: 10px;
      border-radius: 16px 4px 16px 4px;
  }

  element normal.normal, element alternate.normal {
      background-color: transparent;
      text-color: @fg;
  }

  element selected.normal {
      background-color: @sel;
      text-color: @selfg;
  }

  element-text selected.normal {
      text-color: @selfg;
  }

  element-icon {
      size: 1.4em;
  }

''

# Squeekboard GTK3 override — regenerated per-theme by drmis, deployed to
# ~/.config/squeekboard-gtk/gtk-3.0/gtk.css (squeekboard runs with that dir as
# XDG_CONFIG_HOME; the global gtk-3.0/gtk.css belongs to nemo). The stock sheet
# is written in GTK named colours, but a *:dark GTK theme swaps it for a
# hardcoded-hex sheet, so the widget rules below restate the palette at USER
# priority instead of relying on @define-color alone. No hardcoded hex.
{ p }:
''
  @define-color theme_base_color ${p.HALL};
  @define-color theme_fg_color ${p.SCORE};
  @define-color theme_selected_bg_color ${p.STAGE};
  @define-color theme_selected_fg_color ${p.SCORE};
  @define-color borders alpha(${p.SCORE}, 0.15);

  sq_view {
    background-color: ${p.HALL};
    box-shadow: inset 0 1px 0 0 alpha(${p.SCORE}, 0.15);
  }

  sq_button {
    color: ${p.SCORE};
    background: alpha(${p.SCORE}, 0.08);
    box-shadow: 0 1px 0 0 rgba(${p.STAFF}, 0.35);
  }

  sq_button:active {
    background: alpha(${p.SCORE}, 0.16);
  }

  sq_button.altline,
  sq_button.special,
  sq_button.special-2,
  sq_button.special-3,
  sq_button.wide,
  sq_button.change-view,
  sq_button.change-view-2,
  sq_button.change-view-3,
  sq_button.emoji-group,
  sq_button.character-group {
    background: alpha(${p.SCORE}, 0.16);
  }

  sq_button.altline:active,
  sq_button.special:active,
  sq_button.special-2:active,
  sq_button.special-3:active,
  sq_button.wide:active,
  sq_button.change-view:active,
  sq_button.change-view-2:active,
  sq_button.change-view-3:active,
  sq_button.emoji-group:active,
  sq_button.character-group:active {
    background: alpha(${p.SCORE}, 0.28);
  }

  sq_button.latched {
    background: alpha(${p.SCORE}, 0.25);
  }

  sq_button.locked {
    background: ${p.SCORE};
    color: ${p.HALL};
  }

  #Return {
    background: ${p.STAGE};
    color: ${p.SCORE};
  }

  #Return:active {
    background: ${p.WING};
  }
''

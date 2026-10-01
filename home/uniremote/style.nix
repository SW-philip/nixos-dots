# uniremote GTK4/libadwaita override — regenerated per-theme by drmis, deployed
# to ~/.config/uniremote/style.css and loaded by the app at USER priority (not
# ~/.config/gtk-4.0/gtk.css, which every other GTK4 app would also inherit).
# Same vocabulary as home/waybar/style.nix + home/eww/eww.scss: WING shell,
# STAGE chips, SCORE hairline, STAFF drop, ROOT/HALL the one accent.
{ p }:
let
  keyline = "alpha(${p.SCORE}, 0.15)";
  edge    = "alpha(${p.SCORE}, 0.32)";
  bevel   = "inset 0 1px 0 alpha(${p.SCORE}, 0.12)";
  thread  = "alpha(${p.SCORE}, 0.55)";
  drop    = "${bevel}, 0 2px 3px rgba(${p.STAFF}, ${p.STAFF_A_DROP})";
  lift    = "${bevel}, 0 2px 3px rgba(${p.STAFF}, ${p.STAFF_A_DROP}), 0 0 0 1px alpha(${p.SCORE}, 0.18)";
in
''
  @define-color window_bg_color ${p.WING};
  @define-color window_fg_color ${p.SCORE};
  @define-color view_bg_color ${p.WING};
  @define-color view_fg_color ${p.SCORE};
  @define-color headerbar_bg_color ${p.WING};
  @define-color headerbar_fg_color ${p.SCORE};
  @define-color popover_bg_color ${p.STAGE};
  @define-color popover_fg_color ${p.SCORE};
  @define-color dialog_bg_color ${p.WING};
  @define-color dialog_fg_color ${p.SCORE};
  @define-color card_bg_color ${p.STAGE};
  @define-color card_fg_color ${p.SCORE};
  @define-color accent_bg_color ${p.ROOT};
  @define-color accent_fg_color ${p.HALL};
  @define-color accent_color ${p.ROOT};
  @define-color destructive_bg_color ${p.FORTE};
  @define-color destructive_fg_color ${p.HALL};

  * {
      font-family: "Josefin Sans", "DejaVu Sans", sans-serif;
      font-weight: 700;
      text-shadow: none;
  }

  /* Chips: mirrors waybar .module / eww .chip. */
  button {
      background-image: none;
      background-color: ${p.STAGE};
      color: ${p.SCORE};
      border: 1px solid ${edge};
      border-radius: 7px;
      min-height: 28px;
      min-width: 28px;
      margin: 4px 3px;
      padding: 2px 8px;
      box-shadow: ${drop};
      transition: background-color 120ms ease-out, border-color 120ms ease-out,
                  box-shadow 120ms ease-out;
  }

  button:hover {
      background-color: ${p.WING};
      border-color: ${thread};
      box-shadow: ${lift};
  }

  button:active {
      background-color: alpha(${p.ROOT}, 0.15);
      border-color: ${p.ROOT};
      box-shadow: inset 0 1px 3px rgba(${p.STAFF}, ${p.STAFF_A_HOVER});
  }

  button.circular {
      border-radius: 9999px;
  }

  button.suggested-action {
      background-color: ${p.ROOT};
      color: ${p.HALL};
  }

  button.destructive-action {
      background-color: ${p.FORTE};
      color: ${p.HALL};
  }

  /* Dialog headerbars and toasts keep libadwaita's flat buttons, not chips. */
  headerbar button,
  headerbar button:hover,
  headerbar button:active,
  toast button,
  toast button:hover,
  toast button:active {
      background-color: transparent;
      border-color: transparent;
      box-shadow: none;
      margin: 0;
  }

  headerbar button:hover,
  toast button:hover {
      background-color: alpha(${p.SCORE}, 0.1);
  }

  /* Header ------------------------------------------------------ */
  .ur-header {
      padding: 10px 12px 0 12px;
  }

  .ur-nameplate {
      font-size: 10px;
      letter-spacing: 0.24em;
      color: ${p.REST};
  }

  .ur-plate {
      padding: 6px 2px 10px 2px;
  }

  .ur-led {
      min-width: 9px;
      min-height: 9px;
      border-radius: 9999px;
      background-color: ${p.SCORE};
      box-shadow: 0 0 6px alpha(${p.SCORE}, 0.6);
  }

  .ur-plate.offline .ur-led {
      background-color: transparent;
      border: 1px solid ${p.REST};
      box-shadow: none;
  }

  .ur-name {
      font-size: 17px;
      letter-spacing: 0.04em;
  }

  .ur-plate.offline .ur-name {
      color: ${p.REST};
  }

  .ur-status {
      font-size: 12px;
      font-style: italic;
      color: ${p.REST};
  }

  /* Folder tabs: active tab is ROOT and its border runs into .ur-body. */
  .ur-tabs {
      margin-top: 2px;
  }

  button.ur-tab {
      margin: 0;
      min-height: 30px;
      padding: 4px 0;
      border-bottom-width: 0;
      border-radius: 7px 7px 0 0;
      background-color: ${p.STAGE};
      color: ${p.REST};
      letter-spacing: 0.12em;
      box-shadow: none;
  }

  button.ur-tab:hover {
      margin: 0;
      background-color: ${p.STAGE};
      box-shadow: none;
  }

  button.ur-tab:checked {
      background-color: ${p.ROOT};
      border-color: ${p.ROOT};
      color: ${p.HALL};
  }

  .ur-body {
      border-top: 1px solid ${p.ROOT};
      border-left: 1px solid ${keyline};
      border-right: 1px solid ${keyline};
  }

  toast {
      background-color: ${p.STAGE};
      color: ${p.SCORE};
      border: 1px solid ${keyline};
      border-radius: 7px;
  }

  /* Tablet mode (Type Cover detached): mirrors eww .ledger-bar.tablet .chip. */
  window.tablet .ur-header button,
  window.tablet .ur-body button {
      font-size: 19px;
      min-height: 56px;
      min-width: 56px;
      padding: 11px 24px;
      border-radius: 10px;
  }

  window.tablet .ur-header button.circular,
  window.tablet .ur-body button.circular {
      border-radius: 9999px;
  }

  window.tablet .ur-header button.ur-tab {
      min-height: 46px;
      padding: 8px 0;
      border-radius: 10px 10px 0 0;
  }

  window.tablet .ur-name {
      font-size: 21px;
  }

  window.tablet .ur-status {
      font-size: 14px;
  }
''

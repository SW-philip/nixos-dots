{ p, l }:
let
  # Bar font: palette TEMPO + 2px. Parsed here so the 13px light-theme
  # sentinel in the palettes stays intact.
  fontBar = "${toString (builtins.fromJSON (builtins.replaceStrings ["px"] [""] p.TEMPO) + 2)}px";

  # ── Flat kit — same recipe as home/niri/swaync/style.nix ────────────
  # Flat palette fill + one hairline + one soft drop. The house hard-offset
  # survives only under a container shell.
  # Every tint is an alpha over SCORE (light edge) or STAFF (shadow) so
  # palette swaps need no per-theme logic.
  keyline     = "alpha(${p.SCORE}, 0.15)";
  drop        = "0 2px 3px rgba(${p.STAFF}, ${p.STAFF_A_DROP})";
  # Hover "lift" — same STAFF drop, pushed further out (bigger offset +
  # blur) so a module reads as picking up off the bar rather than the
  # keycap-sinks-in physics used by swaync/lix-logout. Paired with a
  # matching margin shift so the chip visibly rises instead of just
  # growing its shadow in place.
  lift        = "0 4px 6px rgba(${p.STAFF}, ${p.STAFF_A_DROP})";
  # Text half of the same lift — small offset + soft blur, same STAFF alpha
  # as everything else. The module rises off a WING fill close in value to
  # its own STAGE rest, so flat text reads as faded there; this is the
  # minimum shadow that reads as "lifted text" without going hard-offset/
  # no-blur (the old cutout-style themes' 1px 2px 0 look).
  liftText    = "0 1px 2px rgba(${p.STAFF}, ${p.STAFF_A_DROP})";
  shellOffset = "3px 4px 0 0 rgba(${p.STAFF}, ${p.STAFF_A_DROP})";
  # SCORE keyline shared with swaync's .control-center / .notification border.
  thread      = "alpha(${p.SCORE}, 0.55)";

  # Faint fiber weave — shell grounds only now (it used to sit on every
  # module: invisible on dark themes, muddy on light ones). rect fill is
  # transparent so an unsupported filter degrades to nothing.
  fiber = ''url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='90' height='90'><filter id='paper'><feTurbulence type='fractalNoise' baseFrequency='0.75' numOctaves='2' result='noise'/><feColorMatrix type='matrix' values='0 0 0 0 0   0 0 0 0 0   0 0 0 0 0  0 0 0 0.06 0' in='noise' result='grain'/><feBlend mode='multiply' in='SourceGraphic' in2='grain'/></filter><rect width='100%25' height='100%25' filter='url(%23paper)' fill='transparent'/></svg>")'';
in
''
/* ============================================================
 * WAYBAR — flat restyle, shared vocabulary with swaync + sqlch-gui.
 * Flat palette fills, one SCORE hairline, one soft STAFF drop. The
 * house hard-offset lives only under a container shell (the top bar
 * as a screen-edge strip). No gradient, no text-shadow, no per-module
 * texture — fiber weave on shell grounds only. See
 * home/niri/swaync/style.nix for the same kit.
 * ============================================================ */

window#waybar {
  background-color: ${p.WING};
  background-image: ${fiber};
  background-repeat: repeat;
  font-family: "Josefin Sans", "Hack Nerd Font", "HackNerdFont", "JetBrainsMono Nerd Font", "JetBrains Mono", "Noto Sans Mono", monospace;
  font-size: ${fontBar};
  color: ${p.SCORE};
  box-shadow: ${shellOffset};
}

/* -----------------------------------------------------------------
   Generic module — flat chip: STAGE fill, SCORE hairline, one drop.
   Chip radius (7), not card radius — same as swaync keycaps / gui rows.
   ----------------------------------------------------------------- */
.module {
  background-color: ${p.STAGE};
  color: ${p.SCORE};
  font-weight: 700;
  padding: 4px 11px;
  /* GTK clips box-shadow rendering to the margin box, so the vertical
     margin must stay >= the drop's offset + spread or the shadow gets
     sliced at the edge — only the horizontal margin (chip-to-chip gap)
     was tightened here. */
  margin: 4px 3px;
  border: 1px solid ${keyline};
  border-radius: 7px;
  box-shadow: ${drop};
  transition: margin 120ms ease-out, box-shadow 120ms ease-out;
}

/* WING fill would equal the bar ground (hover erases the chip); brighten the
   hairline to thread instead — palette-proof, no fill change. Margin shift
   + deepened drop is the lift (see `lift` above); total margin box stays
   4+4=8px so neighbors don't reflow. */
.module:hover {
  background-color: ${p.WING};
  color: ${p.SCORE};
  border-color: ${thread};
  margin: 3px 3px 5px;
  box-shadow: ${lift};
  text-shadow: ${liftText};
}

/* -----------------------------------------------------------------
   Start button — the one accent element. Ink-on-accent, like
   sqlch-gui's active nav (the deliberate palette-rule exception).
   ----------------------------------------------------------------- */
#custom-start {
  color: ${p.HALL};
  background-color: ${p.ROOT};
  font-weight: 700;
  letter-spacing: 0.04em;
  padding: 4px 16px;
  margin: 4px 5px;
  border: 1px solid ${keyline};
  border-radius: 7px;
  box-shadow: ${drop};
  transition: margin 120ms ease-out, box-shadow 120ms ease-out;
}

/* LEDGER is not reliably brighter than ROOT (near-invisible on charcoal-cyan,
   a hue flip on some palettes); brighten the hairline instead. Same lift as
   .module:hover — margin box stays 4+4=8px. */
#custom-start:hover {
  border-color: ${thread};
  margin: 3px 5px 5px;
  box-shadow: ${lift};
  text-shadow: ${liftText};
}

/* -----------------------------------------------------------------
   Clock — always lit, it's the anchor.
   quantum_clock.py's modes swing from ~85px (moon, default) to ~500px
   (caliper's worst case). A min-width freeze sized to that max looked
   right on paper but was visibly wrong live — a mostly-empty ~500px
   box at rest. Fixed via placement instead (default.nix): clock+weather
   moved out of modules-center into modules-right, ahead of the stable
   modules, so their resize pushes against notification's fixed edge
   rather than recentering the whole cluster on the bar's midpoint.
   ----------------------------------------------------------------- */
#custom-clock { font-weight: 700; letter-spacing: 0.05em; color: ${p.SCORE}; }

/* -----------------------------------------------------------------
   Weather — bimodal, not just the resting "{icon} {temp}°F": clicking
   flips to a 3-day forecast summary (~450px). See #custom-clock above
   for why this isn't width-frozen either.
   ----------------------------------------------------------------- */
#custom-weather { color: ${p.REST}; }

/* -----------------------------------------------------------------
   Notification bell (swaync -swb) — dim at rest, accent when something
   is waiting, muted-slash when DND is on. Matches the volume module's
   rest/muted treatment.
   ----------------------------------------------------------------- */
#custom-notification                       { color: ${p.REST}; }
#custom-notification.notification          { color: ${p.ROOT}; }
#custom-notification.inhibited-notification { color: ${p.ROOT}; }
#custom-notification.dnd-none,
#custom-notification.dnd-notification,
#custom-notification.dnd-inhibited-none,
#custom-notification.dnd-inhibited-notification { color: ${p.BAR}; opacity: 0.55; }
#custom-notification:hover                 { color: ${p.SCORE}; }
#custom-notification.notification:hover,
#custom-notification.dnd-notification:hover { color: ${p.FORTE}; }

/* -----------------------------------------------------------------
   Battery — neutral at rest, state color on hover
   ----------------------------------------------------------------- */
#custom-battery                { color: ${p.REST}; }
#custom-battery.full:hover     { color: ${p.FIFTH}; }
#custom-battery.high:hover     { color: #7ab3c0; }
#custom-battery.medium:hover   { color: #a0d44e; }
#custom-battery.low:hover      { color: ${p.FERMATA}; }
#custom-battery.critical:hover { color: ${p.FORTE}; }

/* -----------------------------------------------------------------
   Volume — neutral at rest, thermal scale on hover
   ----------------------------------------------------------------- */
#custom-volume         { color: ${p.SCORE}; }
#custom-volume.muted   { color: ${p.BAR}; opacity: 0.55; }

#custom-volume.muted:hover,
#custom-volume.vol-0:hover   { color: ${p.BAR}; }
#custom-volume.vol-5:hover   { color: #6e9aa8; }
#custom-volume.vol-10:hover  { color: #7ab3c0; }
#custom-volume.vol-15:hover  { color: #8ac8d4; }
#custom-volume.vol-20:hover  { color: ${p.FIFTH}; }
#custom-volume.vol-25:hover  { color: ${p.FIFTH}; }
#custom-volume.vol-30:hover  { color: ${p.FIFTH}; }
#custom-volume.vol-35:hover  { color: #7ecba8; }
#custom-volume.vol-40:hover  { color: #6dc99a; }
#custom-volume.vol-45:hover  { color: #5ec88c; }
#custom-volume.vol-50:hover  { color: #72cc6a; }
#custom-volume.vol-55:hover  { color: #a0d44e; }
#custom-volume.vol-60:hover  { color: ${p.PIANO}; }
#custom-volume.vol-65:hover  { color: #ddd028; }
#custom-volume.vol-70:hover  { color: #f0c020; }
#custom-volume.vol-75:hover  { color: ${p.PIANO}; }
#custom-volume.vol-80:hover  { color: #d94f3a; }
#custom-volume.vol-85:hover  { color: #c0302a; }
#custom-volume.vol-90:hover  { color: #b82020; }
#custom-volume.vol-95:hover  { color: #e0306a; }
#custom-volume.vol-100:hover { color: ${p.FORTE}; }

/* -----------------------------------------------------------------
   sqlch radio — status tint at rest
   ----------------------------------------------------------------- */
#custom-sqlch              { color: ${p.ROOT}; min-width: 210px; }
#custom-sqlch.playing      { color: ${p.FIFTH}; }
#custom-sqlch.paused       { color: ${p.REST}; }
#custom-sqlch.idle         { color: ${p.BAR}; opacity: 0.6; }
#custom-sqlch.inactive     { color: ${p.BAR}; opacity: 0.55; }

/* -----------------------------------------------------------------
   Network — dim at rest, signal-strength color on hover
   ----------------------------------------------------------------- */
#custom-network                    { color: ${p.REST}; }
#custom-network.wifi.low:hover     { color: ${p.FERMATA}; }
#custom-network.wifi.mid:hover     { color: ${p.PIANO}; }
#custom-network.wifi.high:hover    { color: #7ab3c0; }
#custom-network.wifi.full:hover    { color: ${p.FIFTH}; }
#custom-network.wired:hover        { color: ${p.FIFTH}; }
#custom-network.vpn                { color: ${p.SCORE}; }
#custom-network.vpn:hover          { color: ${p.ROOT}; }
#custom-network.offline            { opacity: 0.45; }
#custom-network.offline:hover      { opacity: 0.7; color: ${p.BAR}; }

/* -----------------------------------------------------------------
   Fleet — dim when everything is in step, warn/bad colour otherwise
   ----------------------------------------------------------------- */
#custom-fleet                      { color: ${p.REST}; }
#custom-fleet.warn                 { color: ${p.FERMATA}; }
#custom-fleet.bad                  { color: ${p.FORTE}; }
#custom-fleet.stale                { color: ${p.REST}; opacity: 0.6; }
#custom-fleet.nosnap               { color: ${p.REST}; opacity: 0.45; }
#custom-sync                       { color: ${p.REST}; }
#custom-sync.warn                  { color: ${p.FERMATA}; }
#custom-sync.bad                   { color: ${p.FORTE}; }
#custom-sync.stale                 { color: ${p.REST}; opacity: 0.6; }
#custom-sync.nosnap                { color: ${p.REST}; opacity: 0.45; }

/* -----------------------------------------------------------------
   Bluetooth — dim at rest, state color on hover
   ----------------------------------------------------------------- */
#custom-bluetooth      { color: ${p.REST}; }
#custom-bluetooth.off  { opacity: 0.45; }
#custom-bluetooth:hover { color: ${p.SCORE}; }

/* -----------------------------------------------------------------
   KDE Connect — dim when offline/unpaired, state color on hover
   ----------------------------------------------------------------- */
#custom-kdeconnect                { color: ${p.REST}; }
#custom-kdeconnect.disconnected   { opacity: 0.45; }
#custom-kdeconnect.unpaired       { opacity: 0.45; }
#custom-kdeconnect:hover          { color: ${p.SCORE}; }

/* -----------------------------------------------------------------
   lix-logout (power menu) — dim at rest, FORTE on hover
   ----------------------------------------------------------------- */
#custom-lix-logout       { color: ${p.SCORE}; }
#custom-lix-logout:hover { color: ${p.FORTE}; }

/* -----------------------------------------------------------------
   Workspace label — a plain module (single label, no child buttons;
   clicking it cycles workspaces). Fixed min-width so it doesn't
   resize as names cycle.
   No hover rule: the ID selector outranks .module:hover — the label
   must not light up as the pointer crosses empty space.
   ----------------------------------------------------------------- */
#custom-niri-workspace {
  background-color: ${p.STAGE};
  color: ${p.SCORE};
  font-weight: 700;
  border: 1px solid ${keyline};
  border-radius: 7px;
  box-shadow: ${drop};
  margin: 4px 5px;
  padding: 4px 10px;
  /* 86px = glyph + space + "scratch" (the widest workspace name). */
  min-width: 86px;
}

#custom-niri-workspace.empty {
  /* Output has no active workspace (disconnected) — render nothing. */
  background: transparent;
  box-shadow: none;
  border: none;
  padding: 0;
  margin: 0;
  min-width: 0;
}

/* -----------------------------------------------------------------
   Tray
   ----------------------------------------------------------------- */
#tray > .passive          { -gtk-icon-effect: dim; }
#tray > .needs-attention  { -gtk-icon-effect: highlight; }

/* -----------------------------------------------------------------
   Tooltips
   ----------------------------------------------------------------- */
window.background.tooltip {
  background: ${p.STAGE};
  border-radius: 8px;
}

tooltip {
  background-color: ${p.STAGE};
  background-image: none;
  border: 1px solid ${keyline};
  border-radius: 8px;
  box-shadow: ${drop};
  padding: 4px 2px;
  margin: 0 3px 4px 0;
}

tooltip label {
  color: ${p.SCORE};
  font-family: "Josefin Sans", "JetBrainsMono Nerd Font", monospace;
  font-size: 15px;
  font-weight: 700;
  padding: 3px 10px;
}
''

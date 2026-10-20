# Guard for user units that only make sense inside a niri session. niri
# --session exports XDG_CURRENT_DESKTOP (not _SESSION) after graphical-session
# starts, so the condition alone is evaluated too early and silently skips the
# whole session unless the unit is also ordered After= and tied PartOf= it.
# Usage: Unit = config.lib.niri.unit { wayland = true; } { Description = "..."; };
# After = [...] adds ordering deps. wayland = true also requires WAYLAND_DISPLAY (units that talk to the compositor).
{ lib, ... }:
{
  # An After in attrs is appended to graphical-session.target, not a replacement.
  config.lib.niri.unit = { wayland ? false }: attrs: {
    PartOf = [ "graphical-session.target" ];
    ConditionEnvironment = lib.optional wayland "WAYLAND_DISPLAY" ++ [ "XDG_CURRENT_DESKTOP=niri" ];
  } // attrs // {
    After = [ "graphical-session.target" ] ++ (attrs.After or [ ]);
  };
}

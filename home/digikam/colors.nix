# digiKam color scheme — regenerated per-theme by drmis, deployed to
# ~/.local/share/digikam/colorschemes/drmis.colors. digiKam lists every scheme
# in that dir under Settings → Themes by its Name=, so the name stays fixed and
# picking "drmis" once follows every theme switch (on digiKam's next start).
# KDE scheme format; KConfig reads #rrggbb as well as r,g,b. Semantic roles
# match home/zed/theme.nix.
{ p }:
let
  roles = { bg, alt, fg ? p.SCORE }: ''
    BackgroundNormal=${bg}
    BackgroundAlternate=${alt}
    ForegroundNormal=${fg}
    ForegroundInactive=${p.REST}
    ForegroundActive=${p.ROOT}
    ForegroundLink=${p.ROOT}
    ForegroundVisited=${p.FIFTH}
    ForegroundNegative=${p.FORTE}
    ForegroundNeutral=${p.PIANO}
    ForegroundPositive=${p.SEVENTH}
    DecorationFocus=${p.LEDGER or p.ROOT}
    DecorationHover=${p.ROOT}
  '';
  window = roles { bg = p.STAGE; alt = p.DIM; };
in
''
  [General]
  Name=drmis

  [Colors:Window]
  ${window}
  [Colors:View]
  ${roles { bg = p.HALL; alt = p.DIM; }}
  [Colors:Button]
  ${roles { bg = p.WING; alt = p.STAGE; }}
  [Colors:Header]
  ${window}
  [Colors:Header][Inactive]
  ${window}
  [Colors:Selection]
  ${roles { bg = p.ROOT; alt = p.ROOT; fg = p.HALL; }}
  [Colors:Tooltip]
  ${roles { bg = p.WING; alt = p.STAGE; }}
  [WM]
  activeBackground=${p.STAGE}
  activeForeground=${p.SCORE}
  inactiveBackground=${p.HALL}
  inactiveForeground=${p.REST}
''

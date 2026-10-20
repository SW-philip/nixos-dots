# tuigreet's --theme string for one palette. Shared by drmis (live, per theme) and the
# greetd fallback used before drmis has written /run/tuigreet-theme.
p: builtins.concatStringsSep ";" [
  "background=${p.HALL}"
  "container=${p.STAGE}"
  "border=${p.ROOT}"
  "text=${p.SCORE}"
  "prompt=${p.FIFTH}"
  "time=${p.PIANO}"
  "action=${p.SOTTO}"
  "button=${p.FORTE}"
  "input=${p.SCORE}"
]

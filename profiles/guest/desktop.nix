# The guest on desktop: base (prepko's look and apps) without his personal
# layer (profiles/prepko/common.nix) or his desktop extras.
{ config, lib, ... }:
{
  imports = [ ../base.nix ../../home/pegasus ];

  # The ROM library is read-only to it; saves stay in its tmpfs home, never
  # the shared /srv/game-saves (which it can't open anyway, modules/guest.nix).
  emulation.saveDir = "${config.home.homeDirectory}/.local/share/retroarch/saves";

  myConfig.isDesktop = true;
  home.pointerCursor.size = lib.mkForce 24;

  myConfig.themes = [ "wfp" "the-work" "navy-teal" "indigo-rose" "midnight-rose" "olive-plum" ];

  # No password to protect. Mod+Escape's hyprlock still unlocks with Enter.
  myConfig.idleLock = false;
}

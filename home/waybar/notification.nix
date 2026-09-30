{ config, pkgs, lib, ... }:

let
  isDesktop = config.myConfig.isDesktop;
  swaync = "${pkgs.swaynotificationcenter}/bin/swaync-client";

  # Nix has no \u string escape; round-trip a codepoint through fromJSON.
  # fa-* range keeps the glyphs in the BMP (single \u). The bar font is
  # proportional Hack (heavy ink overhang), so the format string span-forces
  # the Mono variant around the glyph — see CLAUDE.md.
  glyph = cp: builtins.fromJSON ''"\u${cp}"'';

  mod = {
    format = "<span font_family='Hack Nerd Font Mono'>{icon}</span>";
    format-icons = {
      none                         = glyph "f0a2"; # bell-o     — quiet
      notification                 = glyph "f0f3"; # bell       — something waiting
      "dnd-none"                   = glyph "f1f7"; # bell-slash-o
      "dnd-notification"           = glyph "f1f6"; # bell-slash
      "inhibited-none"             = glyph "f0a2";
      "inhibited-notification"     = glyph "f0f3";
      "dnd-inhibited-none"         = glyph "f1f7";
      "dnd-inhibited-notification" = glyph "f1f6";
    };
    return-type = "json";
    # -swb streams on every notification / DND change; it does not poll.
    # waybar won't respawn a dead continuous exec (CLAUDE.md), and the
    # subscriber only drops if swaync.service itself restarts —
    # restart-interval is the safety net, exec-on-event=false keeps a click
    # from tearing the feed down.
    exec = "${swaync} -swb";
    exec-on-event = false;
    restart-interval = 3;
    escape = true;
    tooltip = true;
    on-click = "${config.myConfig.sidebarToggleScript}";
    on-click-right = "${swaync} -d -sw";
  };
in
{
  programs.waybar.settings = lib.mkMerge [
    (lib.mkIf isDesktop {
      leftBar."custom/notification"  = mod;
      rightBar."custom/notification" = mod;
      tvTopBar."custom/notification" = mod;
    })
    (lib.mkIf (!isDesktop) {
      surfaceTopBar."custom/notification" = mod;
    })
  ];
}

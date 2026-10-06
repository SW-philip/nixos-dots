{ config, pkgs, lib, ... }:

let
  cacheName = "stoic-quote";

  # Icon is emitted via jq escape sequence (U+EF0D = fa-scroll),
  # verified present in the installed Symbols Nerd Font Mono cmap via
  # fonttools/ttx against the real .ttf; rather than a literal pasted
  # glyph in this Nix file — Private Use Area characters do not reliably
  # survive being typed into source text.
  quoteScript = pkgs.writeShellScriptBin "waybar-stoic-quote" ''
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils ]}:$PATH"
    set -euo pipefail

    response=$(curl -sS --max-time 5 "https://www.stoic-quotes.com/api/quote")
    text=$(jq -er '.text' <<<"$response")
    author=$(jq -er '.author' <<<"$response")

    jq -nc \
      --arg text "$text" \
      --arg author "$author" \
      '{text: "\uef0d", tooltip: ("\"" + $text + "\"\n— " + $author), class: "quote"}'
  '';

  cacheTools = import ./cache-tools.nix { inherit pkgs; };
  cachePollScript = cacheTools.cachePoll;
  cacheReadScript = cacheTools.cacheRead;
in
{
  options.waybar.stoicQuote.enable = lib.mkEnableOption "Stoic quote module";

  # Poll-and-cache only -- the display surface is the eww ledger chip
  # (home/eww/eww.yuck's `stoic_quote` deflisten reads the same
  # ~/.cache/waybar/stoic-quote.json this poll writes), not a waybar bar
  # module.
  config = lib.mkIf config.waybar.stoicQuote.enable {
    home.packages = [ quoteScript cachePollScript cacheReadScript ];

    systemd.user.services."waybar-${cacheName}-poll" = {
      Unit = {
        Description = "Poll a fresh Stoic quote into cache for waybar";
        After = [ "network-online.target" "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${cachePollScript}/bin/waybar-cache-poll ${cacheName} ${quoteScript}/bin/waybar-stoic-quote";
      };
    };

    systemd.user.timers."waybar-${cacheName}-poll" = {
      Unit.Description = "Stoic quote poll timer";
      Timer = {
        OnStartupSec = "5s";
        OnUnitActiveSec = "60min";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
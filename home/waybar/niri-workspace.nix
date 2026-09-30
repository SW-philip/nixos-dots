{ config, pkgs, lib, ... }:

let
  isDesktop = config.myConfig.isDesktop;

  # Nix has no \u string escape; round-trip a codepoint through fromJSON.
  glyph = cp: builtins.fromJSON ''"\u${cp}"'';

  # fa-* Nerd Font glyphs. The runtime font (HackNerdFont, proportional) has
  # heavy ink overhang, so _render_line span-forces the Mono variant around the
  # glyph — overhang is not a factor here. Edit freely: this map is handed to
  # the script as JSON, so no shell change is needed to retheme.
  icons = {
    code     = glyph "f121";
    browse   = glyph "f0ac";
    media    = glyph "f001";
    scratch  = glyph "f0c3";
    office   = glyph "f0b1";
    fallback = glyph "f2d0";
  };

  scriptsDir = "${config.home.homeDirectory}/.config/waybar/scripts";

  # Git-tracked default; seeded once into $XDG_DATA_HOME below so lines can be
  # edited without a rebuild. `git add` this file before `nrs` — flakes only
  # see tracked files.
  #
  # NOT the same as `home/waybar/snark.json` (deployed read-only to
  # ~/.config/waybar/snark.json, consumed by battery.sh/netstatus.sh/etc. via
  # `jq -r … | shuf -n1`). This one is a writable copy the user hand-edits
  # live, and the per-workspace-tooltip pick is a deterministic codepoint-sum
  # hash, not `shuf`. Different file, path, mechanism, and selection on purpose.
  snarkDefault = ./niri-workspace-snark.json;
  snarkTarget  = "${config.xdg.dataHome}/waybar/niri-workspace-snark.json";

  wsBin = pkgs.writeShellScriptBin "waybar-niri-workspace" ''
    export PATH="${lib.makeBinPath [ pkgs.jq pkgs.coreutils pkgs.niri ]}:$PATH"
    export NIRI_WS_ICONS=${lib.escapeShellArg (builtins.toJSON icons)}
    export NIRI_WS_SNARK_FILE=${lib.escapeShellArg snarkTarget}
    exec ${pkgs.bash}/bin/bash "${scriptsDir}/niri-workspace.sh" "$@"
  '';

  mkModule = output: {
    exec             = "${wsBin}/bin/waybar-niri-workspace feed ${output}";
    return-type      = "json";
    # Clicks must not restart the feed process, and there is no interval —
    # the feed pushes updates itself. restart-interval respawns it if niri
    # (and thus the event-stream) restarts.
    exec-on-event    = false;
    restart-interval = 3;
    # A burst of discrete scroll events from a touchpad swipe would otherwise
    # cycle several workspaces per gesture (matches home/waybar/sqlch.nix).
    smooth-scrolling-threshold = 3;
    # Fixed footprint so the box doesn't resize as you cycle names. min-length
    # can't do it — the label carries Pango <span> markup, which inflates its
    # raw char count — so width is pinned via min-width in style.nix instead.
    justify          = "center";
    on-click         = "${wsBin}/bin/waybar-niri-workspace cycle ${output} next";
    on-click-right   = "${wsBin}/bin/waybar-niri-workspace cycle ${output} prev";
    on-scroll-up     = "${wsBin}/bin/waybar-niri-workspace cycle ${output} prev";
    on-scroll-down   = "${wsBin}/bin/waybar-niri-workspace cycle ${output} next";
    tooltip          = true;
  };
in
{
  home.packages = [ wsBin ];

  # Copy the default snark file into place only if the user has no copy yet, so
  # hand-edits are never clobbered. Delete the target + `nrs` to re-seed.
  home.activation.seedNiriWorkspaceSnark =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -e ${lib.escapeShellArg snarkTarget} ]; then
        run ${pkgs.coreutils}/bin/install -Dm644 \
          ${snarkDefault} ${lib.escapeShellArg snarkTarget}
      fi
    '';

  # The isDesktop gating is load-bearing, not cosmetic: an ungated
  # leftBar."custom/niri-workspace" makes settings.leftBar != {} on the surface,
  # which injects a phantom nameless bar past the `b != {}` filter in default.nix.
  programs.waybar.settings = lib.mkMerge [
    (lib.mkIf isDesktop {
      leftBar."custom/niri-workspace"  = mkModule "DP-1";
      rightBar."custom/niri-workspace" = mkModule "DP-2";
      tvTopBar."custom/niri-workspace" = mkModule "HDMI-A-1";
    })
    (lib.mkIf (!isDesktop) {
      surfaceTopBar."custom/niri-workspace" = mkModule "eDP-1";
    })
  ];
}

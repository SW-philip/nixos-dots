{ config, pkgs, lib, ... }:

let
  isDesktop = config.myConfig.isDesktop;
  scriptDir = "${config.home.homeDirectory}/.config/eww/scripts";
  connector = if isDesktop then "DP-2" else "eDP-1";
  scripts   = [ "context" "vitals" "storage" "boot" "snark"
                "purity" "net" "bt" "power" "mug" "myln" "launcher-favs" ];

  # tablet/osk feeds: inotify on the Type Cover state file and squeekboard's
  # D-Bus signals, instead of a bash loop forking every 1 s / 0.5 s.
  feedPython = pkgs.python3.withPackages (ps: [ ps.dbus-fast ps.inotify-simple ]);
  surfaceFeed = pkgs.writeShellScript "eww-surface-feed" ''
    exec ${feedPython}/bin/python3 ${./scripts/surface_feed.py} "$@"
  '';

  # Nix-baked defaults for the eww panel edge config -- only take effect the
  # first time a host boots this config, via the copy-iff-absent activation
  # block below. Once `eww-panel-edge` has been run once for a slot, its
  # state file is the source of truth and these defaults are never consulted
  # again for that slot, rebuild or not.
  #
  # Surface defaults to a left-docked wing: NiriBridge's cross-machine
  # pointer-capture boundary is also on the right edge of surface's screen
  # (home/niri-bridge's per-host config, edge = "right"), and the two
  # right-edge hover/capture zones fought each other.
  wingEdge     = if isDesktop then "right" else "left";
  wingEdgeTv   = "right";
  ledgerEdge   = "bottom";
  ledgerEdgeTv = "bottom";

  wingEdgeSeed     = pkgs.writeText "eww-panel-edge-wing-seed" wingEdge;
  wingEdgeTvSeed   = pkgs.writeText "eww-panel-edge-wing-tv-seed" wingEdgeTv;
  ledgerEdgeSeed   = pkgs.writeText "eww-panel-edge-ledger-seed" ledgerEdge;
  ledgerEdgeTvSeed = pkgs.writeText "eww-panel-edge-ledger-tv-seed" ledgerEdgeTv;

  panelEdgeBin = pkgs.writeShellScriptBin "eww-panel-edge" ''
    export PATH="${lib.makeBinPath [ pkgs.eww pkgs.coreutils ]}:$PATH"
    exec ${pkgs.bash}/bin/bash ${./scripts/panel-edge.sh} "$@"
  '';

  panelStepBin = pkgs.writeShellScriptBin "eww-panel-step" ''
    export PATH="${lib.makeBinPath [ pkgs.eww pkgs.coreutils pkgs.jq pkgs.niri ]}:$PATH"
    export EWW_PANEL_DEFAULT_SCREEN="${connector}"
    export EWW_PANEL_EDGE_BIN="${panelEdgeBin}/bin/eww-panel-edge"
    exec ${pkgs.bash}/bin/bash ${./scripts/panel-step.sh} "$@"
  '';

  # The stoic-quote cache is populated by home/waybar/stoic.nix's poll
  # timer (writes ~/.cache/waybar/stoic-quote.json); the ledger chip below
  # is just another reader of that same cache, same as waybar's custom
  # module used to be. Wrapped in its own script (rather than inlined as a
  # --replace-fail value) because the fallback JSON needs literal single
  # quotes around it, and two literal `''` back-to-back is Nix's own
  # ''-string escape trigger -- inlining it breaks the outer yuck
  # substitute script's Nix parse.
  quoteCacheRead = pkgs.writeShellScript "eww-quote-cache-read" ''
    exec ${(import ../waybar/cache-tools.nix { inherit pkgs; }).cacheRead}/bin/waybar-cache-read stoic-quote 4000 '{"text":"","tooltip":"","class":"unknown"}'
  '';

  nirScripts = import ../niri/scripts.nix { inherit pkgs lib; };
  sessionActionsForEww = import ../niri/session-actions.nix { inherit pkgs lib config; };

  # The yuck ships several literal placeholder tokens (SCRIPTS, :monitor N,
  # EWW, plus a handful of eww-daemon-specific command tokens below) —
  # --replace-fail is a global replace that fails the build if a token is
  # absent, so a rename can't ship unresolved.
  #
  # TABLET_FEED/OSK_FEED are idle `sleep infinity` on desktop (no Type Cover and
  # no squeekboard, so both stay at their initial false) and the event-driven
  # surface feed elsewhere.
  #
  # UNIREMOTE_TOGGLE/MOONLIGHT_TOGGLE substitute to an inert
  # `true` on desktop: the buttons that use them are `:visible {!is_desktop}`
  # (surface-only), but an unconditional substitution here would still pull
  # uniremote/moonlight-qt into desktop's closure via this derivation.
  yuck = pkgs.runCommand "eww.yuck" { } ''
    substitute ${./eww.yuck} $out \
      --replace-fail 'SCRIPTS' '${scriptDir}' \
      --replace-fail ':monitor 0' ':monitor "${connector}"' \
      --replace-fail ':monitor 1' ':monitor "HDMI-A-1"' \
      --replace-fail '(defvar is_desktop false)' '(defvar is_desktop ${lib.boolToString isDesktop})' \
      --replace-fail 'EWW' '${pkgs.eww}/bin/eww' \
      --replace-fail 'TABLET_FEED' '${if isDesktop then "sleep infinity" else "${surfaceFeed} tablet"}' \
      --replace-fail 'OSK_FEED' '${if isDesktop then "sleep infinity" else "${surfaceFeed} osk"}' \
      --replace-fail 'UNIREMOTE_TOGGLE' '${if isDesktop then "true" else sessionActionsForEww.uniremoteToggle}' \
      --replace-fail 'MOONLIGHT_TOGGLE' '${if isDesktop then "true" else sessionActionsForEww.moonlightToggle}' \
      --replace-fail 'LIX_LOGOUT_TOGGLE' '${pkgs.lix-logout}/bin/lix-logout-toggle' \
      --replace-fail 'NIRI_BIN' '${pkgs.niri}/bin/niri' \
      --replace-fail 'LAUNCHER_BIN' '${nirScripts.launcher}/bin/launcher' \
      --replace-fail 'QUOTE_CACHE_READ' '${quoteCacheRead}' \
      --replace-fail 'QUOTE_REFRESH' '${pkgs.systemd}/bin/systemctl --user start waybar-stoic-quote-poll.service'
  '';
in
{
  home.packages = [ pkgs.eww panelEdgeBin panelStepBin ];

  xdg.configFile = lib.mkMerge [
    { "eww/eww.yuck".source = yuck; }
    { "eww/eww.scss".source = ./eww.scss; }
    (lib.listToAttrs (map (s: {
      name = "eww/scripts/${s}.sh";
      value = { source = ./scripts/${s}.sh; executable = true; };
    }) scripts))
  ];

  # colors.scss and status-snark.json are seeded copy-iff-absent, not xdg-managed:
  # drmis (Task 7) rewrites the deployed colors.scss per theme via shutil.copy2,
  # which can't write through a read-only HM store symlink (same reason
  # home/niri/swaync doesn't xdg-manage style.css). eww.scss @imports colors,
  # so grass hard-errors and the panel renders unstyled if the baseline is missing.
  home.activation.ewwColorsSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _dst="${config.home.homeDirectory}/.config/eww/colors.scss"
    if [ ! -e "$_dst" ]; then
      $DRY_RUN_CMD mkdir -p "$(dirname "$_dst")"
      $DRY_RUN_CMD cp ${./colors.scss} "$_dst"
      $DRY_RUN_CMD chmod u+w "$_dst"
    fi
  '';

  home.activation.ewwSnarkSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _dst="${config.home.homeDirectory}/.local/share/eww/status-snark.json"
    if [ ! -e "$_dst" ]; then
      $DRY_RUN_CMD mkdir -p "$(dirname "$_dst")"
      $DRY_RUN_CMD cp ${./status-snark.json} "$_dst"
      $DRY_RUN_CMD chmod u+w "$_dst"
    fi
  '';

  home.activation.ewwLauncherFavsSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _dst="${config.home.homeDirectory}/.local/share/eww/launcher-favs.json"
    if [ ! -e "$_dst" ]; then
      $DRY_RUN_CMD mkdir -p "$(dirname "$_dst")"
      $DRY_RUN_CMD cp ${./launcher-favs.json} "$_dst"
      $DRY_RUN_CMD chmod u+w "$_dst"
    fi
  '';

  home.activation.ewwPanelEdgeSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _state="${config.home.homeDirectory}/.local/state"
    $DRY_RUN_CMD mkdir -p "$_state"
    if [ ! -e "$_state/eww-panel-edge-wing" ]; then
      $DRY_RUN_CMD cp ${wingEdgeSeed} "$_state/eww-panel-edge-wing"
      $DRY_RUN_CMD chmod u+w "$_state/eww-panel-edge-wing"
    fi
    if [ ! -e "$_state/eww-panel-edge-wing-tv" ]; then
      $DRY_RUN_CMD cp ${wingEdgeTvSeed} "$_state/eww-panel-edge-wing-tv"
      $DRY_RUN_CMD chmod u+w "$_state/eww-panel-edge-wing-tv"
    fi
    if [ ! -e "$_state/eww-panel-edge-ledger" ]; then
      $DRY_RUN_CMD cp ${ledgerEdgeSeed} "$_state/eww-panel-edge-ledger"
      $DRY_RUN_CMD chmod u+w "$_state/eww-panel-edge-ledger"
    fi
    if [ ! -e "$_state/eww-panel-edge-ledger-tv" ]; then
      $DRY_RUN_CMD cp ${ledgerEdgeTvSeed} "$_state/eww-panel-edge-ledger-tv"
      $DRY_RUN_CMD chmod u+w "$_state/eww-panel-edge-ledger-tv"
    fi
  '';

  systemd.user.services.eww = {
    Unit = {
      Description = "eww status window daemon";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
      # nrs that only edits the yuck/scss must actually restart the daemon —
      # the stats sidebar is gone (Phase C), so there is no fallback panel.
      X-Restart-Triggers = [ "${yuck}" "${./eww.scss}" ];
    };
    Service = {
      ExecStart = "${pkgs.eww}/bin/eww daemon --no-daemonize";
      # The window must be open at daemon start: the revealer inside it (not
      # `eww open`) does the show/hide. Poll for the control socket first —
      # ExecStartPost races the daemon's socket bind and a failed open here
      # exits 0, so Restart=on-failure won't catch it.
      ExecStartPost = pkgs.writeShellScript "eww-open" ''
        for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
          ${pkgs.eww}/bin/eww ping >/dev/null 2>&1 && break
          ${pkgs.coreutils}/bin/sleep 0.1
        done

        # Opens the window matching this slot's state file, falling back to
        # $3 (the Nix default) if the file is missing or its content isn't
        # one of $4's legal values (hand-edited, corrupted, etc).
        open_slot() {
          local slot="$1" prefix="$2" default="$3" valid="$4"
          local state_file="$HOME/.local/state/eww-panel-edge-$slot"
          local edge
          edge="$(cat "$state_file" 2>/dev/null || true)"
          case " $valid " in
            *" $edge "*) ;;
            *) edge="$default" ;;
          esac
          ${pkgs.eww}/bin/eww open "$prefix-$edge" || true
        }

        open_slot wing status "${wingEdge}" "left right"
        ${lib.optionalString isDesktop ''open_slot wing-tv status-tv "${wingEdgeTv}" "left right"''}
        open_slot ledger ledger "${ledgerEdge}" "top bottom"
        ${lib.optionalString isDesktop ''open_slot ledger-tv ledger-tv "${ledgerEdgeTv}" "top bottom"''}
      '';
      ExecReload = "${pkgs.eww}/bin/eww reload";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}

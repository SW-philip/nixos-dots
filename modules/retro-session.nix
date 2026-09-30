{ config, lib, pkgs, ... }:
let
  cfg = config.services.retroSession;

  # NVIDIA multi-head dual-monitor atomic DRM commits time out (~40s per
  # connector) — same issue documented for the greeter in modules/greetd.nix.
  # Legacy modesetting avoids the stall but has looser vsync/page-flip
  # timing than atomic, which is visible as a uniform slight slowdown in
  # RetroArch cores. Only worth paying for when 2+ monitors are actually
  # attached; re-enable (or drop the override) the moment that's true again.
  retroLaunch = pkgs.writeShellScript "retro-session-launch" ''
    ${lib.optionalString cfg.legacyModesetting "export WLR_DRM_NO_ATOMIC=1"}
    exec ${pkgs.cage}/bin/cage -s -- ${pkgs.pegasus-frontend}/bin/pegasus-fe
  '';

  # cage is a full wlroots compositor; it just exits when the process it
  # was launched with (pegasus-fe) exits, not when every window closes —
  # so when Pegasus execs an emulator, the emulator's window displays
  # normally and focus returns to Pegasus when the emulator quits.
  retroSessionEntry = pkgs.runCommand "retro-session" {
    passthru.providedSessions = [ "retro" ];
  } ''
    mkdir -p $out/share/wayland-sessions
    cat > $out/share/wayland-sessions/retro.desktop <<EOF
    [Desktop Entry]
    Name=Retro
    Comment=Pegasus Frontend emulation kiosk
    Exec=${retroLaunch}
    Type=Application
    DesktopNames=retro
    EOF
  '';

  # cage has no keybind layer at all (unlike niri, which handles
  # XF86Audio*/F4-F6 itself), so hardware volume keys are silently dropped
  # inside the retro session. actkbd catches keys at the evdev level,
  # outside any compositor, but it's a system-wide daemon — it fires
  # regardless of which user is logged in. Gate on the active seat's user
  # so this only acts during the retro session; otherwise niri's own
  # volume keybinds already handle it, and we'd double-step the volume.
  retroVolumeKey = pkgs.writeShellScript "retro-volume-key" ''
    set -euo pipefail
    action="$1"

    session_id=$(${pkgs.systemd}/bin/loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null || true)
    [ -z "$session_id" ] && exit 0
    user=$(${pkgs.systemd}/bin/loginctl show-session "$session_id" -p Name --value 2>/dev/null || true)
    [ "$user" != "retro" ] && exit 0

    uid=$(${pkgs.coreutils}/bin/id -u retro)
    wpctl="${pkgs.wireplumber}/bin/wpctl"

    case "$action" in
      up)   ${pkgs.util-linux}/bin/runuser -u retro -- ${pkgs.coreutils}/bin/env XDG_RUNTIME_DIR="/run/user/$uid" "$wpctl" set-volume @DEFAULT_AUDIO_SINK@ 5%+ ;;
      down) ${pkgs.util-linux}/bin/runuser -u retro -- ${pkgs.coreutils}/bin/env XDG_RUNTIME_DIR="/run/user/$uid" "$wpctl" set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
      mute) ${pkgs.util-linux}/bin/runuser -u retro -- ${pkgs.coreutils}/bin/env XDG_RUNTIME_DIR="/run/user/$uid" "$wpctl" set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
    esac
  '';
in
{
  options.services.retroSession.legacyModesetting = lib.mkOption {
    type        = lib.types.bool;
    default     = true;
    description = "Force WLR_DRM_NO_ATOMIC=1 for the retro session's cage compositor. Needed on NVIDIA with 2+ monitors attached to avoid an atomic DRM commit timeout at login; costs vsync/frame-pacing precision, so disable when only one display is connected.";
  };

  config = {
  services.displayManager.sessionPackages = [ retroSessionEntry ];

  # Keycodes: KEY_VOLUMEUP=115, KEY_VOLUMEDOWN=114, KEY_MUTE=113
  # (linux/input-event-codes.h).
  services.actkbd = {
    enable = true;
    bindings = [
      { keys = [ 115 ]; events = [ "key" "rep" ]; command = "${retroVolumeKey} up"; }
      { keys = [ 114 ]; events = [ "key" "rep" ]; command = "${retroVolumeKey} down"; }
      { keys = [ 113 ]; events = [ "key" ]; command = "${retroVolumeKey} mute"; }
    ];
  };
  };
}

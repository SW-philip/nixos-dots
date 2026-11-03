{ pkgs, ... }:
let
  retroLaunch = pkgs.writeShellScript "retro-session-launch" ''
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
in
{
  services.displayManager.sessionPackages = [ retroSessionEntry ];
}

# Moonlight connect/disconnect toggle for the swaync menubar#session row
# (home/niri/default.nix). Extracted from the former home/waybar/{wayvnc,
# moonlight}.nix waybar modules — only the toggle action survives; the
# JSON status path was for the waybar module and has no consumer now.
{ pkgs, lib, config }:

let
  user = config.home.username;

  # Desktop's Tailscale IPv4 (modules/tailscale.nix). Not the `desktop`
  # MagicDNS name: that also resolves to a Tailscale IPv6 which wlvncc may
  # try first, but wayvnc listens v4-only and the cert's IP SAN is v4-only.
  desktopHost = "100.64.0.1";
in
{
  # uniremote is a windowed GUI, not a daemon — a bare relaunch just stacks
  # another window. Match its niri window by app-id and kill that, else launch.
  # `status` shares the same app-id predicate so "on" has one definition.
  uniremoteToggle = pkgs.writeShellScript "uniremote-toggle" ''
    if [ "''${1:-}" = status ]; then
      ${pkgs.niri}/bin/niri msg --json windows 2>/dev/null \
        | ${pkgs.jq}/bin/jq -e 'any(.[]; .app_id == "com.prepko.uniremote" and .pid != null)' >/dev/null 2>&1 \
        && echo true || echo false
      exit 0
    fi
    pid=$(${pkgs.niri}/bin/niri msg --json windows 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r 'first(.[] | select(.app_id == "com.prepko.uniremote") | .pid) // empty')
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    else
      ${pkgs.util-linux}/bin/setsid -f ${pkgs.uniremote}/bin/uniremote >/dev/null 2>&1
    fi
  '';

  moonlightToggle = pkgs.writeShellScript "moonlight-toggle" ''
    if [ "''${1:-}" = status ]; then
      ${pkgs.procps}/bin/pgrep -x moonlight >/dev/null && echo true || echo false
      exit 0
    fi
    if ${pkgs.procps}/bin/pgrep -x moonlight >/dev/null; then
      ${pkgs.moonlight-qt}/bin/moonlight quit ${desktopHost} >/dev/null 2>&1
    else
      ${pkgs.util-linux}/bin/setsid -f \
        ${pkgs.moonlight-qt}/bin/moonlight stream ${desktopHost} Desktop \
        --display-mode fullscreen >/dev/null 2>&1
    fi
  '';
}

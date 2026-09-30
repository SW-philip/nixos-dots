{ pkgs, ... }:
{
  # Streaming client only -- emulation itself stays on desktop
  # (modules/sunshine.nix). The swaync toggle (home/niri/session-actions.nix)
  # drives this by full store path, so this package entry is just for having
  # `moonlight` on PATH for manual use (pairing, `moonlight list`, ...).
  home.packages = [ pkgs.moonlight-qt ];
}

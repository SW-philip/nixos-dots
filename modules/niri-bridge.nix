{ config, ... }:
{
  # /dev/uinput is only uaccess-tagged for the seat-*active* session by
  # default. niri-bridge.service runs as a graphical-session.target user
  # service, same as Sunshine (modules/sunshine.nix) -- and hits the exact
  # same gap. A static group grant sidesteps the seat-active requirement
  # entirely, same fix as Sunshine's.
  hardware.uinput.enable = true;
  users.users.${config.myConfig.user}.extraGroups = [ "uinput" ];
}

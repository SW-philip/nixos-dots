# niri-session calls bare `systemctl --user import-environment` (import-all),
# which systemd 258 deprecates. Patch to an explicit list — but ONLY of vars
# greetd/PAM actually set this early. Naming a var that's unset here prints
# "Environment variable $X not set, ignoring" onto the login VT. Three were
# unset at greetd→session time and were the visible login-screen errors:
# DISPLAY + WAYLAND_DISPLAY (niri hasn't created the displays yet; `niri
# --session` imports those itself once the socket exists) and
# XDG_SESSION_CLASS (greetd never sets it). So they're excluded here.
# drop when: niri-session stops using import-all (or systemd stops warning).
{ ... }:
final: prev: {
  niri = prev.niri.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      substituteInPlace $out/bin/niri-session \
        --replace-fail \
          "systemctl --user import-environment" \
          "systemctl --user import-environment PATH HOME USER LOGNAME SHELL XDG_RUNTIME_DIR XDG_SESSION_ID XDG_SESSION_TYPE XDG_SEAT XDG_VTNR DBUS_SESSION_BUS_ADDRESS"
    '';
  });
}

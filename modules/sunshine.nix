{ pkgs, ... }:
{
  # /dev/uinput on this host is only uaccess-tagged by Steam's udev rules
  # (steam-devices-udev-rules, pulled in via programs.steam.enable) -- that
  # grants rw solely to whoever logind currently considers the *active*
  # seat0 session. Fine while physically logged into niri, but sunshine
  # runs as prepko's user service (graphical-session.target below) and
  # streaming to it from elsewhere never makes prepko seat-active, so
  # virtual keyboard/mouse creation hits Permission denied even though
  # KMS video capture (capSysAdmin, session-independent) keeps working.
  # A static group grant sidesteps the seat-active requirement entirely.
  hardware.uinput.enable = true;
  users.users.prepko.extraGroups = [ "uinput" ];

  services.sunshine = {
    enable = true;
    autoStart = true;
    # tailscale0 is a trustedInterface (modules/tailscale.nix, same model as
    # every other remote service here) -- no LAN/WAN ports needed.
    openFirewall = false;

    # niri's portal config (home/niri/default.nix's niri-portals.conf) never
    # routes org.freedesktop.impl.portal.ScreenCast anywhere niri-aware -- it
    # falls through to the `gtk` default, and xdg-desktop-portal-gtk doesn't
    # implement ScreenCast at all. KMS/DRM capture sidesteps the portal
    # entirely, so start here instead of a capture path that's untested (and
    # per current config, unrouted) under this niri build.
    capSysAdmin = true;

    # Sunshine's CSRF check only allow-lists localhost variants by default --
    # pairing/settings POSTs from the web UI fail with "CSRF Protection
    # Error" when reached at any other origin, including the Tailscale IP
    # clients actually use.
    settings = {
      csrf_allowed_origins = "https://100.64.0.1:47990";

      # Sunshine >=2026.914 tries the xdg-desktop-portal capture path first.
      # Under niri the only ScreenCast backend is portal-gnome, which has no
      # RemoteDesktop impl, so init hangs in verify_portal instead of falling
      # back -- unit "active" but nothing ever binds 47984/47989/47990/48010.
      capture = "kms";
    };

    applications.apps = [
      {
        # The same Pegasus build already indexing every system (including
        # ps3/gamecube-wii, home/emulation/default.nix) -- launched fresh
        # inside prepko's niri session, same as running it interactively.
        name = "Pegasus";
        cmd = "${pkgs.pegasus-frontend}/bin/pegasus-fe";
        auto-detach = "true";
      }
      {
        # No launch command: streams the running niri session as-is, for
        # anything outside Pegasus's library.
        name = "Desktop";
      }
    ];
  };
}

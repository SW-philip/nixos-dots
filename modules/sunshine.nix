{ config, lib, pkgs, ... }:
let
  artDir = "/home/prepko/.local/share/retro-tiles/art";
  tileSystems = builtins.filter (s: s.tile or false)
    (import ../hosts/retro-systems.nix { inherit pkgs; });
  # KMS capture grabs the first enabled output and floods "Couldn't get drm
  # fb for plane" (frozen video) when that output is switched off mid-stream.
  # Dropping to DP-2 alone *before* capture starts, and back after, makes DP-2
  # the captured monitor and keeps the mode from changing under it.
  kanshictl = "${pkgs.kanshi}/bin/kanshictl";
  soloWhileStreaming = [{
    do = "${kanshictl} switch desktop-stream";
    undo = "${kanshictl} switch desktop-dual";
  }];
in
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
  users.users.prepko.extraGroups = [ "uinput" "uhid" ];
  # Sunshine presents a DualSense client as a virtual PS5 pad via /dev/uhid,
  # root-only by default, so it fell back to an Xbox pad. Group grant, not
  # uaccess, for the same seat-active reason as uinput above.
  users.groups.uhid = { };
  # Without the module loaded at boot, /dev/uhid is only kmod's static root-only
  # node (udev has no device for it, so the group rule below never applies);
  # loading it creates the real node and the rule takes effect.
  boot.kernelModules = [ "uhid" ];
  services.udev.extraRules = ''
    KERNEL=="uhid", SUBSYSTEM=="misc", GROUP="uhid", MODE="0660"
  '';

  # KMS capture can't initialise while the outputs are in DPMS off (the idle
  # blank): Sunshine then drops its CAP_SYS_ADMIN and every encoder fails with
  # "Failed to gain CAP_SYS_ADMIN". Wake them before each (re)start.
  systemd.user.services.sunshine.serviceConfig.ExecStartPre = [
    "-${config.programs.niri.package}/bin/niri msg action power-on-monitors"
    "${pkgs.coreutils}/bin/sleep 3"
  ];

  # The ExecStartPre above only covers (re)starts. hypridle's DPMS-off blank
  # leaves KMS with no outputs on a later Moonlight connect ("Couldn't find
  # monitor [0]", frozen client), and a stream resumed onto a detached app
  # runs no prep-cmd. Wake on the first line Sunshine logs for every
  # launch/resume, which lands ~400ms before capture initialises.
  systemd.user.services.sunshine-wake = {
    description = "Wake monitors when a Moonlight client launches or resumes";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
      ExecStart = pkgs.writeShellScript "sunshine-wake" ''
        ${pkgs.systemd}/bin/journalctl --user -u sunshine -f -n0 -o cat |
          while read -r line; do
            case "$line" in
              *"Reverting any active display device configuration"*)
                ${config.programs.niri.package}/bin/niri msg action power-on-monitors || true ;;
            esac
          done
      '';
    };
  };

  services.sunshine = {
    enable = true;
    autoStart = true;
    # Without CUDA, Sunshine can't open NVENC on this NVIDIA box (KMS capture
    # hands frames to NVENC via CUDA), so it falls back to hevc_vulkan, which
    # was giving wrong colours.
    package = pkgs.sunshine.override { cudaSupport = true; };
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
  };

  # The nixpkgs wrapper only grants cap_sys_admin, so Sunshine's "EGL context
  # priority HIGH" request fails (CAP_SYS_NICE missing) and its NVENC/EGL work
  # queues behind the game on the same GPU, starving the stream. Add it.
  security.wrappers.sunshine.capabilities = lib.mkForce "cap_sys_admin,cap_sys_nice+p";

  services.sunshine = {
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

      # Present a DualShock 4, not the auto-picked DualSense: SDL names the DS4
      # "PS4 Controller", which is what the rpcs3/dolphin bindings (and every
      # real pad here) are written against; a virtual DualSense is "PS5 Controller"
      # and leaves rpcs3 saying "not detected".
      gamepad = "ds4";
    };

    applications.apps = [
      {
        # The same Pegasus build already indexing every system (including
        # ps3/gamecube-wii, home/emulation/default.nix) -- launched fresh
        # inside prepko's niri session, same as running it interactively.
        name = "Pegasus";
        cmd = "${pkgs.pegasus-frontend}/bin/pegasus-fe";
        image-path = "${artDir}/pegasus.png";
        auto-detach = "true";
        prep-cmd = soloWhileStreaming;
      }
      {
        # No launch command: streams the running niri session as-is, for
        # anything outside Pegasus's library.
        name = "Desktop";
        image-path = "${artDir}/desktop.png";
        prep-cmd = soloWhileStreaming;
      }
    ] ++ map (s: {
      name = "Pegasus - ${s.collection}";
      cmd = "${config.retroTiles.launcher}/bin/retro-pegasus ${s.dir}";
      image-path = "${artDir}/${s.dir}.png";
      auto-detach = "true";
      prep-cmd = soloWhileStreaming;
    }) tileSystems;
  };
}

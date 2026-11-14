{ pkgs, lib, config, ... }:
let
  # Guards the 18-min idle session-quit: media playback (or any other
  # process on the blacklist below) alone doesn't reset hypridle's idle
  # timer (only input activity does), so without this the quit would fire
  # once and kill music/video/a claude session/a rebuild along with the
  # session. Polls while still locked + busy; bails without quitting if the
  # user unlocks first, and quits once nothing on the list is still running.
  # Blacklist patterns are `pgrep -f` regexes, checked across all users'
  # processes (a `nrs`/nixos-rebuild runs as root under sudo) — add a
  # pattern here for anything else that shouldn't be interrupted by a
  # logout while the screen happens to be locked.
  hypridleQuitBlacklist = [
    "nixos-rebuild"    # nrs / nh os switch / manual nixos-rebuild
    "/bin/nh os"        # nh itself, before it shells out to nixos-rebuild
    "claude"           # claude code CLI session (also matches its own child shells)
  ];
  hypridleQuitGuard = pkgs.writeShellScript "hypridle-quit-guard" ''
    export PATH="${lib.makeBinPath [ pkgs.playerctl pkgs.procps ]}:$PATH"

    is_busy() {
      playerctl -a status 2>/dev/null | grep -q Playing && return 0
      ${lib.concatMapStringsSep "\n      " (pat: ''pgrep -f ${lib.escapeShellArg pat} >/dev/null 2>&1 && return 0'') hypridleQuitBlacklist}
      return 1
    }

    while pidof hyprlock >/dev/null 2>&1 && is_busy; do
      sleep 60
    done
    pidof hyprlock >/dev/null 2>&1 && niri msg action quit -s
  '';

  # Desktop's DP monitors have no /sys/class/backlight node, so brightnessctl
  # can't dim them; DDC/CI (VCP 0x10) can. Bus numbers shift between boots,
  # and NVIDIA exposes no sysfs ddc node, so resolve them via ddcutil detect.
  ddcDim = pkgs.writeShellScript "ddc-dim" ''
    state="''${XDG_RUNTIME_DIR:-/run/user/$UID}/ddc-brightness"
    mkdir -p "$state"
    for bus in $(${pkgs.ddcutil}/bin/ddcutil detect --brief 2>/dev/null \
        | awk '/I2C bus:/{b=$3; sub(".*i2c-","",b)} /DRM connector:.*-DP-[12]$/{print b}'); do
      case "$1" in
        dim)
          ${pkgs.ddcutil}/bin/ddcutil --bus "$bus" getvcp 10 --brief 2>/dev/null \
            | awk '{print $4}' > "$state/$bus"
          ${pkgs.ddcutil}/bin/ddcutil --bus "$bus" setvcp 10 10 ;;
        restore)
          [ -s "$state/$bus" ] && ${pkgs.ddcutil}/bin/ddcutil --bus "$bus" setvcp 10 "$(cat "$state/$bus")" ;;
      esac
    done
    true
  '';
in
{
  programs.hyprlock.enable = true;

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || ${config.myConfig.lockScreenScript}";
        unlock_cmd = "niri msg action do-screen-transition";
        before_sleep_cmd = if config.myConfig.idleLock then "loginctl lock-session" else "";
        after_sleep_cmd = "";
        ignore_dbus_inhibit = false;
      };
      listener = [
        {
          timeout = 240;
          on-timeout = if config.myConfig.hasBacklight then "${pkgs.brightnessctl}/bin/brightnessctl -s s 10%" else "${ddcDim} dim";
          on-resume = if config.myConfig.hasBacklight then "${pkgs.brightnessctl}/bin/brightnessctl -r" else "${ddcDim} restore";
        }
      ] ++ lib.optional config.myConfig.idleLock {
        timeout = if config.myConfig.isDesktop then 600 else 480;
        on-timeout = "pidof hyprlock || ${config.myConfig.lockScreenScript}";
      } ++ lib.optionals (!config.myConfig.isDesktop) [
        {
          timeout = 600;
          on-timeout = "niri msg action power-off-monitors 2>/dev/null; true";
          on-resume = "niri msg action power-on-monitors 2>/dev/null; true";
        }
      ] ++ lib.optional (!config.myConfig.isDesktop) {
        # 10 min after the 8-min lock: end the niri session, dropping back to
        # the greeter. No on-resume — there's nothing to come back to.
        # Guarded so it won't kill a playing music/video session (see
        # hypridleQuitGuard above). Desktop is excluded: greetd auto-logs
        # prepko straight back into niri (initial_session in
        # hosts/desktop/config.nix), so dropping to the greeter there just
        # forces a re-login (and a keyring re-unlock) for no security
        # benefit — desktop locks on idle (10 min) but never logs out.
        timeout = 1080;
        on-timeout = "${hypridleQuitGuard}";
      };
    };
  };
}

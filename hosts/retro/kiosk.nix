{ pkgs, lib, ... }:
let
  p = import ../../themes/Custom/slate-lavender/palette-slate-lavender.nix;
  # Moonlight hard-codes the page background and only centres a grid that
  # overflows one row; --replace-fail makes a version bump that moves these
  # strings break the build.
  moonlight = pkgs.moonlight-qt.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace app/gui/main.qml \
        --replace-fail 'Material.background = "#303030"' 'Material.background = "${p.HALL}"'

      substituteInPlace app/gui/CenteredGridView.qml \
        --replace-fail 'itemsPerRow < count && availableWidth >= cellWidth ?' \
                       'availableWidth >= cellWidth ?' \
        --replace-fail '(availableWidth % cellWidth) / 2 : minMargin' \
                       'minMargin + Math.floor((availableWidth - Math.min(itemsPerRow, count) * cellWidth) / 2) : minMargin' \
        --replace-fail '    function updateMargins() {' \
                       '    // Callers set topMargin as a constant; capture it once (not a binding,
              // or it would chase our own writes) so centring never goes below it.
              property real baseTopMargin: -1
              property real verticalMargin: Math.max(baseTopMargin,
                  (parent.height - Math.ceil(count / Math.max(itemsPerRow, 1)) * cellHeight) / 2)

              onVerticalMarginChanged: {
                  updateMargins()
              }

              function updateMargins() {
                  if (baseTopMargin < 0) {
                      baseTopMargin = topMargin
                  }
                  topMargin = verticalMargin'

      substituteInPlace app/gui/PcView.qml \
        --replace-fail '        onPressAndHold: {' \
                       '        // With a single paired host the host screen is redundant. Firing on
              // the false-to-true edge (not on state) keeps Back from re-opening it.
              property bool autoOpenReady: model.online && model.paired && model.serverSupported && pcGrid.count === 1

              onAutoOpenReadyChanged: {
                  if (autoOpenReady && stackView.depth <= 1) {
                      clicked()
                  }
              }

              Component.onCompleted: {
                  if (autoOpenReady && stackView.depth <= 1) {
                      clicked()
                  }
              }

              onPressAndHold: {'

      substituteInPlace app/gui/AppView.qml \
        --replace-fail 'cellWidth: 230; cellHeight: 297;' 'cellWidth: 310; cellHeight: 193;' \
        --replace-fail 'width: 220; height: 287;' 'width: 300; height: 183;' \
        --replace-fail 'width = 200' 'width = 290' \
        --replace-fail 'height = 267' 'height = 163' \
        --replace-fail 'Material.background: "#D0808080"' \
                       'Material.background: "#D0${lib.removePrefix "#" p.WING}"'

      substituteInPlace app/gui/AutoResizingComboBox.qml \
        --replace-fail 'popup.background.color = "#424242"' \
                       'popup.background.color = "${p.STAGE}"'

      substituteInPlace app/gui/NavigableItemDelegate.qml \
        --replace-fail '    highlighted: grid.activeFocus && grid.currentItem === this' \
                       '    id: navDelegate
          highlighted: grid.activeFocus && grid.currentItem === this

          background: Rectangle {
              color: navDelegate.highlighted ? "#55${lib.removePrefix "#" p.ROOT}" : "transparent"
          }'
    '';
  });
  stream = pkgs.writeShellApplication {
    name = "retro-stream";
    runtimeInputs = [ moonlight pkgs.coreutils pkgs.systemd ];
    text = ''
      # systemd only signals cage's MainPID (the client runs in a logind session
      # scope) and cage waits for its client before removing its socket. Moonlight
      # keeps running through a stop while streaming, so poll the unit state while
      # it runs and kill it once the unit starts deactivating, or every stop hangs
      # until TimeoutStopSec SIGKILLs cage.
      stopping() { [ "$(systemctl is-active cage-tty1)" = deactivating ]; }
      # The desktop host (Tailscale 100.64.0.1, Sunshine closed on the LAN) is
      # stored in Moonlight's own config, not here.
      # Moonlight caches Sunshine's box art per app on disk and never refreshes
      # it; the desktop regenerates tile art, so drop the cache on every start.
      rm -rf "$HOME/.cache/Moonlight Game Streaming Project/Moonlight/boxart"
      while ! stopping; do
        moonlight &
        mpid=$!
        while kill -0 "$mpid" 2>/dev/null && ! stopping; do sleep 1; done
        kill "$mpid" 2>/dev/null || true
        wait "$mpid" || true
        if stopping; then break; fi
        sleep 2
      done
    '';
  };
in
{
  services.cage = {
    enable = true;
    user = "retro";
    program = lib.getExe stream;
    environment = {
      LIBVA_DRIVER_NAME = "iHD";
      QT_QPA_PLATFORM = "wayland";
      # cage has no server-side decorations, so Qt would draw a gray title bar.
      QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
      # The picker is read from a couch on a 4K TV: cage runs at the panel's
      # native 3840x2160, so 960 logical px wide: three 310px landscape cells per row.
      QT_SCALE_FACTOR = "4";
      QT_QUICK_CONTROLS_MATERIAL_THEME = "Dark";
      QT_QUICK_CONTROLS_MATERIAL_PRIMARY = p.WING;
      QT_QUICK_CONTROLS_MATERIAL_ACCENT = p.ROOT;
      QT_QUICK_CONTROLS_MATERIAL_FOREGROUND = p.SCORE;
      QT_QUICK_CONTROLS_MATERIAL_BACKGROUND = p.HALL;
      # Nix's constant file mtimes make Qt's QML disk cache serve stale compiled
      # units after a Moonlight patch or update.
      QML_DISABLE_DISK_CACHE = "1";
    };
  };

  fonts.packages = [ (pkgs.callPackage ../../pkgs/josefin-sans.nix { }) ];
  fonts.fontconfig.defaultFonts.sansSerif = [ "Josefin Sans" ];

  # Backstop only: cage waits for its client and systemd signals only cage's
  # MainPID, so the wrapper polls the unit state (see retro-stream above).
  # Without this a stuck stop waits the default 90 s before SIGKILL.
  systemd.services."cage-tty1".serviceConfig.TimeoutStopSec = 10;

  hardware.graphics = {
    enable = true;
    extraPackages = [ pkgs.intel-media-driver ];
  };

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    # The Inspiron's card comes up on its analog profile, so Moonlight played
    # through the laptop's own speakers while the TV sat on volume 0. Select the
    # HDMI output (kept the analog input) so the default sink is the TV.
    wireplumber.extraConfig."99-hdmi-profile" = {
      "monitor.alsa.rules" = [{
        matches = [{ "device.name" = "alsa_card.pci-0000_00_1f.3"; }];
        actions.update-props."device.profile" = "output:hdmi-stereo+input:analog-stereo";
      }];
    };
  };
  security.rtkit.enable = true;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
}

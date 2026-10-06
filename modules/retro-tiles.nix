{ config, lib, pkgs, ... }:
let
  p = import ../themes/Custom/slate-lavender/palette-slate-lavender.nix;
  tileSystems = builtins.filter (s: s.tile or false)
    (import ../hosts/retro-systems.nix { inherit pkgs; });
  # gameOS ships no combined GameCube/Wii logo, so that tile shows both.
  logosOf = s: if s.dir == "gamecube-wii" then [ "gc" "wii" ] else [ s.shortname ];
  # ImageMagick can't pick a variable font's weight axis (it draws the Thin
  # default), so pin Bold (700, as waybar sets) into a static instance.
  font = pkgs.runCommand "JosefinSans-Bold.ttf" { nativeBuildInputs = [ pkgs.python3Packages.fonttools ]; } ''
    fonttools varLib.instancer \
      ${pkgs.callPackage ../pkgs/josefin-sans.nix { }}/share/fonts/truetype/JosefinSans-Variable.ttf \
      wght=700 -o $out
  '';

  # White-on-transparent wordmark for the Desktop tile, trimmed to its ink.
  desktopLogo = pkgs.runCommand "surfwax-logo.png" { nativeBuildInputs = [ pkgs.resvg pkgs.imagemagick ]; } ''
    resvg --height 600 ${../assets/surfwax.svg} raw.png
    magick raw.png -trim +repage $out
  '';

  # Pegasus has no collection CLI option, so each console gets a private
  # config dir whose game_dirs.txt lists only that console's rom dir. Its
  # metadata.pegasus.txt (collection header + launch command) lives in that dir.
  retroPegasus = pkgs.writeShellApplication {
    name = "retro-pegasus";
    runtimeInputs = [ pkgs.coreutils pkgs.pegasus-frontend ];
    text = ''
      dir="''${1:-}"
      if [ -z "$dir" ] || [ ! -d "/srv/roms/$dir" ]; then
        echo "retro-pegasus: no such rom dir: /srv/roms/''${dir}" >&2
        exit 1
      fi

      main="$HOME/.config/pegasus-frontend"
      base="$HOME/.local/share/retro-tiles/$dir/cfg"
      mkdir -p "$base/pegasus-frontend"

      # XDG_CONFIG_HOME moves every emulator Pegasus spawns too, so expose the
      # real config dir's other entries (retroarch.cfg, dolphin-emu, ...).
      shopt -s nullglob dotglob
      for e in "$HOME/.config"/*; do
        name="$(basename "$e")"
        [ "$name" = "pegasus-frontend" ] && continue
        # A real (non-link) entry here would make ln -n nest the link inside it.
        if [ -e "$base/$name" ] && [ ! -L "$base/$name" ]; then continue; fi
        ln -sfn "$e" "$base/$name"
      done
      shopt -u nullglob dotglob

      echo "/srv/roms/$dir" > "$base/pegasus-frontend/game_dirs.txt"
      # Copied, not linked: Pegasus rewrites settings.txt on exit.
      cp -f "$main/settings.txt" "$base/pegasus-frontend/settings.txt"
      ln -sfn "$main/themes" "$base/pegasus-frontend/themes"
      ln -sfn "$main/favorites.txt" "$base/pegasus-frontend/favorites.txt"

      exec env XDG_CONFIG_HOME="$base" pegasus-fe
    '';
  };
  # Sunshine serves these as 16:9 art; Moonlight only draws its own name
  # overlay when art is missing, so every card carries its label.
  retroTileArt = pkgs.writeShellApplication {
    name = "retro-tile-art";
    runtimeInputs = [ pkgs.imagemagick pkgs.coreutils pkgs.findutils ];
    text = ''
      # Art is cosmetic: never fail the unit over a missing input.
      set +e

      out="$HOME/.local/share/retro-tiles/art"
      mkdir -p "$out" || exit 0

      COVERS=()
      covers_of() {
        local all=()
        mapfile -d "" -t all < <(find "/srv/roms/$1/media/covers" -maxdepth 1 -type f \
          \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0 2>/dev/null | sort -z)
        COVERS=("''${all[@]:0:4}")
      }

      # card <dest> <label> <base-image-or-empty> [cover...]
      card() {
        local dest="$1" label="$2" base="$3" tmp i x y c
        shift 3
        tmp="$(mktemp -p "$out" .tile.XXXXXX.png)" || return 0

        local name logodir lf=() n f
        name="$(basename "$dest" .png)"
        logodir="$HOME/.config/pegasus-frontend/themes/gameOS/assets/images/logospng"
        local logoh=120
        if [ -f "$HOME/.local/share/retro-tiles/logos/$name.png" ]; then
          lf=("$HOME/.local/share/retro-tiles/logos/$name.png")
        elif [ -n "''${LOGO_FILE:-}" ]; then
          lf=("$LOGO_FILE")
          logoh=150
        else
          for n in "''${LOGOS[@]}"; do
            f="$logodir/$n.png"
            if [ -f "$f" ]; then lf+=("$f"); fi
          done
        fi

        local bandbg=(-fill '${p.WING}' -draw "rectangle 0,540 1280,720")
        local bandtext=(
          "(" -background none -fill '${p.SCORE}' -font '${font}' -pointsize 72
              -gravity center -size 1200x "caption:$label" ")"
          -gravity center -geometry +0+270 -composite
        )
        local bandend=(-define 'png:exclude-chunks=date,time')

        # One logo fills a 1100x120 box; two (gc + wii) get 530x120 each with a 40px gap.
        local bandlogo=()
        if [ "''${#lf[@]}" -eq 1 ]; then
          bandlogo=(
            "(" "''${lf[0]}[0]" -background none -filter Lanczos -resize "1100x$logoh" ")"
            -gravity center -geometry +0+270 -composite
          )
        elif [ "''${#lf[@]}" -eq 2 ]; then
          bandlogo=(
            "(" "(" "''${lf[0]}[0]" -background none -filter Lanczos -resize 530x120
                    -gravity center -extent 530x120 +repage ")"
                "(" -size 40x120 xc:none ")"
                "(" "''${lf[1]}[0]" -background none -filter Lanczos -resize 530x120
                    -gravity center -extent 530x120 +repage ")"
                +append +repage ")"
            -gravity center -geometry +0+270 -composite
          )
        fi

        local args
        if [ -n "$base" ] && [ -f "$base" ]; then
          args=("''${base}[0]" -resize "1280x720^" -gravity center -extent 1280x720 +gravity)
        else
          args=(-size 1280x720 "xc:${p.HALL}")
        fi
        i=0
        for c in "$@"; do
          x=$((40 + i * 310))
          y=30
          args+=("(" "''${c}[0]" -resize 300x490 -background '${p.HALL}' -gravity center -extent 300x490 +repage ")"
                 -gravity northwest -geometry "+$x+$y" -composite)
          i=$((i + 1))
        done

        local done_=0
        if [ "''${#bandlogo[@]}" -gt 0 ] \
          && magick "''${args[@]}" "''${bandbg[@]}" "''${bandlogo[@]}" "''${bandend[@]}" "PNG:$tmp" 2>/dev/null; then
          done_=1
        elif magick "''${args[@]}" "''${bandbg[@]}" "''${bandtext[@]}" "''${bandend[@]}" "PNG:$tmp" 2>/dev/null; then
          done_=1
        fi
        if [ "$done_" -eq 0 ]; then
          magick -size 1280x720 "xc:${p.HALL}" "''${bandbg[@]}" "''${bandtext[@]}" "''${bandend[@]}" "PNG:$tmp" 2>/dev/null \
            || { rm -f "$tmp"; return 0; }
        fi
        chmod 644 "$tmp"
        mv -f "$tmp" "$dest"
      }

      pegasus=()
      ${lib.concatMapStrings (s: ''
        LOGOS=(${lib.escapeShellArgs (logosOf s)})
        covers_of ${lib.escapeShellArg s.dir}
        card "$out/${s.dir}.png" ${lib.escapeShellArg s.collection} "" "''${COVERS[@]}"
        if [ "''${#COVERS[@]}" -gt 0 ]; then pegasus+=("''${COVERS[0]}"); fi
      '') tileSystems}
      LOGOS=(pegasus)
      card "$out/pegasus.png" Pegasus "" "''${pegasus[@]:0:4}"

      wp=""
      IFS= read -r wp < "$HOME/.local/state/wallpaper" 2>/dev/null
      LOGOS=()
      LOGO_FILE=${desktopLogo} card "$out/desktop.png" SurfWax "$wp"

      exit 0
    '';
  };
in
{
  # modules/sunshine.nix reads this to build its per-console tile commands.
  options.retroTiles.launcher = lib.mkOption {
    type = lib.types.package;
    internal = true;
    default = retroPegasus;
    description = "The retro-pegasus per-console launcher.";
  };

  config.environment.systemPackages = [ config.retroTiles.launcher retroTileArt ];

  # NixOS-level user units: this module is desktop-only system config, and
  # sunshine's own service is system-declared too.
  config.systemd.user.services.retro-tile-art = {
    description = "Regenerate retro tile art for Sunshine";
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    unitConfig = {
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
      StartLimitIntervalSec = 60;
      StartLimitBurst = 30;
    };
    serviceConfig = {
      Type = "oneshot";
      # Lets /srv/roms mounts settle at login; also coalesces wallpaper-write bursts.
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 20";
      ExecStart = "${retroTileArt}/bin/retro-tile-art";
    };
  };

  config.systemd.user.paths.retro-tile-art = {
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    unitConfig.ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
    pathConfig = {
      PathChanged = "%h/.local/state/wallpaper";
      TriggerLimitIntervalSec = 0;
    };
  };
}

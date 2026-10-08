{ inputs, pkgs, lib, config, ... }:
let
  moon = import ../../themes/Dark/indigo-rose/palette-indigo-rose.nix;

  # Firefox's homepage: same tile look as the kid's dashboard, one tile per
  # WebsiteFilter exception. Plain https:// links, so no launcher/GIO
  # involved — Firefox just navigates, same as any normal link click.
  sitesHtml = pkgs.writeText "kid-sites.html" ''
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
      html, body {
        margin: 0; height: 100%;
        background: ${moon.PIT};
        font-family: sans-serif;
      }
      body {
        display: flex; align-items: center; justify-content: center;
      }
      .tiles {
        display: flex; flex-wrap: wrap; justify-content: center;
        gap: 40px; max-width: 760px;
      }
      a.tile {
        display: flex; flex-direction: column; align-items: center; justify-content: center;
        width: 320px; height: 280px;
        border-radius: 32px;
        background: ${moon.PIT_SURFACE};
        border: 6px solid ${moon.BAR};
        color: ${moon.SCORE};
        text-decoration: none;
        font-size: 34px;
        font-weight: bold;
        text-align: center;
      }
      a.tile .icon { font-size: 100px; margin-bottom: 20px; }
      a.tile:active { background: ${moon.ROOT}; border-color: ${moon.ROOT}; }
    </style>
    </head>
    <body>
      <div class="tiles">
        <a class="tile" href="https://pbskids.org/"><span class="icon">📺</span>PBS Kids</a>
        <a class="tile" href="https://www.khanacademy.org/"><span class="icon">🎓</span>Khan Academy</a>
        <a class="tile" href="https://www.starfall.com/"><span class="icon">⭐</span>Starfall</a>
        <a class="tile" href="https://vikidia.org/"><span class="icon">📖</span>Vikidia</a>
      </div>
    </body>
    </html>
  '';
in
{
  imports = [
    ./niri.nix
    ./dashboard-server.nix
    ./controller-home.nix
    ../emulation-light
    ../mako
  ];

  # This account has no drmis, so its keyboard sheet is rendered from its fixed palette.
  xdg.configFile."squeekboard-gtk/gtk-3.0/gtk.css".text =
    import ../niri/squeekboard.nix { p = import ../../themes/Light/kid/palette-kid.nix; };

  home.stateVersion  = "25.11";
  home.username      = "kid";
  home.homeDirectory = "/home/kid";

  gtk = {
    enable = true;
    gtk4.theme = config.gtk.theme;
    theme = {
      name    = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name    = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
  };

  # Epiphany's first-run "set as default browser?" infobar calls
  # set_as_default_browser() -> update_mimeapps_list(), which tries to
  # atomically rewrite ~/.config/mimeapps.list. That path is a home-manager
  # symlink into the read-only Nix store, so the write fails — and a bug in
  # GIO's error handling (it reuses an already-set GError from the failed
  # write in a later g_file_read_link call) turns that failure into an
  # unconditional g_error/abort() instead of a recoverable warning. Any tap
  # on the infobar killed the whole kiosk instantly (confirmed via
  # coredumpctl: button_clicked_cb -> set_as_default_browser ->
  # update_mimeapps_list -> g_file_read_link -> abort), which from the kid's side
  # just looked like "the buttons don't do anything." ask-for-default=false
  # skips the infobar entirely, since we don't want the kid (or Epiphany) ever
  # rewriting mimeapps.list anyway — the app: scheme handler is meant to be
  # permanent.
  dconf.settings."org/gnome/epiphany".ask-for-default = false;

  home.pointerCursor = {
    name       = "posys_cursor_scalable";
    package    = inputs.posys-cursor.packages.${pkgs.stdenv.hostPlatform.system}.default;
    size       = 32;   # logical px; niri renders the seat cursor at 48 on the 2.0 panel
    gtk.enable = true;
  };

  ########################################
  # Wayland session environment (mirrors roles/base.nix essentials)
  ########################################
  home.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    GDK_BACKEND    = "wayland,x11";
  };

  # Emulator set + Pegasus config: shared verbatim with home/pegasus-surface
  # via ../emulation-light. pegasus-frontend itself is a surface system
  # package (hosts/surface/config.nix).
  home.packages = with pkgs; [
    foliate              # ebook reader
    tuxpaint             # drawing for young kids
    krita                # drawing / stylus
    gcompris             # activity suite (ages 2–10)
    nwg-drawer           # big fullscreen touch app grid (the kid's launcher, Mod+Space)
    ghostty              # terminal — available, not foregrounded
    swaybg               # paints the kid's static ice-cream wallpaper
    epiphany             # chrome-less dashboard browser (home workspace)
  ];

  xdg.configFile."nwg-drawer/drawer.css".text = ''
    window { background-color: rgba(35, 33, 54, 0.92); }
    #searchbox, #button, #label { color: #ffffff; font-size: 18px; }
    button { background: transparent; border-radius: 12px; padding: 8px; }
    button:hover { background-color: #303254; }
  '';

  programs.bash = {
    enable = true;
    shellAliases = {
      ls = "ls --color=auto";
      ll = "ls -lh --color=auto";
    };
  };

  ########################################
  # Firefox — locked by enterprise policy. Everything is blocked except the
  # curated allowlist below.
  #
  # HARD RULE: NO YouTube, and NO creator / influencer / "channel" sites — EVER.
  # The block-everything-except model enforces this by default. Do NOT add
  # youtube.com, youtubekids.com, or any creator channel to the Exceptions.
  # Curated educational sites only. Re-verify on every edit.
  ########################################
  programs.firefox = {
    enable = true;
    configPath = ".mozilla/firefox";
    policies = {
      WebsiteFilter = {
        Block = [ "<all_urls>" ];
        Exceptions = [
          "https://pbskids.org/*"
          "https://*.pbskids.org/*"
          "https://learn.khanacademy.org/*"
          "https://*.khanacademy.org/*"
          "https://www.starfall.com/*"
          "https://*.starfall.com/*"
          # Vikidia, not Wikipedia — an encyclopedia actually written for
          # kids (~8-13), not just Wikipedia with simpler words. Full
          # Wikipedia was pulled deliberately: the kid is sharp enough to
          # wiki-walk from any article into genuinely dark subject matter
          # in a couple clicks, which Vikidia's curated/kid-authored scope
          # doesn't have.
          "https://vikidia.org/*"
          "https://*.vikidia.org/*"
          # <all_urls> in the Block rule follows the WebExtension match-
          # pattern spec, which explicitly includes file:// alongside http/
          # https — so without this, their own homepage (file://sitesHtml,
          # below) would get blocked by the very policy meant to open it.
          # Harmless to allow broadly: file:// can only reach local files,
          # never a remote site like youtube.com.
          #
          # Confirmed live that "file://*" is NOT the same pattern and does
          # NOT match — file:// URLs have no host component (file:///path,
          # empty string between the 2nd and 3rd slash), and match-pattern
          # syntax requires <scheme>://<host><path>. "file://*" tries to
          # match "*" against that empty host and fails; the actual
          # "all local files" pattern collapses the host entirely:
          # file:///*  (three slashes, wildcard starts the path).
          "file:///*"
        ];
      };

      # Open straight to a tile page for all four allowed sites, matching
      # the dashboard's look, instead of dropping the kid onto just one of them
      # with no way to reach the others short of typing a URL.
      Homepage = {
        URL = "file://${sitesHtml}";
        StartPage = "homepage";
      };
      NewTabPage = false;

      # Every kill of the firefox process (niri close-window, service
      # restart, anything short of the app's own Quit) counts as an
      # unclean shutdown. Without this, that trips Firefox's own "Restore
      # Session?" prompt on next launch, sitting between the kid and the
      # homepage instead of the tile page loading straight away — confirmed
      # live after closing/relaunching the window during this fix.
      Preferences = {
        "browser.sessionstore.resume_from_crash" = {
          Value = false;
          Status = "locked";
        };
      };

      # Lock it down so a sharp, frustrated 5yo can't wander out.
      DisablePrivateBrowsing = true;
      DisableDeveloperTools = true;
      BlockAboutConfig = true;
      BlockAboutProfiles = true;
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
      DontCheckDefaultBrowser = true;
      OverrideFirstRunPage = "";
      OverridePostUpdatePage = "";
      FirefoxHome = {
        Search = true;
        TopSites = false;
        SponsoredTopSites = false;
        Highlights = false;
        Pocket = false;
        SponsoredPocket = false;
      };
    };
  };

}

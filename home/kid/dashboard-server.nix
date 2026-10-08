{ pkgs, config, ... }:
let
  moon = import ../../themes/Dark/indigo-rose/palette-indigo-rose.nix;

  # Arbitrary unused high port, loopback-only — nothing outside this account
  # needs to reach it.
  port = 47823;

  # Reuse the eggclock waybar module's script unchanged — same hatch,
  # rarity, and lore logic, same ~/.cache/eggclock state files. Only the
  # transport changes (HTTP response instead of waybar's stdout polling).
  eggclockPy = ../waybar/scripts/eggclock.py;

  # The kid's home screen: a static tile page (Pegasus/Firefox/Krita/GCompris)
  # plus the eggclock badge, served by the Python backend below instead of
  # a file:// URL.
  #
  # Tiles used to be <a href="app:pegasus"> resolved via a registered
  # x-scheme-handler/app GIO handler. Confirmed live that Epiphany/WebKit
  # never hands a click on a custom scheme off to GIO at all — zero trace of
  # it in the journal across multiple real taps, even after the launcher
  # script itself was fixed and proven working when invoked directly. Plain
  # http:// links to this same-origin server are normal navigation, which
  # WebKit unambiguously handles — no scheme registration, no mimeapps.list,
  # no GIO resolution chain to go wrong.
  dashboardHtml = pkgs.writeText "kid-dashboard.html" ''
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
      .tiles { display: grid; grid-template-columns: repeat(2, 320px); gap: 48px; }
      a.tile {
        display: flex; flex-direction: column; align-items: center; justify-content: center;
        width: 320px; height: 320px;
        border-radius: 32px;
        background: ${moon.PIT_SURFACE};
        border: 6px solid ${moon.BAR};
        color: ${moon.SCORE};
        text-decoration: none;
        font-size: 42px;
        font-weight: bold;
      }
      a.tile .icon { font-size: 120px; margin-bottom: 24px; }
      a.tile:active { background: ${moon.ROOT}; border-color: ${moon.ROOT}; }

      #eggclock {
        position: fixed;
        top: 24px; right: 32px;
        background: ${moon.PIT_SURFACE};
        border: 4px solid ${moon.BAR};
        color: ${moon.SCORE};
        border-radius: 20px;
        padding: 10px 22px;
        font-size: 26px;
        font-weight: bold;
      }
    </style>
    </head>
    <body>
      <div id="eggclock">🥚</div>
      <div class="tiles">
        <a class="tile" href="/launch/pegasus"><span class="icon">🎮</span>Pegasus</a>
        <a class="tile" href="/launch/firefox"><span class="icon">🌐</span>Firefox</a>
        <a class="tile" href="/launch/krita"><span class="icon">🎨</span>Krita</a>
        <a class="tile" href="/launch/gcompris"><span class="icon">🧩</span>GCompris</a>
      </div>
      <script>
        async function updateEgg() {
          try {
            const r = await fetch('/eggclock');
            const d = await r.json();
            const el = document.getElementById('eggclock');
            el.textContent = d.text;
            el.title = d.tooltip;
          } catch (e) {}
        }
        updateEgg();
        setInterval(updateEgg, 60000);
      </script>
    </body>
    </html>
  '';

  dashboardServerPy = pkgs.writeText "kid-dashboard-server.py" ''
    import http.server
    import socketserver
    import subprocess

    PORT = ${toString port}
    NIRI = "${pkgs.niri}/bin/niri"
    LAUNCHERS = {
        "pegasus": ["${pkgs.pegasus-frontend}/bin/pegasus-fe"],
        # NOT pkgs.firefox — that's the plain, policy-less package. The
        # WebsiteFilter allowlist (default.nix's programs.firefox.policies)
        # only exists on the wrapped derivation home-manager builds
        # separately as finalPackage; pkgs.firefox and finalPackage are
        # different store paths with the same version number, so this was
        # silently launching completely unrestricted Firefox — confirmed
        # live when the kid reached youtube.com straight through it.
        #
        # --kiosk: confirmed via --help that Firefox has no standalone
        # fullscreen flag, only --kiosk, which fullscreens AND drops all
        # browser chrome (toolbar, tabs, address bar) — same mechanism
        # Epiphany already uses for the dashboard itself. The kid navigates via
        # page links and Mod+H, same as everywhere else in this kiosk.
        "firefox": ["${config.programs.firefox.finalPackage}/bin/firefox", "--kiosk"],
        "krita": ["${pkgs.krita}/bin/krita"],
        # Real binary is gcompris-qt, not gcompris — confirmed by building
        # the package and listing its bin/ output.
        "gcompris": ["${pkgs.gcompris}/bin/gcompris-qt"],
    }
    EGGCLOCK_CMD = ["${pkgs.python3}/bin/python3", "${eggclockPy}"]

    with open("${dashboardHtml}", "rb") as f:
        DASHBOARD_HTML = f.read()


    class Handler(http.server.BaseHTTPRequestHandler):
        # systemd's journal already timestamps every line; the default
        # per-request access log is just noise here.
        def log_message(self, format, *args):
            pass

        def do_GET(self):
            if self.path == "/":
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(DASHBOARD_HTML)
            elif self.path.startswith("/launch/"):
                target = self.path.removeprefix("/launch/")
                exe = LAUNCHERS.get(target)
                if exe:
                    subprocess.run([NIRI, "msg", "action", "focus-workspace", "active"])
                    subprocess.Popen(exe)
                self.send_response(302)
                self.send_header("Location", "/")
                self.end_headers()
            elif self.path == "/eggclock":
                result = subprocess.run(EGGCLOCK_CMD, capture_output=True, text=True)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(result.stdout.encode())
            else:
                self.send_response(404)
                self.end_headers()


    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
  '';

  # Epiphany has no retry-on-connection-refused behavior — if it starts
  # before the Python server's TCPServer has actually bound the port, it
  # just shows a permanent "Unable to connect" page with nothing to
  # self-heal it. Poll for real readiness instead of trusting systemd's
  # Type=simple "process forked" signal, same wait-loop idiom used
  # elsewhere in this repo for the identical class of startup race.
  dashboardLaunch = pkgs.writeShellScript "kid-dashboard-launch" ''
    set -euo pipefail
    for _ in $(seq 1 50); do
      ${pkgs.curl}/bin/curl -s -o /dev/null "http://127.0.0.1:${toString port}/" && break
      sleep 0.1
    done
    exec ${pkgs.epiphany}/bin/epiphany --kiosk-mode "http://127.0.0.1:${toString port}/"
  '';
in
{
  systemd.user.services.kid-dashboard-server = {
    Unit = {
      Description = "Kid's kiosk backend (dashboard page, app launcher, eggclock)";
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = "${pkgs.python3}/bin/python3 ${dashboardServerPy}";
      Restart = "always";
      RestartSec = 1;
    };
  };

  # Supervised instead of spawn-at-startup: Mod+H and Mod+Q both do an
  # unconditional close-window, which would kill the dashboard itself if
  # pressed while already on "home" (likely, for a young child) and leave the kid
  # stranded until logout/login. Restart=always respawns it immediately no
  # matter what closes it.
  systemd.user.services.kid-dashboard = {
    Unit = {
      Description = "Kid's dashboard home screen (epiphany kiosk)";
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=niri";
      After = [ "graphical-session.target" "kid-dashboard-server.service" ];
      Requires = [ "kid-dashboard-server.service" ];
      PartOf = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = "${dashboardLaunch}";
      Restart = "always";
      RestartSec = 1;
    };
  };
}

# prepko's personal layer, shared by both of his hosts: everything that knows
# his machines, accounts or ~/nixos. profiles/base.nix is the look and the
# apps, and is what the guest account gets, so anything personal lands here.
{ inputs, pkgs, lib, config, inventory, ports, ... }:
let
  pythonEnv = import ../python-env.nix pkgs;

  sqlchYtdlp = pkgs.writeShellScript "yt-dlp-wait" ''
    YT_DLP=${pkgs.yt-dlp}/bin/yt-dlp POPUP_MPV=${pkgs.mpv}/bin/mpv exec ${pkgs.python3}/bin/python3 ${../../scripts/yt-dlp-wait.py} "$@"
  '';

  sqlchHttpBridge = pkgs.writeScript "sqlch-http-bridge" ''
    #!${pkgs.python3}/bin/python3
    import json, os, socket
    from http.server import BaseHTTPRequestHandler, HTTPServer

    PORT = ${toString ports.sqlch-http-bridge}
    SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "sqlch", "control.sock")

    def sqlch(msg):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2.0)
            s.connect(SOCK)
            s.sendall((json.dumps(msg) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
        return json.loads(buf.decode("utf-8", errors="replace"))

    class H(BaseHTTPRequestHandler):
        def _send(self, code, body):
            b = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", len(b))
            self.end_headers()
            self.wfile.write(b)

        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()

        def do_GET(self):
            if self.path != "/status":
                self._send(404, {"error": "not found"}); return
            try:
                self._send(200, sqlch({"cmd": "status"}))
            except Exception as e:
                self._send(503, {"ok": False, "error": str(e)})

        def do_POST(self):
            if self.path != "/command":
                self._send(404, {"error": "not found"}); return
            try:
                n = int(self.headers.get("Content-Length", 0))
                msg = json.loads(self.rfile.read(n))
                self._send(200, sqlch(msg))
            except Exception as e:
                self._send(503, {"ok": False, "error": str(e)})

        def log_message(self, *_): pass

    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
  '';
in
{
  imports = [
    ../../home/sqlch-sync.nix
    ../../home/niri-bridge
    ../../home/claude-tidy.nix
    ../../home/tree-sync.nix
    ../../home/theme-sync.nix
    ../../home/fleet-status.nix
    ../../home/whats-new.nix
    ../../home/nixfetch.nix
    ../../home/sync-status.nix
    ../../home/pass-through.nix
    ../../home/quivr.nix
    ../../home/go-librespot.nix
    ../../home/on.nix
    ../../home/tunnel.nix
    ../../home/dnslog.nix
    inputs.sqlch.homeManagerModules.default
  ];

  sqlch.gui.enable = true;
  home.sessionVariables.CLAUDE_ENV_FILE = "$HOME/.claude/.env";

  systemd.user.services = {
    sqlch-daemon = {
      Unit = {
        Description = "sqlch mpris daemon";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.bash}/bin/bash -c 'set -a; . /run/secrets/spotify_env; set +a; exec ${pkgs.sqlch}/bin/sqlch daemon'";
        Restart = "on-failure";
        # mpv children (video + ytdl cache) live in this cgroup; 300M OOM-killed
        # the whole unit, window and all, as soon as a video source started.
        MemoryMax = "2G";
        MemorySwapMax = "0";
        Environment = [ "MALLOC_ARENA_MAX=2" "SQLCH_YTDLP=${sqlchYtdlp}" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    sqlch-http-bridge = {
      Unit = {
        Description = "sqlch HTTP bridge for Firefox startpage";
        After = [ "sqlch-daemon.service" "graphical-session.target" ];
        BindsTo = [ "sqlch-daemon.service" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${sqlchHttpBridge}";
        Restart = "on-failure";
        RestartSec = "3s";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };

  programs.zsh.shellAliases = {
      lb = "sudo rm -f /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI && sudo rm -f /boot/EFI/Linux/nixos-*.efi";
      # -e pins nh's elevation strategy to the real setuid sudo wrapper —
      # nh's "auto" detection can otherwise resolve the non-setuid
      # /run/current-system/sw/bin/sudo and fail activation.
      nrs = "{ nh os switch -e /run/wrappers/bin/sudo ${config.home.homeDirectory}/nixos && whats-new; } || sfx error";
      nrb = "nh os boot -e /run/wrappers/bin/sudo ${config.home.homeDirectory}/nixos";
      nrt = "nh os test -e /run/wrappers/bin/sudo ${config.home.homeDirectory}/nixos";
      ship = "~/nixos/scripts/ship.sh";
      secrets = "~/nixos/scripts/secrets.py";
  };

  programs.zsh.initContent =
    # Plain `sops` uses the passphrase-encrypted editor key (scripts/sops-editor-key.sh), so no
    # host key sits in ~. Not SOPS_AGE_KEY_CMD: sops reruns that once per recipient it tries,
    # i.e. a passphrase prompt per recipient. The key reaches only this one sops process.
    (lib.mkAfter ''
      sops() {
        local key
        key=$(${pkgs.age}/bin/age -d "$HOME/.config/sops/age/editor.age") || return
        SOPS_AGE_KEY=$key command sops "$@"
      }
    '');

  programs.ssh = {
    enable = true;
    # enableDefaultConfig is deprecated upstream; the block it injected just
    # restates OpenSSH's own compiled-in defaults (ForwardAgent no,
    # ServerAliveInterval 0, HashKnownHosts no, ControlMaster/Persist no,
    # etc.) so disabling it changes nothing behaviorally.
    enableDefaultConfig = false;
    # Fleet hosts get the passphrase-free id_fleet (authorized from= our tailnet
    # IPs only, identities/prepko.nix) so overnight jobs run unattended;
    # id_ed25519 carries a passphrase and goes only to GitHub. Both must precede
    # `*`: ssh keeps the first value it sees per option.
    settings = let
      patterns = lib.concatLists (lib.mapAttrsToList
        (name: h: [ name h.ts h.ip "${name}.*.ts.net" "${h.ts}.*.ts.net" ]) inventory);
    in {
      fleet = lib.hm.dag.entryBefore [ "*" ] {
        header = "Host ${lib.concatStringsSep " " patterns}";
        IdentityFile = "~/.ssh/id_fleet";
        IdentitiesOnly = "yes";
      };
      "github.com" = lib.hm.dag.entryBefore [ "*" ] {
        IdentityFile = "~/.ssh/id_ed25519";
        IdentitiesOnly = "yes";
      };
      # A lifetime, not "yes": a borrowed session can't reuse a key unlocked hours ago.
      "*".AddKeysToAgent = "1h";
    };
  };

  home.packages = with pkgs; [
    claude-code
    sqlch            # prepko only: it has a YouTube source, so never system-wide
    (writeShellScriptBin "get-theme" ''
      exec ${pythonEnv}/bin/python3 ~/nixos/scripts/auto-theme.py "$@"
    '')

    (writeShellScriptBin "scrape" ''
      exec ~/nixos/scripts/skyscraper-scrape.sh "$@"
    '')

    (writeShellScriptBin "openb64" ''
      exec ~/nixos/scripts/openb64.sh "$@"
    '')

    (writeShellScriptBin "extract-to-backup" ''
      exec ~/nixos/scripts/extract-to-backup.sh "$@"
    '')
  ];
}

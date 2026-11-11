{ pkgs, ... }:
let
  ports = import ../hosts/ports.nix;
  webui = "http://127.0.0.1:${toString ports.qbittorrent-webui}";

  # `torrent <magnet|file>` adds it; bare `torrent` opens the web UI. Either
  # way qbittorrent is started first (sudo rule in modules/qbittorrent.nix),
  # which refuses unless a ProtonVPN tunnel is up.
  torrent = pkgs.writeShellApplication {
    name = "torrent";
    runtimeInputs = with pkgs; [ curl libnotify xdg-utils coreutils ];
    text = ''
      fail() { notify-send -a qbittorrent -i network-error "qBittorrent" "$1"; exit 1; }

      if ! systemctl is-active --quiet qbittorrent.service; then
        up=""
        for t in /sys/class/net/protonvpn-*; do [ -e "$t" ] && up=1; done
        [ -n "$up" ] || fail "Won't start without ProtonVPN. Connect Ohio (P2P) first."
        /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl start qbittorrent.service \
          || fail "Failed to start. See: journalctl -u qbittorrent"
      fi
      for _ in $(seq 1 30); do
        curl -fs ${webui}/api/v2/app/version >/dev/null && break
        sleep 0.5
      done

      if [ $# -eq 0 ]; then
        exec xdg-open "${webui}"
      fi
      for t in "$@"; do
        if [ -f "$t" ]; then
          curl -fs ${webui}/api/v2/torrents/add -F "torrents=@$t" >/dev/null
        else
          curl -fs ${webui}/api/v2/torrents/add --data-urlencode "urls=$t" >/dev/null
        fi || fail "Couldn't add the torrent."
      done
      notify-send -a qbittorrent -i folder-download "qBittorrent" "Added, downloading to /srv/torrents"
    '';
  };
in
{
  home.packages = [ torrent ];

  xdg.desktopEntries.torrent = {
    name = "qBittorrent";
    genericName = "BitTorrent client";
    exec = "${torrent}/bin/torrent %U";
    icon = "qbittorrent";
    categories = [ "Network" "FileTransfer" "P2P" ];
    mimeType = [ "x-scheme-handler/magnet" "application/x-bittorrent" ];
  };
}

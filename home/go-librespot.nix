# go-librespot: a Spotify Connect device ("sqlch") that sqlch's spotify source
# drives over the local HTTP API. Premium account required.
#
# First run only: the service logs a short code (device_auth login). Read it
# with `journalctl --user -u go-librespot -n 20` or `curl localhost:3678/auth/code`,
# enter it at spotify.com/pair; the credentials are then kept in
# ~/.config/go-librespot/state.json.
#
# The package pin (nixpkgs-unstable, v0.10.5) is overlays/go-librespot.nix.
{ pkgs, lib, config, ... }:
let
  ports = import ../hosts/ports.nix;
  configFile = (pkgs.formats.yaml { }).generate "go-librespot-config.yml" {
    device_name = "sqlch";
    device_type = "computer";
    audio_backend = "pulseaudio"; # PipeWire's pulse socket
    zeroconf_enabled = false;
    credentials.type = "device_auth";
    # sqlch (core/handoff.py) expects this address
    server = {
      enabled = true;
      address = "localhost";
      port = ports.go-librespot;
    };
  };
in
{
  xdg.configFile."go-librespot/config.yml".source = configFile;

  systemd.user.services.go-librespot = {
    Unit = {
      Description = "go-librespot Spotify Connect device for sqlch";
      After = [ "graphical-session.target" "pipewire-pulse.service" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.go-librespot}/bin/go-librespot --config_dir ${config.xdg.configHome}/go-librespot";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}

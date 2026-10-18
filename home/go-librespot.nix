# go-librespot: a Spotify Connect device ("sqlch") that sqlch's spotify source
# drives over the local HTTP API. Premium account required.
#
# First run only: the service logs a short code (device_auth login). Read it
# with `journalctl --user -u go-librespot -n 20` or `curl localhost:3678/auth/code`,
# enter it at spotify.com/pair; the credentials are then kept in
# ~/.config/go-librespot/state.json.
#
# go-librespot is not in nixos-26.05, so it comes from nixpkgs-unstable, bumped
# to v0.10.5 for the device_auth login (the interactive one is rejected by
# Spotify's client id).
{ inputs, pkgs, lib, config, ... }:
let
  goLibrespot =
    inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.go-librespot.overrideAttrs
      (old: rec {
        version = "0.10.5";
        src = old.src.override {
          tag = "v${version}";
          hash = "sha256-lSObYalZqAYfik59L5PrH4CGcZilA7Tpzx4tVmTdsks=";
        };
        vendorHash = "sha256-fxB99qZE+U355iKJHIl7LgxqHmYgCiU1FpbyObTXVcQ=";
      });

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
      port = 3678;
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
      ExecStart = "${goLibrespot}/bin/go-librespot --config_dir ${config.xdg.configHome}/go-librespot";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}

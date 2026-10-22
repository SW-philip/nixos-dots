# ErsatzTV (legacy, with the Next streaming engine) as a podman container:
# not packaged in nixpkgs. Web UI is published on localhost only — podman's
# port publishing can bypass the NixOS firewall, so a LAN bind would be open.
# Reach it with `ssh -L 8409:localhost:8409 desktop`.
{ config, ... }:
let
  ports = import ../hosts/ports.nix;
in
{
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers.ersatztv = {
    image = "ghcr.io/ersatztv/legacy:v26.11.3";
    ports = [ "127.0.0.1:${toString ports.ersatztv}:8409" ];
    environment.TZ = config.time.timeZone;
    volumes = [
      "/var/lib/ersatztv:/config"
      "/srv/Videos/kid_and_henry:/media/kid_and_henry:ro"
    ];
    extraOptions = [ "--tmpfs=/transcode" ];
  };

  systemd.tmpfiles.rules = [ "d /var/lib/ersatztv 0750 root root -" ];

  environment.persistence."/persist".directories = [
    "/var/lib/ersatztv"
    # podman image store: without it the impermanent root re-pulls every boot
    "/var/lib/containers"
  ];
}

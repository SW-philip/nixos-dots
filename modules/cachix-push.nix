{ config, pkgs, ... }: {
  sops.secrets.cachix_token = {
    sopsFile = ../secrets/shared.yaml;
  };

  environment.systemPackages = [ pkgs.cachix ];

  nix.settings.post-build-hook = toString (pkgs.writeShellScript "cachix-push" ''
    set -euf
    export HOME=/root
    IFS=' ' read -ra out_paths <<< "$OUT_PATHS"
    CACHIX_AUTH_TOKEN=$(cat ${config.sops.secrets.cachix_token.path}) \
      ${pkgs.cachix}/bin/cachix push swphilip "''${out_paths[@]}"
  '');
}

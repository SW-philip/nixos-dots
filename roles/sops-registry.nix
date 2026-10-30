{ config, lib, ... }:
let
  inventory = import ../hosts/inventory.nix;
  self = lib.findFirst (n: inventory.${n}.nick == config.networking.hostName) null (lib.attrNames inventory);
  # Secrets added with `secrets add` (scripts/secrets.py): names and hosts only, values stay in sops.
  file = ../secrets/registry.json;
  registry = lib.optionals (builtins.pathExists file) (builtins.fromJSON (builtins.readFile file));
in
{
  sops.secrets = lib.listToAttrs (map
    (e: lib.nameValuePair e.name {
      sopsFile = ../. + "/${e.file}";
      owner = config.myConfig.user;
    })
    (lib.filter (e: lib.elem self e.hosts) registry));
}

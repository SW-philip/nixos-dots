# ~/nixos/modules/protonvpn.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.protonvpn;
  names = lib.attrNames cfg.configs;
in
{
  options.protonvpn.configs = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = {};
    description = "Attrset of interface name → wg-quick .conf file path";
    example = lib.literalExpression ''
      {
        protonvpn    = config.sops.secrets.protonvpn_conf.path;
        protonvpn-ca = config.sops.secrets.protonvpn_ca_conf.path;
      }
    '';
  };

  config = lib.mkIf (names != []) {
    networking.wg-quick.interfaces = lib.mapAttrs (_: confFile: {
      configFile = confFile;
      autostart = false;
    }) cfg.configs;

    # wg-quick's full-tunnel rules (priority ~5208) sit ahead of tailscale's (5210+), so with a
    # tunnel up even 100.x traffic and tailscaled's own marked packets go out the VPN and the
    # tailnet dies. These sit ahead of both: tailnet addresses use tailscale's table, its
    # transport bypasses the tunnel. A unit hook, not wg-quick's postUp: that is ignored with configFile.
    systemd.services = lib.genAttrs (map (n: "wg-quick-${n}") names) (_: {
      postStart = ''
        ${pkgs.iproute2}/bin/ip rule add fwmark 0x80000/0xff0000 lookup main priority 5100 || true
        ${pkgs.iproute2}/bin/ip rule add to 100.64.0.0/10 lookup 52 priority 5101 || true
        ${pkgs.iproute2}/bin/ip -6 rule add to fd7a:115c:a1e0::/48 lookup 52 priority 5101 || true
      '';
      preStop = ''
        ${pkgs.iproute2}/bin/ip rule del priority 5100 || true
        ${pkgs.iproute2}/bin/ip rule del priority 5101 || true
        ${pkgs.iproute2}/bin/ip -6 rule del priority 5101 || true
      '';
    });

    networking.networkmanager.unmanaged = names;
    networking.firewall.trustedInterfaces = names;

    security.sudo.extraRules = [{
      users = [ config.myConfig.user ];
      commands = lib.concatMap (name: [
        {
          command = "/run/current-system/sw/bin/systemctl start wg-quick-${name}.service";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl stop wg-quick-${name}.service";
          options = [ "NOPASSWD" ];
        }
      ]) names;
    }];
  };
}

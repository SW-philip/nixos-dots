{ config, lib, ... }:
let
  cfg = config.homeWifi;
in
{
  options.homeWifi.band = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "a" "bg" ]);
    default = null;
    description = "Pin the home network to a band (a = 5 GHz); null leaves NetworkManager free to choose.";
  };

  config = {
    sops.secrets.wifi_env.sopsFile = ../secrets/wifi.yaml;

    networking.networkmanager.ensureProfiles = {
      environmentFiles = [ config.sops.secrets.wifi_env.path ];
      profiles.ARRIS-3545 = {
        connection = {
          id = "ARRIS-3545";
          type = "wifi";
          uuid = "6c2e1a0e-8f4b-4d57-9a53-3b1f0d5e7c42";
          # Wins over the hand-made profile of the same name until that is deleted.
          autoconnect-priority = 10;
        };
        wifi = {
          ssid = "ARRIS-3545";
          mode = "infrastructure";
        } // lib.optionalAttrs (cfg.band != null) { band = cfg.band; };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$ARRIS_PSK";
        };
        ipv4.method = "auto";
        ipv6 = { method = "auto"; addr-gen-mode = "default"; };
      };
    };
  };
}

{ config, ... }: {
  sops.secrets.spotify_env = {
    sopsFile = ../secrets/shared.yaml;
    owner    = config.myConfig.user;
  };
  sops.secrets.openweathermap_api_key = {
    sopsFile = ../secrets/shared.yaml;
    owner    = config.myConfig.user;
  };
  # sqlch's jellyfin source reads this at /run/secrets/jellyfin_api_key.
  # Add the key first: `sops secrets/shared.yaml`, new line `jellyfin_api_key: <key>`.
  sops.secrets.jellyfin_api_key = {
    sopsFile = ../secrets/shared.yaml;
    owner    = config.myConfig.user;
  };
}

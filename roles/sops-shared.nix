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
  # sqlch's podcasts source reads this at /run/secrets/podcastindex_env.
  # Add it first: `sops secrets/shared.yaml`, an env-style block like spotify_env:
  #   podcastindex_env: |
  #     PODCASTINDEX_API_KEY=...
  #     PODCASTINDEX_API_SECRET=...
  sops.secrets.podcastindex_env = {
    sopsFile = ../secrets/shared.yaml;
    owner    = config.myConfig.user;
  };
}

# Workstations only: retro and pi are built on desktop and never fetch these.
{
  nix.settings = {
    substituters = [
      "https://claude-code.cachix.org"
      "https://cache.lix.systems"
    ];
    trusted-public-keys = [
      "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk="
      "cache.lix.systems-1:aBnZUw8zA7H35Cz2RyKFVs3H4PlGTLawyY5KRbvJR8o="
    ];
  };
}

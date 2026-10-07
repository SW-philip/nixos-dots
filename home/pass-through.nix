{ config, ... }:
let
  root = if config.myConfig.isDesktop then "/srv/prepko" else "${config.home.homeDirectory}/.desktop";
  link = n: config.lib.file.mkOutOfStoreSymlink "${root}/${n}";
in
{
  # real directories must be migrated first (scripts/pass-through-migrate.sh); home-manager will not overwrite them
  home.file."Pictures".source = link "Pictures";
  home.file."Downloads".source = link "Downloads";
}

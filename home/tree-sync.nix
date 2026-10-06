{ config, lib, pkgs, ... }:
let
  isDesktop = config.myConfig.isDesktop;
  treeSync = pkgs.writeShellApplication {
    name = "tree-sync";
    runtimeInputs = with pkgs; [ git openssh rsync coreutils util-linux gnugrep libnotify ];
    text = builtins.readFile ../scripts/tree-sync.sh;
  };
in
{
  home.packages = [ treeSync ];

  systemd.user.services.tree-sync = {
    Unit.Description = "Autosave and fast-forward ~/nixos through the pi git hub";
    Service = {
      Type = "oneshot";
      ExecStart = "${treeSync}/bin/tree-sync auto";
      Nice = 19;
      # desktop is where the gitignored files (wallpapers) originate
      Environment = lib.optional (!isDesktop) "TREE_SYNC_ASSETS_FROM=desktop";
    };
  };

  systemd.user.timers.tree-sync = {
    Unit.Description = "tree-sync timer";
    Timer = { OnStartupSec = "2min"; OnUnitActiveSec = "5min"; };
    Install.WantedBy = [ "timers.target" ];
  };

  # Back up unsaved work whenever a shell closes; detached so exit is never delayed.
  programs.zsh.initContent = lib.mkAfter ''
    # Claude Code's shell snapshots carry every zsh function and run zshexit in
    # non-interactive `zsh -c`, so only interactive shells may fire it.
    _tree_sync_exit() {
      [[ -o interactive ]] || return 0
      tree-sync save >/dev/null 2>&1 &!
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook zshexit _tree_sync_exit
  '';
}

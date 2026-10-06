{ pkgs, ... }:
let
  # inside an ssh login (no desktop to query) use the SESSION variant drmis deploys beside the main config
  ff = pkgs.writeShellScriptBin "ff" ''
    ssh_cfg="$HOME/.config/fastfetch/config-ssh.jsonc"
    conn="''${SSH_CONNECTION:-}"
    # a tmux pane keeps the env it was born with; the session env follows whoever attached last
    if [ -n "''${TMUX:-}" ] && tenv=$(tmux show-environment SSH_CONNECTION 2>/dev/null); then
      case "$tenv" in
        SSH_CONNECTION=*) conn="''${tenv#SSH_CONNECTION=}" ;;
        *) conn="" ;;
      esac
    fi
    if [ -n "$conn" ] && [ -r "$ssh_cfg" ]; then
      exec fastfetch -c "$ssh_cfg" "$@"
    fi
    exec fastfetch "$@"
  '';
in
{
  home.packages = [ ff ];
  programs.fastfetch.enable = true;
}

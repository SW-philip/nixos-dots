{ pkgs, ... }:
let
  on = pkgs.writeShellApplication {
    name = "on";
    runtimeInputs = with pkgs; [ waypipe openssh ];
    text = builtins.readFile ../scripts/on.sh;
  };
  completion = pkgs.writeTextDir "share/zsh/site-functions/_on" ''
    #compdef on
    _arguments '1:host:(desktop surface retro pi)' '*::command:_normal'
  '';
in
{
  home.packages = [ on completion ];
}

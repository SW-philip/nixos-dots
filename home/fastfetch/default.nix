{ pkgs, ... }:
let
  ff = pkgs.writeShellScriptBin "ff" "exec fastfetch";
in
{
  home.packages = [ ff ];
  programs.fastfetch.enable = true;
}

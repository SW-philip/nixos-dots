{ pkgs, ... }:
let
  whatsNew = pkgs.writeShellApplication {
    name = "whats-new";
    runtimeInputs = with pkgs; [ bash git nvd libnotify coreutils gnused gnugrep less ghostty ];
    text = builtins.readFile ../scripts/whats-new.sh;
  };
in
{
  home.packages = [ whatsNew ];
}

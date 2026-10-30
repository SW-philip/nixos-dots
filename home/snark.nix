{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "snark";
      text = builtins.readFile ../scripts/snark.sh;
    })
  ];
}

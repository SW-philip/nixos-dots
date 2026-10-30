{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "commands";
      runtimeInputs = [ pkgs.jq ];
      runtimeEnv.COMMANDS_JSON = "${../assets/commands.json}";
      text = builtins.readFile ../scripts/commands.sh;
    })
  ];
}

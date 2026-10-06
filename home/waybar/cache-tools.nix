{ pkgs }:
{
  cachePoll = pkgs.writeShellScriptBin "waybar-cache-poll" (builtins.readFile ./scripts/waybar-cache-poll);
  cacheRead = pkgs.writers.writePython3Bin "waybar-cache-read" { doCheck = false; }
    (builtins.readFile ./scripts/waybar-cache-read);
}

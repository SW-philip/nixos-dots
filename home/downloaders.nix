# burn (video), rip (audio), tape (video only): yt-dlp wrappers, scripts/<name>.sh.
{ pkgs, ... }:
let
  mk = name: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = [ pkgs.yt-dlp pkgs.ffmpeg ];
    text = builtins.readFile ../scripts/${name}.sh;
  };
in
{
  home.packages = map mk [ "burn" "rip" "tape" ];
}

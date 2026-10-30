# Nightly Whisper subtitles for the Jellyfin library (scripts/jellyfin-whisper.sh). Runs as the
# library owner (the dirs are prepko:users 755, so the jellyfin user can't write sidecars).
# Vulkan, not CUDA: the Vulkan build is in the binary cache and runs ~14x realtime on the 1660.
# medium.en, not large-v3-turbo: same speed, but turbo snaps every cue to a whole second.
# No VAD: it halves the time but drops punctuation and case from the cues.
{ config, pkgs, ... }:
let
  model = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en-q5_0.bin";
    hash = "sha256-dnM+Jq2P4celv3UxqdQZF7KtwPIPLk9VMWiKjGzYjrA=";
  };
  jellyfinWhisper = pkgs.writeShellApplication {
    name = "jellyfin-whisper";
    runtimeInputs = with pkgs; [ (whisper-cpp.override { vulkanSupport = true; }) ffmpeg-headless jq coreutils findutils gawk gnused gnugrep ];
    text = ''
      export WHISPER_MODEL=''${WHISPER_MODEL:-${model}}
      export WHISPER_STATE=''${WHISPER_STATE:-/var/lib/jellyfin-whisper}
    '' + builtins.readFile ../scripts/jellyfin-whisper.sh;
  };
in
{
  environment.systemPackages = [ jellyfinWhisper ];

  systemd.services.jellyfin-whisper = {
    description = "Generate Whisper subtitles for the Jellyfin library";
    after = [ "srv.mount" ];
    requires = [ "srv.mount" ];
    environment = {
      # Shows and movies only for now; commercials, bumpers and the rest wait their turn.
      WHISPER_ROOTS = builtins.concatStringsSep ":" (map (d: "/srv/Videos/${d}") [
        "mom_and_dad/movies"
        "mom_and_dad/television"
        "kid_and_henry/movies"
        "kid_and_henry/television"
      ]);
      # Leave the GPU free by morning; a killed run only loses the file in progress.
      WHISPER_DEADLINE = toString (4 * 3600);
    };
    serviceConfig = {
      Type = "oneshot";
      User = config.myConfig.user;
      Group = "users";
      ExecStart = "${jellyfinWhisper}/bin/jellyfin-whisper";
      StateDirectory = "jellyfin-whisper";
      TimeoutStartSec = "6h";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  # After goodnight (02:30) has finished deploying.
  systemd.timers.jellyfin-whisper = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30";
      Persistent = false;
    };
  };
}

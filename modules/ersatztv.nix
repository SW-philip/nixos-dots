# ErsatzTV (legacy, with the Next streaming engine) as a podman container:
# not packaged in nixpkgs. Web UI is published on localhost only — podman's
# port publishing can bypass the NixOS firewall, so a LAN bind would be open.
# Reach it with `ssh -L 8409:localhost:8409 desktop`.
#
# Channels play Sequential playouts generated from `channels` below, mounted
# at /schedules. ErsatzTV's API can't create channels or playouts, so each
# new number needs a one-time UI pass: Channels → Add (number, name, nvenc
# profile), then Playouts → Add → Sequential → /schedules/<number>.yaml.
# 1, 2, 5–8 and 10 are visible to every Jellyfin user; 3, 4 and 9 are group
# `Big`, blocked for Kid under Parental Controls. Channels from mom_and_dad must get their
# own group, blocked for every kid user.
{ config, lib, pkgs, ... }:
let
  ports = import ../hosts/ports.nix;

  show = t: ''show_title:"${t}"'';
  shows = lib.concatMapStringsSep " OR " show;
  # ErsatzTV tags Other Videos with every folder in their path
  # (bumpers/brain-breaks/x.mkv → bumpers, brain-breaks). Loose files only
  # index in an Other Videos library; under a TV library they're skipped.
  folder = t: "tag:${t}";
  anyFolder = lib.concatMapStringsSep " OR " folder;
  # a Music Videos library, so no folder tags
  musicVideos = "type:music_video";

  # a break after every episode: two ads, then a bumper. Ads are spots cut by
  # scripts/split-commercials.sh.
  breaks = {
    little = {
      ads = anyFolder [ "spots-preschool" ];
      # kid-shorts: songs, quick facts, home-made spots (scripts/tv-add.sh)
      bumpers = "${anyFolder [ "brain-breaks" "brain-break-tv" "ms-rachel" "kid-shorts" ]} OR ${musicVideos}";
    };
    big = {
      ads = anyFolder [ "spots-kids" "spots-halloween" ];
      bumpers = "${folder "monster-jam"} OR ${musicVideos}";
    };
    # mom_and_dad/commercials-split; no bumpers, and a longer break
    grown = {
      ads = anyFolder [ "spots-90s" "spots-2000s" "spots-october" ];
      adCount = 3;
    };
    # "coming attractions" between movies: VHS-tape preview reels, split
    cinema = {
      ads = folder "trailers";
      adCount = 3;
    };
  };

  channels = {
    "1" = { name = "Kids Movies"; query = "type:movie AND library_id:1"; };
    "2" = {
      name = "Little Kids";
      query = shows [ "Bluey" "Sesame Street" "Eureeka's Castle" "Frog & Toad" "Sago Mini Friends" "Toca Life Stories" ];
      filler = "little";
    };
    "3" = {
      name = "Big Kids";
      query = shows [ "Big City Greens" "Pokémon" "Regular Show" "Gravity Falls" ];
      filler = "big";
    };
    "4" = {
      name = "Retro Cartoons";
      query = shows [ "The Powerpuff Girls" "CatDog" "The Angry Beavers" "Aaahh!!! Real Monsters" ];
      filler = "big";
    };
    # kid_and_henry/channels/<folder>, filled by scripts/yt-curate.sh
    "5" = { name = "Craft Time"; query = folder "crafts"; };
    "6" = { name = "Brain Breaks"; query = folder "brain-break-tv"; };
    "7" = { name = "Story Time"; query = folder "story-time"; };
    "8" = { name = "Science!"; query = "${folder "science"} OR ${show "Bill Nye the Science Guy"}"; };
    # live-action older shows
    "9" = {
      name = "Retro";
      query = shows [ "Wishbone" "My Brother and Me" "Are You Afraid of the Dark?" ];
      filler = "big";
    };
    "10" = { name = "Español"; query = folder "spanish"; };

    # grown-ups: library 1 is kid_and_henry/movies
    "21" = { name = "Movie Night"; query = "type:movie AND NOT library_id:1"; filler = "cinema"; };
    "22" = { name = "Community"; query = show "Community"; filler = "grown"; };
    "23" = { name = "Letterkenny"; query = show "Letterkenny"; filler = "grown"; };
    "24" = { name = "The IT Crowd"; query = show "The IT Crowd"; filler = "grown"; };
    "25" = { name = "Spaced"; query = show "Spaced"; filler = "grown"; };
    "26" = { name = "Party Down"; query = show "Party Down"; filler = "grown"; };
    "27" = { name = "Better Off Ted"; query = show "Better Off Ted"; filler = "grown"; };
    "28" = { name = "Firefly"; query = show "Firefly"; order = "chronological"; filler = "grown"; };
    # by air date, so Ashes to Ashes picks up where Life on Mars ends
    "29" = {
      name = "Life on Mars";
      query = shows [ "Life on Mars" "Ashes to Ashes" ];
      order = "chronological";
      filler = "grown";
    };
    "30" = { name = "Game of Thrones"; query = show "Game of Thrones"; order = "chronological"; filler = "grown"; };
    "31" = { name = "House of the Dragon"; query = show "House of the Dragon"; order = "chronological"; filler = "grown"; };
    "32" = { name = "Euphoria"; query = show "Euphoria"; order = "chronological"; filler = "grown"; };
    # by air date, so each Untucked follows its episode
    "33" = {
      name = "Drag Race";
      query = shows [ "RuPaul's Drag Race" "RuPaul's Drag Race Untucked" ];
      order = "chronological";
      filler = "grown";
    };
  };

  # JSON is YAML. Marker keys (search, all) are "", not null: ErsatzTV maps
  # an empty scalar to null but reads a literal `null` as the string "null".
  # Real files, not linkFarm symlinks: the container can't
  # follow links into /nix/store.
  schedules = pkgs.runCommand "ersatztv-schedules" { } (
    "mkdir $out\n"
    + lib.concatStrings (
      lib.mapAttrsToList (n: c: ''
        cp ${pkgs.writeText "ersatztv-${n}.yaml" (builtins.toJSON {
          content = [{
            search = "";
            key = "main";
            inherit (c) query;
            order = c.order or "shuffle";
          }] ++ lib.optionals (c ? filler) (lib.mapAttrsToList (key: query: {
            search = "";
            inherit key query;
            order = "shuffle";
          }) (removeAttrs breaks.${c.filler} [ "adCount" ]));
          playout =
            (if c ? filler then [
              { count = 1; content = "main"; }
              # postroll folds the break into the episode's guide slot
              { count = breaks.${c.filler}.adCount or 2; content = "ads"; filler_kind = "postroll"; }
            ] ++ lib.optional (breaks.${c.filler} ? bumpers)
              { count = 1; content = "bumpers"; filler_kind = "postroll"; }
            else [
              { all = ""; content = "main"; }
            ])
            ++ [ { repeat = true; } ];
        })} $out/${n}.yaml
      '') channels
    )
  );
in
{
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";
  # CDI spec for the GTX 1660 so the container can use NVENC/NVDEC
  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.oci-containers.containers.ersatztv = {
    image = "ghcr.io/ersatztv/legacy:v26.11.3";
    ports = [ "127.0.0.1:${toString ports.ersatztv}:8409" ];
    environment.TZ = config.time.timeZone;
    volumes = [
      "/var/lib/ersatztv:/config"
      "/srv/Videos/kid_and_henry:/media/kid_and_henry:ro"
      "/srv/Videos/mom_and_dad:/media/mom_and_dad:ro"
      "${schedules}:/schedules:ro"
    ];
    extraOptions = [
      "--tmpfs=/transcode"
      "--device=nvidia.com/gpu=all"
    ];
  };

  # Channel logos, served for each channel's External Logo URL:
  # http://localhost:<ersatztv-logos>/<number>.png (1–10 are drawn: src/*.svg,
  # Nunito Black, rendered with rsvg-convert). Uploaded logos live in
  # ErsatzTV's artwork cache, and its hourly orphaned-artwork cleanup deleted
  # them twice; an external URL never enters the cache.
  systemd.services.ersatztv-logos = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString ports.ersatztv-logos} --bind 127.0.0.1 --directory ${./ersatztv-logos}";
      DynamicUser = true;
      Restart = "on-failure";
    };
  };

  systemd.tmpfiles.rules = [ "d /var/lib/ersatztv 0750 root root -" ];

  environment.persistence."/persist".directories = [
    "/var/lib/ersatztv"
    # podman image store: without it the impermanent root re-pulls every boot
    "/var/lib/containers"
  ];
}

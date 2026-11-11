# ErsatzTV (legacy, with the Next streaming engine) as a podman container:
# not packaged in nixpkgs. Web UI is published on localhost only — podman's
# port publishing can bypass the NixOS firewall, so a LAN bind would be open.
# Reach it with `ssh -L 8409:127.0.0.1:8409 desktop` from a tailnet host
# (roles/base.nix lets sshd forward only to this port).
#
# Channels play Sequential playouts generated from `channels` below, mounted
# at /schedules. ErsatzTV's API can't create channels or playouts, so each
# new number needs a one-time UI pass: Channels → Add (number, name, nvenc
# profile), then Playouts → Add → Sequential → /schedules/<number>.yaml.
# 1, 2 and 8 are visible to every Jellyfin user; 3, 4 and 9 are group
# `Big`, blocked for Kid under Parental Controls. Channels from mom_and_dad must get their
# own group, blocked for every kid user.
# Little Kids, Big Kids, Science! and Retro run by time of day (`dayparts`):
# calm shows and storybooks mornings and nights, livelier shows and brain
# breaks by day.
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

  # break pools, one item per step
  pools = {
    # Danny Go (assets/yt-curate/brain-breaks.txt) mixed with every song
    brainBreaks = "${anyFolder [ "brain-breaks" "brain-break-tv" "ms-rachel" "kid-shorts" ]} OR ${musicVideos}";
    msRachel = folder "ms-rachel";
    # songs, quick facts, home-made spots (scripts/tv-add.sh)
    kidShorts = folder "kid-shorts";
    music = musicVideos;
    # full kids-movie trailers (assets/yt-curate/previews.txt)
    previews = folder "previews";
    monsterJam = folder "monster-jam";
    # Vooks storybooks: the night-time break
    stories = folder "story-time";
    crafts = folder "crafts";
    # full episodes (~26 min), so a long break
    spanish = folder "spanish";
    # science songs and explainers (scripts/yt-curate.sh)
    science = folder "science";
    scienceMix = anyFolder [ "science" "crafts" "kid-shorts" ];
    # VHS-tape preview reels, split
    vhsTrailers = folder "trailers";
    songs = "${anyFolder [ "ms-rachel" "kid-shorts" ]} OR ${musicVideos}";
  };

  # Average minutes per item and episode counts, measured with ffprobe on
  # 2026-11-09 (Science! and Retro's on 2026-11-10), not counting extras/:
  # ErsatzTV never airs those, and Gravity Falls' 79 shorts made it look
  # 8 minutes long, so Big Kids ran hours late. They only size each
  # daypart's rounds; a stale number changes how long the top-off clip run
  # before the next block is, nothing else.
  poolMins = {
    brainBreaks = 3.2; msRachel = 2.0; kidShorts = 2.1; music = 2.9;
    previews = 2.5; monsterJam = 1.7; stories = 7.6; songs = 2.5;
    crafts = 5.7; spanish = 26.4; science = 3.8;
  };
  runtime = {
    "Bluey" = { eps = 141; mins = 7.3; };
    "Sesame Street" = { eps = 104; mins = 26.0; };
    "Eureeka's Castle" = { eps = 24; mins = 24.8; };
    "Frog & Toad" = { eps = 17; mins = 23.2; };
    "Sago Mini Friends" = { eps = 10; mins = 23.3; };
    "Toca Life Stories" = { eps = 42; mins = 4.0; };
    "LEGO Friends: The Next Chapter" = { eps = 51; mins = 16.2; };
    "Big City Greens" = { eps = 124; mins = 14.3; };
    "Pokémon" = { eps = 80; mins = 22.4; };
    "Regular Show" = { eps = 243; mins = 12.0; };
    "Gravity Falls" = { eps = 20; mins = 23.8; };
    "Wishbone" = { eps = 49; mins = 27.7; };
    "Are You Afraid of the Dark?" = { eps = 91; mins = 24.4; };
    "Bill Nye the Science Guy" = { eps = 100; mins = 23.0; };
    "My Brother and Me" = { eps = 13; mins = 24.5; };
  };

  # Energy tiers, a first guess until pacing is measured.
  little = {
    calm = [ "Frog & Toad" "Sago Mini Friends" "Eureeka's Castle" ];
    medium = [ "Sesame Street" "Toca Life Stories" ];
    lively = [ "Bluey" "LEGO Friends: The Next Chapter" ];
  };
  big = {
    calm = [ "Are You Afraid of the Dark?" "Wishbone" ];
    medium = [ "Pokémon" "Gravity Falls" "Regular Show" ];
    lively = [ "Big City Greens" ];
  };

  # A daypart plays `pattern` (episodes are "main", anything else a pool)
  # as many whole rounds as fit, then tops off to `until` with `pad`.
  # Blocks run 6 AM to 6 AM; the last one pads into tomorrow.
  dayparts = {
    little = [
      { name = "morning"; from = 6; until = 9; shows = little.calm ++ little.medium;
        pattern = [ "main" "stories" "main" "msRachel" "main" "stories" "main" "kidShorts" ];
        pad = "songs"; }
      { name = "day"; from = 9; until = 17; shows = little.calm ++ little.medium ++ little.lively;
        pattern = [ "main" "brainBreaks" "main" "msRachel" "main" "brainBreaks" "main" "kidShorts"
                    "main" "brainBreaks" "main" "music" "main" "msRachel" "main" "previews" ];
        pad = "brainBreaks"; }
      { name = "evening"; from = 17; until = 19; shows = little.calm ++ little.medium ++ [ "Bluey" ];
        pattern = [ "main" "kidShorts" "main" "stories" "main" "music" "main" "stories" ];
        pad = "songs"; }
      { name = "night"; from = 19; until = 30; shows = little.calm;
        pattern = [ "main" "main" "stories" "stories" ];
        pad = "stories"; }
    ];
    big = [
      { name = "morning"; from = 6; until = 9; shows = big.medium ++ [ "Wishbone" ];
        pattern = [ "main" "music" "main" "stories" ];
        pad = "music"; }
      { name = "day"; from = 9; until = 17; shows = big.medium ++ big.lively;
        pattern = [ "main" "music" "main" "previews" "main" "monsterJam" "main" "music"
                    "main" "previews" "main" "brainBreaks" ];
        pad = "music"; }
      { name = "evening"; from = 17; until = 19; shows = big.medium;
        pattern = [ "main" "music" "main" "previews" "main" "stories" ];
        pad = "music"; }
      { name = "night"; from = 19; until = 30; shows = big.calm ++ [ "Gravity Falls" ];
        pattern = [ "main" "main" "stories" "stories" ];
        pad = "stories"; }
    ];
    # Bill Nye is the show; the science clips, crafts and Español are breaks
    science = let nye = [ "Bill Nye the Science Guy" ]; in [
      { name = "morning"; from = 6; until = 9; shows = nye;
        pattern = [ "main" "science" "main" "spanish" ];
        pad = "scienceMix"; }
      { name = "day"; from = 9; until = 17; shows = nye;
        pattern = [ "main" "crafts" "main" "science" "main" "spanish" "main" "crafts" ];
        pad = "scienceMix"; }
      { name = "evening"; from = 17; until = 19; shows = nye;
        pattern = [ "main" "crafts" "main" "science" ];
        pad = "scienceMix"; }
      { name = "night"; from = 19; until = 30; shows = nye;
        pattern = [ "main" "main" "stories" "stories" ];
        pad = "stories"; }
    ];
    # Are You Afraid of the Dark? only after 5
    retro = let light = [ "Wishbone" "My Brother and Me" ]; in [
      { name = "morning"; from = 6; until = 9; shows = light;
        pattern = [ "main" "music" "main" "previews" ];
        pad = "music"; }
      { name = "day"; from = 9; until = 17; shows = light;
        pattern = [ "main" "music" "main" "previews" "main" "monsterJam" ];
        pad = "music"; }
      { name = "evening"; from = 17; until = 19; shows = light ++ [ "Are You Afraid of the Dark?" ];
        pattern = [ "main" "music" "main" "previews" ];
        pad = "music"; }
      { name = "night"; from = 19; until = 30; shows = [ "Are You Afraid of the Dark?" "Wishbone" ];
        pattern = [ "main" "main" "stories" "stories" ];
        pad = "stories"; }
    ];
  };

  # patterns for channels without dayparts
  patterns = {
    retro = [ "main" "music" "main" "previews" "main" "monsterJam" ];
    cinema = [ "main" "vhsTrailers" "vhsTrailers" "vhsTrailers" ];
    # no bumpers or music for mom_and_dad
    grown = [ "main" "main" "vhsTrailers" ];
  };

  channels = {
    # "coming attractions" to the next :00 or :30, so movies start on the clock
    "1" = { name = "Kids Movies"; query = "type:movie AND library_id:1"; padTo = { mins = 30; content = "previews"; }; };
    "2" = { name = "Little Kids"; dayparts = "little"; };
    "3" = { name = "Big Kids"; dayparts = "big"; };
    "4" = { name = "Retro Cartoons"; query = show "Aaahh!!! Real Monsters"; pattern = "retro"; };
    # kid_and_henry/channels/science, filled by scripts/yt-curate.sh
    "8" = { name = "Science!"; dayparts = "science"; };
    # live-action older shows
    "9" = { name = "Retro"; dayparts = "retro"; };
    # mom_and_dad/concerts: tagged `concerts` under a library rooted above it,
    # untagged in a library of its own (tags are folders below the root).
    # Placeholder while concerts are still being added: every one, shuffled.
    "10" = { name = "Concerts"; query = ''${folder "concerts"} OR library_name:"Concerts"''; };

    # grown-ups: library 1 is kid_and_henry/movies
    "21" = { name = "Movie Night"; query = "type:movie AND NOT library_id:1"; pattern = "cinema"; };
    "22" = { name = "Community"; query = show "Community"; pattern = "grown"; };
    "23" = { name = "Letterkenny"; query = show "Letterkenny"; pattern = "grown"; };
    "24" = { name = "The IT Crowd"; query = show "The IT Crowd"; pattern = "grown"; };
    "25" = { name = "Spaced"; query = show "Spaced"; pattern = "grown"; };
    "26" = { name = "Party Down"; query = show "Party Down"; pattern = "grown"; };
    "27" = { name = "Better Off Ted"; query = show "Better Off Ted"; pattern = "grown"; };
    "28" = { name = "Firefly"; query = show "Firefly"; order = "chronological"; pattern = "grown"; };
    # by air date, so Ashes to Ashes picks up where Life on Mars ends
    "29" = {
      name = "Life on Mars";
      query = shows [ "Life on Mars" "Ashes to Ashes" ];
      order = "chronological";
      pattern = "grown";
    };
    "30" = { name = "Game of Thrones"; query = show "Game of Thrones"; order = "chronological"; pattern = "grown"; };
    "31" = { name = "House of the Dragon"; query = show "House of the Dragon"; order = "chronological"; pattern = "grown"; };
    "32" = { name = "Euphoria"; query = show "Euphoria"; order = "chronological"; pattern = "grown"; };
    # by air date, so each Untucked follows its episode
    "33" = {
      name = "Drag Race";
      query = shows [ "RuPaul's Drag Race" "RuPaul's Drag Race Untucked" ];
      order = "chronological";
      pattern = "grown";
    };
  };

  search = key: query: order: { search = ""; inherit key query order; };
  poolsIn = steps: lib.unique (lib.filter (s: s != "main") steps);
  # "main" plays from `main`; a pool step is a postroll, folded into the
  # episode's guide slot
  step = main: s:
    if s == "main" then { count = 1; content = main; }
    else { count = 1; content = s; filler_kind = "postroll"; };
  clock = h: let h' = lib.mod h 24; in
    "${toString (if lib.mod h' 12 == 0 then 12 else lib.mod h' 12)}:00 ${if h' < 12 then "AM" else "PM"}";

  avgMins = names:
    let rs = map (n: runtime.${n}) names;
    in lib.foldl' (a: r: a + r.eps * r.mins) 0.0 rs / lib.foldl' (a: r: a + r.eps) 0 rs;
  # Whole rounds of the pattern that fit the block, then as many of its
  # leading steps as fit the rest, so the pad that tops off to the clock
  # stays short. Slack: a block that overruns starts the next one late.
  fit = b:
    let
      cost = s: if s == "main" then avgMins b.shows else poolMins.${s};
      perRound = lib.foldl' (a: s: a + cost s) 0.0 b.pattern;
      budget = 0.95 * (b.until - b.from) * 60;
      n = builtins.floor (budget / perRound);
      tail = (lib.foldl' (acc: s:
        if acc.full || acc.used + cost s > budget - n * perRound then acc // { full = true; }
        else { used = acc.used + cost s; steps = acc.steps ++ [ s ]; full = false; })
        { used = 0.0; steps = [ ]; full = false; } b.pattern).steps;
    in { inherit n tail; };

  daypartSchedule = blocks: {
    content =
      map (b: search b.name (shows b.shows) "shuffle") blocks
      ++ map (p: search p pools.${p} "shuffle")
        (lib.unique (lib.concatMap (b: poolsIn b.pattern ++ [ b.pad ]) blocks));
    sequence = map (b: { key = "${b.name}-round"; items = map (step b.name) b.pattern; }) blocks;
    # built as if it started at 6 AM today, so a reset lands mid-day in the right block
    reset = [ { wait_until = "6:00 AM"; tomorrow = false; rewind_on_reset = true; } ];
    # `tomorrow` is an NCalc expression, read only once the clock is past the
    # target. A block ending after midnight pads into tomorrow only while it's
    # still evening: one that overran past 6 AM stops instead of padding a
    # whole day (Big Kids aired 24 h of stories on 2026-11-11).
    playout = lib.concatMap (b: let f = fit b; in
      lib.optional (f.n > 0) { sequence = "${b.name}-round"; repeat = f.n; }
      ++ map (step b.name) f.tail
      ++ [ { pad_until = clock b.until; tomorrow = if b.until >= 24 then "now > 12" else false;
             content = b.pad; trim = true; filler_kind = "postroll"; } ]
    ) blocks ++ [ { repeat = true; } ];
  };

  plainSchedule = c:
    let
      steps = if c ? pattern then patterns.${c.pattern} else if c ? padTo then [ "main" ] else [ ];
      pad = lib.optional (c ? padTo) c.padTo.content;
    in {
      content = [ (search "main" c.query (c.order or "shuffle")) ]
        ++ map (p: search p pools.${p} "shuffle") (lib.unique (poolsIn steps ++ pad));
      playout =
        (if steps != [ ] then map (step "main") steps else [ { all = ""; content = "main"; } ])
        ++ lib.optional (c ? padTo) { pad_to_next = c.padTo.mins; content = c.padTo.content; trim = true; filler_kind = "postroll"; }
        ++ [ { repeat = true; } ];
    };

  # JSON is YAML. Marker keys (search, all) are "", not null: ErsatzTV maps
  # an empty scalar to null but reads a literal `null` as the string "null".
  # Real files, not linkFarm symlinks: the container can't
  # follow links into /nix/store.
  # ErsatzTV picks an instruction's type from its first key it recognises, and
  # both `repeat` and `sequence` are such keys. toJSON sorts keys, so
  # {repeat = 4; sequence = ...;} would load as a `repeat: <bool>` instruction
  # and fail; the sed moves `sequence` first.
  schedules = pkgs.runCommand "ersatztv-schedules" { } (
    "mkdir $out\n"
    + lib.concatStrings (
      lib.mapAttrsToList (n: c: ''
        sed -E 's/\{"repeat":([0-9]+),"sequence":("[^"]*")\}/{"sequence":\2,"repeat":\1}/g' \
          ${pkgs.writeText "ersatztv-${n}.yaml" (builtins.toJSON (
            if c ? dayparts then daypartSchedule dayparts.${c.dayparts} else plainSchedule c
          ))} > $out/${n}.yaml
      '') channels
    )
  );

  # logos plus wm/<number>.png: each logo in greyscale lifted toward white,
  # for the on-screen bug
  logos = pkgs.runCommand "ersatztv-logos" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
    mkdir -p $out/wm
    cp ${./ersatztv-logos}/*.png $out/
    for f in $out/*.png; do
      magick "$f" -channel RGB -colorspace Gray +level 55%,100% +channel "$out/wm/$(basename "$f")"
    done
  '';

  # Store files are all dated 1970, so http.server's Last-Modified let
  # browsers cache a logo for years and never see a redrawn one. Serve
  # uncacheable, without Last-Modified, ignoring If-Modified-Since.
  logoServer = pkgs.writeText "ersatztv-logo-server.py" ''
    import functools, http.server, sys

    class NoCache(http.server.SimpleHTTPRequestHandler):
        def send_head(self):
            del self.headers["If-Modified-Since"]
            return super().send_head()

        def send_header(self, k, v):
            if k != "Last-Modified":
                super().send_header(k, v)

        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

    port, root = int(sys.argv[1]), sys.argv[2]
    handler = functools.partial(NoCache, directory=root)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
  '';
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

  # /srv is a nofail mount, so nothing orders the container after it; started
  # first, podman binds the empty mountpoint and ErsatzTV scans an empty library
  systemd.services.podman-ersatztv.unitConfig.RequiresMountsFor = [ "/srv/Videos" ];

  # Off the boot transaction: WantedBy=multi-user.target made graphical.target
  # wait on the HDD mount plus container init, and nothing needs it at login.
  virtualisation.oci-containers.containers.ersatztv.autoStart = false;
  systemd.timers.podman-ersatztv = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnBootSec = "30s";
  };

  # Channel logos, served for each channel's External Logo URL:
  # http://localhost:<ersatztv-logos>/<number>.png (1–10 and 21 are drawn:
  # src/gen*.py writes src/*.svg, rendered with rsvg-convert). Uploaded logos live in
  # ErsatzTV's artwork cache, and its hourly orphaned-artwork cleanup deleted
  # them twice; an external URL never enters the cache.
  # Watermarks are the exception: ffmpeg runs inside the container, which
  # can't reach this host-local server, so each wm/<number>.png is uploaded
  # as that channel's Custom watermark. Cleanup spares any image a watermark
  # references.
  systemd.services.ersatztv-logos = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${logoServer} ${toString ports.ersatztv-logos} ${logos}";
      DynamicUser = true;
      Restart = "on-failure";
      CapabilityBoundingSet = "";
      PrivateDevices = true;
      ProtectHome = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged @resources" ];
      IPAddressAllow = "localhost";
      IPAddressDeny = "any";
      UMask = "0077";
    };
  };

  # Jellyfin reloads the guide once a day, so a playout reset left it showing
  # stale times until then. This starts its Refresh Guide once ErsatzTV's
  # guide changes and settles. State is lost on reboot; the first run after
  # just takes a new snapshot.
  systemd.services.ersatztv-guide-sync = {
    after = [ "podman-ersatztv.service" "jellyfin.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${../scripts/ersatztv-guide-sync.py}";
      Environment = [
        "XMLTV_URL=http://127.0.0.1:${toString ports.ersatztv}/iptv/xmltv.xml"
        "JELLYFIN_URL=http://127.0.0.1:${toString ports.jellyfin}"
      ];
      LoadCredential = "jellyfin-key:${config.sops.secrets.jellyfin_api_key.path}";
      DynamicUser = true;
      StateDirectory = "ersatztv-guide-sync";
      CapabilityBoundingSet = "";
      PrivateDevices = true;
      ProtectHome = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged @resources" ];
      # podman DNATs 127.0.0.1:<port> to the container before the cgroup egress
      # filter sees it, so localhost alone drops every SYN (connect timeout)
      IPAddressAllow = [ "localhost" "10.88.0.0/16" ];
      IPAddressDeny = "any";
    };
  };
  systemd.timers.ersatztv-guide-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "5min"; };
  };

  systemd.tmpfiles.rules = [ "d /var/lib/ersatztv 0750 root root -" ];

  environment.persistence."/persist".directories = [
    "/var/lib/ersatztv"
    # podman image store: without it the impermanent root re-pulls every boot
    "/var/lib/containers"
  ];
}

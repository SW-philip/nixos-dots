{ inputs, config, pkgs, lib, ... }:
let
  # The subset of hosts/retro-systems.nix this Surface's Intel iGPU can run —
  # ppsspp + libretro cores only, no heavy standalone emulators. The list
  # stays a local value (not the NFS mount) because NFS serves symlinks
  # as-is: a metadata.pegasus.txt symlinked into desktop's /nix/store (as
  # desktop's own tmpfiles rules do) dangles on any other host, since the
  # client resolves the target in its own store. See
  # docs/superpowers/specs/2026-08-05-surface-roms-nfs-migration-design.md.
  lightDirs = [ "nes" "snes" "genesis" "gba" "psx" "n64" "saturn" "psp" "dreamcast" ];
  retroSystems = builtins.filter (s: builtins.elem s.dir lightDirs)
    (import ../retro-systems.nix { inherit pkgs; });
  mkPegasusMetadata = import ../pegasus-metadata.nix { inherit pkgs; };
in
{
  ############################################################
  # Imports
  ############################################################
  imports = [
    ../../roles/base.nix
    ../../roles/secure-boot.nix
    ../../roles/niri.nix
    ../../identities/prepko.nix
    ../../identities/kid.nix
    ./surface.nix
    inputs.nixos-hardware.nixosModules.microsoft-surface-pro-intel
    inputs.sops-nix.nixosModules.sops
    ../../roles/sops-shared.nix
    ../../roles/ssh-known-hosts.nix
    ../../modules/greetd.nix
    ../../modules/retro-session.nix
    ../../modules/tailscale.nix
    ../../modules/niri-bridge.nix
    ../../modules/protonvpn.nix
    ../../modules/sqlch.nix
    ../../modules/bluetooth-idle-off.nix
    ./hardware.nix
    ./boot.nix
    ./features.nix
    ./msmtp.nix
    ./power.nix
    ./gpu-intel.nix
    ./impermanence.nix
    ./services.nix
  ];

  ############################################################
  # Host identity
  ############################################################
  networking.hostName = "SWsurface";

  ############################################################
  # Secrets (SOPS)
  ############################################################
  sops = {
    age.keyFile = "/persist/var/lib/sops-nix/key.txt";
    secrets.protonvpn_ny_conf = { sopsFile = ../../secrets/shared.yaml; };
    secrets.protonvpn_au_conf = { sopsFile = ../../secrets/shared.yaml; };
    secrets.protonvpn_ca_conf = { sopsFile = ../../secrets/shared.yaml; };
    # neededForUsers: decrypted before user creation, since mutableUsers = false.
    secrets.prepko_password_hash    = { sopsFile = ../../secrets/passwords.yaml; neededForUsers = true; };
    secrets.kid_password_hash = { sopsFile = ../../secrets/passwords.yaml; neededForUsers = true; };
  };

  ############################################################
  # ProtonVPN
  ############################################################
  protonvpn.configs = {
    protonvpn-ny = config.sops.secrets.protonvpn_ny_conf.path;
    protonvpn-au = config.sops.secrets.protonvpn_au_conf.path;
    protonvpn-ca = config.sops.secrets.protonvpn_ca_conf.path;
  };

  users.mutableUsers = false;
  # Per-host override of the base account declared in identities/prepko.nix.
  users.users.prepko.hashedPasswordFile = config.sops.secrets.prepko_password_hash.path;
  users.users.kid.hashedPasswordFile = config.sops.secrets.kid_password_hash.path;

  ############################################################
  # Retro — ROM storage. The ROM *data* is desktop's export, mounted
  # read-only over NFS at /srv/roms-nfs (not /srv/roms itself — see below).
  #
  # `soft` + a short mount-timeout means Pegasus just sees an empty
  # collection instead of hanging login when surface is away from home or
  # desktop's off. `x-systemd.automount` defers the actual NFS connection
  # until something first touches /srv/roms-nfs (e.g. Pegasus scanning at
  # session launch), so this never blocks boot either. `timeo` is in
  # deciseconds — timeo=30 is a 3s per-retry timeout, not 30s.
  ############################################################
  fileSystems."/srv/roms-nfs" = {
    device  = "100.64.0.1:/srv/roms";
    fsType  = "nfs";
    options = [
      "nfsvers=4.2" "ro" "soft" "timeo=30" "retrans=2" "_netdev" "nofail"
      "x-systemd.automount" "x-systemd.mount-timeout=10s"
    ];
  };

  # Shared RetroArch save store: desktop's /srv/game-saves, mounted read-WRITE
  # (unlike roms) so every account's saves land in one copy. Same
  # soft/nofail/automount options as the roms mount; away from home the dir is
  # simply absent and RetroArch writes locally (not auto-merged back).
  # See docs/superpowers/specs/2026-08-29-shared-retroarch-saves-design.md.
  fileSystems."/srv/game-saves" = {
    device  = "100.64.0.1:/srv/game-saves";
    fsType  = "nfs";
    options = [
      "nfsvers=4.2" "rw" "soft" "timeo=30" "retrans=2" "_netdev" "nofail"
      "x-systemd.automount" "x-systemd.mount-timeout=10s"
    ];
  };

  # NFSv4 only: no rpcbind/statd needed (NixOS enables rpcbind for any NFS use).
  # Revert: drop this line and the nfsvers option above.
  services.rpcbind.enable = lib.mkForce false;

  # Black Diamond advertises both A2DP Source and Sink. With WirePlumber's local
  # A2DP *sink* endpoints registered, the headset opens its own source stream
  # into them and bluez answers our playback connect with EBUSY, leaving the
  # card stuck on `audio-gateway` (a mic, no output sink). Role names are local:
  # keep a2dp_source (play out to headphones), drop a2dp_sink (receive from
  # phones). A per-device rule doesn't work; the endpoints are monitor-wide.
  services.pipewire.wireplumber.extraConfig."99-bt-roles" = {
    "monitor.bluez.properties"."bluez5.roles" = [ "a2dp_source" "hsp_hs" "hfp_hf" ];
  };

  ############################################################
  # Retro — /srv/roms itself stays a small LOCAL tree, not the NFS mount
  # directly. Each metadata.pegasus.txt has to resolve on the host reading
  # it, and desktop's own copy is a symlink into desktop's /nix/store —
  # NFS hands clients the symlink itself, not its target, so that link
  # dangles on surface. Pegasus's `directories:` field can point anywhere,
  # so surface generates its own local metadata pointing at the NFS data
  # path (/srv/roms-nfs/<dir>) instead of co-locating (`directories: .`)
  # the way desktop does. game_dirs.txt in home/kid is unchanged —
  # it still points at /srv/roms/<dir>.
  #
  # Owned root:root, not a per-app user — the retro kiosk account that used
  # to own this tree was retired (Pegasus is a system package now, and the
  # Retro kiosk session execs pegasus-fe by full store path regardless of
  # which account is logged in), and nothing writes into this tree at
  # runtime, it only holds generated metadata symlinks.
  ############################################################
  systemd.tmpfiles.rules =
    [ "d /srv/roms 0755 root root -" ]
    ++ (map (s: "d /srv/roms/${s.dir} 0755 root root -") retroSystems)
    ++ (map (s: "L+ /srv/roms/${s.dir}/metadata.pegasus.txt - - - - ${
      mkPegasusMetadata { inherit s; name = "pegasus-metadata-surface-${s.dir}"; directories = "/srv/roms-nfs/${s.dir}"; }
    }") retroSystems);

  # Scraped metadata (Skyscraper's skyscraper*.metadata.pegasus.txt plus any
  # hand-written sidecars from add-rom.sh) lives on desktop under /srv/roms/<dir>
  # with absolute `file:`/`assets.*` paths rooted at /srv/roms. Pegasus only
  # loads sidecars from the local collection dir here, and the ROMs and media
  # are at /srv/roms-nfs, so mirror each sidecar locally with the prefix
  # rewritten. Desktop stays the single source: rerunning skyscraper-deploy.sh
  # there is picked up within the hour (or 3 min after boot) with no rebuild.
  # A dead NFS mount leaves the previous mirror in place.
  systemd.services.pegasus-sidecar-sync =
    let
      dirs = lib.concatStringsSep " " (map (s: s.dir) retroSystems);
      script = pkgs.writeShellScript "pegasus-sidecar-sync" ''
        shopt -s nullglob
        for d in ${dirs}; do
          src=/srv/roms-nfs/$d dst=/srv/roms/$d
          ls "$src" >/dev/null 2>&1 || continue
          keep=()
          for f in "$src"/*.metadata.pegasus.txt; do
            b=$(basename "$f"); keep+=("$b")
            ${pkgs.gnused}/bin/sed 's#/srv/roms/#/srv/roms-nfs/#g' "$f" > "$dst/$b.tmp" \
              && mv "$dst/$b.tmp" "$dst/$b"
          done
          for f in "$dst"/*.metadata.pegasus.txt; do
            b=$(basename "$f")
            [[ " ${"$"}{keep[*]} " == *" $b "* ]] || rm -f "$f"
          done
        done
      '';
    in {
      description = "Mirror desktop's Pegasus sidecars with NFS paths";
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" ];
      # No wantedBy: a boot-time run always hit "Network is unreachable" (tailscale
      # isn't routing yet), so the timer's OnBootSec is the first real sync.
      serviceConfig = { Type = "oneshot"; ExecStart = script; };
    };
  systemd.timers.pegasus-sidecar-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "3min"; OnUnitActiveSec = "1h"; };
  };

  ############################################################
  # sixpair — one-time USB pairing tool for PS3 (Sixaxis/DualShock 3)
  # controllers. Run once per controller PER HOST: plug in via USB, run
  # `sixpair`, then the controller pairs over Bluetooth from then on
  # (kernel hid-sony handles it, no extra package needed for that part).
  # A pad already paired to desktop needs this step repeated here.
  #
  # pegasus-frontend — system-wide, not tied to any one user's home-manager
  # profile. The Retro kiosk session (modules/retro-session.nix) execs
  # pegasus-fe by full store path already, so this just makes it available
  # to launch manually from any account's regular session too.
  ############################################################
  environment.systemPackages = [ pkgs.sixpair pkgs.pegasus-frontend ];

  # Auto-login disabled for the moment — boot lands on the greeter
  # (default_session, from modules/greetd.nix) which forces a login and
  # pre-selects prepko + niri. Re-enable by restoring initial_session here:
  #   services.greetd.settings.initial_session = {
  #     command = "niri-session";
  #     user    = "kid";
  #   };

  ############################################################
  # Safe-DNS (Cloudflare for Families) for kid only. System DNS stays
  # whatever DHCP hands out, so prepko gets unfiltered Google. Their port-53
  # traffic is DNATed by uid; 1.1.1.3 also forces Google SafeSearch via CNAME.
  # ProtonVPN overrides DNS while connected; the real lock is the Firefox
  # allowlist in home/kid.
  ############################################################
  networking.firewall.extraCommands = ''
    iptables -w -t nat -N clem-safedns 2>/dev/null || iptables -w -t nat -F clem-safedns
    iptables -w -t nat -A clem-safedns -p udp --dport 53 -j DNAT --to-destination 1.1.1.3:53
    iptables -w -t nat -A clem-safedns -p tcp --dport 53 -j DNAT --to-destination 1.1.1.3:53
    iptables -w -t nat -D OUTPUT -m owner --uid-owner kid -j clem-safedns 2>/dev/null || true
    iptables -w -t nat -A OUTPUT -m owner --uid-owner kid -j clem-safedns
  '';
  networking.firewall.extraStopCommands = ''
    iptables -w -t nat -D OUTPUT -m owner --uid-owner kid -j clem-safedns 2>/dev/null || true
    iptables -w -t nat -F clem-safedns 2>/dev/null || true
    iptables -w -t nat -X clem-safedns 2>/dev/null || true
  '';

  nix.settings.max-jobs = "auto"; # grade:host-specific
  # distributedBuilds/buildMachines was tried here and abandoned: Lix's
  # machines-file SSH client is libssh2-in-process (confirmed via strace —
  # never spawns a real ssh, never reads known_hosts), so it fails host-key
  # verification and silently falls back to building locally regardless of
  # sshKey/publicHostKey being correct. `nrs` now uses `nixos-rebuild
  # --build-host` instead (profiles/prepko/surface.nix), which uses a real
  # ssh subprocess and just works.

  ############################################################
  # Swap / zram
  ############################################################
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

}

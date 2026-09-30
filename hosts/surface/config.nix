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

  # NFSv4 only: no rpcbind/statd needed (NixOS enables rpcbind for any NFS use).
  # Revert: drop this line and the nfsvers option above.
  services.rpcbind.enable = lib.mkForce false;

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
      pkgs.writeText "pegasus-metadata-surface-${s.dir}" ''
        collection: ${s.collection}
        shortname: ${s.shortname}
        extensions: ${s.extensions}
        launch: ${s.launch}
        directories: /srv/roms-nfs/${s.dir}
      ''
    }") retroSystems);

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
  # Safe-DNS (Cloudflare for Families) — system-wide; it's their device now.
  # ProtonVPN overrides DNS while connected; the real lock is the Firefox
  # allowlist in home/kid.
  ############################################################
  networking.networkmanager.insertNameservers = [ "1.1.1.3" "1.0.0.3" ];
  networking.nameservers = [ "1.1.1.3" "1.0.0.3" ];

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

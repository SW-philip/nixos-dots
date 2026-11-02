{ inputs, config, pkgs, lib, ... }:
let
  # Full emulated-system list (surface filters this to its iGPU subset).
  retroSystems = import ../retro-systems.nix { inherit pkgs; };
  mkPegasusMetadata = import ../pegasus-metadata.nix { inherit pkgs; };
  pegasusPc = import ./pegasus-pc.nix { inherit pkgs; };
  surfaceIp = (import ../inventory.nix).surface.ip;
in
{
  ############################################################
  # Imports
  ############################################################
  imports = [
    ../../modules/nixfetch.nix
    ../../modules/port-viewer.nix
    ../../modules/health-root.nix
    ../../roles/goodnight-activate.nix
    ../../roles/base.nix
    ../../roles/secure-boot.nix
    ../../roles/niri.nix
    ../../identities/prepko.nix
    ./desktop.nix

    ./hardware.nix
    ./boot.nix
    ./gpu-nvidia.nix

    ./services.nix
    ./iptv.nix
    inputs.sops-nix.nixosModules.sops
    ../../roles/sops-shared.nix
    ../../roles/ssh-known-hosts.nix
    ../../modules/protonvpn.nix
    ../../modules/jellyfin.nix
    ../../modules/jellyfin-whisper.nix
    ../../modules/ersatztv.nix
    ../../modules/sqlch.nix
    ../../modules/greetd.nix
    ../../modules/tailscale.nix
    ../../modules/syncthing.nix
    ../../modules/sunshine.nix
    ../../modules/retro-tiles.nix
    ../../modules/niri-bridge.nix
    ../../modules/btrbk.nix
    ../../modules/overnight-notify.nix
    ../../modules/transmission.nix
    ./myln.nix
    ./impermanence.nix
  ];

  ############################################################
  # Host identity
  ############################################################
  networking.hostName = "SWphil";
  greetd.greeting = "Welcome back, Phil.";

  # Auto-login straight into niri so sunshine.service (graphical-session.target,
  # modules/sunshine.nix) is always up for remote streaming, even right after a
  # cold boot with nobody at the console. greetd falls back to the normal
  # lix/dsa greeter (default_session) if this session ever exits. Same pattern
  # as the disabled block in hosts/surface/config.nix (kept off there
  # deliberately -- Kid's machine should still require a login).
  services.greetd.settings.initial_session = {
    command = "niri-session";
    user    = "prepko";
  };

  ############################################################
  # Secrets (SOPS)
  ############################################################
  sops = {
    defaultSopsFile = ../../secrets/shared.yaml;
    # Not the SSH host key: a 0644 copy of it sat in ~ for months, and regenerating
    # host keys would orphan every secret. Empty, not unset: the default derives
    # from services.openssh.hostKeys, i.e. that same key.
    age.keyFile = "/persist/var/lib/sops-nix/key.txt";
    # A missing key must fail loudly, not mint a new one that decrypts nothing.
    age.generateKey = false;
    age.sshKeyPaths = [ ];
    # neededForUsers: decrypted before user creation, since mutableUsers = false.
    secrets.prepko_password_hash = { sopsFile = ../../secrets/passwords.yaml; neededForUsers = true; };
    secrets.protonvpn_ny_conf = {};
    secrets.protonvpn_au_conf = {};
    secrets.protonvpn_ca_conf = {};
    # scrape (scripts/skyscraper-scrape.sh) appends this to a throwaway copy
    # of ~/.skyscraper/config.ini for the igdb pass, so the creds never sit
    # in that plain file or in Skyscraper's argv (`-u` would expose them).
    secrets.igdb_client_id = {};
    secrets.igdb_client_secret = {};
    templates."skyscraper-igdb.ini" = {
      owner = "prepko";
      content = ''
        [igdb]
        userCreds="${config.sops.placeholder.igdb_client_id}:${config.sops.placeholder.igdb_client_secret}"
      '';
    };
  };

  users.mutableUsers = false;
  users.users.prepko.hashedPasswordFile = config.sops.secrets.prepko_password_hash.path;

  ############################################################
  # Audio — BT headset priority (MAC specific to this machine)
  ############################################################
  services.pipewire.wireplumber.extraConfig."99-bt-headset" = { # grade:host-specific
    "monitor.bluez.rules" = [
      {
        matches = [{ "api.bluez5.address" = "00:00:00:00:00:02"; }];
        actions.update-props = {
          "priority.session" = 3000;
          "priority.driver"  = 3000;
        };
      }
    ];
  };

  # Nothing is plugged into the onboard optical S/PDIF out, but its stock
  # session priority (~736) outranks the NVIDIA HDMI sink (~696), so any time
  # WirePlumber has to auto-pick a sink — TV off at login, or Sunshine
  # exiting a stream with `sink-sunshine-stereo` left as a dangling default —
  # it lands on a port that never drains at 48kHz. RetroArch's synchronous
  # audio driver (and the sync-to-audio path in most standalone emulators)
  # then paces emulation off that dead sink and everything runs at ~half
  # speed with crackling audio. Dolphin is the lone exception; its cubeb
  # backend doesn't gate speed on the audio buffer. Drop the S/PDIF sink
  # below HDMI so the automatic fallback order is BT > HDMI > optical.
  # If a real optical device is ever connected, select it by hand — it
  # won't auto-switch anymore.
  services.pipewire.wireplumber.extraConfig."99-spdif-deprioritise" = { # grade:host-specific
    "monitor.alsa.rules" = [
      {
        matches = [{ "node.name" = "alsa_output.pci-0000_00_1f.3.iec958-stereo"; }];
        actions.update-props = {
          "priority.session" = 100;
          "priority.driver"  = 100;
        };
      }
    ];
  };

  ############################################################
  # ProtonVPN
  ############################################################
  protonvpn.configs = {
    protonvpn-ny = config.sops.secrets.protonvpn_ny_conf.path;
    protonvpn-au = config.sops.secrets.protonvpn_au_conf.path;
    protonvpn-ca = config.sops.secrets.protonvpn_ca_conf.path;
  };

  ############################################################
  # Swap / zram
  ############################################################
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };
  boot.kernel.sysctl = {
    "vm.swappiness" = 100;
    "vm.page-cluster" = 0;
    # rp_filter is left loose on purpose (tailscale and wireguard route
    # asymmetrically); the rest of the hardening sysctls live in roles/base.nix.
  };

  # No modem here; NetworkManager pulls ModemManager in by default.
  networking.modemmanager.enable = false;

  ############################################################
  # Retro — ROM storage + Pegasus collection metadata (one directory
  # and one metadata.pegasus.txt per emulated system). No dedicated
  # kiosk account or session anymore — prepko's own niri session runs
  # Pegasus directly (home/pegasus), same retirement already done for
  # surface's `retro` account. See surface's config.nix for the
  # matching NFS-client side of this.
  #
  # /srv/game-saves — shared RetroArch save store for every emulation
  # account on both hosts (desktop prepko, surface prepko/kid
  # NFS-mount it, see the export below). 0777, NOT sticky: accounts
  # must be able to create, overwrite AND rename-replace each other's
  # saves, and the sticky bit blocks cross-owner rename/unlink.
  # The A+ default ACL forces every file created underneath — local or via
  # the all_squash NFS client — group/other-writable regardless of the
  # writer's umask (RetroArch writes .srm 0644), so any account can
  # overwrite any save. Per-account ~/.config/retroarch/saves/ trees stay
  # in place as backups after the one-time scripts/game-save-merge.sh.
  # See docs/superpowers/specs/2026-08-29-shared-retroarch-saves-design.md.
  ############################################################
  systemd.tmpfiles.rules =
    [ "d /srv/roms 0755 prepko users -"
      "d /srv/game-saves 0777 root root -"
      "A+ /srv/game-saves - - - - d:group::rwx,d:other::rwx,d:mask::rwx,group::rwx,other::rwx,mask::rwx"
    ]
    ++ (map (s: "d /srv/roms/${s.dir} 0755 prepko users -") retroSystems)
    ++ (map (s: "L+ /srv/roms/${s.dir}/metadata.pegasus.txt - - - - ${mkPegasusMetadata { inherit s; }}") retroSystems)
    # pc isn't a retroSystems entry, so it needs its own `d`: a root-owned
    # /srv/roms/pc (left by a sudo copy) makes tmpfiles refuse the L+ below
    # as an unsafe path transition, and the PC collection silently vanishes.
    ++ [ "d /srv/roms/pc 0755 prepko users -"
         "L+ /srv/roms/pc/metadata.pegasus.txt - - - - ${pegasusPc}" ];

  networking.nftables.enable = true;

  # ConnectBot 1.9.1 on the G1 (Android 2.2) predates the -etm MACs; mkOptionDefault
  # appends to the NixOS defaults instead of replacing them.
  services.openssh.settings.Macs = lib.mkOptionDefault [ "hmac-sha2-256" ];
  users.users.prepko.openssh.authorizedKeys.keys = [
    ''from="10.0.0.0/24" ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY
  ];

  ############################################################
  # NFS export of /srv/roms for surface, which no longer stores its own
  # copy of the ROMs (docs/superpowers/specs/2026-08-05-surface-roms-nfs-migration-design.md).
  # Restricted to surface's Tailscale IP; all_squash + a fixed anonuid/anongid
  # (1002:984, arbitrary now that the `retro` account is gone — /srv/roms and
  # /srv/game-saves are both world-readable/writable so the exact numbers
  # don't matter) gives every NFS client a consistent identity regardless of
  # its own local uid/gid mapping. No firewall rule needed — tailscale0 is
  # opened on tailscale0 below.
  #
  # /srv/game-saves is exported read-WRITE (unlike roms) so surface's two
  # accounts write shared saves back to the single copy here. Same
  # all_squash identity — every NFS-written save lands 1002:984, and the
  # dir's default ACL keeps it overwritable by everyone.
  # See docs/superpowers/specs/2026-08-29-shared-retroarch-saves-design.md.
  ############################################################
  # v4 only: single TCP port 2049, no rpcbind/statd (NixOS turns rpcbind on for
  # any NFS server). Revert: remove the settings + mkForce lines.
  services.nfs.settings.nfsd = { vers2 = "n"; vers3 = "n"; vers4 = "y"; };
  services.rpcbind.enable = lib.mkForce false;
  # nfs-server Wants rpc-statd, which Requires rpcbind.socket; statd is v3-only.
  systemd.services.rpc-statd.enable = false;
  # /srv is nofail so local-fs.target doesn't wait for it, and its spinning-disk
  # mount takes ~3s: without this nfs-server came up ~1.4s before /srv existed.
  systemd.services.nfs-server.after = [ "srv.mount" ];
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 2049 ];
  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/roms ${surfaceIp}(ro,all_squash,anonuid=1002,anongid=984,no_subtree_check)
      /srv/game-saves ${surfaceIp}(rw,all_squash,anonuid=1002,anongid=984,no_subtree_check)
      # anonuid/gid are prepko (1000:users) so files surface writes here are owned by prepko
      /srv/prepko ${surfaceIp}(rw,all_squash,anonuid=1000,anongid=100,no_subtree_check)
    '';
  };

  # Builds the pi host (aarch64): its image and --build-host deploys run
  # aarch64 derivations through qemu-user.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Overnight jobs that report in (scripts/overnight.sh); the user-side ones are in the profile.
  overnight.notify.units = [ "btrbk-daily" "jellyfin-whisper" "nix-optimise" "nh-clean" "fstrim" "myln-diagnose" ];

}

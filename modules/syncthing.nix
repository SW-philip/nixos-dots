{ config, lib, pkgs, ... }:
let
  user = config.myConfig.user;
  home = "/home/${user}";
  inventory = import ../hosts/inventory.nix;
  ports = import ../hosts/ports.nix;
  self = if config.networking.hostName == inventory.desktop.nick then "desktop" else "surface";

  ids = {
    desktop = "DC4OU4E-7SEHYZG-3PBCEXA-ATTVWHM-RWANARJ-CF6UZDM-IGYOADZ-U6M6RQJ";
    surface = "TJUDMUW-5WC5LZV-4X4ROEJ-RIY7SQH-RV54LM7-HIVSXAK-MEY53CJ-Y7BSPAP";
  };
  peers = lib.mapAttrs (n: id: { name = inventory.${n}.nick; inherit id; inherit (inventory.${n}) ip; }) ids;
  others = lib.filterAttrs (n: _: n != self) peers;

  folders = [ "Documents" "Projects" ];

  # Projects carries build trees that must not travel; the rest only skip temp files.
  ignoreFor = n: pkgs.writeText "stignore-${n}" (
    lib.optionalString (n == "Projects") ''
      node_modules
      .venv
      target
      result
    '' + ''
      *.tmp
      *.part
      *.crdownload
      *.download
      .~lock.*#
    '');
in
{
  # syncthing copies these in only at start (syncthing-copy-keys), so a new key needs a restart.
  sops.secrets.syncthing_key  = { sopsFile = ../secrets/shared.yaml; key = "syncthing_${self}_key";  owner = user; restartUnits = [ "syncthing.service" ]; };
  sops.secrets.syncthing_cert = { sopsFile = ../secrets/shared.yaml; key = "syncthing_${self}_cert"; owner = user; restartUnits = [ "syncthing.service" ]; };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ ports.syncthing-sync ];

  services.syncthing = {
    enable = true;
    user = user;
    group = "users";
    dataDir = home;
    configDir = "${home}/.config/syncthing";
    guiAddress = "/run/syncthing/gui.sock";
    openDefaultPorts = false;
    key  = config.sops.secrets.syncthing_key.path;
    cert = config.sops.secrets.syncthing_cert.path;
    overrideDevices = true;
    overrideFolders = true;
    settings = {
      gui.unixSocketPermissions = "0600";
      options = {
        globalAnnounceEnabled = false;
        localAnnounceEnabled = false;
        relaysEnabled = false;
        natEnabled = false;
        urAccepted = -1;
        listenAddresses = [ "tcp://0.0.0.0:${toString ports.syncthing-sync}" ];
      };
      devices = lib.mapAttrs (_: p: { id = p.id; name = p.name; addresses = [ "tcp://${p.ip}:${toString ports.syncthing-sync}" ]; }) others;
      folders = lib.genAttrs folders (n: {
        path = "${home}/${n}";
        devices = lib.attrNames others;
        versioning = {
          type = "staggered";
          params = { cleanInterval = "3600"; maxAge = "31536000"; };
        };
      });
    };
  };

  # no empty ~/Sync default folder
  systemd.services.syncthing.environment.STNODEFAULTFOLDER = "1";

  # GUI/API on a socket only the service user can open: a TCP listener on
  # localhost would hand prepko's Syncthing (external versioning = exec) to any local user.
  systemd.services.syncthing.serviceConfig = {
    RuntimeDirectory = "syncthing";
    RuntimeDirectoryMode = "0700";
  };

  # syncthing-init polls the GUI socket until syncthing finishes starting; wanted
  # by multi-user.target it held the whole boot (~4s on desktop).
  systemd.services.syncthing-init.wantedBy = lib.mkForce [ ];
  systemd.services.syncthing.wants = [ "syncthing-init.service" ];

  # "-" keeps the mode of a directory that already exists.
  systemd.tmpfiles.rules = lib.concatMap (n: [
    "d ${home}/${n} - ${user} users -"
    "L+ ${home}/${n}/.stignore - - - - ${ignoreFor n}"
  ]) folders;
}

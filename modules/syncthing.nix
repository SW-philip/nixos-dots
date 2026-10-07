{ config, lib, pkgs, ... }:
let
  user = config.myConfig.user;
  home = "/home/${user}";
  self = if config.networking.hostName == "SWphil" then "desktop" else "surface";

  peers = {
    desktop = { name = "SWphil"; id = "4I2JNFZ-TV7TPBL-TGK7EQS-IXO2T76-OGJXBEI-WPPQ446-JLRMHIP-KTDKJQZ"; ip = "100.64.0.1"; };
    surface = { name = "SWsurface"; id = "MKDT6NZ-QZUGSFS-7TUSEXT-NHXU7KO-RBN2ZEQ-R6YOENF-WFG6XTR-XCPL2QP"; ip = "100.64.0.2"; };
  };
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
  sops.secrets.syncthing_key  = { sopsFile = ../secrets/shared.yaml; key = "syncthing_${self}_key";  owner = user; };
  sops.secrets.syncthing_cert = { sopsFile = ../secrets/shared.yaml; key = "syncthing_${self}_cert"; owner = user; };

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
        listenAddresses = [ "tcp://0.0.0.0:22000" ];
      };
      devices = lib.mapAttrs (_: p: { id = p.id; name = p.name; addresses = [ "tcp://${p.ip}:22000" ]; }) others;
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

  # "-" keeps the mode of a directory that already exists.
  systemd.tmpfiles.rules = lib.concatMap (n: [
    "d ${home}/${n} - ${user} users -"
    "L+ ${home}/${n}/.stignore - - - - ${ignoreFor n}"
  ]) folders;
}

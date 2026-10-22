{ lib, ... }:
{
  services.transmission = {
    enable = true;
    # Peer port stays closed on the LAN; RPC/web UI binds 127.0.0.1:9091.
    openPeerPorts = false;
    openRPCPort = false;
  };

  # Idle transmission keeps network and disk out of low-power states; start it
  # by hand (`systemctl start transmission`) when there is something to transfer.
  systemd.services.transmission.wantedBy = lib.mkForce [ ];

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/transmission"; user = "transmission"; group = "transmission"; mode = "0750"; }
  ];
}

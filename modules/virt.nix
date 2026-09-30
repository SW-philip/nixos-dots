{ pkgs, ... }:
{
  ############################################################
  # Libvirt / KVM
  ############################################################

  # libvirt 12.2.0 added LoadCredentialEncrypted in its upstream service file,
  # which requires /dev/tpmrm0. This machine has no TPM hardware, so we clear it.
  systemd.services.libvirtd.serviceConfig.LoadCredentialEncrypted = "";

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = false;
      swtpm.enable = true;
    };
  };

  programs.virt-manager.enable = true;

  virtualisation.spiceUSBRedirection.enable = true;

  # libvirtd.service (upstream libvirt unit, not ours) has
  # Wants=systemd-machined.service — it starts machined directly as a plain
  # service rather than via socket activation. systemd-machined.socket then
  # tries to bind on its own right after and finds the service already
  # active, so it refuses and logs "Failed to listen on Virtual Machine and
  # Container Registration Service Socket" on every boot/reload. Since
  # libvirtd always brings machined up anyway, the socket's on-demand
  # activation path is never used here — disable it to silence the noise.
  systemd.sockets.systemd-machined.enable = false;

  ############################################################
  # User access
  ############################################################
  users.users.prepko.extraGroups = [ "libvirtd" "kvm" ];

  ############################################################
  # Packages
  ############################################################
  environment.systemPackages = with pkgs; [
    virt-manager
    virt-viewer    # remote-viewer — SPICE client
    spice-gtk      # SPICE GTK widget / libraries
    virtiofsd      # host-side virtiofs daemon for shared folders
    qemu_kvm       # qemu-img, qemu-system-x86_64, etc.
  ];
}

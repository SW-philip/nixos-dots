{ config, pkgs, ... }:

{
  sops.secrets.msmtp_password = { sopsFile = ../../secrets/surface.yaml; };
  sops.secrets.msmtp_user = { sopsFile = ../../secrets/surface.yaml; };

  systemd.tmpfiles.rules = [
    "f /var/log/msmtp.log 0640 root root -"
  ];

  environment.systemPackages = [ pkgs.msmtp ];

  security.wrappers.sendmail = {
    source = "${pkgs.msmtp}/bin/msmtp";
    setuid = false;
    owner = "root";
    group = "root";
  };

  system.activationScripts.msmtpConfig = {
    deps = [ "setupSecrets" ];
    text = ''
      EMAIL="$(cat ${config.sops.secrets.msmtp_user.path})"
      PASS_PATH="${config.sops.secrets.msmtp_password.path}"
      cat > /etc/msmtprc << MSMTP_CONF
defaults
  auth on
  tls on
  tls_starttls on
  logfile /var/log/msmtp.log

account default
  host smtp.gmail.com
  port 587
  from $EMAIL
  user $EMAIL
  passwordeval cat $PASS_PATH
MSMTP_CONF
      chmod 600 /etc/msmtprc
    '';
  };
}

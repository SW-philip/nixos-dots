{ pkgs, ... }:
let
  # Fixed read-only command run as root via pkexec. Takes no arguments and
  # ignores its environment; the store path is immutable, so the polkit action
  # below can pin to it.
  helper = pkgs.writeShellScriptBin "port-viewer-root" ''
    exec ${pkgs.iproute2}/bin/ss -tulnpH
  '';
  action = "org.philnix.port-viewer.list";
in
{
  environment.systemPackages = [
    helper
    (pkgs.writeTextDir "share/polkit-1/actions/${action}.policy" ''
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
        "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
      <policyconfig>
        <action id="${action}">
          <description>List listening ports and the processes that own them</description>
          <message>Authentication is required to list every listening port and its process</message>
          <defaults>
            <allow_any>no</allow_any>
            <allow_inactive>no</allow_inactive>
            <allow_active>auth_admin</allow_active>
          </defaults>
          <annotate key="org.freedesktop.policykit.exec.path">${helper}/bin/port-viewer-root</annotate>
          <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
        </action>
      </policyconfig>
    '')
  ];

  # auth_admin (not _keep): every run asks again. Local, active, wheel only.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id === "${action}" &&
          !(subject.local && subject.active && subject.isInGroup("wheel"))) {
        return polkit.Result.NO;
      }
    });
  '';
}

# Baseline systemd sandbox for unprivileged services. Merge into serviceConfig
# and add only what the unit needs back: ReadWritePaths, RestrictAddressFamilies,
# a wider SystemCallFilter, etc.
{
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  PrivateDevices = true;
  NoNewPrivileges = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectKernelLogs = true;
  ProtectControlGroups = true;
  ProtectClock = true;
  ProtectHostname = true;
  ProtectProc = "invisible";
  ProcSubset = "pid";
  RestrictSUIDSGID = true;
  RestrictNamespaces = true;
  RestrictRealtime = true;
  LockPersonality = true;
  RemoveIPC = true;
  SystemCallFilter = [ "@system-service" ];
  SystemCallArchitectures = "native";
  CapabilityBoundingSet = [ "" ];
}

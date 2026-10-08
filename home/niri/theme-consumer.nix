{ lib }:
# One service + one path unit: the service runs `exec` whenever drmis finishes
# applying a theme. drmis writes theme.applied last (after every file is
# deployed), which is what makes it safe to read palette files from `exec`.
{ name, description, exec, environment ? { } }:
{
  service = {
    Unit.Description = description;
    Service = {
      Type = "oneshot";
      # "-": a failure is logged to the journal without failing the unit (drmis
      # used to ignore these pokes; an out-of-range mug would stay failed).
      ExecStart = "-${exec}";
      Environment = lib.mapAttrsToList (k: v: "${k}=${v}") environment;
    };
  };
  path = {
    Unit.Description = "Run ${name} when the drmis theme changes";
    Path.PathChanged = "%h/.local/state/theme.applied";
    Install.WantedBy = [ "default.target" ];
  };
}

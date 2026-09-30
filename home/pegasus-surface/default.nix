{ ... }:
{
  # Everything this profile runs comes from home/emulation-light, shared
  # verbatim with home/kid. Only the account wiring is prepko-specific
  # (which currently is nothing — pegasus-frontend is a surface system
  # package), so this is just the import.
  imports = [ ../emulation-light ];
}

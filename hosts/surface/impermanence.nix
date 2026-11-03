{ ... }:
{
  imports = [ ../../roles/impermanence.nix ];
  rootRollback.device = "/dev/mapper/cryptroot";

  environment.etc."machine-id" = {
    text = "24385d4f7c084e3c8d153b2a37073595\n";
    mode = "0444";
  };
}

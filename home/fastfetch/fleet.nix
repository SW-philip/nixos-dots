# Wraps the ff row scripts so palette colours (ANSI) arrive as env vars; scripts never hold a colour.
{ pkgs, lib, an, rs, p }:
let
  colourEnv = ''
    export FF_OK=${lib.escapeShellArg (an p.FIFTH)}
    export FF_WARN=${lib.escapeShellArg (an p.FERMATA)}
    export FF_BAD=${lib.escapeShellArg (an p.FORTE)}
    export FF_DIM=${lib.escapeShellArg (an p.REST)}
    export FF_RS=${lib.escapeShellArg rs}
  '';
  wrap = { name, file, inputs, pre ? "" }: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = inputs;
    text = pre + builtins.readFile file;
  };
in
{
  # host is passed as an argument by the fastfetch row, so one wrapper serves every host
  fleet = wrap {
    name = "ff-fleet";
    file = ../../scripts/ff-fleet.sh;
    inputs = with pkgs; [ jq coreutils ];
    pre = colourEnv;
  };
  sync = wrap {
    name = "ff-sync";
    file = ../../scripts/ff-sync.sh;
    inputs = with pkgs; [ jq coreutils ];
    pre = colourEnv;
  };
  sessionFrom = wrap {
    name = "ff-session-from";
    file = ../../scripts/ff-session.sh;
    inputs = with pkgs; [ jq coreutils gawk procps tailscale util-linux ];
    pre = "set -- from\n";
  };
  sessionOthers = wrap {
    name = "ff-session-others";
    file = ../../scripts/ff-session.sh;
    inputs = with pkgs; [ jq coreutils gawk procps tailscale util-linux ];
    pre = "set -- others\n";
  };
}

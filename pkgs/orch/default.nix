{ lib, python3Packages, git, gh, openssh, bubblewrap, passt, iproute2, coreutils, bash, gnugrep
, gnused, findutils, claude-code, codex }:

python3Packages.buildPythonApplication {
  pname = "orch";
  version = "0.1.0";
  src = ./.;
  pyproject = true;

  build-system = [ python3Packages.setuptools ];

  nativeCheckInputs = [ git ];
  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s tests -t . -v
    runHook postCheck
  '';

  # Only /nix/store entries of this PATH reach the sandboxed agents (see
  # orch/sandbox.py store_path), so every tool an agent shells out to is
  # listed here. openssh is for the orchestrator's own git pushes (git@ remotes);
  # passt provides pasta (the agents' network namespace), iproute2 answers
  # `ip route get` for the egress device.
  makeWrapperArgs = [
    "--prefix" "PATH" ":" (lib.makeBinPath [
      git gh openssh bubblewrap passt iproute2 coreutils bash gnugrep gnused findutils
      claude-code codex
    ])
  ];

  meta = {
    description = "Issue to reviewed draft PR with sandboxed coding agents";
    mainProgram = "orch";
  };
}

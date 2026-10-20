# Skip lix's test suites so a store-miss doesn't mean a long local build.
# Override both lix and nix (comma/nix-direnv depend on pkgs.nix).
# doCheck=false skips checkPhase (meson --suite=check); installCheckPhase=: skips installCheck.
# doInstallCheck alone is ignored by lix — both overrides are needed.
# Not in default.nix: must run after lix-module's overlay, so flake.nix
# adds it with lib.mkAfter.
# drop when: lix's checks pass reliably in the sandbox (or are cached).
{ ... }:
_: prev:
let
  noCheck = prev.lix.overrideAttrs (_: { doCheck = false; installCheckPhase = ":"; });
in
{ lix = noCheck; nix = noCheck; }

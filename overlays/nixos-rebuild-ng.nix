# nixos-rebuild-ng's own test suite asserts tempfile.gettempdir() stays
# under a hardcoded 45-byte limit, but Nix build-sandbox TMPDIRs
# (/nix/var/nix/b/<hash>/b) are always longer than that — so
# installCheckPhase (this package's tests run there, gated by
# doInstallCheck, not doCheck/checkPhase) fails on every build
# regardless of anything in this config. Broken in nixpkgs as of the
# 2026-07-14 channel bump.
# drop when: upstream fixes test_tmpdir.py.
{ ... }:
final: prev: {
  nixos-rebuild-ng = prev.nixos-rebuild-ng.overrideAttrs (old: {
    doInstallCheck = false;
  });
}

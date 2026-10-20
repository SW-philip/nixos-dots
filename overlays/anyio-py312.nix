# anyio 4.14.2's tests fail (test_tls_connectable, uvloop unraisable
# warnings) in the python3.12 set, which Hydra hasn't cached. Scoped to
# 3.12 on unstable (26.11pre sorts below 26.11, so gate at 26.10; surface's
# 26.05 keeps its cached builds): python3 (3.14) anyio is cached, and touching it rebuilds
# firefox/thunderbird/libreoffice from source.
# drop when: nixpkgs fixes anyio's python3.12 checks.
{ ... }:
final: prev: {
  pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ])
    ++ prev.lib.optional (prev.lib.versionAtLeast prev.lib.version "26.10") (_: pyPrev: prev.lib.optionalAttrs (pyPrev.python.pythonVersion == "3.12") {
      anyio = pyPrev.anyio.overridePythonAttrs (_: {
        doCheck = false;
        doInstallCheck = false;
      });
    });
}

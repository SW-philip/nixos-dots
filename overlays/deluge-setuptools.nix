# setuptools 82 dropped pkg_resources upstream. deluge 2.2.0 still does
# `import pkg_resources` in pluginmanagerbase.py and hasn't been patched
# in nixpkgs to stop, so deluged.service crashes on every start with
# ModuleNotFoundError: No module named 'pkg_resources'. nixpkgs kept
# setuptools_80 (last release that still ships pkg_resources) around for
# exactly this transition — swap it in for deluge's runtime python env.
# On channels where nixpkgs' default setuptools hasn't moved past 80.x
# yet (e.g. stable 26.05), the setuptools_80 alias doesn't exist yet —
# fall back to whatever setuptools already is in that case.
# drop when: deluge no longer imports pkg_resources (or nixpkgs patches it).
{ ... }:
final: prev: {
  deluge-gtk = prev.deluge-gtk.overridePythonAttrs (old: {
    propagatedBuildInputs =
      (prev.lib.filter (p: (p.pname or "") != "setuptools") old.propagatedBuildInputs)
      ++ [ (prev.python3Packages.setuptools_80 or prev.python3Packages.setuptools) ];
  });
  deluged = prev.deluged.overridePythonAttrs (old: {
    propagatedBuildInputs =
      (prev.lib.filter (p: (p.pname or "") != "setuptools") old.propagatedBuildInputs)
      ++ [ (prev.python3Packages.setuptools_80 or prev.python3Packages.setuptools) ];
  });
  deluge = final.deluge-gtk;
}

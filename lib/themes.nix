# Every theme under themes/<Family>/<slug>/, keyed by slug. Passed to all
# modules as `allThemes` (flake.nix), so consumers name a theme, never its path.
{ lib }:
let
  root = ../themes;
  loadTheme = family: folderName:
    let
      dir   = "${root}/${family}/${folderName}";
      files = builtins.readDir dir;

      nixName = builtins.head (builtins.attrNames (
        lib.filterAttrs (n: _: lib.hasPrefix "palette-" n && lib.hasSuffix ".nix" n) files));
      slug = lib.removeSuffix ".nix" (lib.removePrefix "palette-" nixName);

      shName = builtins.head (builtins.attrNames (
        lib.filterAttrs (n: _: lib.hasPrefix "palette-" n && lib.hasSuffix ".sh" n) files));

      wallpaper = let f = "wallpaper-${slug}.png";
                  in if files ? ${f} then "${dir}/${f}" else null;

      p = import "${dir}/${nixName}";
      isLight = p.isLight or ((p.TEMPO or "12px") == "13px");
    in
      # the folder is the mode: a light palette in Dark/ (or the reverse) is a filing mistake
      assert lib.assertMsg (isLight == (family == "Light"))
        "theme ${slug}: isLight = ${lib.boolToString isLight} but it lives in themes/${family}/";
      {
        inherit family slug wallpaper dir isLight;
        palette   = p;
        shContent = builtins.readFile "${dir}/${shName}";
      };

  familyDirs = lib.filterAttrs (_: t: t == "directory") (builtins.readDir root);

  familyThemes = family:
    let themeDirs = lib.filterAttrs (_: t: t == "directory")
                      (builtins.readDir "${root}/${family}");
    in lib.mapAttrs' (folder: _:
         let t = loadTheme family folder;
         in lib.nameValuePair t.slug t
       ) themeDirs;

in lib.foldlAttrs (acc: family: _: acc // familyThemes family) {} familyDirs

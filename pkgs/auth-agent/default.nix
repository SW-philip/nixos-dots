{ lib, stdenvNoCC, python3, gtk3, gtk4, gcr_3, polkit, iproute2, gobject-introspection
, wrapGAppsHook4, makeWrapper }:
let
  pythonEnv = python3.withPackages (ps: [ ps.pygobject3 ]);
in
stdenvNoCC.mkDerivation {
  pname = "auth-agent";
  version = "0.2.0";
  src = ./.;

  nativeBuildInputs = [ wrapGAppsHook4 gobject-introspection makeWrapper ];
  # gtk4 for the polkit agent, gtk3 + gcr_3 for the keyring prompter (gcr's dialog is GTK3)
  buildInputs = [ gtk3 gtk4 gcr_3 polkit pythonEnv ];

  installPhase = ''
    runHook preInstall
    install -Dm444 -t "$out/share/auth-agent" auth_agent.py keyring_prompter.py procinfo.py
    makeWrapper ${pythonEnv}/bin/python3 "$out/bin/auth-agent" \
      --add-flags "$out/share/auth-agent/auth_agent.py"
    makeWrapper ${pythonEnv}/bin/python3 "$out/bin/keyring-prompter" \
      --add-flags "$out/share/auth-agent/keyring_prompter.py" \
      --prefix PATH : ${lib.makeBinPath [ iproute2 ]}
    runHook postInstall
  '';

  meta = {
    description = "Polkit agent and keyring prompter whose dialogs name the process asking";
    platforms = lib.platforms.linux;
    mainProgram = "auth-agent";
  };
}

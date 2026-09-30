{ lib, appimageTools, fetchurl }:

let
  pname = "wiiu-downloader";
  version = "2.100";

  src = fetchurl {
    url = "https://github.com/Xpl0itU/WiiUDownloader/releases/download/v${version}/WiiUDownloader-Linux-x86_64.AppImage";
    hash = "sha256-Tz5c9VvWtDqs5tog1cDYX8pKYqecu29ed93ZUi9TSK4=";
  };

  appimageContents = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    install -Dm444 ${appimageContents}/usr/share/applications/WiiUDownloader.desktop -t $out/share/applications
    install -Dm444 ${appimageContents}/usr/share/icons/hicolor/512x512/apps/WiiUDownloader.png -t $out/share/icons/hicolor/512x512/apps
    substituteInPlace $out/share/applications/WiiUDownloader.desktop \
      --replace-fail 'Exec=WiiUDownloader' 'Exec=wiiu-downloader'
  '';

  meta = {
    description = "Wii U NUS downloader (titles/updates/DLC), alternative to Wii U USB Helper";
    homepage = "https://github.com/Xpl0itU/WiiUDownloader";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "wiiu-downloader";
  };
}

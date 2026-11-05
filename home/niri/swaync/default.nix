{ ... }:
{
  services.swaync.enable = true;

  # notify-send sends no icon, so swaync falls back to the missing-image glyph;
  # it looks the app icon up by app name.
  xdg.dataFile."icons/hicolor/scalable/apps/notify-send.svg".source = ../../../assets/notify-send.svg;
}

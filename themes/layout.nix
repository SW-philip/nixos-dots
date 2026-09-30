# themes/layout.nix — layout constants shared across all UI surfaces
# Import as `l` in default.nix; pass as `l` arg to config.kdl.nix and style.nix.
{
  gap          = 6;    # niri window gap
  borderW      = 2;    # niri window border — thin; flat vocabulary, accent on active only
  radiusSm     = 6;    # small: workspace pills, scrollbars, fuzzel
  radiusMd     = 8;    # medium: bar modules, entry fields, tooltips
  radiusLg     = 12;   # large: pill groups, lix-logout buttons
}

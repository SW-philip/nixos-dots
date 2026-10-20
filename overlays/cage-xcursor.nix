# cage 0.2.1 documents XCURSOR_THEME/XCURSOR_SIZE but never passes them to
# wlroots: the seat cursor is created with (NULL, 24), so wlroots loads the
# theme literally named "default" (→ black embedded fallback when absent)
# at a fixed 24px regardless of env. Make it honor the two env vars it
# already advertises so the greeter can use the posys cursor at a real size.
# drop when: cage's seat.c passes XCURSOR_THEME/XCURSOR_SIZE to wlroots.
{ ... }:
final: prev: {
  cage = prev.cage.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace seat.c \
        --replace-fail 'wlr_xcursor_manager_create(NULL, XCURSOR_SIZE)' \
                       'wlr_xcursor_manager_create(getenv("XCURSOR_THEME"), getenv("XCURSOR_SIZE") ? atoi(getenv("XCURSOR_SIZE")) : XCURSOR_SIZE)'
    '';
  });
}

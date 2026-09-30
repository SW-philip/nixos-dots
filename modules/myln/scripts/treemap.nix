# myln-treemap — on-demand system layout scan (never touches /nix/store)
# Run manually after the filesystem layout changes, then `embed` to re-index.
{ pkgs, cfg, lib, ... }:

let
  outFile = "${cfg.storePath}/system-map.md";

  pruneClause = lib.optionalString (cfg.treeExcludes != [])
    "\\( ${lib.concatMapStringsSep " -o " (e: "-name ${lib.escapeShellArg e}") cfg.treeExcludes} \\) -prune -o";

  scanRoot = root: ''
    if [[ -d ${lib.escapeShellArg root} ]]; then
      {
        echo
        echo "## ${root}"
        echo
      } >> "$OUT"
      find ${lib.escapeShellArg root} -mindepth 1 -maxdepth "$MAX_DEPTH" \
        ${pruneClause} -print \
        2>/dev/null | sort >> "$OUT"
    fi
  '';
in
{
  treemapScript = pkgs.writeShellApplication {
    name = "myln-treemap";
    runtimeInputs = with pkgs; [ coreutils findutils ];
    text = ''
      OUT="${outFile}"
      MAX_DEPTH="${toString cfg.treeMaxDepth}"

      mkdir -p "${cfg.storePath}"

      {
        echo "# System Map"
        echo
        echo "Generated $(date -Iseconds). On-disk layout outside /nix/store — use this to answer \"where is X located\" questions."
      } > "$OUT"

      ${lib.concatMapStrings scanRoot cfg.treeRoots}

      echo "Wrote $OUT"
    '';
  };
}

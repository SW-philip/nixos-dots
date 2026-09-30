# myln-pull + myln-pull-embed — model download helpers
{ pkgs, cfg, ... }:

{
  pullScript = pkgs.writeShellScriptBin "myln-pull" ''
    set -euo pipefail
    MODEL="${cfg.modelPath}"
    URL="${cfg.modelUrl}"

    if [[ -f "$MODEL" ]]; then
      echo "Model already present: $MODEL"
      exit 0
    fi

    mkdir -p "$(dirname $MODEL)"
    echo "Downloading model to $MODEL ..."
    ${pkgs.curl}/bin/curl -L --progress-bar "$URL" -o "$MODEL"
    echo "Done."
  '';

  pullEmbedScript = pkgs.writeShellScriptBin "myln-pull-embed" ''
    set -euo pipefail
    MODEL="${if cfg.embeddingModelPath != "" then cfg.embeddingModelPath else cfg.modelPath}"
    URL="${cfg.embeddingModelUrl}"

    if [[ -z "$URL" ]]; then
      echo "No embeddingModelUrl set — nothing to download" >&2
      exit 1
    fi

    if [[ -f "$MODEL" ]]; then
      echo "Embedding model already present: $MODEL"
      exit 0
    fi

    mkdir -p "$(dirname $MODEL)"
    echo "Downloading embedding model to $MODEL ..."
    ${pkgs.curl}/bin/curl -L --progress-bar "$URL" -o "$MODEL"
    echo "Done. Restart myln-embeddings.service and re-run embed."
  '';
}

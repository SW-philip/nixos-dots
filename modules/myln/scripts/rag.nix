# ask + embed — the two user-facing RAG tools
{ pkgs, cfg, pythonEnv, sqliteVec, embeddingUrl, ... }:

let
  vecExt = "${sqliteVec}/lib/vec0${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
in
{
  askScript = pkgs.writeShellScriptBin "ask" ''
    set -euo pipefail

    QUERY="$*"
    DB="${cfg.storePath}/vectors.db"
    VEC_EXT="${vecExt}"

    if [[ -z "$QUERY" ]]; then
      echo "Usage: ask <question>" >&2
      exit 1
    fi

    if [[ ! -f "$DB" ]]; then
      echo "No vector store at $DB" >&2
      echo "Run: embed  to index your docs first" >&2
      exit 1
    fi

    # Talk to the persistent myln-inference server (module.nix) rather than loading
    # our own copy of the model — it already holds the model on the GPU, and a second
    # llama-completion process requesting -ngl ${toString cfg.gpuLayers} on top of that
    # blows out VRAM (cudaMalloc failed: out of memory).
    if ! ${pkgs.curl}/bin/curl -sf --max-time 2 "http://127.0.0.1:${toString cfg.inferencePort}/health" > /dev/null 2>&1; then
      echo "myln-inference.service is not up — start it first: sudo systemctl start myln-inference" >&2
      exit 1
    fi

    CONTEXT=$(${pythonEnv}/bin/python3 ${../scripts/retrieve.py} \
      --db "$DB" \
      --ext "$VEC_EXT" \
      --query "$QUERY" \
      --top-k ${toString cfg.topK} \
      --embed-url "${embeddingUrl}")

    SYS_MSG="You are a NixOS configuration assistant. Answer the question using only the documentation excerpts below. Cite the source file when relevant. If the answer is not in the excerpts, say so."
    USER_MSG=$(printf 'Documentation:\n\n%s\n\nQuestion: %s' "$CONTEXT" "$QUERY")

    BODY=$(printf '%s' "$USER_MSG" | ${pkgs.jq}/bin/jq -Rs \
      --arg sys "$SYS_MSG" \
      --argjson n ${toString cfg.maxTokens} \
      --argjson t ${cfg.temperature} \
      '{
        messages: [
          {role: "system", content: $sys},
          {role: "user", content: .}
        ],
        max_tokens: $n,
        temperature: $t,
        stop: ["</s>", "<|end|>", "<|endoftext|>"]
      }')

    printf "\n\033[1m%s\033[0m\n\n" "$QUERY"

    ${pkgs.curl}/bin/curl -sf \
      -X POST "http://127.0.0.1:${toString cfg.inferencePort}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "$BODY" \
    | ${pkgs.jq}/bin/jq -r '.choices[0].message.content // empty'
  '';

  embedScript = pkgs.writeShellScriptBin "embed" ''
    set -euo pipefail

    DB="${cfg.storePath}/vectors.db"
    VEC_EXT="${vecExt}"
    DOC_PATHS="${pkgs.lib.concatStringsSep " " cfg.docPaths}"

    mkdir -p "${cfg.storePath}"

    ${pythonEnv}/bin/python3 ${../scripts/embed.py} \
      --db "$DB" \
      --ext "$VEC_EXT" \
      --embed-url "${embeddingUrl}" \
      --paths $DOC_PATHS \
      "$@"

    echo "Vector store updated: $DB"
  '';
}

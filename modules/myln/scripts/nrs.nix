# myln-nrs + myln-failures — nixos-rebuild wrapper with fail logging
{ pkgs, cfg, pythonEnv, sqliteVec, embeddingUrl, hostName, ... }:

let
  vecExt = "${sqliteVec}/lib/vec0${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
in
{
  nrsWrapScript = pkgs.writeShellApplication {
    name = "myln-nrs";
    runtimeInputs = with pkgs; [ coreutils gnugrep nh ];
    text = ''
      DB="${cfg.storePath}/vectors.db"
      VEC_EXT="${vecExt}"
      STDERR_FILE="${cfg.storePath}/last-stderr"
      CONTEXT_FILE="${cfg.storePath}/last-context"

      EXIT_CODE=0
      # nh's "auto" elevation strategy resolves sudo via its own internal
      # lookup rather than PATH order, and can land on the non-setuid
      # /run/current-system/sw/bin/sudo instead of the real wrapper. Pin it
      # explicitly to avoid "must be owned by uid 0" activation failures.
      nh os switch --hostname "${hostName}" --elevation-strategy /run/wrappers/bin/sudo "${cfg.gitDir}" \
        2> >(tee "$STDERR_FILE" >&2) || EXIT_CODE=$?

      if [[ $EXIT_CODE -eq 0 ]]; then
        if [[ -f "$DB" ]]; then
          ${pythonEnv}/bin/python3 ${../scripts/fail_log.py} \
            --db "$DB" --ext "$VEC_EXT" \
            --embed-url "${embeddingUrl}" \
            --target "${cfg.buildTarget}" \
            --git-dir "${cfg.gitDir}" \
            --resolve 2>/dev/null || true
        fi
      else
        if [[ -f "$DB" ]]; then
          QUERY=$(grep -E "error:|failed|cannot" "$STDERR_FILE" 2>/dev/null | head -5 | tr '\n' ' ' || true)
          if [[ -n "$QUERY" ]]; then
            ${pythonEnv}/bin/python3 ${../scripts/retrieve.py} \
              --db "$DB" --ext "$VEC_EXT" \
              --query "$QUERY" \
              --top-k 3 \
              --embed-url "${embeddingUrl}" \
              > "$CONTEXT_FILE" 2>/dev/null || true
          fi
          ${pythonEnv}/bin/python3 ${../scripts/fail_log.py} \
            --db "$DB" --ext "$VEC_EXT" \
            --embed-url "${embeddingUrl}" \
            --target "${cfg.buildTarget}" \
            --git-dir "${cfg.gitDir}" \
            --log \
            --stderr-file "$STDERR_FILE" \
            --exit-code "$EXIT_CODE" \
            --config-context-file "$CONTEXT_FILE" 2>/dev/null || true
        fi
        exit $EXIT_CODE
      fi
    '';
  };

  failLogScript = pkgs.writeShellScriptBin "myln-failures" ''
    DB="${cfg.storePath}/vectors.db"
    VEC_EXT="${vecExt}"

    if [[ ! -f "$DB" ]]; then
      echo "No vector store at $DB — run embed first" >&2
      exit 1
    fi

    ${pythonEnv}/bin/python3 ${../scripts/fail_log.py} \
      --db "$DB" \
      --ext "$VEC_EXT" \
      --embed-url "${embeddingUrl}" \
      --target "${cfg.buildTarget}" \
      --git-dir "${cfg.gitDir}" \
      "$@"
  '';
}

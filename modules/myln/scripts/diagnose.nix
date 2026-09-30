# myln-diagnose — daily LLM error analysis pass
{ pkgs, cfg, lib, pythonEnv, sqliteVec, embeddingUrl, inferenceUrl, hostName, ... }:

let
  reportsDir = "${cfg.storePath}/reports";
  vecExt = "${sqliteVec}/lib/vec0${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
in
{
  diagnoseScript = pkgs.writeShellApplication {
    name = "myln-diagnose";
    runtimeInputs = with pkgs; [ coreutils curl jq ];
    text = ''
      DATE=$(date +%Y-%m-%d)
      RAW="${reportsDir}/errors-raw-$DATE.txt"
      REPORT="${reportsDir}/report-$DATE.md"
      STATUS="${reportsDir}/status"

      COUNT=$(cat "$STATUS" 2>/dev/null || echo 0)

      if [[ "$COUNT" -eq 0 ]] || [[ ! -s "$RAW" ]]; then
        printf "# System Log Report %s\n\nNo errors found.\n" "$DATE" > "$REPORT"
        exit 0
      fi

      {
        printf "# System Log Report %s\n\n## Unique Errors (%s)\n\n\`\`\`\n" "$DATE" "$COUNT"
        cat "$RAW"
        printf "\`\`\`\n\n## Analysis\n\n"
      } > "$REPORT"

      if ! curl -sf --max-time 2 "http://127.0.0.1:${toString cfg.inferencePort}/health" > /dev/null 2>&1; then
        printf "\n_(inference server not running — start myln-inference.service first)_\n" >> "$REPORT"
        exit 0
      fi

      ERRORS=$(head -${toString cfg.diagnosisMaxErrors} "$RAW")

      # retrieve relevant config context — use first 5 errors as the semantic query
      CONFIG_CONTEXT=""
      DB="${cfg.storePath}/vectors.db"
      VEC_EXT="${vecExt}"
      if [[ -f "$DB" ]]; then
        QUERY=$(head -5 "$RAW" | tr '\n' ' ')
        CONFIG_CONTEXT=$(${pythonEnv}/bin/python3 ${../scripts/retrieve.py} \
          --db "$DB" \
          --ext "$VEC_EXT" \
          --query "$QUERY" \
          --top-k 3 \
          --embed-url "${embeddingUrl}" 2>/dev/null || true)
      fi

      if [[ -n "$CONFIG_CONTEXT" ]]; then
        USER_MSG=$(printf 'Relevant excerpts from the system config:\n\n%s\n\nToday'"'"'s journal errors:\n\n%s\n\nFor each error, briefly state the likely cause (reference the config where relevant) and whether action is needed.' \
          "$CONFIG_CONTEXT" "$ERRORS")
      else
        USER_MSG=$(printf 'Today'"'"'s journal errors:\n\n%s\n\nFor each error, briefly state the likely cause and whether action is needed.' \
          "$ERRORS")
      fi

      SYS_BASE="You are a NixOS systems analyst for host '${hostName}'. For each journal error state: (1) the likely root cause, (2) whether action is needed, and (3) the specific config file or service to check if relevant. Do not invent paths, options, or values that are not present in the provided context."
      ${lib.optionalString (cfg.diagnoseSystemContext != "") ''
        SYS_MSG=$(printf '%s\n\n%s' "$SYS_BASE" ${lib.escapeShellArg cfg.diagnoseSystemContext})
      ''}
      ${lib.optionalString (cfg.diagnoseSystemContext == "") ''
        SYS_MSG="$SYS_BASE"
      ''}

      BODY=$(printf '%s' "$USER_MSG" | jq -Rs \
        --arg sys "$SYS_MSG" \
        --argjson n ${toString cfg.diagnosisMaxTokens} \
        --argjson t ${cfg.temperature} \
        '{
          messages: [
            {role: "system", content: $sys},
            {role: "user", content: .}
          ],
          max_tokens: $n,
          temperature: $t,
          repeat_penalty: 1.15,
          frequency_penalty: 0.3,
          top_p: 0.9,
          stop: ["</s>", "<|end|>", "<|endoftext|>"]
        }')

      timeout ${toString cfg.diagnoseTimeout} \
        curl -sf \
          -X POST "http://127.0.0.1:${toString cfg.inferencePort}/v1/chat/completions" \
          -H "Content-Type: application/json" \
          -d "$BODY" \
      | jq -r '.choices[0].message.content // empty' >> "$REPORT" \
        || printf "\n_(diagnosis timed out or failed)_\n" >> "$REPORT"
    '';
  };
}

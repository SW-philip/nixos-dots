# myln-diagnose — daily LLM error analysis pass
{ pkgs, cfg, lib, pythonEnv, sqliteVec, embeddingUrl, inferenceUrl, hostName, ... }:

let
  reportsDir = "${cfg.storePath}/reports";
  vecExt = "${sqliteVec}/lib/vec0${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";

  knownFile = pkgs.writeText "myln-known-issues.tsv"
    (lib.concatMapStrings (k: "${k.pattern}\t${k.verdict}\t${k.note}${lib.optionalString (k.clearedBy != null) "\t${k.clearedBy}"}\n") cfg.knownIssues);
in
{
  diagnoseScript = pkgs.writeShellApplication {
    name = "myln-diagnose";
    runtimeInputs = with pkgs; [ coreutils curl gnused jq gawk systemd ];
    text = ''
      # The day to diagnose: today by default, or any `date -d` string. The timer
      # passes "yesterday" because it fires at midnight, when today's file is still empty.
      DATE=$(date -d "''${1:-today}" +%Y-%m-%d)
      RAW="${reportsDir}/errors-raw-$DATE.txt"
      REPORT="${reportsDir}/report-$DATE.md"

      # Long lines (a sudo entry carries the whole environment) bury the report.
      trunc() { awk '{ print (length($0) > 200 ? substr($0, 1, 199) "…" : $0) }'; }

      COUNT=$(wc -l < "$RAW" 2>/dev/null | tr -d ' ' || true)
      COUNT=''${COUNT:-0}

      if [[ "$COUNT" -eq 0 ]] || [[ ! -s "$RAW" ]]; then
        printf "# System Log Report %s\n\nNo errors found.\n" "$DATE" > "$REPORT"
        exit 0
      fi

      {
        printf "# System Log Report %s\n\n## Unique Errors (%s)\n\n\`\`\`\n" "$DATE" "$COUNT"
        trunc < "$RAW"
        printf "\`\`\`\n\n"
      } > "$REPORT"

      # Collapse the raw lines: strip PIDs, store hashes and long numbers so repeats of
      # one event compare equal, then count them. Most frequent first.
      NORM=$(mktemp); KNOWN=$(mktemp); REST=$(mktemp)
      trap 'rm -f "$NORM" "$KNOWN" "$REST"' EXIT
      sed -E \
          -e 's/\[ *[0-9]+\]/[]/g' \
          -e 's#/nix/store/[a-z0-9]{32}-#/nix/store/…-#g' \
          -e 's/\b[0-9]{4,}\b/N/g' "$RAW" \
        | sort | uniq -c | sort -rn \
        | sed -E 's/^ *1 //; s/^ *([0-9]+) /(x\1) /' > "$NORM"

      # Known issues are answered from the table; only the rest goes to the model.
      ${pythonEnv}/bin/python3 ${../scripts/triage.py} split \
        --lines "$NORM" --table ${knownFile} --table "${cfg.storePath}/known-issues.tsv" \
        --since "$DATE 00:00:00" --known-out "$KNOWN" --rest-out "$REST"

      if [[ -s "$KNOWN" ]]; then
        { printf '## Known issues\n\n'; cat "$KNOWN"; printf '\n'; } >> "$REPORT"
      fi

      if [[ ! -s "$REST" ]]; then
        printf '## Unexplained\n\nNothing outside the known issues.\n' >> "$REPORT"
        exit 0
      fi
      printf '## Unexplained\n\n' >> "$REPORT"

      if ! curl -sf --max-time 120 "http://127.0.0.1:${toString cfg.inferencePort}/health" > /dev/null 2>&1; then
        printf "\n_(inference server did not come up — check myln-inference.service)_\n" >> "$REPORT"
        exit 0
      fi

      ERRORS=$(head -${toString cfg.diagnosisMaxErrors} "$REST" | trunc)

      # Query retrieval with the commonest distinct errors, without the count prefix.
      QUERY=$(printf '%s\n' "$ERRORS" | head -5 | sed -E 's/^\(x[0-9]+\) //' | tr '\n' ' ')

      CONFIG_CONTEXT=""
      DB="${cfg.storePath}/vectors.db"
      VEC_EXT="${vecExt}"
      if [[ -f "$DB" ]]; then
        CONFIG_CONTEXT=$(${pythonEnv}/bin/python3 ${../scripts/retrieve.py} \
          --db "$DB" \
          --ext "$VEC_EXT" \
          --query "$QUERY" \
          --top-k 3 \
          --embed-url "${embeddingUrl}" 2>/dev/null || true)
      fi

      FORMAT='Reply with one line per error as: "- <subsystem>: <cause in one short sentence>. Check: <command or file>". Example: "- pipewire: a Bluetooth sink dropped while streaming. Check: bluetoothctl info". Maximum 30 words per line. Merge errors with the same cause. Name a file only if it appears in the excerpts; otherwise use a command such as journalctl -b -u <unit> or systemctl status <unit>, or write "no action". If you do not know the cause write "unknown". This is NixOS: /etc files are generated from the flake, so never tell the user to edit them.'

      NERR=$(printf '%s\n' "$ERRORS" | wc -l)
      FORMAT=$(printf 'There are %s errors below. Write exactly %s lines, one per error.\n%s' "$NERR" "$NERR" "$FORMAT")

      if [[ -n "$CONFIG_CONTEXT" ]]; then
        USER_MSG=$(printf 'Relevant excerpts from the system config:\n\n%s\n\nToday'"'"'s journal errors ((xN) = repeated N times):\n\n%s\n\n%s' \
          "$CONFIG_CONTEXT" "$ERRORS" "$FORMAT")
      else
        USER_MSG=$(printf 'Today'"'"'s journal errors ((xN) = repeated N times):\n\n%s\n\n%s' \
          "$ERRORS" "$FORMAT")
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
          chat_template_kwargs: {enable_thinking: false},
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
      | jq -r '.choices[0].message.content // empty' \
      | awk '!seen[$0]++' \
      | ${pythonEnv}/bin/python3 ${../scripts/triage.py} check-paths >> "$REPORT" \
        || printf "\n_(diagnosis timed out or failed)_\n" >> "$REPORT"
    '';
  };
}

# myln-harvest — hourly journal log collector
{ pkgs, cfg, lib, ... }:

let
  reportsDir = "${cfg.storePath}/reports";

  ignoreUnitsAwk = lib.optionalString (cfg.logIgnoreUnits != [])
    ''
      unitName = unit; gsub(/:$/, "", unitName)
      if (unitName ~ /^(${lib.concatStringsSep "|" cfg.logIgnoreUnits})$/) next'';

  ignorePatternGreps = lib.concatMapStrings
    (p: "  | grep -vE ${lib.escapeShellArg p} \\\n")
    cfg.logIgnorePatterns;
in
{
  harvestScript = pkgs.writeShellApplication {
    name = "myln-harvest";
    runtimeInputs = with pkgs; [ coreutils findutils gawk gnugrep systemd ];
    text = ''
      DATE=$(date +%Y-%m-%d)
      RAW="${reportsDir}/errors-raw-$DATE.txt"
      STATUS="${reportsDir}/status"
      CURSOR_FILE="${reportsDir}/cursor-$DATE"

      mkdir -p "${reportsDir}"

      if [[ -f "$CURSOR_FILE" ]] && [[ -s "$CURSOR_FILE" ]]; then
        RANGE_ARG="--after-cursor=$(cat "$CURSOR_FILE")"
      else
        RANGE_ARG="--since=${cfg.logSince}"
      fi

      # clean up cursor files older than 7 days
      find "${reportsDir}" -name "cursor-*" -mtime +7 -delete 2>/dev/null || true

      TEMP=$(mktemp)

      journalctl \
        "$RANGE_ARG" \
        --until="now" \
        --priority="${cfg.logPriority}" \
        --no-pager \
        --output=short \
        2>/dev/null \
      | awk '
          /^-- /  { next }
          NF < 6  { next }
          {
            unit = $5
            gsub(/\[[0-9]+\]/, "", unit)
            ${ignoreUnitsAwk}
            msg = ""
            for (i = 6; i <= NF; i++) msg = msg (i > 6 ? " " : "") $i
            print unit " " msg
          }
        ' \
      | grep -v "Ignoring duplicate name" \
      | grep -vE "^\+ 0x[0-9a-f]+\)$" \
      | grep -vE "^[A-Za-z0-9_-]+: \[20[0-9]{2}/[0-9]{2}/[0-9]{2}" \
      | grep -vE "^\S+ (x86-64|aarch64|Got sig\[)" \
      ${ignorePatternGreps}\
      > "$TEMP" || true

      if [[ -f "$RAW" ]]; then
        sort -u "$RAW" "$TEMP" > "$RAW.new" && mv "$RAW.new" "$RAW"
      else
        sort -u "$TEMP" > "$RAW"
      fi
      rm -f "$TEMP"

      journalctl -n 0 --show-cursor 2>/dev/null \
        | awk '/^-- cursor:/ { print substr($0, 12) }' \
        > "$CURSOR_FILE" || true

      # remove the old undated cursor file if it still exists from before this fix
      rm -f "${reportsDir}/cursor"

      COUNT=$(wc -l < "$RAW" 2>/dev/null | tr -d ' ')
      printf '%s\n' "''${COUNT:-0}" > "$STATUS"
    '';
  };
}

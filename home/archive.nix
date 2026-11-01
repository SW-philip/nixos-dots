{ pkgs, lib, config, osConfig, ... }:
let
  archive = "${config.home.homeDirectory}/archive";
  # sops, not literals: make-public.sh's leak gate rejects any gmail address in the tree.
  secret = name: osConfig.sops.secrets.${name}.path;

  overnight = import ../modules/overnight-package.nix { inherit pkgs; };

  # Re-runnable: icloudpd skips anything already on disk.
  icloud-pull = pkgs.writeShellApplication {
    name = "icloud-pull";
    runtimeInputs = [ pkgs.icloudpd ];
    text = ''
      exec icloudpd --username "$(cat ${secret "icloud_apple_id"})" --directory /srv/prepko/Pictures/icloud "$@"
    '';
  };

  # The OAuth token rclone rewrites on refresh stays in rclone.conf, encrypted with a
  # sops-held password; the client id/secret come from sops through env so they never
  # land in that file.
  rcloneEnv = ''
    RCLONE_DRIVE_CLIENT_ID=$(cat ${secret "gdrive_client_id"})
    RCLONE_DRIVE_CLIENT_SECRET=$(cat ${secret "gdrive_client_secret"})
    export RCLONE_DRIVE_CLIENT_ID RCLONE_DRIVE_CLIENT_SECRET
    export RCLONE_PASSWORD_COMMAND="cat ${secret "rclone_config_pass"}"
  '';

  # Google accounts drive-pull archives, by alias: never the address (make-public.sh's leak
  # gate). "main" keeps the remote it was first set up as; the rest are gdrive-<alias>.
  driveAccounts = [ "main" "old" "alt" ];

  # `copy`, never `sync`: deleting from Drive must not touch the local copy, so Drive can
  # be freed after the pull. Each account lands in /srv/prepko/Drive/<alias>/{mine,shared}.
  drive-pull = pkgs.writeShellApplication {
    name = "drive-pull";
    runtimeInputs = with pkgs; [ rclone jq coreutils gnugrep ];
    text = rcloneEnv + ''
      remote() { if [ "$1" = main ]; then echo gdrive; else echo "gdrive-$1"; fi; }

      if [ "''${1:-}" = setup ]; then
        account=''${2:-main}
        r=$(remote "$account")
        rclone config encryption check 2>/dev/null || rclone config encryption set
        echo "sign in as the Google account you call '$account'" >&2
        # stdout gets the finished remote, live token included; the sign-in link is on stderr.
        # Recreated rather than reconnected: reconnect prompts on the stdout hidden here.
        if rclone listremotes | grep -qxF "$r:"; then rclone config delete "$r"; fi
        exec rclone config create "$r" drive scope=drive.readonly >/dev/null
      fi

      # Drive allows same-named files in one folder; `copy` keeps one and skips the rest.
      # Fetch every member of such a group by ID as "name (<last 8 of id>).ext" so none is lost.
      # Called under `||`, where errexit is off, so every failure returns explicitly.
      args=("$@")
      pull() {
        local r=$1 dest=$2 rc=0 path id ext
        shift 2
        local extra=("$@")
        # drive-prune apply writes these; what it pruned must not come back.
        mkdir -p "$dest" && touch "$dest/.prune-exclude" "$dest/.prune-ids" "$dest/.export-fallback" || return 1
        # drive-prune purge stages files in a drive-prune-trash-* folder seconds before
        # trashing it; a pull racing a failed purge mustn't archive them.
        pull_copy() {
          rclone copy "$r:" "$dest" --exclude-from "$dest/.prune-exclude" --exclude-from "$dest/.export-fallback" \
            --exclude "/drive-prune-trash-*/**" "''${extra[@]}" "''${args[@]}" 2>&1 >&3 | tee "$dest/.pull.log" >&2
        } 3>&1
        # drive-prune maps local files back to Drive IDs from this listing.
        rclone lsjson -R --files-only "$r:" "$@" > "$dest/.listing.json" || return 1
        if ! pull_copy; then
          # Google refuses a big Doc's docx/xlsx/pptx export (HTTP 413) while its OpenDocument
          # export works: fetch that instead and leave the path out of every later copy.
          while IFS= read -r path; do
            case ''${path##*.} in docx) ext=odt ;; xlsx) ext=ods ;; pptx) ext=odp ;; *) continue ;; esac
            id=$(jq -r --arg p "$path" 'first(.[] | select(.Path == $p) | .ID) // empty' "$dest/.listing.json")
            [ -n "$id" ] || continue
            # shellcheck disable=SC2001 # escapes each glob char; ''${//} can't backreference
            rclone backend copyid "$r:" "$id" "$dest/''${path%.*}.$ext" "$@" --drive-export-formats odt,ods,odp \
              && printf '/%s\n' "$(sed 's/[][\\*?{}]/\\&/g' <<<"$path")" >> "$dest/.export-fallback"
          done < <(sed -n 's/^.*ERROR : \(.*\): Failed to copy: .*response code 413.*$/\1/p' "$dest/.pull.log" | sort -u)
          pull_copy || return 1
        fi
        while IFS=$'\t' read -r id path; do
          base=''${path##*/} dir=''${path%"$base"}
          if [[ $base == *.* ]]; then
            out="$dest/$dir''${base%.*} (''${id: -8}).''${base##*.}"
          else
            out="$dest/$dir$base (''${id: -8})"
          fi
          if grep -qxF -- "$id" "$dest/.prune-ids"; then continue; fi
          [ -e "$out" ] || rclone backend copyid "$r:" "$id" "$out" || rc=1
        # rclone IDs a shortcut "<target>\t<shortcut>"; copyid can't take one, and its target
        # is pulled under its own name anyway.
        done < <(jq -r 'map(select(.ID | contains("\t") | not)) | group_by(.Path)[] | select(length > 1)[] | [.ID, .Path] | @tsv' "$dest/.listing.json")
        return "$rc"
      }

      # One account failing (revoked sign-in, quota) doesn't stop the rest; the run still
      # exits non-zero so the unit's OnFailure notification fires.
      failed=()
      for account in ${lib.escapeShellArgs driveAccounts}; do
        r=$(remote "$account") root=/srv/prepko/Drive/$account
        if ! rclone listremotes | grep -qxF "$r:"; then
          echo "drive-pull: $account isn't signed in; run: drive-pull setup $account" >&2
          failed+=("$account")
          continue
        fi
        pull "$r" "$root/mine" || failed+=("$account mine")
        pull "$r" "$root/shared" --drive-shared-with-me || failed+=("$account shared")
      done
      if [ ''${#failed[@]} -gt 0 ]; then
        printf 'drive-pull: failed: %s\n' "''${failed[@]}" >&2
        exit 1
      fi
    '';
  };

  drive-prune = pkgs.writeShellApplication {
    name = "drive-prune";
    runtimeInputs = with pkgs; [ python3 fzf poppler-utils chafa rclone ];
    text = rcloneEnv + ''exec python3 ${../scripts/drive-prune.py} "$@"'';
  };

  photo-merge = pkgs.writeShellApplication {
    name = "photo-merge";
    runtimeInputs = [
      (pkgs.python3.withPackages (p: with p; [ pillow pillow-heif imagehash ]))
      pkgs.exiftool
      pkgs.fzf
      pkgs.chafa
    ];
    text = ''exec python3 ${../scripts/photo-merge.py} "$@"'';
  };

  takeout-photos = pkgs.writeShellApplication {
    name = "takeout-photos";
    runtimeInputs = with pkgs; [ python3 exiftool gnutar gzip ];
    text = ''exec python3 ${../scripts/takeout-photos.py} "$@"'';
  };

  # Runs nightly and can be started by hand (`systemctl --user start <name>`) so a long
  # pull outlives the terminal; on a dropped connection it resumes, skipping what's
  # already on disk. The start limit stops a restart loop once the login needs a human
  # (fresh 2FA code, revoked token); the unit then fails and OnFailure notifies.
  nightlyPull = { name, desc, exec, at, failMsg }: {
    services.${name} = {
      Unit = {
        Description = desc;
        OnFailure = "${name}-failed.service";
        OnSuccess = "overnight-ok@${name}.service";
        StartLimitIntervalSec = 3600;
        StartLimitBurst = 6;
      };
      Service = {
        ExecStart = exec;
        Restart = "on-failure";
        RestartSec = 120;
        # Retries skip OnFailure; only a run that exhausts the start limit notifies.
        RestartMode = "direct";
      };
    };
    timers.${name} = {
      Unit.Description = "Nightly: ${desc}";
      Timer = {
        OnCalendar = "*-*-* ${at}";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
    services."${name}-failed" = {
      Unit.Description = "Record that ${name} failed";
      Service = {
        Type = "oneshot";
        ExecStart = "${overnight}/bin/overnight record user ${name} fail ${lib.escapeShellArg failMsg}";
      };
    };
  };
in
{
  home.packages = with pkgs; [
    isync rclone
    icloud-pull drive-pull drive-prune photo-merge takeout-photos digikam czkawka exiftool
  ];

  systemd.user = lib.mkMerge [
    (nightlyPull {
      name = "icloud-pull";
      desc = "Pull the iCloud Photos library to /srv/prepko/Pictures/icloud";
      exec = "${icloud-pull}/bin/icloud-pull --no-progress-bar --log-level info";
      at = "04:00:00";
      failMsg = "Photo pull failed — likely needs a fresh 2FA code: run icloud-pull";
    })
    (nightlyPull {
      name = "drive-pull";
      desc = "Pull Google Drive to /srv/prepko/Drive";
      exec = "${drive-pull}/bin/drive-pull --stats-one-line --stats 10m --stats-log-level NOTICE";
      at = "04:30:00";
      failMsg = "Drive pull failed — journalctl --user -u drive-pull names the account; it may need drive-pull setup <alias>";
    })
  ];

  # Pull-only archive of the Gmail `Keep-Archive` label. PullNew alone (no Gone/Flags)
  # plus Expunge/Remove None means deleting or unlabelling mail in Gmail never touches
  # the local copy — the point is to free Gmail after the pull.
  xdg.configFile."isyncrc".text = ''
    IMAPAccount gmail
    Host imap.gmail.com
    UserCmd "cat ${secret "gmail_user"}"
    PassCmd "cat ${secret "gmail_app_password"}"
    TLSType IMAPS
    AuthMechs LOGIN

    IMAPStore gmail-far
    Account gmail

    MaildirStore gmail-near
    Path ${archive}/mail/gmail/
    Inbox ${archive}/mail/gmail/INBOX
    SubFolders Verbatim

    Channel gmail-keep
    Far :gmail-far:Keep-Archive
    Near :gmail-near:Keep-Archive
    Create Near
    Sync PullNew
    Expunge None
    Remove None
    CopyArrivalDate yes
    SyncState *
  '';
}

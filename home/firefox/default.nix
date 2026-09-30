{ config, lib, ... }:
let
  # Surface Pro 7+ has 8 GB RAM and systemd-oomd (stock NixOS) will SIGKILL a
  # whole scope under app.slice — including the ghostty scope running a shell /
  # editor / agent — once memory pressure on the slice holds above 60 % for
  # 30 s. A heavy Firefox tab session is the usual thing that trips it. These
  # prefs bound what Firefox keeps resident so it stops being that trigger.
  # The desktop has the headroom to not care; only apply on the Surface.
  lowMem = !config.myConfig.isDesktop;
in
{
  programs.firefox = {
    enable = true;
    configPath = ".mozilla/firefox";
    profiles.default = {
      path = "default";
      isDefault = true;
      settings = {
        "privacy.resistFingerprinting"       = false;
        "privacy.clearOnShutdown.cookies"    = false;
        "privacy.clearOnShutdown.cache"      = false;
        "webgl.disabled"                     = false;
        "media.eme.enabled"                  = true;
        # Intel IPU6 (surface's built-in cams) floods raw V4L2 with junk nodes;
        # PipeWire is the only backend that enumerates USB webcams cleanly here.
        "media.webrtc.camera.allow-pipewire" = true;
        "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

        "datareporting.healthreport.uploadEnabled"                        = false;
        "datareporting.policy.dataSubmissionEnabled"                      = false;
        "toolkit.telemetry.unified"                                       = false;
        "browser.ping-centre.telemetry"                                   = false;
        "browser.newtabpage.activity-stream.feeds.telemetry"              = false;
        "browser.newtabpage.activity-stream.telemetry"                    = false;
        "browser.newtabpage.activity-stream.showSponsored"                = false;
        "browser.newtabpage.activity-stream.showSponsoredTopSites"        = false;

        # Crash reporter
        "breakpad.reportURL"                       = "";
        "browser.tabs.crashReporting.sendReport"   = false;
      } // lib.optionalAttrs lowMem {
        # ── Surface (8 GB) memory guards — see `lowMem` note above ──────────

        # Content-process pool cap (default 8). Each process carries ~120-180 MB
        # of fixed overhead, so 4 saves ~0.5-0.7 GB at idle. Fission (per-site
        # isolation, still on) routes most pages through its own webIsolated
        # pool (dom.ipc.processCount.webIsolated, left at 4); this cap mostly
        # bounds the shared non-isolated pool and the absolute ceiling. Cost:
        # more tabs share a process, so one content crash takes more tabs down.
        "dom.ipc.processCount" = 4;

        # Let Firefox drop the least-recently-used *background* tab when the OS
        # signals memory pressure; revisiting it reloads the page. Linux has
        # defaulted this on since ~FF 121 — pinned so a default flip can't
        # silently take it away on this machine.
        "browser.tabs.unloadOnLowMemory" = true;

        # React to "memory getting tight" earlier: fire the internal
        # memory-pressure signal (flush caches, unload tabs) when free commit
        # space drops under 10 % / 384 MB rather than the 5 % / 200 MB defaults.
        "browser.low_commit_space_threshold_percent" = 10;
        "browser.low_commit_space_threshold_mb" = 384;

        # In-RAM content cache. Default -1 = auto, which scales with RAM toward
        # ~1 GB. Pin to 256 MB; the disk cache (btrfs, unaffected) absorbs the
        # rest with a negligible latency cost.
        "browser.cache.memory.capacity" = 262144; # KiB

        # In-RAM back/forward page cache (bfcache). Default -1 = auto ≈ 8 fully
        # rendered prior pages held live. 2 keeps instant Back on the current
        # page without a wall of retained DOM trees.
        "browser.sessionhistory.max_total_viewers" = 2;

        # Session-restore checkpoint interval. Default 15 s means a steady
        # trickle of small writes (a real share of "everything feels laggy").
        # 60 s cuts that 4×; the exposure is up to ~60 s of tab/scroll state
        # lost only on a hard crash or power cut, not a normal quit.
        "browser.sessionstore.interval" = 60000;
      };
    };

    policies = {
      DisableTelemetry        = true;
      DisableFirefoxStudies   = true;
      DisablePocket           = true;
      DontCheckDefaultBrowser = true;
      OverrideFirstRunPage    = "";
      OverridePostUpdatePage  = "";
      FirefoxHome = {
        Search             = true;
        TopSites           = false;
        SponsoredTopSites  = false;
        Highlights         = false;
        Pocket             = false;
        SponsoredPocket    = false;
      };
    };
  };
}

{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchNpmDeps,
  rustPlatform,
  pkg-config,
  wrapGAppsHook4,
  nodejs,
  npmHooks,
  cargo-tauri,
  writableTmpDirAsHomeHook,
  jq,
  moreutils,
  openssl,
  glib-networking,
  webkitgtk_4_1,
  libayatana-appindicator,
  gtk3,
  glib,
  cairo,
  pango,
  gdk-pixbuf,
  librsvg,
  xdotool,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "fit-launcher";
  version = "4.2.0";

  src = fetchFromGitHub {
    owner = "CarrotRub";
    repo = "Fit-Launcher";
    tag = "app-v${finalAttrs.version}";
    hash = "sha256-UvJiU1xxJjIMabWNqqnS0XovZTYmalyvoPR2cTxslIw=";
  };

  cargoRoot = "src-tauri";
  buildAndTestSubdir = "src-tauri";

  cargoHash = "sha256-MLRUUic/ax0mTV1CGs89X657TO5Gt2hYMqLjYSZj9tA=";

  npmDeps = fetchNpmDeps {
    inherit (finalAttrs) src;
    hash = "sha256-RDkp1DwuwIPbxhGkAnpJaHdYsNtoUNEuB0O/tKev+10=";
  };

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook4
    nodejs
    npmHooks.npmConfigHook
    cargo-tauri.hook
    writableTmpDirAsHomeHook
    jq
    moreutils
  ];

  buildInputs = [
    openssl
    glib-networking
    webkitgtk_4_1
    libayatana-appindicator
    gtk3
    glib
    cairo
    pango
    gdk-pixbuf
    librsvg
    xdotool
  ];

  # Upstream ships no Linux CI (see .github/workflows/main.yml, runs-on: windows-latest
  # only) — externalBin sidecars (aria2c/FitLauncherService) are Windows-only and their
  # own src-tauri/tauri.linux.conf.json already drops them for Linux builds, but the
  # tray-icon feature still pulls in libappindicator-sys, which dlopen()s a bare soname
  # at runtime — point it at the real store path so it doesn't depend on LD_LIBRARY_PATH.
  postPatch = ''
    jq '.mainBinaryName = "fit-launcher" | .bundle.createUpdaterArtifacts = false' src-tauri/tauri.conf.json | sponge src-tauri/tauri.conf.json

    substituteInPlace $cargoDepsCopy/*/libappindicator-sys-*/src/lib.rs \
      --replace-fail "libayatana-appindicator3.so.1" "${libayatana-appindicator}/lib/libayatana-appindicator3.so.1"

    # fitgirl-decrypt lives in a subdir of its own workspace and its crate-level doc
    # reaches up to the workspace-root README; git-dep vendoring only carries the
    # crate directory itself, so that path doesn't exist in the vendor tree.
    substituteInPlace $cargoDepsCopy/*/fitgirl-decrypt-*/src/lib.rs \
      --replace-fail '#![doc = include_str!("../../README.md")]' ""

    # Upstream bug: folder_exclusion(_cleanup) manage Windows Defender exclusions via
    # the Windows-only controller_client/controller_manager/defender modules (which talk
    # to the FitLauncherService sidecar, itself dropped on Linux by tauri.linux.conf.json)
    # but aren't cfg(windows)-gated themselves, unlike every other item in this file.
    # Unlike the other fixes below, gating the whole functions doesn't work here: the
    # tauri-helper build.rs command scanner (generate_command_file) discovers
    # #[tauri::command] items via a naive syn-based text scan of the source tree that
    # doesn't evaluate #[cfg(...)] at all, so tauri_collect_commands!() still expects
    # these functions to exist on every platform. Replacement keeps both signatures
    # unconditional (matching upstream's own start_executable/is_controller_running
    # pattern in this same file) and only branches the bodies on #[cfg(windows)].
    cp ${./mighty_commands.rs} src-tauri/local-crates/fit-launcher-ui-automation/src/mighty_commands.rs

    # Same class of bug: OpenOptionsExt::share_mode is a Windows-only extension trait
    # method, called unconditionally on the fluent builder chain.
    substituteInPlace src-tauri/local-crates/fit-launcher-torrent/src/handler.rs \
      --replace-fail '                    if let Ok(mut file) = tokio::fs::OpenOptions::new()
                        .share_mode(0) // exclusive open
                        .create(true)
                        .write(true)
                        .truncate(true)
                        .open(torrent_path)
                        .await
                    {' \
      '                    let mut open_options = tokio::fs::OpenOptions::new();
                    #[cfg(windows)]
                    {
                        use std::os::windows::fs::OpenOptionsExt;
                        open_options.share_mode(0); // exclusive open
                    }
                    if let Ok(mut file) = open_options
                        .create(true)
                        .write(true)
                        .truncate(true)
                        .open(torrent_path)
                        .await
                    {'

    # Same class of bug again: fit-launcher-download-manager calls the Windows-only
    # ControllerManager (Windows Defender exclusion / UAC helper) unconditionally,
    # fully-qualified rather than via a `use`, so the earlier import-gating fix doesn't
    # cover these call sites.
    substituteInPlace src-tauri/local-crates/fit-launcher-download-manager/src/manager.rs \
      --replace-fail '        if let Err(e) = fit_launcher_ui_automation::controller_manager::ControllerManager::global()
            .ensure_running()
        {
            error!("ControllerManager failed to start: {:?}", e);
        }' \
      '        #[cfg(windows)]
        if let Err(e) = fit_launcher_ui_automation::controller_manager::ControllerManager::global()
            .ensure_running()
        {
            error!("ControllerManager failed to start: {:?}", e);
        }' \
      --replace-fail '                if let Ok(uuid) = Uuid::parse_str(job_id) {
                    let _ =
                        fit_launcher_ui_automation::controller_manager::ControllerManager::global()
                            .cancel_download(uuid);
                    // Also try to shutdown if we just cancelled the last thing keeping it alive
                    let _ =
                        fit_launcher_ui_automation::controller_manager::ControllerManager::global()
                            .shutdown_if_idle();
                }' \
      '                #[cfg(windows)]
                if let Ok(uuid) = Uuid::parse_str(job_id) {
                    let _ =
                        fit_launcher_ui_automation::controller_manager::ControllerManager::global()
                            .cancel_download(uuid);
                    // Also try to shutdown if we just cancelled the last thing keeping it alive
                    let _ =
                        fit_launcher_ui_automation::controller_manager::ControllerManager::global()
                            .shutdown_if_idle();
                }'

    # Same command-scanner constraint as mighty_commands.rs above: keep the signature
    # unconditional (via a per-platform type alias for the Windows-only QueueStatus
    # type) and only branch the body.
    substituteInPlace src-tauri/src/utils.rs \
      --replace-fail '#[tauri::command]
#[specta]
pub fn get_install_queue_status()
-> Result<fit_launcher_ui_automation::controller_manager::QueueStatus, CustomError> {
    fit_launcher_ui_automation::controller_manager::get_install_queue_status()
        .map_err(|e| CustomError { message: e })
}' \
      '#[cfg(windows)]
type InstallQueueStatus = fit_launcher_ui_automation::controller_manager::QueueStatus;
#[cfg(not(windows))]
type InstallQueueStatus = ();

#[tauri::command]
#[specta]
pub fn get_install_queue_status() -> Result<InstallQueueStatus, CustomError> {
    #[cfg(windows)]
    {
        fit_launcher_ui_automation::controller_manager::get_install_queue_status()
            .map_err(|e| CustomError { message: e })
    }
    #[cfg(not(windows))]
    {
        Err(CustomError {
            message: "Install queue status is only available on Windows".to_string(),
        })
    }
}'

    substituteInPlace src-tauri/local-crates/fit-launcher-cache/src/commands.rs \
      --replace-fail '        let mut file = tokio::fs::OpenOptions::new()
            .share_mode(0)
            .create(true)
            .write(true)
            .truncate(true)
            .open(&img_path)
            .await?;' \
      '        let mut open_options = tokio::fs::OpenOptions::new();
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            open_options.share_mode(0);
        }
        let mut file = open_options
            .create(true)
            .write(true)
            .truncate(true)
            .open(&img_path)
            .await?;'
  '';

  dontWrapGApps = true;

  postFixup = ''
    # WebKitGTK's DMA-BUF GL renderer reliably segfaults inside the proprietary
    # NVIDIA driver (libnvidia-eglcore.so) when tearing down a GL context, taking
    # the whole GPU/DRM stack down with it (not just this process) -- disable it
    # and fall back to the (slower but stable) EGL image path.
    wrapGApp $out/bin/fit-launcher \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath finalAttrs.buildInputs} \
      --set WEBKIT_DISABLE_DMABUF_RENDERER 1
  '';

  meta = {
    description = "Launcher/downloader client for FitGirl Repacks, built with Tauri";
    homepage = "https://github.com/CarrotRub/Fit-Launcher";
    license = lib.licenses.gpl3Only;
    mainProgram = "fit-launcher";
    platforms = [ "x86_64-linux" ];
  };
})

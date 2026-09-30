# Wires up the 'ask' and 'embed' tools as packages on each host.
# SWphil gets CUDA. Everyone else gets CPU inference. Same interface.

{ config, lib, pkgs, ... }:

let
  cfg = config.myln;

  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    sqlite-utils
    numpy
    requests
    tqdm
  ]);

  # sqlite-vec gives vector similarity search on a plain .db file (loaded at runtime as .so)
  sqliteVec = pkgs.sqlite-vec;

  llamaBin = if cfg.cudaSupport
    then pkgs.llama-cpp.override { cudaSupport = true; }
    else pkgs.llama-cpp;

  embeddingUrl = "http://127.0.0.1:${toString cfg.embeddingPort}/v1/embeddings";
  inferenceUrl = "http://127.0.0.1:${toString cfg.inferencePort}/completion";

  scriptArgs = { inherit pkgs cfg pythonEnv llamaBin sqliteVec embeddingUrl inferenceUrl lib; };

  inherit (import ./scripts/rag.nix      scriptArgs) askScript embedScript;
  inherit (import ./scripts/model.nix    { inherit pkgs cfg; }) pullScript pullEmbedScript;
  inherit (import ./scripts/harvest.nix  scriptArgs) harvestScript;
  inherit (import ./scripts/treemap.nix  scriptArgs) treemapScript;
  inherit (import ./scripts/diagnose.nix (scriptArgs // { hostName = config.networking.hostName; })) diagnoseScript;
  inherit (import ./scripts/nrs.nix      (scriptArgs // { hostName = config.networking.hostName; }))
    nrsWrapScript failLogScript;

  embeddingModel = if cfg.embeddingModelPath != "" then cfg.embeddingModelPath else cfg.modelPath;
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      askScript embedScript
      pullScript pullEmbedScript
      harvestScript diagnoseScript
      treemapScript
      failLogScript nrsWrapScript
      pythonEnv llamaBin
    ];

    system.activationScripts.myln = lib.stringAfter [ "var" ] ''
      mkdir -p ${cfg.storePath}/reports
      chown -R ${cfg.user}:users ${cfg.storePath}
    '';

    systemd.services.myln-harvest = {
      description = "myln hourly log harvest";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${harvestScript}/bin/myln-harvest";
        User = cfg.user;
      };
    };

    systemd.timers.myln-harvest = {
      description = "Hourly myln log harvest";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
      };
    };

    systemd.services.myln-diagnose = {
      description = "myln daily LLM diagnosis";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${diagnoseScript}/bin/myln-diagnose";
        User = cfg.user;
      };
    };

    systemd.timers.myln-diagnose = {
      description = "Daily myln LLM diagnosis";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.diagnoseTime;
        Persistent = true;
      };
    };

    systemd.services.myln-embeddings = {
      description = "llama-server embedding endpoint (myln)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      # Don't start if the model file isn't there yet (run myln-pull first)
      unitConfig.ConditionPathExists = embeddingModel;
      serviceConfig = {
        ExecStart = lib.escapeShellArgs ([
          "${llamaBin}/bin/llama-server"
          "--model" embeddingModel
          "--embeddings"
          "--pooling" "mean"
          "--port" (toString cfg.embeddingPort)
          "--ctx-size" (toString cfg.embeddingCtxSize)
          "--batch-size" (toString cfg.embeddingBatchSize)
          "--ubatch-size" (toString cfg.embeddingBatchSize)
          "-ngl" (toString cfg.embeddingGpuLayers)
          "--log-disable"
        ] ++ lib.optionals (cfg.embeddingContextOverrideKey != "") [
          "--override-kv" "${cfg.embeddingContextOverrideKey}=int:${toString cfg.embeddingCtxSize}"
        ]);
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    # Persistent inference server so myln-diagnose avoids cold CUDA init in a terminal.
    # Model loads once at boot (D-state during startup is fine); diagnose becomes a curl call.
    systemd.services.myln-inference = {
      description = "llama-server inference endpoint (myln-diagnose)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      unitConfig = {
        ConditionPathExists = cfg.modelPath;
        # Stop retrying after 3 failures in 60s — model not downloaded yet.
        # Run: sudo systemctl reset-failed myln-inference && myln-pull && sudo systemctl start myln-inference
        StartLimitIntervalSec = 60;
        StartLimitBurst = 3;
      };
      serviceConfig = {
        ExecStart = lib.escapeShellArgs ([
          "${llamaBin}/bin/llama-server"
          "--model" cfg.modelPath
          "--port" (toString cfg.inferencePort)
          "--ctx-size" (toString cfg.ctxSize)
          "-ngl" (toString cfg.gpuLayers)
          "--log-disable"
        ]);
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}

# Wires up the 'ask' and 'embed' tools as packages on each host.
# SWphil gets Vulkan (cached build; CUDA recompiled from source on every bump). Everyone else gets CPU inference. Same interface.

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

  llamaBin = if cfg.vulkanSupport
    then pkgs.llama-cpp-vulkan
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

  # The servers only read a world-readable model and talk on loopback, so they
  # run as a throwaway user instead of root.
  sandbox = {
    DynamicUser = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateUsers = true;
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
    IPAddressAllow = "localhost";
    IPAddressDeny = "any";
    UMask = "0077";
  };

  # Vulkan on the NVIDIA driver opens the render node and the /dev/nvidia*
  # nodes, and writes a shader cache (it went to /root/.nv while this ran as root).
  gpuSandbox = name: sandbox // {
    DevicePolicy = "closed";
    DeviceAllow = [
      "char-drm rw"
      "/dev/nvidiactl rw"
      "/dev/nvidia0 rw"
      "/dev/nvidia-modeset rw"
      "/dev/nvidia-uvm rw"
      "/dev/nvidia-uvm-tools rw"
    ];
    CacheDirectory = name;
    Environment = [ "XDG_CACHE_HOME=%C/${name}" "__GL_SHADER_DISK_CACHE_PATH=%C/${name}" ];
  };
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
        ExecStart = "${diagnoseScript}/bin/myln-diagnose yesterday";
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
        ] ++ lib.optionals (cfg.embeddingContextOverrideKey != "") [
          "--override-kv" "${cfg.embeddingContextOverrideKey}=int:${toString cfg.embeddingCtxSize}"
        ]);
        Restart = "on-failure";
        RestartSec = "5s";
      } // gpuSandbox "myln-embeddings";
    };

    # Inference loads on demand: the socket owns inferencePort and (re)starts the
    # proxy, which Requires the real server. Once the proxy idles out nothing
    # needs the server any more, so StopWhenUnneeded unloads it and frees ~4 GB
    # of the 1660's 6 GB VRAM.
    systemd.sockets.myln-inference = {
      description = "myln inference endpoint (starts llama-server on demand)";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "127.0.0.1:${toString cfg.inferencePort}" ];
      socketConfig.Service = "myln-inference-proxy.service";
    };

    systemd.services.myln-inference-proxy = {
      description = "myln inference socket proxy";
      requires = [ "myln-inference.service" ];
      after = [ "myln-inference.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=${cfg.inferenceIdleTime} 127.0.0.1:${toString cfg.inferenceBackendPort}";
      } // sandbox // { PrivateDevices = true; };
    };

    systemd.services.myln-inference = {
      description = "llama-server inference endpoint (myln-diagnose)";
      after = [ "network.target" ];
      unitConfig = {
        ConditionPathExists = cfg.modelPath;
        StopWhenUnneeded = true;
      };
      serviceConfig = {
        ExecStart = lib.escapeShellArgs ([
          "${llamaBin}/bin/llama-server"
          "--model" cfg.modelPath
          "--port" (toString cfg.inferenceBackendPort)
          "--ctx-size" (toString cfg.ctxSize)
          "-ngl" (toString cfg.gpuLayers)
        ]);
        # llama-server doesn't sd_notify, and /health is 503 while the model
        # loads; block start-up until it is ready so the proxy never sees a
        # refused connection.
        ExecStartPost = "${pkgs.curl}/bin/curl -sf --retry 120 --retry-delay 1 --retry-connrefused --retry-all-errors -o /dev/null http://127.0.0.1:${toString cfg.inferenceBackendPort}/health";
        TimeoutStartSec = 180;
        Restart = "on-failure";
        RestartSec = "5s";
      } // gpuSandbox "myln-inference";
    };
  };
}

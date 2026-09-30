{ config, lib, ... }:

{
  options.myln = {
    enable = lib.mkEnableOption "myln — NixOS-native RAG assistant";

    cudaSupport = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable CUDA acceleration (SWphil only)";
    };

    modelPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/myln/models/model.gguf";
      description = "Path to the GGUF model file (not in nix store)";
    };

    modelUrl = lib.mkOption {
      type = lib.types.str;
      # Phi-3 Mini 4K Q4 — 2.2GB, fits in 6GB VRAM with room for context
      default = "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf";
      description = "URL for myln-pull to fetch the model";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "User that runs ask/embed and owns the vector store";
    };

    storePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/myln";
      description = "Where the vector DB lives (must be writable by myln.user)";
    };

    docPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Paths to index. Files and directories both work.";
      example = [
        "/etc/nixos"           # your flake
        "/home/phil/.config"   # dotfiles
      ];
    };

    treeRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Directories scanned by myln-treemap to build the system-map doc. Never point this at /nix/store.";
      example = [ "/home/phil" "/srv" "/var/lib" "/mnt" ];
    };

    treeExcludes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        ".git" "node_modules" "__pycache__"
        ".cache" ".config" ".mozilla" ".librewolf" ".thunderbird" ".claude"
        ".steam" "Steam" ".npm" ".cargo" ".rustup" ".venv" "venv"
      ];
      description = ''
        Basenames pruned from the myln-treemap scan. Defaults skip app config/cache
        dirs (noisy, already declared in the flake) so the map stays focused on
        actual content locations.
      '';
    };

    treeMaxDepth = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Max depth (relative to each treeRoots entry) for the myln-treemap scan.";
    };

    topK = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Number of context chunks to retrieve per query";
    };

    maxTokens = lib.mkOption {
      type = lib.types.int;
      default = 512;
    };

    ctxSize = lib.mkOption {
      type = lib.types.int;
      default = 4096;
    };

    temperature = lib.mkOption {
      type = lib.types.str;
      default = "0.3";
      description = "Lower = more focused. You want this low for config questions.";
    };

    gpuLayers = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Layers to offload to GPU. Set to 999 to offload all (with cudaSupport).";
    };

    embeddingPort = lib.mkOption {
      type = lib.types.int;
      default = 8766;
      description = "Port for the llama-server embedding endpoint.";
    };

    embeddingModelPath = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "GGUF model for the embedding server. Defaults to modelPath if empty.";
    };

    embeddingModelUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "URL for myln-pull-embed to fetch the embedding model.";
    };

    embeddingCtxSize = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Context size for the embedding server. Must be >= chunk token count (~1.3x word count for prose, ~4x for code).";
    };

    embeddingBatchSize = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      # Code tokenizes at ~4 tok/word; 512 words can reach 2300+ tokens.
      # batch-size and ubatch-size must both be set to this value.
      description = "Physical batch size for the embedding server. Must be >= longest input in tokens.";
    };

    embeddingGpuLayers = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "GPU layers for the embedding server. Default 0: CPU-only leaves all VRAM for inference.";
    };

    embeddingContextOverrideKey = lib.mkOption {
      type = lib.types.str;
      default = "nomic-bert.context_length";
      description = ''
        GGUF metadata key passed to llama-server's --override-kv to bypass its
        training-context clamp. Some GGUF conversions (e.g. nomic-embed-text-v1.5's
        Q4_K_M quant) bake in a context_length far below the model's advertised
        max (2048 vs. the claimed 8192) — llama-server silently caps --ctx-size to
        that value otherwise, no warning surfaces past --log-disable. Set to ""
        to skip the override (e.g. if a future embedding model doesn't need it).
      '';
    };

    inferencePort = lib.mkOption {
      type = lib.types.int;
      default = 8767;
      description = "Port for the persistent llama-server inference endpoint used by myln-diagnose.";
    };

    logPriority = lib.mkOption {
      type = lib.types.str;
      default = "err";
      description = "Minimum journald priority to harvest. Passed to journalctl --priority (emerg..debug).";
    };

    logSince = lib.mkOption {
      type = lib.types.str;
      default = "today";
      description = "Fallback --since when no cursor exists for today (first hourly run of a new day). Set to 'yesterday' once to bootstrap a fresh install.";
    };

    logIgnoreUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Journal unit names to exclude from harvest entirely (matched after stripping PID and colon).";
      example = [ "audit" "dbus-broker" "NetworkManager" ];
    };

    logIgnorePatterns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extended regex patterns applied to 'unit message' lines after unit filtering. Lines matching any pattern are dropped.";
      example = [ "systemd: Failed to.*scope.*: No such process" ];
    };

    diagnosisMaxTokens = lib.mkOption {
      type = lib.types.int;
      default = 512;
      description = "Max tokens for the diagnosis LLM pass.";
    };

    diagnosisMaxErrors = lib.mkOption {
      type = lib.types.int;
      default = 20;
      description = "Max error lines to send to the LLM. Prevents context overflow on noisy days.";
    };

    diagnoseTimeout = lib.mkOption {
      type = lib.types.int;
      default = 180;
      description = "Seconds before myln-diagnose aborts the LLM pass. Tune to your GPU speed.";
    };

    diagnoseTime = lib.mkOption {
      type = lib.types.str;
      default = "22:00";
      description = "OnCalendar time for the daily LLM diagnosis pass (runs once, after a day of hourly harvests).";
    };

    diagnoseSystemContext = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Freeform context injected into the diagnosis system prompt.
        Use for host hardware notes, known-benign error patterns, and
        disambiguation hints that prevent retrieval pollution (e.g. clarifying
        that 'temperature' in retrieved Nix config is an LLM sampling param).
      '';
    };

    buildTarget = lib.mkOption {
      type = lib.types.str;
      default = "nixosConfigurations.${config.networking.hostName}";
      description = "Build target identifier stored in failure records (e.g. nixosConfigurations.SWphil).";
    };

    gitDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/${config.myConfig.user}/nixos";
      description = "Path to the nixos flake git repo used by fail_log for commit tracking.";
    };
  };
}

{ config, lib, pkgs, ... }:

# Speech-to-text for video/audio files, on the RX 9070 XT.
#
# whisper.cpp rather than OpenAI's Python whisper: the reference
# implementation runs on PyTorch, which on this card means ROCm, and RDNA4
# (gfx1201) support in a packaged ROCm/PyTorch stack is still the fragile
# part of the AMD story. whisper.cpp's Vulkan backend uses the same RADV
# driver Wolf already depends on, needs no extra kernel or firmware, and runs
# the same Whisper weights (converted to ggml).
#
# The model is pinned in the store instead of downloaded at first use, so a
# rebuild is all it takes to get a working `transcribe` and it survives GC
# for as long as this generation does. large-v3 rather than the turbo
# variant: turbo trades accuracy for speed, and on smaller languages such as
# Romanian the gap is noticeable while the speed is not needed on this GPU.
#
# Usage:  transcribe lectie.mp4 [limba]     (default language: ro)
# Env:    WHISPER_CONTEXT=N (default 128, 0 = off), WHISPER_VAD=0 (disable VAD)
#         WHISPER_DENOISE=1 (take background noise out first, see `denoise`)
#         WHISPER_START=S WHISPER_LENGTH=S (seconds: only that part of the input;
#         the timestamps then start at 0), WHISPER_OUT=prefix (default: input
#         name without its extension)
# Writes lectie.txt, lectie.srt and lectie.vtt next to the input.
# Web:    rig.whisper.web.enable = true serves the same command as a page on
#         port 8091 (LAN and tailnet only) for sending files from a phone.
let
  model = pkgs.fetchurl {
    name = "ggml-large-v3.bin";
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin";
    sha256 = "1qnijhsv47x1vx2vixy4jr8n0k6q8ham9ggrqh1m53dr82s85lb4";
  };

  # Silero voice-activity detector, so whisper is only ever handed audio that
  # contains speech. Most of whisper's invented text starts over silence or
  # room noise, where it has nothing to go on but the previous transcript.
  vadModel = pkgs.fetchurl {
    name = "ggml-silero-v6.2.0.bin";
    url = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin";
    sha256 = "11v9zgvwkihs750kmdiswd49q7bwvwfm081sk213mdgfhnvnk8ia";
  };

  # Noise removal before Whisper (WHISPER_DENOISE=1): MossFormer2_SE_48K
  # from Alibaba's ClearerVoice-Studio (Apache-2.0, code and weights). Of
  # the enhancement models tried on lecture recordings it was the only one
  # that helped: Whisper got more of the terms right and stopped looping
  # on noisy but audible speech. The generative ones (VoiceFixer, StoRM,
  # MossFormerGAN) made Whisper hear nothing or invent text. On a voice
  # that is barely there it removes speech too, hence off by default for
  # `transcribe` and a checkbox on the page.
  #
  # Only the model's own module is used, not the clearvoice package, which
  # pulls in a long list of dependencies for its other models. It runs on
  # the CPU (about 10x real time): this torch comes from the binary cache,
  # a ROCm build of it would not.
  clearerVoice = pkgs.fetchFromGitHub {
    owner = "modelscope";
    repo = "ClearerVoice-Studio";
    rev = "6b3774dc79c46ae8bed2a4fa5f706f0ac8c75c61";
    sha256 = "0fddcfkzp04p9rj0yg6k3wr2im92qz5rji4wcxps6vkkqymc9k8b";
  };
  mossformer2Src = pkgs.runCommand "mossformer2-se-src" { } ''
    mkdir -p $out
    cp -r ${clearerVoice}/clearvoice/clearvoice/models/mossformer2_se $out/
    chmod -R u+w $out
    # Only used for printing a model summary.
    sed -i '/from torchinfo import summary/d' $out/mossformer2_se/mossformer2_block.py
  '';
  mossformer2Weights = pkgs.fetchurl {
    name = "mossformer2-se-48k.pt";
    url = "https://huggingface.co/alibabasglab/MossFormer2_SE_48K/resolve/eff8c97925c8bec812af707814b3e5d777fd4503/last_best_checkpoint.pt";
    sha256 = "1ii7nbcd6sn6psvrcdz1cvysya0ydgwl2nlw7fs6pg9vfygjns83";
  };
  denoise = pkgs.writers.writePython3Bin "whisper-denoise"
    {
      libraries = with pkgs.python3Packages; [ torch torchaudio einops rotary-embedding-torch soundfile numpy ];
      flakeIgnore = [ "E501" ];
    }
    (lib.replaceStrings [ "@modelSrc@" "@weights@" ] [ "${mossformer2Src}" "${mossformer2Weights}" ]
      (builtins.readFile ./whisper-denoise.py));

  transcribe = pkgs.writeShellApplication {
    name = "transcribe";
    runtimeInputs = [ pkgs.ffmpeg-headless pkgs.whisper-cpp-vulkan denoise ];
    text = ''
      if [ $# -lt 1 ]; then
        echo "usage: transcribe <video-or-audio> [language, default ro]" >&2
        exit 1
      fi
      in="$1"
      lang="''${2:-ro}"
      out="''${WHISPER_OUT:-''${in%.*}}"
      wav="$(mktemp --suffix=.wav)"
      raw="$(mktemp --suffix=.wav)"
      clean="$(mktemp --suffix=.wav)"
      trap 'rm -f "$wav" "$raw" "$clean"' EXIT

      # Vulkan enumerates the 9800X3D's iGPU as device 0 and the RX 9070 XT
      # as device 1, and whisper.cpp takes the first one it sees.
      export GGML_VK_VISIBLE_DEVICES="''${GGML_VK_VISIBLE_DEVICES:-1}"

      # whisper.cpp only accepts 16 kHz mono PCM.
      range=()
      if [ -n "''${WHISPER_START:-}" ]; then
        range=(-ss "$WHISPER_START" -t "''${WHISPER_LENGTH:?WHISPER_LENGTH goes with WHISPER_START}")
      fi
      if [ "''${WHISPER_DENOISE:-0}" = 1 ]; then
        # The model works at 48 kHz; Whisper gets the result at 16 kHz.
        ffmpeg -nostdin -hide_banner -loglevel error -y \
          -i "$in" "''${range[@]}" -vn -ar 48000 -ac 1 -c:a pcm_s16le "$raw"
        whisper-denoise "$raw" "$clean"
        ffmpeg -nostdin -hide_banner -loglevel error -y \
          -i "$clean" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"
        rm -f "$raw" "$clean"
      else
        ffmpeg -nostdin -hide_banner -loglevel error -y \
          -i "$in" "''${range[@]}" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$wav"
      fi

      # Prime each 30 s window with only ~three sentences of the previous
      # transcript instead of the default 224 tokens. With full priming a
      # long lecture eventually locks into repeating one phrase until the
      # end (a 58-minute recording lost its last 42 minutes to that); with
      # none, names and punctuation drift between windows. 0 turns it off.
      # VAD on unless WHISPER_VAD=0. The 200 ms pad (default 30) keeps the
      # detector from clipping the first and last syllable of each phrase.
      vad=()
      if [ "''${WHISPER_VAD:-1}" != 0 ]; then
        vad=(--vad -vm "${vadModel}" -vp 200)
      fi

      whisper-cli \
        -m "''${WHISPER_MODEL:-${model}}" \
        "''${vad[@]}" \
        -l "$lang" \
        --max-context "''${WHISPER_CONTEXT:-128}" \
        -f "$wav" \
        -otxt -osrt -ovtt \
        -of "$out" \
        -pp

      echo "Done: $out.txt  $out.srt  $out.vtt"
    '';
  };

  # The same command behind a web page (whisper-web/), for sending a
  # recording from a phone: upload, a queue of one, then copy or download
  # the transcript. Rust rather than a script, so a multi-GB video upload is
  # streamed to disk instead of passing through memory.
  whisperWeb = pkgs.rustPlatform.buildRustPackage {
    pname = "whisper-web";
    version = "0.1.0";
    src = ./whisper-web;
    cargoLock.lockFile = ./whisper-web/Cargo.lock;
    meta.mainProgram = "whisper-web";
  };

  cfg = config.rig.whisper;
in
{
  imports = [ ./lan.nix ];

  options.rig.whisper = {
    enable = lib.mkEnableOption "speech-to-text with whisper.cpp (the `transcribe` command)";

    web = {
      enable = lib.mkEnableOption ''
        a web page for `transcribe` (upload a file, download the transcript),
        open to rig.lanCidrs and the tailnet only. There is no login: anyone
        who can reach the port can use it'';

      port = lib.mkOption {
        type = lib.types.port;
        default = 8091;
        description = "Port of the transcription web page.";
      };

      keepDays = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 7;
        description = "Finished transcriptions are deleted after this many days; 0 keeps them.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        transcribe
        pkgs.whisper-cpp-vulkan
        pkgs.ffmpeg-headless
      ];

      # No mining while a transcription runs. Whisper is on the GPU, but
      # feeding it, the voice detector and ffmpeg are CPU work, and sixteen
      # RandomX threads on a capped clock slow all of it. The guard's grace
      # period also covers the short gaps between the passes of one job
      # (the transcription, then each repaired passage).
      # The noise removal is all CPU, and next to RandomX it runs some 50
      # times slower (its threads spin waiting on each other).
      rig.gamingGuard.busyProcesses = [ "whisper-cli" "whisper-denoise" ];
    }

    (lib.mkIf cfg.web.enable {
      systemd.services.whisper-web = {
        description = "Web page for the transcribe command";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LISTEN = "[::]:${toString cfg.web.port}";
          TRANSCRIBE = lib.getExe transcribe;
          KEEP_DAYS = toString cfg.web.keepDays;
          # Mesa keeps its Vulkan shader cache here.
          HOME = "/var/lib/whisper-web";
          XDG_CACHE_HOME = "/var/lib/whisper-web/cache";
        };
        serviceConfig = {
          ExecStart = lib.getExe whisperWeb;
          DynamicUser = true;
          StateDirectory = "whisper-web";
          # The GPU: /dev/dri/renderD* belongs to `render`.
          SupplementaryGroups = [ "render" "video" ];
          Restart = "on-failure";
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
          # Whisper is the GPU's background work; a game stream comes first.
          Nice = 10;
        };
      };

      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.web.port ];
      networking.firewall.extraInputRules =
        lib.optionalString (config.rig.lanCidrs != [ ]) ''
          ip saddr { ${lib.concatStringsSep ", " config.rig.lanCidrs} } tcp dport ${toString cfg.web.port} accept
        '';
    })
  ]);
}

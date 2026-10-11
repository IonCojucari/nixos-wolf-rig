{ pkgs, ... }:

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
# Writes lectie.txt, lectie.srt and lectie.vtt next to the input.
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

  transcribe = pkgs.writeShellApplication {
    name = "transcribe";
    runtimeInputs = [ pkgs.ffmpeg-headless pkgs.whisper-cpp-vulkan ];
    text = ''
      if [ $# -lt 1 ]; then
        echo "usage: transcribe <video-or-audio> [language, default ro]" >&2
        exit 1
      fi
      in="$1"
      lang="''${2:-ro}"
      out="''${in%.*}"
      wav="$(mktemp --suffix=.wav)"
      trap 'rm -f "$wav"' EXIT

      # Vulkan enumerates the 9800X3D's iGPU as device 0 and the RX 9070 XT
      # as device 1, and whisper.cpp takes the first one it sees.
      export GGML_VK_VISIBLE_DEVICES="''${GGML_VK_VISIBLE_DEVICES:-1}"

      # whisper.cpp only accepts 16 kHz mono PCM.
      ffmpeg -nostdin -hide_banner -loglevel error -y \
        -i "$in" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$wav"

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
in
{
  environment.systemPackages = [
    transcribe
    pkgs.whisper-cpp-vulkan
    pkgs.ffmpeg-headless
  ];
}

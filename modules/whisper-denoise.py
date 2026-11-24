"""Speech enhancement before Whisper: MossFormer2_SE_48K from ClearerVoice-Studio.

Usage: whisper-denoise <in.wav> <out.wav>   (48 kHz mono in, 48 kHz mono 16-bit out)

The same processing as ClearerVoice's own decoder for this model (4 s
windows, 3 s apart, of which the middle 3 s are kept; log-mel features
with their deltas in, a spectral mask out), except that the recording is
read and written a few windows at a time, so a two-hour lecture does not
have to fit in memory, and windows go through the model in small batches.
Progress goes to stderr as "denoise: N%".
"""

import ctypes
import math
import os
import sys

import numpy as np
import soundfile as sf
import torch
import torchaudio

SR = 48000
WIN_LEN = 1920  # 40 ms
WIN_INC = 384  # 8 ms
N_MELS = 60
WINDOW = 4 * SR
STRIDE = 3 * SR
EDGE = (WINDOW - STRIDE) // 2  # dropped at both ends of every window but the first
SCALE = 32768.0  # the model was trained on 16-bit sample values
# More than one window per call was slower on the CPU, not faster.
BATCH = int(os.environ.get("DENOISE_BATCH", "1"))
# Filled in by modules/whisper.nix; the variables are for trying it by hand.
MODEL_SRC = os.environ.get("MOSSFORMER2_SRC", "@modelSrc@")
WEIGHTS = os.environ.get("MOSSFORMER2_WEIGHTS", "@weights@")


def name_process():
    """Call this process whisper-denoise, which the gaming guard looks for
    (pgrep -x), even if the interpreter was started through a wrapper."""
    try:
        ctypes.CDLL(None).prctl(15, b"whisper-denoise", 0, 0, 0)  # PR_SET_NAME
    except (OSError, AttributeError):
        pass


def load_model():
    sys.path.insert(0, MODEL_SRC)
    from mossformer2_se.mossformer2_se_wrapper import MossFormer2_SE_48K

    model = MossFormer2_SE_48K(None).model
    state = torch.load(WEIGHTS, map_location="cpu", weights_only=True)
    state = state.get("model", state)
    model.load_state_dict({k.removeprefix("module."): v for k, v in state.items()})
    return model.eval()


def features(x):
    fb = torchaudio.compliance.kaldi.fbank(
        x.unsqueeze(0), dither=1.0, frame_length=WIN_LEN / SR * 1000, frame_shift=WIN_INC / SR * 1000,
        num_mel_bins=N_MELS, sample_frequency=SR, window_type="hamming")
    d1 = torchaudio.functional.compute_deltas(fb.T)
    d2 = torchaudio.functional.compute_deltas(d1)
    return torch.cat([fb, d1.T, d2.T], 1)


def enhance(model, batch, window):
    """batch: [B, WINDOW] in 16-bit units -> the same, cleaned."""
    mask = model(torch.stack([features(x) for x in batch]))[-1]  # [B, frames, bins]
    spec = torch.stft(batch, WIN_LEN, WIN_INC, WIN_LEN, window=window, center=False, return_complex=True)
    return torch.istft(spec * mask.transpose(1, 2), WIN_LEN, WIN_INC, WIN_LEN, window=window,
                       center=False, length=WINDOW)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: whisper-denoise <in.wav> <out.wav>  (48 kHz mono)")
    src, dst = sys.argv[1:]
    name_process()
    info = sf.info(src)
    if info.samplerate != SR or info.channels != 1:
        sys.exit(f"whisper-denoise: {src} must be {SR} Hz mono")
    n = info.frames
    count = 1 if n + EDGE <= WINDOW else math.ceil((n + EDGE - WINDOW) / STRIDE) + 1

    torch.set_num_threads(os.cpu_count() or 1)
    model = load_model()
    window = torch.hamming_window(WIN_LEN, periodic=False)
    shown = -1
    with sf.SoundFile(src) as f, sf.SoundFile(dst, "w", SR, 1, "PCM_16") as g, torch.inference_mode():
        for first in range(0, count, BATCH):
            ks = range(first, min(count, first + BATCH))
            segs = np.zeros((len(ks), WINDOW), dtype=np.float32)
            for row, k in zip(segs, ks):
                f.seek(k * STRIDE)
                a = f.read(WINDOW, dtype="float32")
                row[:len(a)] = a
            out = enhance(model, torch.from_numpy(segs) * SCALE, window) / SCALE
            # Window k keeps [k*STRIDE + EDGE, (k+1)*STRIDE + EDGE): back to back.
            for k, o in zip(ks, out):
                lo = 0 if k == 0 else EDGE
                start = k * STRIDE + lo
                keep = min(WINDOW - EDGE - lo, n - start)
                if keep > 0:
                    g.write(o[lo:lo + keep].clamp(-1, 1).numpy())
            pct = 100 * (ks[-1] + 1) // count
            if pct != shown:
                print(f"denoise: {pct}%", file=sys.stderr, flush=True)
                shown = pct


if __name__ == "__main__":
    main()

#!/usr/bin/env python
"""F5-TTS voice cloning CLI with two backends.

Backends
--------
- mlx (default for non-Cyrillic): f5-tts-mlx, native Apple Silicon, ~8x faster
       than torch on CPU. Uses lucasnewman/f5-tts-mlx (EN+ZH base model).
       Auto-resamples reference to 24kHz.
- torch: official f5_tts.api.F5TTS, slower but more compatible. Best for
       Russian (off-distribution for the MLX base model).
- auto (default): picks mlx if text is mostly non-Cyrillic, torch otherwise.

Usage:
    f5_synth.py --text "..." --ref-audio /path/to/sample.wav \
                --ref-text "..." --save-file /tmp/out.wav \
                [--backend auto|mlx|torch] [--steps 8]
"""
import argparse
import os
import sys
import time
import warnings

warnings.filterwarnings("ignore", category=SyntaxWarning)
warnings.filterwarnings("ignore", category=UserWarning, module="jieba")


def cyrillic_share(text: str) -> float:
    if not text:
        return 0.0
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return 0.0
    cyr = sum(1 for c in letters if "Ѐ" <= c <= "ӿ")
    return cyr / len(letters)


def resolve_backend(selected: str, text: str) -> str:
    if selected != "auto":
        return selected
    return "torch" if cyrillic_share(text) > 0.3 else "mlx"


def ensure_24k(src_path: str) -> str:
    """If src is not 24kHz, resample to a sibling _24k.wav. Return resampled path."""
    import soundfile as sf
    info = sf.info(src_path)
    if info.samplerate == 24000:
        return src_path
    import librosa
    y, _ = librosa.load(src_path, sr=24000)
    base, _ = os.path.splitext(src_path)
    dst = f"{base}_24k.wav"
    sf.write(dst, y, 24000, subtype="PCM_16")
    return dst


def run_mlx(args) -> int:
    from f5_tts_mlx.generate import generate
    ref_path = ensure_24k(args.ref_audio)
    t = time.time()
    generate(
        generation_text=args.text,
        ref_audio_path=ref_path,
        ref_audio_text=args.ref_text,
        output_path=args.save_file,
        steps=args.steps,
        model_name=args.mlx_model,
    )
    import soundfile as sf
    out = sf.info(args.save_file)
    dur = out.frames / out.samplerate
    synth = time.time() - t
    print(
        f"  -> [mlx] Synthesized {dur:.2f}s of audio in {synth:.2f}s (RTF {synth/max(dur,1e-6):.3f}x)",
        flush=True,
    )
    print(f"Saved: {args.save_file}", flush=True)
    return 0


def run_torch(args) -> int:
    from f5_tts.api import F5TTS
    t = time.time()
    f5 = F5TTS(model=args.torch_model, device=args.device)
    print(f"  -> [torch] Model loaded in {time.time() - t:.2f}s on {args.device}", flush=True)
    t1 = time.time()
    wav, sr, _ = f5.infer(
        ref_file=args.ref_audio,
        ref_text=args.ref_text,
        gen_text=args.text,
        file_wave=args.save_file,
        remove_silence=True,
    )
    dur = len(wav) / sr if hasattr(wav, "__len__") else 0
    synth = time.time() - t1
    print(
        f"  -> [torch] Synthesized {dur:.2f}s of audio in {synth:.2f}s (RTF {synth/max(dur,1e-6):.3f}x)",
        flush=True,
    )
    print(f"Saved: {args.save_file}", flush=True)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="F5-TTS voice cloning (mlx | torch | auto)")
    p.add_argument("--text", required=True, help="Text to synthesize")
    p.add_argument("--ref-audio", required=True, help="Reference WAV/MP3 (5-15s)")
    p.add_argument("--ref-text", required=True, help="Transcription of the reference audio")
    p.add_argument("--save-file", required=True, help="Output WAV path")

    p.add_argument(
        "--backend",
        default="auto",
        choices=["auto", "mlx", "torch"],
        help="auto = mlx for non-Cyrillic text, torch for Cyrillic",
    )
    p.add_argument("--steps", type=int, default=8, help="Diffusion steps (default 8)")

    p.add_argument("--mlx-model", default="lucasnewman/f5-tts-mlx")
    p.add_argument("--torch-model", default="F5TTS_v1_Base")
    p.add_argument("--device", default="cpu", choices=["cpu", "mps"], help="Only for torch backend")

    args = p.parse_args()

    if not os.path.exists(args.ref_audio):
        print(f"ERROR: reference audio not found: {args.ref_audio}", file=sys.stderr)
        return 2

    out_dir = os.path.dirname(os.path.abspath(args.save_file))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    backend = resolve_backend(args.backend, args.text)
    print(f"=== F5-TTS [{backend}] ===", flush=True)

    if backend == "mlx":
        return run_mlx(args)
    return run_torch(args)


if __name__ == "__main__":
    sys.exit(main())

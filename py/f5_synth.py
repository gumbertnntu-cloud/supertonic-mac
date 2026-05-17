#!/usr/bin/env python
"""F5-TTS voice cloning CLI.

Usage:
    f5_synth.py --text "Произнести вот это." \
                --ref-audio /path/to/sample.wav \
                --ref-text "Что говорится в образце." \
                --save-file /tmp/out.wav
"""
import argparse
import os
import sys
import time
import warnings

# pydub emits ugly SyntaxWarnings on import; mute them so logs stay readable
warnings.filterwarnings("ignore", category=SyntaxWarning)


def main() -> int:
    parser = argparse.ArgumentParser(description="F5-TTS voice cloning")
    parser.add_argument("--text", required=True, help="Text to synthesize")
    parser.add_argument("--ref-audio", required=True, help="Reference WAV/MP3 (5-15s)")
    parser.add_argument("--ref-text", required=True, help="Transcription of the reference audio")
    parser.add_argument("--save-file", required=True, help="Output WAV path")
    parser.add_argument(
        "--device",
        default="cpu",
        choices=["cpu", "mps"],
        help="Inference device. MPS is experimental on Apple Silicon.",
    )
    parser.add_argument(
        "--model",
        default="F5TTS_v1_Base",
        help="F5-TTS model id (default F5TTS_v1_Base)",
    )
    args = parser.parse_args()

    print("=== F5-TTS voice cloning ===", flush=True)
    if not os.path.exists(args.ref_audio):
        print(f"ERROR: reference audio not found: {args.ref_audio}", file=sys.stderr)
        return 2

    t0 = time.time()
    from f5_tts.api import F5TTS

    f5 = F5TTS(model=args.model, device=args.device)
    print(f"  -> Model loaded in {time.time() - t0:.2f}s on {args.device}", flush=True)

    out_dir = os.path.dirname(os.path.abspath(args.save_file))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    t1 = time.time()
    wav, sr, _ = f5.infer(
        ref_file=args.ref_audio,
        ref_text=args.ref_text,
        gen_text=args.text,
        file_wave=args.save_file,
        remove_silence=True,
    )
    synth_time = time.time() - t1
    duration = len(wav) / sr if hasattr(wav, "__len__") else 0
    rtf = synth_time / max(duration, 1e-6)
    print(
        f"  -> Synthesized {duration:.2f}s of audio in {synth_time:.2f}s (RTF {rtf:.3f}x)",
        flush=True,
    )
    print(f"Saved: {args.save_file}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

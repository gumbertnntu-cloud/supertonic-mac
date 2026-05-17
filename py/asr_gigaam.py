#!/usr/bin/env python
"""ASR via local GigaAM v3 (MLX) — recognizes Russian speech offline on Apple Silicon.

Output: a single line on stdout — the recognized text. Errors go to stderr with
exit code 1. Designed to be invoked by Supertonic.app to auto-fill the
"transcription" field when importing a voice sample.

Usage:
    asr_gigaam.py /path/to/audio.wav
    asr_gigaam.py /path/to/audio.wav --model-type rnnt  # default
    asr_gigaam.py /path/to/audio.wav --model-type ctc   # faster, slightly worse
"""
import argparse
import os
import sys
import warnings

warnings.filterwarnings("ignore", category=SyntaxWarning)
warnings.filterwarnings("ignore", category=UserWarning)


def main() -> int:
    p = argparse.ArgumentParser(description="Local GigaAM v3 ASR (MLX, Apple Silicon)")
    p.add_argument("audio", help="Path to WAV / MP3 / FLAC / M4A")
    p.add_argument(
        "--model-type",
        default="rnnt",
        choices=["rnnt", "ctc"],
        help="rnnt = higher quality (default), ctc = ~4x faster",
    )
    args = p.parse_args()

    if not os.path.exists(args.audio):
        print(f"ERROR: audio file not found: {args.audio}", file=sys.stderr)
        return 1

    try:
        from gigaam_mlx import load_model, transcribe
    except ImportError as exc:
        print(
            f"ERROR: gigaam_mlx not installed in this venv ({exc}). "
            f"Run: uv pip install 'git+https://github.com/aystream/gigaam-mlx.git'",
            file=sys.stderr,
        )
        return 2

    # Suppress library chatter so stdout stays clean for the parent process.
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        model, tokenizer = load_model(args.model_type)
        text = transcribe(model, tokenizer, args.audio)

    print(text.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())

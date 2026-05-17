#!/usr/bin/env python
import argparse
import os
import sys
import time

import soundfile as sf
import torch


SPEAKERS = ["aidar", "baya", "kseniya", "xenia", "eugene"]


def main() -> int:
    parser = argparse.ArgumentParser(description="Silero TTS v4 (RU) inference")
    parser.add_argument("--text", required=True, help="Text to synthesize")
    parser.add_argument("--speaker", default="aidar", choices=SPEAKERS + ["random"])
    parser.add_argument(
        "--save-file",
        required=True,
        help="Output WAV path",
    )
    parser.add_argument("--sample-rate", type=int, default=48000, choices=[8000, 24000, 48000])
    parser.add_argument(
        "--no-accent",
        action="store_true",
        help="Disable automatic stress placement",
    )
    parser.add_argument(
        "--no-yo",
        action="store_true",
        help="Disable automatic ё restoration",
    )
    args = parser.parse_args()

    print("=== Silero TTS v4 (RU) ===", flush=True)
    t0 = time.time()

    torch.set_num_threads(max(1, os.cpu_count() or 4))
    device = torch.device("cpu")

    model, _ = torch.hub.load(
        repo_or_dir="snakers4/silero-models",
        model="silero_tts",
        language="ru",
        speaker="v4_ru",
        trust_repo=True,
    )
    model.to(device)
    print(f"  -> Model loaded in {time.time() - t0:.2f}s", flush=True)

    t1 = time.time()
    audio = model.apply_tts(
        text=args.text,
        speaker=args.speaker,
        sample_rate=args.sample_rate,
        put_accent=not args.no_accent,
        put_yo=not args.no_yo,
    )
    synth_time = time.time() - t1
    audio_np = audio.cpu().numpy()
    duration = len(audio_np) / args.sample_rate
    rtf = synth_time / max(duration, 1e-6)
    print(
        f"  -> Synthesized {duration:.2f}s of audio in {synth_time:.2f}s (RTF {rtf:.3f}x)",
        flush=True,
    )

    out_dir = os.path.dirname(os.path.abspath(args.save_file))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    sf.write(args.save_file, audio_np, args.sample_rate, subtype="PCM_16")
    print(f"Saved: {args.save_file}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

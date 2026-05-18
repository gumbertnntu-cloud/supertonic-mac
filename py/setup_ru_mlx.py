#!/usr/bin/env python
"""One-shot: stage the Russian F5-TTS finetune for the MLX backend.

Downloads Misha24-10/F5-TTS_RUSSIAN weights + vocab, copies them into
~/.cache/local-f5-misha-ru/ with the filenames f5_tts_mlx expects
(model_v1.safetensors, vocab.txt). After this runs, tts_worker.py
auto-detects the directory and routes Cyrillic F5 calls through MLX
(~5× faster than the torch fallback).

Idempotent — safe to re-run.
"""
import os
import shutil
import sys
from pathlib import Path

TARGET_DIR = Path(os.path.expanduser("~/.cache/local-f5-misha-ru"))
RU_REPO = "Misha24-10/F5-TTS_RUSSIAN"
RU_CKPT = "F5TTS_v1_Base_accent_tune/model_last_inference.safetensors"
RU_VOCAB = "F5TTS_v1_Base/vocab.txt"


def main() -> int:
    TARGET_DIR.mkdir(parents=True, exist_ok=True)

    from huggingface_hub import hf_hub_download

    print(f"Downloading {RU_REPO}/{RU_CKPT} (~1.3 GB)...", flush=True)
    ckpt_src = hf_hub_download(repo_id=RU_REPO, filename=RU_CKPT)

    print(f"Downloading {RU_REPO}/{RU_VOCAB}...", flush=True)
    vocab_src = hf_hub_download(repo_id=RU_REPO, filename=RU_VOCAB)

    dst_ckpt = TARGET_DIR / "model_v1.safetensors"
    dst_vocab = TARGET_DIR / "vocab.txt"

    if not dst_ckpt.exists() or dst_ckpt.stat().st_size != os.path.getsize(ckpt_src):
        print(f"Copying ckpt -> {dst_ckpt}", flush=True)
        shutil.copy(ckpt_src, dst_ckpt)
    else:
        print(f"ckpt up-to-date: {dst_ckpt}", flush=True)

    if not dst_vocab.exists() or dst_vocab.stat().st_size != os.path.getsize(vocab_src):
        print(f"Copying vocab -> {dst_vocab}", flush=True)
        shutil.copy(vocab_src, dst_vocab)
    else:
        print(f"vocab up-to-date: {dst_vocab}", flush=True)

    print(f"\nDone. tts_worker.py will now route Cyrillic F5 calls through MLX.", flush=True)
    print(f"Staged at: {TARGET_DIR}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

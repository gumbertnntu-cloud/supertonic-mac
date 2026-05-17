#!/usr/bin/env python
"""Persistent TTS worker.

Long-running process that loads each engine on first use and keeps it
in memory for subsequent requests. Speaks JSON over stdio so the Swift app can
hold a single Process for the whole session.

Protocol
--------
Each request is one line on stdin: a JSON object. Each response is one line on
stdout: also a JSON object. Library chatter (model download progress, warnings)
goes to stderr and is ignored by the parent.

Request schema (action-tagged):

    {"action": "ping"}
    {"action": "synthesize_supertonic", "voice": "M1", "text": "...", "out": "/tmp/x.wav"}
    {"action": "synthesize_silero",     "voice": "aidar", "text": "...", "out": "/tmp/x.wav"}
    {"action": "synthesize_f5",         "text": "...", "ref_audio": "...",
                                          "ref_text": "...", "out": "/tmp/x.wav",
                                          "backend": "auto"|"mlx"|"torch"}
    {"action": "asr_gigaam", "audio": "/tmp/sample.wav"}
    {"action": "shutdown"}

Response schema:

    {"ok": true,  "engine": "silero", "duration": 3.2, "rtf": 0.21}
    {"ok": true,  "text": "..."}                              # for asr_gigaam
    {"ok": false, "error": "human readable message"}
"""
import json
import os
import sys
import time
import traceback
import warnings
import contextlib

warnings.filterwarnings("ignore", category=SyntaxWarning)
warnings.filterwarnings("ignore", category=UserWarning)


# Lazy-loaded engine handles. Functions return them, caching globally.
_silero_model = None
_supertonic_pipeline = None
_f5_torch = None
_gigaam = None


# Save a copy of the real stdout FD at startup — BEFORE anything has a chance
# to override it. All protocol responses are written via this FD, so even if
# we redirect FD 1 to /dev/null inside a handler (to silence tqdm / hf_hub /
# library prints that bypass sys.stdout), our response still reaches the parent.
_PROTOCOL_FD = os.dup(sys.stdout.fileno())


def _send_response(obj):
    payload = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
    os.write(_PROTOCOL_FD, payload)


@contextlib.contextmanager
def _quiet():
    """FD-level silencing — replaces FD 1 and FD 2 with /dev/null so even
    libraries that write directly via the file descriptor (tqdm,
    huggingface_hub progress bars, native code) can't pollute our protocol.
    Inside the block, sys.stdout still goes nowhere — but _send_response uses
    the saved _PROTOCOL_FD so responses keep flowing."""
    devnull = os.open(os.devnull, os.O_WRONLY)
    saved_out = os.dup(1)
    saved_err = os.dup(2)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    try:
        yield
    finally:
        os.dup2(saved_out, 1)
        os.dup2(saved_err, 2)
        os.close(devnull)
        os.close(saved_out)
        os.close(saved_err)


# ----- Silero -----

def _ensure_silero():
    global _silero_model
    if _silero_model is not None:
        return _silero_model
    import torch
    torch.set_num_threads(max(1, os.cpu_count() or 4))
    with _quiet():
        model, _ = torch.hub.load(
            repo_or_dir="snakers4/silero-models",
            model="silero_tts",
            language="ru",
            speaker="v4_ru",
            trust_repo=True,
        )
        model.to(torch.device("cpu"))
    _silero_model = model
    return model


def do_silero(req):
    import soundfile as sf
    model = _ensure_silero()
    sr = 48000
    t = time.time()
    with _quiet():
        audio = model.apply_tts(
            text=req["text"],
            speaker=req.get("voice", "aidar"),
            sample_rate=sr,
            put_accent=True,
            put_yo=True,
        )
    out_path = req["out"]
    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    sf.write(out_path, audio.cpu().numpy(), sr, subtype="PCM_16")
    dur = len(audio) / sr
    synth = time.time() - t
    return {"ok": True, "engine": "silero", "out": out_path, "duration": dur, "rtf": synth / max(dur, 1e-6)}


# ----- Supertonic ONNX -----
# We don't have a clean public API for Supertonic 3 — we shell out to
# example_onnx.py in the upstream repo on each call, but since the worker stays
# alive we still gain process-startup savings between calls. The deeper win
# (in-process model caching) requires factoring example_onnx.py upstream; left
# as a follow-up.

def do_supertonic(req):
    import subprocess
    upstream = os.path.expanduser("~/projects/supertonic")
    script = f"{upstream}/py/example_onnx.py"
    voice_style = f"{upstream}/assets/voice_styles/{req.get('voice', 'M1')}.json"
    out_dir = os.path.dirname(os.path.abspath(req["out"])) or "."
    os.makedirs(out_dir, exist_ok=True)
    t = time.time()
    res = subprocess.run(
        [
            sys.executable, script,
            "--n-test", "1",
            "--lang", "na",
            "--text", req["text"],
            "--voice-style", voice_style,
            "--save-dir", out_dir,
        ],
        cwd=f"{upstream}/py",
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        return {"ok": False, "error": f"supertonic exited {res.returncode}: {res.stderr[-500:]}"}
    # Find the freshest WAV in out_dir and rename to req["out"]
    wavs = sorted(
        [os.path.join(out_dir, f) for f in os.listdir(out_dir) if f.endswith(".wav")],
        key=os.path.getmtime,
        reverse=True,
    )
    if not wavs:
        return {"ok": False, "error": "supertonic produced no .wav"}
    if wavs[0] != os.path.abspath(req["out"]):
        os.replace(wavs[0], req["out"])
    synth = time.time() - t
    return {"ok": True, "engine": "supertonic", "out": req["out"], "duration": None, "rtf": None, "elapsed": synth}


# ----- F5 -----

def _resolve_f5_backend(selected, text):
    if selected and selected != "auto":
        return selected
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return "mlx"
    cyr = sum(1 for c in letters if "Ѐ" <= c <= "ӿ")
    return "torch" if (cyr / len(letters)) > 0.3 else "mlx"


def _ensure_f5_torch():
    global _f5_torch
    if _f5_torch is not None:
        return _f5_torch
    with _quiet():
        from f5_tts.api import F5TTS
        _f5_torch = F5TTS(model="F5TTS_v1_Base", device="cpu")
    return _f5_torch


def do_f5(req):
    backend = _resolve_f5_backend(req.get("backend", "auto"), req["text"])
    out = req["out"]
    os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)

    if backend == "mlx":
        # f5_tts_mlx requires 24kHz reference
        import soundfile as sf
        info = sf.info(req["ref_audio"])
        ref_path = req["ref_audio"]
        if info.samplerate != 24000:
            with _quiet():
                import librosa
                y, _ = librosa.load(ref_path, sr=24000)
            base, _ext = os.path.splitext(ref_path)
            ref_path = f"{base}_24k.wav"
            if not os.path.exists(ref_path):
                sf.write(ref_path, y, 24000, subtype="PCM_16")
        t = time.time()
        with _quiet():
            # Import inside _quiet too — first import triggers vocoder lazy-loads
            # that print to stdout via huggingface_hub.
            from f5_tts_mlx.generate import generate
            generate(
                generation_text=req["text"],
                ref_audio_path=ref_path,
                ref_audio_text=req["ref_text"],
                output_path=out,
                steps=int(req.get("steps", 8)),
            )
        synth = time.time() - t
        dur_info = sf.info(out)
        dur = dur_info.frames / dur_info.samplerate
        return {"ok": True, "engine": "f5/mlx", "out": out, "duration": dur, "rtf": synth / max(dur, 1e-6)}

    # torch backend
    f5 = _ensure_f5_torch()
    t = time.time()
    with _quiet():
        wav, sr, _ = f5.infer(
            ref_file=req["ref_audio"],
            ref_text=req["ref_text"],
            gen_text=req["text"],
            file_wave=out,
            remove_silence=True,
        )
    synth = time.time() - t
    dur = len(wav) / sr if hasattr(wav, "__len__") else 0
    return {"ok": True, "engine": "f5/torch", "out": out, "duration": dur, "rtf": synth / max(dur, 1e-6)}


# ----- ASR (GigaAM) -----

def _ensure_gigaam():
    global _gigaam
    if _gigaam is not None:
        return _gigaam
    with _quiet():
        from gigaam_mlx import load_model, transcribe
        model, tokenizer = load_model("rnnt")
    _gigaam = (model, tokenizer, transcribe)
    return _gigaam


def do_asr(req):
    model, tokenizer, transcribe = _ensure_gigaam()
    with _quiet():
        text = transcribe(model, tokenizer, req["audio"])
    return {"ok": True, "text": text.strip()}


# ----- Dispatcher -----

HANDLERS = {
    "ping": lambda req: {"ok": True, "pong": True},
    "synthesize_supertonic": do_supertonic,
    "synthesize_silero": do_silero,
    "synthesize_f5": do_f5,
    "asr_gigaam": do_asr,
}


def main() -> int:
    # Signal readiness via the protected FD — Swift waits for this before sending requests.
    _send_response({"ready": True})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            _send_response({"ok": False, "error": f"bad json: {exc}"})
            continue
        action = req.get("action", "")
        if action == "shutdown":
            _send_response({"ok": True, "shutdown": True})
            return 0
        handler = HANDLERS.get(action)
        if handler is None:
            _send_response({"ok": False, "error": f"unknown action: {action}"})
            continue
        try:
            resp = handler(req)
        except Exception as exc:
            resp = {
                "ok": False,
                "error": f"{type(exc).__name__}: {exc}",
                "traceback": traceback.format_exc(limit=3),
            }
        _send_response(resp)
    return 0


if __name__ == "__main__":
    sys.exit(main())

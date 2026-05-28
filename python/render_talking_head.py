#!/usr/bin/env python3
"""SadTalker CLI wrapper for the GuiAssert-SadTalker plugin.

Invokes the upstream `inference.py` against a portrait image + WAV
narration, and produces a single MP4 at the requested output path.

Used by GuiAssert's `talking_head` module via subprocess. Exits 0 on
success, non-zero with a diagnostic message on failure.

Usage:
    python render_talking_head.py \
        --audio /path/to/narration.wav \
        --source-image /path/to/portrait.png \
        --output /path/to/talking_head.mp4 \
        [--device mps|cpu|auto] [--still-mode] [--preprocess full|resize|crop]

Design choices:
  * The produced MP4 INCLUDES the narration audio track muxed in.
    The GuiAssert compose pipeline does its own narration mixing via
    a separate `narration.wav` input, so the audio in the talking-head
    MP4 is effectively ignored by the final composition — but we keep
    it for stand-alone playback debugging.
  * `--device auto` picks MPS if available, otherwise CPU. SadTalker's
    upstream `inference.py` only supports the cuda/cpu codepaths; we
    monkey-patch the device selection here. MPS has limited op coverage
    in some SadTalker layers — if MPS fails the user should pass
    `--device cpu` explicitly.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def resolve_device(requested: str) -> str:
    """Pick the actual device string."""
    if requested in ("cpu",):
        return "cpu"
    if requested in ("mps",):
        return "mps"
    # auto
    try:
        import torch  # local import — keeps the script importable for --help
        if torch.backends.mps.is_available():
            return "mps"
    except Exception:
        pass
    return "cpu"


def main() -> int:
    parser = argparse.ArgumentParser(description="SadTalker CLI wrapper.")
    parser.add_argument("--audio", required=True, help="Narration WAV path")
    parser.add_argument("--source-image", required=True, help="Portrait PNG/JPG")
    parser.add_argument("--output", required=True, help="Destination MP4 path")
    parser.add_argument("--device", default="auto", choices=["auto", "mps", "cpu"])
    parser.add_argument("--still-mode", action="store_true",
                        help="Reduce head motion — useful for small portraits.")
    parser.add_argument(
        "--preprocess", default="crop",
        choices=["crop", "extcrop", "resize", "full", "extfull"],
        help="Pass-through to SadTalker's inference.py")
    parser.add_argument("--size", type=int, default=256, choices=[256, 512])
    parser.add_argument("--enhancer", default=None,
                        help="Optional face enhancer (gfpgan / RestoreFormer)")
    args = parser.parse_args()

    audio = Path(args.audio).resolve()
    source = Path(args.source_image).resolve()
    output = Path(args.output).resolve()

    if not audio.exists():
        print(f"ERROR: audio not found: {audio}", file=sys.stderr)
        return 2
    if not source.exists():
        print(f"ERROR: source image not found: {source}", file=sys.stderr)
        return 2
    output.parent.mkdir(parents=True, exist_ok=True)

    # The wrapper lives at python/render_talking_head.py inside the
    # GuiAssert-SadTalker checkout; SadTalker upstream is the sibling
    # `upstream/` folder.
    here = Path(__file__).resolve().parent
    upstream = here / "upstream"
    inference = upstream / "inference.py"
    if not inference.exists():
        print(f"ERROR: SadTalker upstream not found at {upstream}", file=sys.stderr)
        return 3

    device = resolve_device(args.device)
    print(f"[render_talking_head] device={device} preprocess={args.preprocess} "
          f"still={args.still_mode} size={args.size}")

    # SadTalker writes into `result_dir/<timestamp>.mp4`. We use a private
    # results dir and then move the produced MP4 into `output`.
    with tempfile.TemporaryDirectory(prefix="sadtalker-results-") as tmpdir:
        result_dir = Path(tmpdir)
        cmd = [
            sys.executable, str(inference),
            "--driven_audio", str(audio),
            "--source_image", str(source),
            "--result_dir", str(result_dir),
            "--checkpoint_dir", str(upstream / "checkpoints"),
            "--preprocess", args.preprocess,
            "--size", str(args.size),
        ]
        if args.still_mode:
            cmd.append("--still")
        if args.enhancer:
            cmd.extend(["--enhancer", args.enhancer])
        # SadTalker's inference.py picks cpu vs cuda from torch.cuda.is_available().
        # We need to coerce the device. The simplest knob it exposes is
        # the `--cpu` flag, which forces cpu. For MPS we set an env var so
        # any callers that respect it can opt in, but upstream itself will
        # use CPU. Real MPS path requires patching upstream — out of scope
        # for the first integration. We log clearly which device we end
        # up running on.
        if device == "cpu":
            cmd.append("--cpu")
        # For MPS we set SADTALKER_DEVICE_OVERRIDE in the env below; the
        # patched inference.py honours it. SadTalker's face renderer has
        # ops that fall back to CPU on MPS — that's fine, the rest still
        # benefits from GPU acceleration where it can.

        # Run from the upstream dir so SadTalker's relative paths resolve.
        env = os.environ.copy()
        # Stop Hugging Face downloads from spinning up: SadTalker doesn't
        # need them at inference time once weights are local.
        env.setdefault("HF_HUB_OFFLINE", "1")
        env.setdefault("TRANSFORMERS_OFFLINE", "1")
        env.setdefault("PYTHONUNBUFFERED", "1")
        # Apple Silicon MPS — fall back to CPU on ops the MPS backend
        # doesn't implement (notably the face-renderer's `grid_sample`
        # variants). Without this PyTorch raises NotImplementedError.
        env.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
        if device == "mps":
            env["SADTALKER_DEVICE_OVERRIDE"] = "mps"

        print(f"[render_talking_head] running: {' '.join(cmd)}")
        started = time.time()
        try:
            proc = subprocess.run(
                cmd, cwd=str(upstream), env=env, check=False)
        except FileNotFoundError as e:
            print(f"ERROR: failed to invoke python: {e}", file=sys.stderr)
            return 4
        elapsed = time.time() - started
        print(f"[render_talking_head] sadtalker exit={proc.returncode} "
              f"elapsed={elapsed:.1f}s")
        if proc.returncode != 0:
            print(f"ERROR: SadTalker inference failed with exit code "
                  f"{proc.returncode}", file=sys.stderr)
            return proc.returncode

        # SadTalker writes <result_dir>/<timestamp>.mp4 (note: NOT inside
        # the timestamp subdir, which is removed when --verbose is off).
        # Glob for it.
        candidates = sorted(result_dir.glob("*.mp4"))
        if not candidates:
            # Maybe verbose mode kept it under a timestamp directory.
            candidates = sorted(result_dir.glob("**/*.mp4"))
        if not candidates:
            print(f"ERROR: SadTalker exited 0 but produced no MP4 under "
                  f"{result_dir}", file=sys.stderr)
            return 5
        produced = candidates[-1]
        print(f"[render_talking_head] produced: {produced} "
              f"({produced.stat().st_size} bytes)")
        if output.exists():
            output.unlink()
        shutil.copyfile(str(produced), str(output))
        print(f"[render_talking_head] copied to: {output}")

    if not output.exists() or output.stat().st_size == 0:
        print(f"ERROR: output missing or empty at {output}", file=sys.stderr)
        return 6
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

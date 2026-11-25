#!/usr/bin/env bash
# Install / refresh the SadTalker plugin.
#
# Steps (each idempotent — re-running the script is safe):
#   1. create a Python 3.10 venv under .venv/ if missing,
#   2. install python/requirements-patched.txt,
#   3. clone SadTalker upstream at the pinned commit from
#      python/COMMIT.txt,
#   4. apply the source patches documented in python/PATCHES.md,
#   5. download SadTalker's pretrained model weights via the bundled
#      script.
#
# Run from inside `nix develop` (the flake exposes python310, git,
# curl, ffmpeg-full). The script makes no assumption about the host
# Python version beyond it being 3.10 — pin python310 in your shell
# before invoking.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PY=${PYTHON:-python3.10}
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "ERROR: $PY not on PATH. Activate the Nix devShell first:" >&2
  echo "  nix develop" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# 1. venv
# ---------------------------------------------------------------------
if [ ! -d .venv ]; then
  echo "[install] creating Python venv under .venv/ ..."
  "$PY" -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

# Refresh pip + wheel ahead of installing scientific deps.
pip install --upgrade pip wheel

# ---------------------------------------------------------------------
# 2. requirements
# ---------------------------------------------------------------------
echo "[install] installing PyTorch (CPU+MPS wheel on macOS, CPU on Linux)..."
# We do NOT pin a CUDA wheel here. Users wanting CUDA acceleration
# should pre-install their preferred torch wheel before re-running
# this script (we don't reinstall when torch is already importable).
if ! python -c "import torch" >/dev/null 2>&1; then
  pip install torch torchvision torchaudio
fi
echo "[install] installing patched requirements ..."
pip install -r python/requirements-patched.txt

# ---------------------------------------------------------------------
# 3. clone upstream at the pinned commit
# ---------------------------------------------------------------------
PINNED_SHA="$(tr -d '[:space:]' < python/COMMIT.txt)"
UPSTREAM_DIR="python/upstream"
if [ ! -d "$UPSTREAM_DIR/.git" ]; then
  echo "[install] cloning SadTalker upstream at $PINNED_SHA ..."
  git clone https://github.com/OpenTalker/SadTalker.git "$UPSTREAM_DIR"
fi
( cd "$UPSTREAM_DIR" && git fetch --tags && git checkout "$PINNED_SHA" )

# ---------------------------------------------------------------------
# 4. apply patches (see python/PATCHES.md for the manifest)
# ---------------------------------------------------------------------
echo "[install] applying numpy2/MPS patches ..."

apply_patch() {
  local file="$1"
  local needle="$2"
  local replacement="$3"
  # -F: a needle is text, not a pattern (`t[0]` is not a bracket class)
  if grep -qF "$needle" "$file" 2>/dev/null; then
    echo "  patching $file"
    python - "$file" "$needle" "$replacement" <<'PY'
import sys, pathlib, re
path = pathlib.Path(sys.argv[1])
needle = sys.argv[2]
replacement = sys.argv[3]
data = path.read_text()
data = data.replace(needle, replacement)
path.write_text(data)
PY
  fi
}

# (1) np.VisibleDeprecationWarning -> np.exceptions.VisibleDeprecationWarning
apply_patch "$UPSTREAM_DIR/src/face3d/util/preprocess.py" \
  "np.VisibleDeprecationWarning" \
  "getattr(np, 'exceptions', np).VisibleDeprecationWarning"

# (2) align_img: numpy 2 rejects an array of mixed shapes, and POS returns
# t as a (2, 1) array and s as a 1-element array
apply_patch "$UPSTREAM_DIR/src/face3d/util/preprocess.py" \
  "trans_params = np.array([w0, h0, s, t[0], t[1]])" \
  "trans_params = np.array([float(w0), float(h0), float(np.ravel(s)[0]), float(np.ravel(t)[0]), float(np.ravel(t)[1])])"

# (3) np.float removed in numpy 1.20+
apply_patch "$UPSTREAM_DIR/src/face3d/util/my_awing_arch.py" \
  "preds.astype(np.float, copy=False)" \
  "preds.astype(float, copy=False)"

# (4) util.py: `.type('torch.mps.FloatTensor')` is refused on MPS; a helper
# moves to the type's device and dtype instead, `.type()` everywhere else
# (each needle is gone once patched, so a second run changes nothing)
apply_patch "$UPSTREAM_DIR/src/facerender/modules/util.py" \
  "import torch.nn.utils.spectral_norm as spectral_norm


def kp2gaussian(" \
  "import torch.nn.utils.spectral_norm as spectral_norm


def _coerce_type(t, type):
    if isinstance(type, str) and '.mps.' in type:
        return t.to(dtype=torch.float32, device='mps')
    return t.type(type)


def kp2gaussian("
for pair in x:w y:h z:d; do
  apply_patch "$UPSTREAM_DIR/src/facerender/modules/util.py" \
    "${pair%:*} = torch.arange(${pair#*:}).type(type)" \
    "${pair%:*} = _coerce_type(torch.arange(${pair#*:}), type)"
done

# (5) dense_motion.py: the same, for the heatmap's zeros
apply_patch "$UPSTREAM_DIR/src/facerender/modules/dense_motion.py" \
  "spatial_size[2]).type(heatmap.type())" \
  "spatial_size[2]).to(heatmap)"

# (6) inference.py: SADTALKER_DEVICE_OVERRIDE names the device (the wrapper
# sets it for mps); without it upstream knows only cuda and cpu
apply_patch "$UPSTREAM_DIR/inference.py" \
  '    if torch.cuda.is_available() and not args.cpu:
        args.device = "cuda"' \
  '    if os.environ.get("SADTALKER_DEVICE_OVERRIDE") and not args.cpu:
        args.device = os.environ["SADTALKER_DEVICE_OVERRIDE"]
    elif torch.cuda.is_available() and not args.cpu:
        args.device = "cuda"'

# (8) videoio.py: the venv's own static ffmpeg, not the first on PATH
apply_patch "$UPSTREAM_DIR/src/utils/videoio.py" \
  "cmd = r'ffmpeg -y" \
  "cmd = imageio_ffmpeg.get_ffmpeg_exe() + r' -y"
apply_patch "$UPSTREAM_DIR/src/utils/videoio.py" \
  "import cv2

def load_video_to_cv2(" \
  "import cv2
import imageio_ffmpeg

def load_video_to_cv2("

# (7) basicsr -> torchvision functional_tensor moved to functional.
# We resolve the file by inspecting the venv's site-packages directly —
# `importlib.util.find_spec('basicsr.data.degradations')` would import
# `basicsr/__init__.py`, which itself eagerly imports the broken module
# and raises ModuleNotFoundError before we get a chance to patch.
BASICSR_DEG="$(python -c "import sysconfig, os, sys; sp = sysconfig.get_paths()['purelib']; p = os.path.join(sp, 'basicsr', 'data', 'degradations.py'); print(p if os.path.exists(p) else '')")"
if [ -n "$BASICSR_DEG" ] && grep -q "functional_tensor" "$BASICSR_DEG"; then
  echo "  patching $BASICSR_DEG"
  python - "$BASICSR_DEG" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
data = path.read_text()
data = data.replace(
    "from torchvision.transforms.functional_tensor import rgb_to_grayscale",
    "from torchvision.transforms.functional import rgb_to_grayscale",
)
path.write_text(data)
PY
fi

echo "[install] patch pass complete (see python/PATCHES.md for the full"
echo "          manifest — items 2, 4, 5, 6 are MPS-specific and require"
echo "          manual application against the cloned upstream)."

# ---------------------------------------------------------------------
# 5. weights — defer to SadTalker's own download script
# ---------------------------------------------------------------------
if [ ! -d "$UPSTREAM_DIR/checkpoints" ] || [ -z "$(ls -A "$UPSTREAM_DIR/checkpoints" 2>/dev/null)" ]; then
  echo "[install] downloading SadTalker model weights ..."
  ( cd "$UPSTREAM_DIR" && bash scripts/download_models.sh )
fi

echo
echo "[install] DONE. Sanity-check with: ./scripts/verify-install.sh"

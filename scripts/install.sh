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
  if grep -q "$needle" "$file" 2>/dev/null; then
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

# (3) np.float removed in numpy 1.20+
apply_patch "$UPSTREAM_DIR/src/face3d/util/my_awing_arch.py" \
  "preds.astype(np.float, copy=False)" \
  "preds.astype(float, copy=False)"

# (7) basicsr -> torchvision functional_tensor moved to functional
BASICSR_DEG="$(python -c "import importlib.util as u; m=u.find_spec('basicsr.data.degradations'); print(m.origin if m else '')")"
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

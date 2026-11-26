#!/usr/bin/env bash
# Quick smoke-test that the SadTalker plugin is wired up.
#
# Verifies:
#   * .venv/bin/python exists and imports torch, torchvision and torchaudio
#     without raising,
#   * the installed torch family is exactly the version install.sh pins in
#     python/torch-<platform>.txt (any other version fails),
#   * the wrapper script's --help runs cleanly,
#   * the checkpoints directory is non-empty.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PY=".venv/bin/python"
SCRIPT="python/render_talking_head.py"
UPSTREAM_DIR="python/upstream"

if [ ! -x "$PY" ]; then
  echo "FAIL: $PY not found. Run ./scripts/install.sh first." >&2
  exit 1
fi
if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: wrapper script missing at $SCRIPT" >&2
  exit 1
fi
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) TORCH_REQS="python/torch-linux-x86_64.txt" ;;
  Darwin-arm64) TORCH_REQS="python/torch-macos-arm64.txt" ;;
  *)
    echo "FAIL: no pinned PyTorch set for $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

echo "[verify] importing torch, torchvision, torchaudio ..."
"$PY" -c "import torch, torchvision, torchaudio; print('  torch', torch.__version__, 'cuda', torch.version.cuda, 'cuda_available=', torch.cuda.is_available(), 'mps_available=', torch.backends.mps.is_available())"

echo "[verify] torch family matches the pins in $TORCH_REQS ..."
"$PY" - "$TORCH_REQS" <<'PY'
import importlib.metadata as md
import re
import sys

pins = {}
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"^(torch|torchvision|torchaudio)==(\S+)", line)
        if m:
            pins[m.group(1)] = m.group(2)
bad = 0
for name in ("torch", "torchvision", "torchaudio"):
    want = pins.get(name)
    try:
        have = md.version(name)
    except md.PackageNotFoundError:
        have = None
    ok = want is not None and have == want
    print(f"  {name}: installed {have}, pinned {want}" + ("" if ok else "  <-- MISMATCH"))
    bad += not ok
sys.exit(1 if bad else 0)
PY

if [ ! -d "$UPSTREAM_DIR/checkpoints" ] || [ -z "$(ls -A "$UPSTREAM_DIR/checkpoints" 2>/dev/null)" ]; then
  echo "FAIL: SadTalker checkpoints missing under $UPSTREAM_DIR/checkpoints/" >&2
  echo "Run ./scripts/install.sh to populate them." >&2
  exit 1
fi

echo "[verify] wrapper --help ..."
"$PY" "$SCRIPT" --help >/dev/null

echo "[verify] DONE — SadTalker plugin is wired up."

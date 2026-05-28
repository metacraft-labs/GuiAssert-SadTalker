#!/usr/bin/env bash
# Quick smoke-test that the SadTalker plugin is wired up.
#
# Verifies:
#   * .venv/bin/python exists and imports torch + sadtalker upstream
#     deps without raising,
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
if [ ! -d "$UPSTREAM_DIR/checkpoints" ] || [ -z "$(ls -A "$UPSTREAM_DIR/checkpoints" 2>/dev/null)" ]; then
  echo "FAIL: SadTalker checkpoints missing under $UPSTREAM_DIR/checkpoints/" >&2
  echo "Run ./scripts/install.sh to populate them." >&2
  exit 1
fi

echo "[verify] importing torch ..."
"$PY" -c "import torch; print('  torch', torch.__version__, 'mps_available=', torch.backends.mps.is_available())"

echo "[verify] wrapper --help ..."
"$PY" "$SCRIPT" --help >/dev/null

echo "[verify] DONE — SadTalker plugin is wired up."

# SadTalker patches for the GuiAssert-SadTalker plugin

The `upstream/` directory is a checkout of OpenTalker/SadTalker pinned in
`COMMIT.txt`. SadTalker was last released in 2023 and pins old versions of
numpy, scipy, and torchvision that no longer install under Python 3.10 with
modern PyTorch 2.x on Apple Silicon. This document records every patch
applied so the install can be reproduced.

## Why we patched instead of pinning to legacy versions

We use PyTorch 2.12 (the current stable) so MPS-backed GPU inference works on
Apple Silicon. PyTorch 2.x ships numpy 2.x by default. Numpy 2 removed
several deprecated aliases (`np.float`, `np.VisibleDeprecationWarning` at
module root, etc.) that SadTalker's source still uses, and torchvision 0.17+
moved `functional_tensor` into `functional`.

## requirements-patched.txt

`upstream/requirements.txt` hard-pins very old versions of `numpy`, `scipy`,
`librosa`, `face_alignment`, `imageio`, and `scikit-image`. We bypass it via
`requirements-patched.txt` (checked in alongside this file), which unpins
everything that conflicts with numpy 2.x and lets pip pick compatible newer
wheels. Install with:

    pip install -r python/requirements-patched.txt

Notable resolutions chosen by pip with these unpins:
- numpy 2.2.6
- scipy 1.15.3
- librosa 0.11.0
- face_alignment 1.5.0
- imageio 2.37.3
- scikit-image 0.25.2
- torch 2.12.0, torchvision 0.27.0, torchaudio 2.11.0

`kornia==0.6.8` is kept at its original pin (works with PyTorch 2.x).
`basicsr==1.4.2` is kept at its pinned version — see the source patch below.

## Source patches applied to `upstream/`

These are applied directly to the checked-out copy. If you re-clone upstream
you must reapply them. The first hunk in each file is documented inline with
a `gui-assert-sadtalker patch:` comment.

### 1. `src/face3d/util/preprocess.py`

`np.VisibleDeprecationWarning` moved to `np.exceptions.VisibleDeprecationWarning`
in numpy 2.x. Falls back to the legacy attribute on older numpy.

### 2. `src/face3d/util/preprocess.py` (continued)

`align_img` builds `np.array([w0, h0, s, t[0], t[1]])`. Under numpy 2.x this
raises `ValueError: setting an array element with a sequence` because `t[0]`
may itself be a 0-d numpy scalar (numpy 2 rejects mixed shapes). Patched to
coerce every element through `float(...)` and flatten `t` first.

### 3. `src/face3d/util/my_awing_arch.py`

`preds.astype(np.float, copy=False)`. `np.float` was removed in numpy 1.20+;
replaced with the builtin `float`.

### 4. `src/facerender/modules/util.py`

`make_coordinate_grid_2d` and `make_coordinate_grid` call `.type(type)` where
`type` is a tensor-type string like `'torch.cuda.FloatTensor'`. On MPS this
becomes `'torch.mps.FloatTensor'`, which `.type()` refuses to consume
(`ValueError: invalid type: 'torch.mps.FloatTensor'`). We introduced a
`_coerce_type` helper that special-cases MPS strings via
`.to(dtype=torch.float32, device='mps')` and falls through to `.type(type)`
on every other backend.

### 5. `src/facerender/modules/dense_motion.py`

`zeros = torch.zeros(...).type(heatmap.type())` triggers the same MPS issue.
Replaced with `.to(heatmap)` which copies dtype + device on every backend.

### 6. `inference.py`

Patched the device-selection tail to honour a new `SADTALKER_DEVICE_OVERRIDE`
environment variable. Without it the upstream code only knows about `cuda` /
`cpu`; with it our `render_talking_head.py` wrapper can force `mps` and
PyTorch's `PYTORCH_ENABLE_MPS_FALLBACK=1` handles the few ops MPS lacks.

### 7. site-packages: `basicsr/data/degradations.py`

`basicsr` 1.4.2 imports `torchvision.transforms.functional_tensor.rgb_to_grayscale`.
That submodule was removed in torchvision 0.17. The function was moved to
`torchvision.transforms.functional`. We rewrite the import line in the
installed `basicsr` package. This patch lives in the venv's site-packages,
not in `upstream/` — it is reapplied automatically when the install script
recreates the venv.

The install script resolves the file path via `sysconfig.get_paths()['purelib']`
rather than `importlib.util.find_spec('basicsr.data.degradations')`. `find_spec`
would import `basicsr/__init__.py`, which itself eagerly imports the broken
module and raises `ModuleNotFoundError` *before* the patch can run — so the
sysconfig-based resolution is required for the install to be idempotent.

### 8. `src/utils/videoio.py`

`save_video_with_watermark` invokes a bare `ffmpeg` via `os.system`, picking up
the first one on `PATH`. On Apple Silicon dev boxes a Nix-built `ffmpeg-full`
binary can be selected while the inherited `DYLD_LIBRARY_PATH` still points at
Homebrew's incompatible libavfilter, producing
`Symbol not found: _av_buffer_replace` at launch. The fix swaps the bare
`ffmpeg` token for `imageio_ffmpeg.get_ffmpeg_exe()` — a statically linked
binary bundled with the venv's `imageio-ffmpeg` package, unaffected by host
dynamic-linker state.

## Re-applying the patches

If `python/upstream/` is wiped and re-cloned, the patches above must be
reapplied. They're all small one-liners; the `gui-assert-sadtalker patch:`
comments in the source make them locatable via `grep`. The basicsr
site-package patch is also re-applied automatically by `scripts/install.sh`.

## Dev-shell vs host Python (temporary)

The repo's `flake.nix` requests `python310` from the workspace's transitive
`nixpkgs` follow-chain. The currently pinned channel no longer exposes that
attribute, so `nix develop` in this repo fails until the flake is repinned to
a nixpkgs revision that still ships `python310` (or until the install is
migrated to a newer Python version supported by the patched stack).

As a short-term workaround the install runs against a host Python 3.10
installation (Homebrew's `python@3.10` on macOS, or the distribution's
`python3.10` on Linux); every other dependency is satisfied inside the
local venv created by `scripts/install.sh`. Repin the flake before relying
on `nix develop` for the install.

## Apple Silicon MPS performance

With these patches in place, SadTalker on MPS renders ~26 s of narration in
~3.5 minutes wall-clock on an M-series Mac (Face Renderer runs at ~1.4 it/s).
The CPU path also works but is roughly 10× slower (~12 s/iteration).

Lip-sync remains accurate because the audio→coefficient stage runs entirely
on the GPU and the renderer output is timestamped by `imageio-ffmpeg` at the
WAV's sample rate.

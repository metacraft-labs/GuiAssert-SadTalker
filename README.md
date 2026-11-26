# GuiAssert-SadTalker

Implements the talking-head provider contract of [DemoVideoStudio](https://github.com/metacraft-labs/DemoVideoStudio), version 1 (`demo_video_studio/plugins/talking_head`), and runs its conformance kit in `just test` (`tests/tcontract.nim`). Build it next to DemoVideoStudio and GuiAssert checkouts (or set `DEMO_VIDEO_STUDIO_SRC` and `GUI_ASSERT_SRC`).

SadTalker talking-head plugin for [GuiAssert]. Implements
DemoVideoStudio's `TalkingHeadProvider` contract by shelling out to a
local SadTalker install (a Python 3.10 venv + the OpenTalker/SadTalker
repo at a pinned commit + ~2.4 GB of model weights).

This repository is intentionally heavyweight. By keeping it separate
from GuiAssert, any caller that only wants the lightweight
`stock_avatar` placeholder avoids paying the SadTalker dependency
cost.

[GuiAssert]: ../GuiAssert/

## Layout

```
GuiAssert-SadTalker/
├── flake.nix                          Python 3.10 + nim + git + curl + ffmpeg-full devShell
├── gui_assert_sadtalker.nimble        nimble package
├── src/
│   └── gui_assert_sadtalker.nim       plugin implementation (TalkingHeadProvider)
├── python/
│   ├── render_talking_head.py         SadTalker CLI wrapper
│   ├── requirements-patched.txt       deps relaxed for Python 3.10 + numpy 2.x + PyTorch 2.11
│   ├── torch-linux-x86_64.txt         hash-pinned PyTorch set, CUDA 12.6 (scripts/lock-torch.sh)
│   ├── torch-macos-arm64.txt          hash-pinned PyTorch set, CPU/MPS
│   ├── PATCHES.md                     patch manifest applied to the upstream checkout
│   ├── COMMIT.txt                     pinned upstream SHA
│   └── upstream/                      (gitignored) SadTalker clone — populated by install.sh
├── scripts/
│   ├── install.sh                     create .venv, clone upstream, apply patches, fetch weights
│   ├── verify-install.sh              smoke-test the install, versions against the pins
│   └── lock-torch.sh                  regenerate the hash-pinned PyTorch requirement files
└── tests/
    ├── tsadtalker.nim                 pure tests + `-d:sadtalkerLive` gated live test
    ├── tcontract.nim                  DemoVideoStudio provider-contract kit
    └── tdev_gates.nim                 the repository's own lint/hook/SDK gates
```

## Setup

```sh
nix develop                  # or `direnv allow` once: .envrc is `use flake`
./scripts/install.sh         # ~5 min on a fresh checkout (~2.4 GB of weights)
./scripts/verify-install.sh  # quick smoke-test
```

The install script is idempotent. Re-running it skips already-done
steps and applies the patches incrementally.

## Wiring into a runner

```nim
import demo_video_studio/plugins/talking_head
import gui_assert_sadtalker

let reg = newRegistry()         # registry pre-populated with `stock_avatar`
registerSadTalker(reg)          # now `sadtalker` is also registered

var opts = TalkingHeadOpts(
  avatarImagePath: some(avatarPng),
  device: "mps",
  cacheDir: some("/tmp/sadtalker-cache"),
  extraArgs: @["--still-mode", "--preprocess", "crop"],
)
generateTalkingHead(reg, "sadtalker", narrationWav, outputMp4, opts)
```

Path discovery uses three environment variables (each with a sensible
default):

| Variable                             | Default                                | Purpose                               |
| ------------------------------------ | -------------------------------------- | ------------------------------------- |
| `GUI_ASSERT_SADTALKER_HOME`          | this repo's root                       | Override the plugin install location. |
| `GUI_ASSERT_SADTALKER_PYTHON`        | `<home>/.venv/bin/python`              | Override the Python interpreter.      |
| `GUI_ASSERT_SADTALKER_RENDER_SCRIPT` | `<home>/python/render_talking_head.py` | Override the wrapper script.          |

## Tests

```sh
# Pure tests — always safe to run.
nim c -r --hints:off --path:src --path:../DemoVideoStudio/src --path:../GuiAssert/src tests/tsadtalker.nim

# Live end-to-end — requires the install to have completed.
nim c -d:sadtalkerLive -r --hints:off --path:src --path:../DemoVideoStudio/src --path:../GuiAssert/src tests/tsadtalker.nim
```

The live test fails the run if SadTalker is not actually available —
it is not a graceful skip. CI that does not want to install SadTalker
simply compiles without `-d:sadtalkerLive`.

## Development gates

| Recipe        | What it runs                                                                                                                               |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `just build`  | compiles the plugin module, debug and release                                                                                              |
| `just test`   | the pure suites above, plus `tests/tdev_gates.nim`                                                                                         |
| `just lint`   | `nim check` of the module and every test program, `nixfmt --check`, `shellcheck`, `ruff check`, `editorconfig-checker`, `prettier --check` |
| `just format` | `nixfmt` and `prettier --write`                                                                                                            |

`.pre-commit-config.yaml` carries the whole MCL standard hook set and a
`just lint` hook; install it with `prek install --install-hooks` from the dev
shell, which provides every tool the hooks call (including `uv`, without which
prek cannot install hooks on NixOS).

On Linux the dev shell prepends its own C++ runtime (`libstdc++.so.6`) to
`LD_LIBRARY_PATH`. The PyTorch wheels `install.sh` puts in `.venv` load it
through the dynamic loader, and NixOS has no ambient copy, so without it
`import torch` fails.

## License

MIT — see `LICENSE`. Upstream SadTalker is MIT-licensed; this plugin
does not redistribute it (the install script clones it directly from
GitHub).

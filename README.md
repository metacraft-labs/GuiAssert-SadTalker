# GuiAssert-SadTalker

SadTalker talking-head plugin for [GuiAssert]. Implements
GuiAssert's `TalkingHeadProvider` contract by shelling out to a
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
│   ├── requirements-patched.txt       deps relaxed for Python 3.10 + numpy 2.x + PyTorch 2.12
│   ├── PATCHES.md                     patch manifest applied to the upstream checkout
│   ├── COMMIT.txt                     pinned upstream SHA
│   └── upstream/                      (gitignored) SadTalker clone — populated by install.sh
├── scripts/
│   ├── install.sh                     create .venv, clone upstream, apply patches, fetch weights
│   └── verify-install.sh              smoke-test the install
└── tests/
    └── tsadtalker.nim                 pure tests + `-d:sadtalkerLive` gated live test
```

## Setup

```sh
nix develop                  # python310 + nim + ffmpeg-full + cmake + pkg-config
./scripts/install.sh         # ~5 min on a fresh checkout (~2.4 GB of weights)
./scripts/verify-install.sh  # quick smoke-test
```

The install script is idempotent. Re-running it skips already-done
steps and applies the patches incrementally.

## Wiring into a runner

```nim
import gui_assert/talking_head
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

| Variable | Default | Purpose |
| --- | --- | --- |
| `GUI_ASSERT_SADTALKER_HOME` | this repo's root | Override the plugin install location. |
| `GUI_ASSERT_SADTALKER_PYTHON` | `<home>/.venv/bin/python` | Override the Python interpreter. |
| `GUI_ASSERT_SADTALKER_RENDER_SCRIPT` | `<home>/python/render_talking_head.py` | Override the wrapper script. |

## Tests

```sh
# Pure tests — always safe to run.
nim c -r --hints:off --path:src --path:../GuiAssert/src tests/tsadtalker.nim

# Live end-to-end — requires the install to have completed.
nim c -d:sadtalkerLive -r --hints:off --path:src --path:../GuiAssert/src tests/tsadtalker.nim
```

The live test fails the run if SadTalker is not actually available —
it is not a graceful skip. CI that does not want to install SadTalker
simply compiles without `-d:sadtalkerLive`.

## License

MIT — see `LICENSE`. Upstream SadTalker is MIT-licensed; this plugin
does not redistribute it (the install script clones it directly from
GitHub).

# GuiAssert-SadTalker
#
# `just build`             - compile the plugin module (debug and release).
# `just test`              - run the pure tests (no SadTalker install needed).
# `just test-live`         - run the gated live test (-d:sadtalkerLive).
# `just lint`              - every linter and check this repository has.
# `just format`            - apply the formatters of the MCL standard hook set.
# `just install`           - install / refresh the local SadTalker setup.
# `just verify`            - smoke-test the install.
#
# Every recipe expects the dev shell (`nix develop`, direnv via `.envrc`, or
# `repro exec -- just <recipe>`), which provides each tool named below.

# Sibling sources: DemoVideoStudio (the plugin contract) and GuiAssert (what
# the studio itself builds on), next to this checkout unless overridden.
studio_src := env_var_or_default("DEMO_VIDEO_STUDIO_SRC", "../DemoVideoStudio/src")
gui_assert_src := env_var_or_default("GUI_ASSERT_SRC", "../GuiAssert/src")
nim_paths := "--path:src --path:" + studio_src + " --path:" + gui_assert_src

default: test

alias t := test
alias fmt := format

# This repository ships a Nim library module, not an executable, so building
# means compiling the module in both modes the nimcache layout distinguishes.
build:
    nim c --hints:off --app:lib --noMain {{ nim_paths }} -o:.nimcache/build/gui_assert_sadtalker_d.so src/gui_assert_sadtalker.nim
    nim c --hints:off --app:lib --noMain -d:release {{ nim_paths }} -o:.nimcache/build/gui_assert_sadtalker_r.so src/gui_assert_sadtalker.nim

# Pure unit tests for the plugin, the provider-contract kit and the
# repository's own development gates (tests/tdev_gates.nim).
test:
    nim c -r --hints:off --path:src tests/tnimcache_is_worktree_local.nim
    nim c -r --hints:off {{ nim_paths }} tests/tsadtalker.nim
    nim c -r --hints:off {{ nim_paths }} tests/tcontract.nim
    nim c -r --hints:off tests/tdev_gates.nim
    nim c -r --hints:off tests/twrapper.nim

# End-to-end live test.  Requires a completed install (.venv + upstream
# checkout + model weights) under this repo.
test-live:
    nim c -d:sadtalkerLive -r --hints:off {{ nim_paths }} tests/tsadtalker.nim

# Install / refresh the local SadTalker setup.
install:
    ./scripts/install.sh

# Smoke-test the install.
verify:
    ./scripts/verify-install.sh

# All linters and checks. Run by the `lint` pre-commit hook. Each sub-recipe
# exits non-zero and names the offending file on a real defect;
# tests/tdev_gates.nim plants one per linter to prove it.
lint: lint-nim lint-nix lint-shell lint-python lint-style

# Semantic check of the plugin module and of every Nim test program, live
# test included (-d:sadtalkerLive compiles the gated branch too).
lint-nim:
    nim check --hints:off {{ nim_paths }} src/gui_assert_sadtalker.nim
    nim check --hints:off {{ nim_paths }} tests/tsadtalker.nim
    nim check --hints:off -d:sadtalkerLive {{ nim_paths }} tests/tsadtalker.nim
    nim check --hints:off {{ nim_paths }} tests/tcontract.nim
    nim check --hints:off --path:src tests/tnimcache_is_worktree_local.nim
    nim check --hints:off tests/tdev_gates.nim

lint-nix:
    nixfmt --check flake.nix

lint-shell:
    shellcheck scripts/install.sh scripts/verify-install.sh

lint-python:
    ruff check --no-cache python/render_talking_head.py

# The style members of the standard hook set, as checks (no rewriting).
lint-style:
    editorconfig-checker
    prettier --check --log-level=warn --ignore-unknown .

# The formatters of the MCL standard hook set, applied in place.
format:
    nixfmt flake.nix
    prettier --write --log-level=warn --ignore-unknown .

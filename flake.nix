{
  description = "GuiAssert-SadTalker - SadTalker talking-head plugin for GuiAssert";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    # SadTalker's installer and wheel set require Python 3.10, which the
    # shared unstable input no longer carries. flake.lock pins this channel.
    python310-nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-parts.follows = "nixos-modules/flake-parts";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        let
          # The shared libraries the venv's manylinux wheels expect from a
          # host /usr/lib that NixOS does not have (from `ldd` over the venv,
          # 2026-11-27): libstdc++ (torch); libz (numpy's _multiarray_umath,
          # pillow, scipy, PyAV, llvmlite); and for opencv-python's cv2,
          # libGL, glib's libglib and libgthread, and libxcb, plus libX11,
          # libXext, libSM and libICE for its bundled Qt platform plugin.
          # Pinned by flake.lock, never taken from the host profile.
          runtimeLibs = pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.stdenv.cc.cc.lib
            pkgs.zlib
            pkgs.libGL
            pkgs.glib
            pkgs.libxcb
            pkgs.libx11
            pkgs.libxext
            pkgs.libsm
            pkgs.libice
          ];
          libraryPath = pkgs.lib.makeLibraryPath runtimeLibs;
          # The same path as a store file: scripts/install.sh roots it at
          # .venv/library-path, and the provider prepends its contents to
          # LD_LIBRARY_PATH before it starts the venv's Python, so a render
          # outside this shell finds the same libraries.
          libraryPathFile = pkgs.writeText "gui-assert-sadtalker-library-path" libraryPath;
        in
        {
          devShells.default = pkgs.mkShell {
            # PyTorch is intentionally NOT in this list — its wheel ecosystem
            # works better via pip into the local .venv (so MPS-enabled
            # builds on Apple Silicon and CUDA builds on Linux compose
            # naturally without rebuilding the Nix closure). The system
            # packages below cover the build/runtime toolchain that
            # `scripts/install.sh` and the plugin's Nim subprocess rely on.
            packages = with pkgs; [
              inputs.python310-nixpkgs.legacyPackages.${system}.python310
              nim
              nimble
              just
              git
              curl
              ffmpeg-full
              pkg-config
              cmake
              # The repository's own gates (`just lint`, `just format` and the
              # committed `.pre-commit-config.yaml`). repo-requirements.md §4.1:
              # the flake provides the tools, the committed config the rules.
              # `uv` must be on PATH on NixOS, or prek downloads a generic-linux
              # uv that cannot exec there and every hook fails to install.
              nixfmt
              shellcheck
              ruff
              prek
              uv
              editorconfig-checker
              prettier
            ];
            shellHook = ''
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                # The PyTorch, numpy and opencv wheels pip installs into .venv
                # load libstdc++.so.6, libz.so.1, libGL.so.1, libxcb.so.1 and
                # more (runtimeLibs above) through the dynamic loader; their own DT_RPATH lists only
                # $ORIGIN-relative wheel directories, and python's RUNPATH does
                # not apply to them. NixOS has none of these ambiently, so
                # `import torch`, `import numpy` and `import cv2` fail without
                # this. Prepend the pinned set and keep any inherited suffix.
                export LD_LIBRARY_PATH="${libraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                # scripts/install.sh records this file in the venv (see
                # runtimeLibs above).
                export GUI_ASSERT_SADTALKER_LIBRARY_PATH_FILE="${libraryPathFile}"
              ''}
              # SadTalker on Apple Silicon: PyTorch's MPS backend still
              # has gaps for some ops; this env var instructs PyTorch
              # to silently fall back to CPU for unsupported kernels.
              export PYTORCH_ENABLE_MPS_FALLBACK=1
              # Once weights are local we don't need Hugging Face hub
              # at inference time; keeping this off avoids surprise
              # network calls from SadTalker's deps.
              export HF_HUB_OFFLINE=1
              export TRANSFORMERS_OFFLINE=1
              echo "GuiAssert-SadTalker dev shell ready."
              echo "  python:   $(python3 --version)"
              echo "  nim:      $(nim --version | head -1)"
              echo "  ffmpeg:   $(ffmpeg -version | head -1)"
              echo
              echo "Next steps:"
              echo "  ./scripts/install.sh           # create .venv + clone upstream + apply patches + download weights"
              echo "  ./scripts/verify-install.sh    # smoke-test the install"
            '';
          };
        };
    };
}

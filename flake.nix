{
  description = "GuiAssert-SadTalker - SadTalker talking-head plugin for GuiAssert";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
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
        {
          devShells.default = pkgs.mkShell {
            # PyTorch is intentionally NOT in this list — its wheel ecosystem
            # works better via pip into the local .venv (so MPS-enabled
            # builds on Apple Silicon and CUDA builds on Linux compose
            # naturally without rebuilding the Nix closure). The system
            # packages below cover the build/runtime toolchain that
            # `scripts/install.sh` and the plugin's Nim subprocess rely on.
            packages = with pkgs; [
              python310
              nim
              nimble
              just
              git
              curl
              ffmpeg-full
              pkg-config
              cmake
            ];
            shellHook = ''
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

## The Python side the provider spawns, checked without SadTalker installed.
##
##   * `render_talking_head.resolve_device` picks CUDA where torch has it
##     (before MPS, then CPU), and honours an explicit `--device`. A fake
##     `torch` module stands in for the real one, so the check runs on any
##     host with a Python 3.
##   * every patch `python/PATCHES.md` documents for a source file is one
##     `scripts/install.sh` applies: a documented patch the script did not
##     apply once let `align_img` fail on numpy 2 at the first render.

import std/[os, osproc, strutils, unittest]

let root = currentSourcePath().parentDir.parentDir
let python = findExe("python3")

var calls = 0

proc resolveWith(cuda, mps: bool; requested: string): string =
  inc calls
  let fake = getTempDir() / ("twrapper-torch-" & $getCurrentProcessId() & "-" & $calls)
  createDir(fake / "torch")
  let py = proc (b: bool): string = (if b: "True" else: "False")
  writeFile(fake / "torch" / "__init__.py",
    "class _Cuda:\n    @staticmethod\n    def is_available(): return " & py(cuda) & "\n" &
    "class _Mps:\n    @staticmethod\n    def is_available(): return " & py(mps) & "\n" &
    "class _Backends:\n    mps = _Mps()\n" &
    "cuda = _Cuda()\nbackends = _Backends()\n")
  defer: removeDir(fake)
  let code = "import sys; sys.path[:0] = [" & escape(fake) & ", " & escape(root / "python") &
    "]; import render_talking_head as r; print(r.resolve_device(" & escape(requested) & "))"
  let (o, rc) = execCmdEx(quoteShellCommand(@[python, "-I", "-B", "-c", code]))
  doAssert rc == 0, o
  o.strip

suite "the wrapper":

  test "python3 is on PATH":
    check python.len > 0

  test "auto picks CUDA, then MPS, then the CPU":
    check resolveWith(cuda = true, mps = false, "auto") == "cuda"
    check resolveWith(cuda = true, mps = true, "auto") == "cuda"
    check resolveWith(cuda = false, mps = true, "auto") == "mps"
    check resolveWith(cuda = false, mps = false, "auto") == "cpu"

  test "an explicit device is honoured":
    check resolveWith(cuda = true, mps = false, "cpu") == "cpu"
    check resolveWith(cuda = false, mps = false, "cuda") == "cuda"

  test "every documented source patch is applied by the installer":
    let doc = readFile(root / "python" / "PATCHES.md")
    let script = readFile(root / "scripts" / "install.sh")
    var n = 0
    for line in doc.splitLines:
      if line.startsWith("### ") and "`src/" in line:
        let num = line[4 ..< line.find('.')]
        inc n
        check ("# (" & num & ")") in script
    check n > 0

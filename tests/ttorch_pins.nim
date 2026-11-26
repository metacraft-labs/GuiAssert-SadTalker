## PyTorch is pinned: `scripts/install.sh` installs the torch family only
## from a hash-pinned requirement file, and that file names a matched set.
##
## On 2026-11-25 an unpinned `pip install torch torchvision torchaudio`
## resolved to torch 2.14.1, torchvision 0.29.2 and torchaudio 2.11.1 on a
## CUDA host: a set nothing in the plugin was tested against, and not even
## a matched one. This test reads the installer and the per-platform
## requirement files it names and checks:
##
##   * every `pip install` in the installer that names a torch-family package
##     does so through `--require-hashes -r <file>`, never as a bare name;
##   * each named file pins torch, torchvision and torchaudio with `==` and
##     at least one `--hash=sha256:<64 hex>` each;
##   * the three versions are a known matched set (`matchedSets`), and every
##     platform file names the same set.
##
## Control: the checks are run against the installer line this test exists to
## stop, and must refuse it; and against a requirement file with one hash
## removed and with a mismatched triple, and must refuse both.
##
## No mocks: the positive checks parse the real files in this checkout. The
## negative controls are literal text, because the defect they model is a line
## of text.

import std/[os, sequtils, strutils, tables, unittest]

let root = currentSourcePath().parentDir.parentDir

const torchFamily = ["torch", "torchvision", "torchaudio"]

## Matched (torch, torchvision, torchaudio) releases, from PyTorch's own
## compatibility table. A pin outside this list fails the test: add a set
## here only after checking it there.
const matchedSets = [
  ("2.11.0", "0.26.0", "2.11.0"),
  ("2.10.0", "0.25.0", "2.10.0"),
  ("2.9.1", "0.24.1", "2.9.1"),
  ("2.9.0", "0.24.0", "2.9.0"),
  ("2.8.0", "0.23.0", "2.8.0"),
  ("2.7.1", "0.22.1", "2.7.1"),
  ("2.7.0", "0.22.0", "2.7.0"),
  ("2.6.0", "0.21.0", "2.6.0"),
]

proc logicalLines(text: string): seq[string] =
  ## Join backslash continuations, drop comments and blank lines.
  var cur = ""
  for raw in text.splitLines:
    var line = raw
    let hashAt = line.find(" #")
    if line.strip.startsWith("#"): line = ""
    elif hashAt >= 0: line = line[0 ..< hashAt]
    line = line.strip
    if line.endsWith("\\"):
      cur.add line[0 ..< ^1] & " "
    else:
      cur.add line
      if cur.strip.len > 0: result.add cur.strip
      cur = ""
  if cur.strip.len > 0: result.add cur.strip

proc mentionsTorchFamily(words: seq[string]): bool =
  for w in words:
    let name = w.split({'=', '<', '>', '~', '!', '['})[0]
    if name in torchFamily: return true

proc installerProblems(script: string): seq[string] =
  ## Every torch-family `pip install` must be `--require-hashes -r FILE`.
  for line in logicalLines(script):
    let words = line.splitWhitespace
    let at = words.find("pip")
    if at < 0 or at + 1 >= words.len or words[at + 1] != "install": continue
    let args = words[at + 2 .. ^1]
    if mentionsTorchFamily(args):
      result.add "installs a torch-family package by name: " & line
    if "--require-hashes" notin args and
        args.anyIt(it.contains("torch-")):
      result.add "installs a torch requirement file without --require-hashes: " & line

proc hashedInstalls(script: string): int =
  ## `pip install` lines that install a requirement file with --require-hashes.
  for line in logicalLines(script):
    let words = line.splitWhitespace
    let at = words.find("pip")
    if at >= 0 and at + 1 < words.len and words[at + 1] == "install" and
        "--require-hashes" in words and "-r" in words:
      inc result

proc requirementFiles(script: string): seq[string] =
  ## The torch requirement files the installer selects (python/torch-*.txt).
  var at = script.find("python/torch-")
  while at >= 0:
    let stop = script.find(".txt", at)
    if stop < 0: break
    let f = script[at ..< stop + 4]
    if f.allCharsInSet(Letters + Digits + {'/', '-', '_', '.'}) and f notin result:
      result.add f
    at = script.find("python/torch-", at + 1)

proc pins(reqs: string): tuple[versions: Table[string, string], problems: seq[string]] =
  for line in logicalLines(reqs):
    if line.startsWith("-"): continue
    let words = line.splitWhitespace
    let spec = words[0]
    let name = spec.split({'=', '<', '>', '~', '!', '[', ';'})[0].toLowerAscii
    if name notin torchFamily: continue
    if "==" notin spec:
      result.problems.add name & " is not pinned with ==: " & line
      continue
    var version = spec.split("==")[1]
    let plus = version.find('+')
    if plus >= 0: version = version[0 ..< plus]
    var hashed = false
    for w in words[1 .. ^1]:
      if w.startsWith("--hash=sha256:"):
        let h = w["--hash=sha256:".len .. ^1]
        if h.len == 64 and h.allCharsInSet(HexDigits): hashed = true
    if not hashed:
      result.problems.add name & " carries no --hash=sha256: " & line
    result.versions[name] = version
  for name in torchFamily:
    if name notin result.versions:
      result.problems.add name & " is missing"

proc matched(v: Table[string, string]): bool =
  for (t, tv, ta) in matchedSets:
    if v.getOrDefault("torch") == t and v.getOrDefault("torchvision") == tv and
        v.getOrDefault("torchaudio") == ta:
      return true

suite "the torch pin":

  let script = readFile(root / "scripts" / "install.sh")
  let files = requirementFiles(script)

  test "the installer installs torch only from hash-pinned files":
    check installerProblems(script).len == 0
    check hashedInstalls(script) >= 1
    check files.len >= 2

  test "the installer names both platform files":
    check "python/torch-linux-x86_64.txt" in files
    check "python/torch-macos-arm64.txt" in files

  test "each file pins the torch family by == and sha256, to a matched set":
    check files.len > 0
    var first = initTable[string, string]()
    for f in files:
      checkpoint f
      check fileExists(root / f)
      let (versions, problems) = pins(readFile(root / f))
      check problems.len == 0
      if problems.len > 0: echo problems.join("\n")
      check matched(versions)
      if first.len == 0: first = versions
      else: check versions == first

  test "control: the old unpinned installer line is refused":
    let old = "if ! python -c \"import torch\" >/dev/null 2>&1; then\n" &
      "  pip install torch torchvision torchaudio\nfi\n"
    check installerProblems(old).len > 0
    check hashedInstalls(old) == 0
    check requirementFiles(old).len == 0

  test "control: a missing hash, a loose pin and a mismatched set are refused":
    let h = "--hash=sha256:" & repeat('a', 64)
    let good = "torch==2.11.0+cu126 " & h & "\ntorchvision==0.26.0+cu126 " & h &
      "\ntorchaudio==2.11.0+cu126 " & h & "\n"
    check pins(good).problems.len == 0
    check matched(pins(good).versions)
    check pins(good.replace("torchaudio==2.11.0+cu126 " & h,
                            "torchaudio==2.11.0+cu126")).problems.len > 0
    check pins(good.replace("torch==2.11.0+cu126", "torch>=2.11.0")).problems.len > 0
    # The set the unpinned install picked on 2026-11-25.
    let drifted = "torch==2.14.1 " & h & "\ntorchvision==0.29.2 " & h &
      "\ntorchaudio==2.11.1 " & h & "\n"
    check pins(drifted).problems.len == 0
    check not matched(pins(drifted).versions)

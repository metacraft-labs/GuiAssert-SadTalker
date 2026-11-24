## The repository's own development gates: direnv selects this repository's
## SDK, `just lint` is a real gate, the committed hook set is the whole MCL
## standard set, and on Linux the dev shell supplies the C++ runtime the
## PyTorch wheels load.
##
## Requirements: metacraft-dev-guidelines/policies/repo-requirements.md
## §2 (`.envrc` is `use flake`), §3 (`lint` runs all linters and checks),
## §4 (the full `mcl-standard-hooks` set plus a `just lint` hook) and §1 (the
## dev shell holds every tool needed to build, test and lint -- here, the
## `libstdc++.so.6` that `import torch` needs on Linux).
##
## Each check that could pass vacuously has a control:
##
## * `just lint` is run on a scratch copy of this checkout, first unchanged
##   (must pass), then once per linter with one genuine defect planted in a
##   file that linter owns (must fail), then restored byte for byte (must pass
##   again). A placeholder `lint` passes the first run and fails every planted
##   one, so this test fails against it.
## * The C++ runtime check does not stop at "it loaded": it reads the path the
##   loader actually mapped and requires it to come from a directory on the
##   dev shell's `LD_LIBRARY_PATH`, so an ambient host copy cannot satisfy it.
##
## No mocks: every check runs the real tools from the dev shell (`just`, `nim`,
## `nixfmt`, `shellcheck`, `ruff`, `python3.10`) against real files. The test
## must run inside the dev shell (`nix develop`, direnv or `repro exec`), like
## every other recipe in the Justfile.

import std/[os, osproc, strutils, unittest, sets]

const repoRoot = currentSourcePath().parentDir.parentDir

proc run(cmd: string, dir = repoRoot): tuple[output: string, exitCode: int] =
  execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut, poEvalCommand},
            workingDir = dir)

proc siblingSrc(envVar, fallback: string): string =
  ## The same sibling resolution the Justfile uses, made absolute so a scratch
  ## copy of the checkout still finds the siblings.
  let p = getEnv(envVar, fallback)
  result = if p.isAbsolute: p else: absolutePath(p, repoRoot)

proc trackedAndUntrackedFiles(): seq[string] =
  ## Everything git would publish from this checkout, including files not yet
  ## committed, and nothing it ignores (.venv, upstream, nimcache).
  let (o, code) = run("git ls-files -co --exclude-standard")
  doAssert code == 0, o
  for line in o.splitLines:
    if line.len > 0 and fileExists(repoRoot / line):
      result.add line

proc copyCheckout(dest: string) =
  ## A scratch git work tree holding exactly what this checkout would publish,
  ## so the style checks see the same file set (they honour .gitignore).
  for rel in trackedAndUntrackedFiles():
    createDir(parentDir(dest / rel))
    copyFileWithPermissions(repoRoot / rel, dest / rel)
  let (o, code) = run("git init -q && git add -A", dest)
  doAssert code == 0, o

suite "direnv selects this repository's SDK (repo-requirements §2)":
  test ".envrc exists and its core mechanism is `use flake`":
    let envrc = repoRoot / ".envrc"
    check fileExists(envrc)
    if fileExists(envrc):
      var directives: seq[string]
      for line in readFile(envrc).splitLines:
        let s = line.strip
        if s.len > 0 and not s.startsWith("#"):
          directives.add s
      check "use flake" in directives

suite "the committed hook set is the whole MCL standard set (§4)":
  test "every standard hook id and the repo's own `just lint` hook":
    let cfg = readFile(repoRoot / ".pre-commit-config.yaml")
    var ids: HashSet[string]
    for line in cfg.splitLines:
      let s = line.strip
      if s.startsWith("- id:"):
        ids.incl s["- id:".len .. ^1].strip
    # The set as published in devops-modules git-hooks/mcl-standard-hooks.yaml.
    for id in ["check-added-large-files", "ban-added-ct-recordings",
               "end-of-file-fixer", "editorconfig-checker", "nixfmt",
               "terraform-format", "prettier", "lint"]:
      checkpoint "hook id: " & id
      check id in ids
    check "entry: just lint" in cfg
    # §4.2: upstream's default is 500 KB; the house ceiling is 1024 KB.
    check "--maxkb=1024" in cfg
    # §4.1: the devops-modules block is pinned to a sha, never a branch.
    var pinned = false
    var inDevops = false
    for line in cfg.splitLines:
      let s = line.strip
      if s.startsWith("- repo:"):
        inDevops = s.endsWith("metacraft-labs/devops-modules")
      elif inDevops and s.startsWith("rev:"):
        let rev = s["rev:".len .. ^1].strip
        pinned = rev.len == 40 and rev.allCharsInSet(HexDigits)
    check pinned

suite "`just lint` is a real gate (§3)":
  let scratch = getTempDir() / ("sadtalker-lint-control-" & $getCurrentProcessId())
  removeDir(scratch)
  copyCheckout(scratch)
  putEnv("DEMO_VIDEO_STUDIO_SRC",
         siblingSrc("DEMO_VIDEO_STUDIO_SRC", "../DemoVideoStudio/src"))
  putEnv("GUI_ASSERT_SRC", siblingSrc("GUI_ASSERT_SRC", "../GuiAssert/src"))

  template lint(): tuple[output: string, exitCode: int] =
    run("just lint", scratch)

  # Templates, not procs: `check` must expand inside the `test` body to fail it.
  template failedIn(o, recipe: string): bool =
    ## `just` names the recipe whose command failed, so a defect caught by
    ## the wrong linter (or by an earlier one) does not count.
    ("Recipe `" & recipe & "` failed") in o

  template plant(rel, defect: string; linter, recipe: string) =
    ## Append one genuine defect to `rel`, require `just lint` to fail in the
    ## recipe that owns `linter` and to name the file, then restore the
    ## original bytes.
    let path = scratch / rel
    let original = readFile(path)
    writeFile(path, original & defect)
    let (o, code) = lint()
    checkpoint linter & " on " & rel & " -> exit " & $code & "\n" & o
    check code != 0
    check failedIn(o, recipe)
    check rel.extractFilename in o
    writeFile(path, original)
    check readFile(path) == original

  test "the unchanged checkout passes":
    let (o, code) = lint()
    checkpoint o
    check code == 0

  test "a Nim type error in the plugin module fails `nim check`":
    plant("src/gui_assert_sadtalker.nim",
          "\nlet lintControlNotAnInt: int = \"not an int\"\n", "nim check", "lint-nim")

  test "a Nim type error in a test program fails `nim check`":
    plant("tests/tsadtalker.nim",
          "\nlet lintControlNotAnInt: int = \"not an int\"\n", "nim check", "lint-nim")

  test "an unformatted Nix expression fails `nixfmt --check`":
    # Extra spaces around `=` are valid Nix that nixfmt would rewrite; a
    # comment would not do, because nixfmt keeps comments as written.
    let path = scratch / "flake.nix"
    let original = readFile(path)
    let planted = original.replace("  outputs =", "  outputs   =")
    check planted != original
    writeFile(path, planted)
    let (o, code) = lint()
    checkpoint o
    check code != 0
    check failedIn(o, "lint-nix")
    check "flake.nix" in o
    writeFile(path, original)
    check readFile(path) == original

  test "a shell defect fails `shellcheck`":
    plant("scripts/verify-install.sh",
          "\nlint_control_var=\"a b\"\nls $lint_control_var\n", "shellcheck", "lint-shell")

  test "a Python defect fails `ruff`":
    plant("python/render_talking_head.py",
          "\nlint_control_undefined_name()\n", "ruff", "lint-python")

  test "trailing whitespace fails `editorconfig-checker`":
    plant("scripts/install.sh", "# lint control   \n", "editorconfig-checker", "lint-style")

  test "unformatted Markdown fails `prettier --check`":
    plant("README.md", "\nA *lint control* emphasis.\n", "prettier", "lint-style")

  test "the restored checkout passes again":
    let (o, code) = lint()
    checkpoint o
    check code == 0

  removeDir(scratch)

when defined(linux):
  suite "the Linux dev shell supplies the C++ runtime (§1)":
    test "a library with no search path needing libstdc++.so.6 loads into python3.10":
      # The PyTorch wheels' shared objects carry no search path to a C++
      # runtime (their DT_RPATH lists only $ORIGIN-relative wheel
      # directories), so when `import torch` dlopens them the loader looks
      # for `libstdc++.so.6` on LD_LIBRARY_PATH, the cache and the default
      # directories -- never on python's own DT_RUNPATH, which the loader
      # does not apply to the dependencies of other objects
      # (https://man7.org/linux/man-pages/man8/ld.so.8.html). Build an object
      # in that shape and load it the way torch is loaded. Nix's linker
      # wrapper adds search paths of its own (NIX_LDFLAGS carries
      # `-rpath $out/lib`, and the wrapper adds store `-L` directories), so
      # strip them after linking and require that none is left: an object
      # whose own path finds libstdc++ would pass whatever the shell does.
      let work = getTempDir() / ("sadtalker-cxx-probe-" & $getCurrentProcessId())
      removeDir(work)
      createDir(work)
      defer: removeDir(work)
      writeFile(work / "probe.c",
                "extern int probe_marker(void);\nint probe_marker(void) { return 0; }\n")
      let (co, cc) = run("cc -shared -fPIC -o probe.so probe.c " &
                         "-Wl,--no-as-needed -lstdc++ && " &
                         "patchelf --remove-rpath probe.so", work)
      checkpoint co
      require cc == 0
      let (dyn, dc) = run("readelf -d probe.so", work)
      checkpoint dyn
      require dc == 0
      require "Shared library: [libstdc++.so.6]" in dyn
      require "(RPATH)" notin dyn and "(RUNPATH)" notin dyn
      writeFile(work / "probe.py", """
import ctypes, sys
ctypes.CDLL(sys.argv[1])
for line in open("/proc/self/maps"):
    if "libstdc++.so" in line:
        print(line.split()[-1])
        break
""")
      let (o, code) = run("python3.10 probe.py " & quoteShell(work / "probe.so"), work)
      checkpoint o
      check code == 0
      if code == 0:
        let mapped = o.strip.splitLines[^1]
        let dirs = getEnv("LD_LIBRARY_PATH").split(':')
        checkpoint "mapped " & mapped & "; LD_LIBRARY_PATH=" & dirs.join(":")
        # It must come from the dev shell's declared library path, not from a
        # copy the host happens to have in its loader cache.
        var fromDevShell = false
        for d in dirs:
          if d.startsWith("/nix/store/") and fileExists(d / "libstdc++.so.6") and
             sameFile(d / "libstdc++.so.6", mapped):
            fromDevShell = true
        check fromDevShell

## SadTalker talking-head plugin for GuiAssert.
##
## Implements GuiAssert's `TalkingHeadProvider` contract on top of a
## local SadTalker install: a Python 3.10 venv under `.venv/` and a
## clone of OpenTalker/SadTalker pinned in `python/COMMIT.txt`.
##
## Wire shape:
##
##   * `sadtalkerProvider()` builds a `TalkingHeadProvider` value with
##     `name = "sadtalker"`, an `isAvailable` check (does the venv +
##     wrapper script exist?), and a `generate` proc that shells out
##     to the wrapper.
##   * `registerSadTalker(reg)` is the one-liner plugin registration
##     entry point.
##
## ## Path discovery
##
## The plugin needs two paths at runtime:
##
##   * `<plugin-root>/.venv/bin/python` — the Python interpreter.
##   * `<plugin-root>/python/render_talking_head.py` — the wrapper
##     script.
##
## `pluginRoot()` resolves to the directory containing this `src/`
## folder.  The `GUI_ASSERT_SADTALKER_HOME` environment variable lets
## a user pin a non-standard layout (for example a Nix flake build
## that places the plugin elsewhere on disk).

import std/[json, options, os, osproc, streams, strformat, strutils, times]

import gui_assert/talking_head

const
  ProviderName* = "sadtalker"
  DefaultPythonRelPath* = ".venv" / "bin" / "python"
  DefaultRenderScriptRelPath* = "python" / "render_talking_head.py"
  PluginRootEnvVar* = "GUI_ASSERT_SADTALKER_HOME"
  PythonOverrideEnvVar* = "GUI_ASSERT_SADTALKER_PYTHON"
  ScriptOverrideEnvVar* = "GUI_ASSERT_SADTALKER_RENDER_SCRIPT"

proc pluginRoot*(): string =
  ## Returns the on-disk location of the GuiAssert-SadTalker checkout.
  ## Resolution order:
  ##   1. `$GUI_ASSERT_SADTALKER_HOME` env var.
  ##   2. The directory two levels up from this source file
  ##      (`<repo>/src/gui_assert_sadtalker.nim` -> `<repo>`).
  let env = getEnv(PluginRootEnvVar)
  if env.len > 0:
    return env
  result = currentSourcePath().parentDir().parentDir()

proc resolvedPython*(): string =
  ## Returns the path of the Python interpreter the plugin will use.
  ## Honours `$GUI_ASSERT_SADTALKER_PYTHON` for tests / non-standard
  ## layouts; otherwise points at `<pluginRoot>/.venv/bin/python`.
  let env = getEnv(PythonOverrideEnvVar)
  if env.len > 0:
    return env
  result = pluginRoot() / DefaultPythonRelPath

proc resolvedRenderScript*(): string =
  ## Returns the path of the SadTalker wrapper script the plugin will
  ## invoke.  Honours `$GUI_ASSERT_SADTALKER_RENDER_SCRIPT`; otherwise
  ## points at `<pluginRoot>/python/render_talking_head.py`.
  let env = getEnv(ScriptOverrideEnvVar)
  if env.len > 0:
    return env
  result = pluginRoot() / DefaultRenderScriptRelPath

proc sadtalkerIsAvailable*(): bool {.gcsafe.} =
  ## True iff the Python interpreter and wrapper script both exist on
  ## disk.  We deliberately do NOT exec Python here — `isAvailable` is
  ## a cheap-call probe; a non-functional venv that fails at import
  ## time surfaces during `generate`.
  let py = resolvedPython()
  let scr = resolvedRenderScript()
  py.len > 0 and fileExists(py) and scr.len > 0 and fileExists(scr)

proc runSadTalker(py, script, narrationWav, outputMp4, device, logPath: string,
                  extraArgs: seq[string]): tuple[exitCode: int, tail: string,
                                                  elapsed: float] =
  ## Spawn the SadTalker wrapper.  Captures combined stdout/stderr into
  ## `logPath` and keeps the trailing 8 KB in memory so callers can
  ## include it in error messages.
  if not fileExists(narrationWav):
    raise newException(TalkingHeadError,
      "SadTalker: narration WAV not found: " & narrationWav)
  let outParent = outputMp4.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  var argv: seq[string] = @[
    script,
    "--audio", narrationWav,
    "--output", outputMp4,
    "--device", device,
  ]
  for extra in extraArgs:
    argv.add extra

  let logFile = open(logPath, fmWrite)
  var tail = ""
  var exitCode = -1
  let started = epochTime()
  try:
    let p = startProcess(
      command = py,
      args = argv,
      options = {poStdErrToStdOut}
    )
    try:
      let s = p.outputStream
      while not s.atEnd:
        let line =
          try: s.readLine()
          except IOError: break
        logFile.writeLine(line)
        logFile.flushFile()
        if tail.len < 8192:
          tail.add(line)
          tail.add('\n')
        else:
          tail = tail[tail.len - 6144 .. ^1] & line & "\n"
      exitCode = p.waitForExit()
    finally:
      p.close()
  finally:
    logFile.close()
  let elapsed = epochTime() - started
  result = (exitCode: exitCode, tail: tail, elapsed: elapsed)

proc generateSadTalker(narrationWav, outputMp4: string,
                       opts: TalkingHeadOpts) {.gcsafe.} =
  ## Validates the inputs, looks up a cached render under
  ## `opts.cacheDir` (default: GuiAssert's `defaultCacheDir`), and on a
  ## miss spawns the Python wrapper.  All errors surface as
  ## `TalkingHeadError`.
  if opts.avatarImagePath.isNone or opts.avatarImagePath.get.len == 0:
    raise newException(TalkingHeadError,
      "sadtalker provider requires avatarImagePath to be set.")
  let avatar = opts.avatarImagePath.get
  if not fileExists(avatar):
    raise newException(TalkingHeadError,
      "sadtalker provider: avatar image not found: " & avatar)

  let py = resolvedPython()
  let script = resolvedRenderScript()
  if py.len == 0 or not fileExists(py):
    raise newException(TalkingHeadError,
      "sadtalker provider: python binary not found at " & py &
      " (run scripts/install.sh in the GuiAssert-SadTalker checkout or " &
      "set $GUI_ASSERT_SADTALKER_PYTHON).")
  if script.len == 0 or not fileExists(script):
    raise newException(TalkingHeadError,
      "sadtalker provider: render script not found at " & script &
      " (set $GUI_ASSERT_SADTALKER_RENDER_SCRIPT to override).")

  let device = effectiveDevice(opts)
  let cacheDir = effectiveCacheDir(opts)
  if not dirExists(cacheDir):
    createDir(cacheDir)
  let key = cacheKeyFor(avatar, narrationWav, ProviderName, device)
  let logPath = cacheDir / (key & ".log")

  # Build the SadTalker-specific argv that the wrapper's argparse
  # consumes.  The avatar image is passed as `--source-image`, which
  # is wrapper-specific (the registry-level contract only knows about
  # `narrationWav` + `outputMp4`).
  var extra: seq[string] = @["--source-image", avatar]
  for e in opts.extraArgs:
    extra.add e

  let generator = proc() =
    let res = runSadTalker(py, script, narrationWav, outputMp4, device,
                           logPath, extra)
    if res.exitCode != 0:
      raise newException(TalkingHeadError,
        &"SadTalker failed (exit={res.exitCode}, elapsed={res.elapsed:.1f}s). " &
        "Log: " & logPath & "\nTail:\n" & res.tail)
    if not fileExists(outputMp4) or getFileSize(outputMp4) == 0:
      raise newException(TalkingHeadError,
        "SadTalker reported success but produced no MP4 at " & outputMp4 &
        ". See log: " & logPath)

  # applyCache takes a non-{.gcsafe.} closure for ergonomic test use,
  # but we call it from inside a `{.gcsafe.}` provider entry point.
  # The closure above captures only stack-local values from the
  # enclosing proc; the GC-unsafety comes from the indirect call. We
  # assert gcsafe at the call site.
  {.cast(gcsafe).}:
    discard applyCache(cacheDir, key, outputMp4, generator)

proc sadtalkerProvider*(): TalkingHeadProvider =
  ## Build the SadTalker provider value.  Plugins of the same shape
  ## compose into the same registry — register multiple to expose
  ## both SadTalker and (say) MuseTalk under one runner.
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: sadtalkerIsAvailable,
    generate: generateSadTalker,
  )

proc registerSadTalker*(r: TalkingHeadRegistry) =
  ## One-liner plugin entry point.  Callers do:
  ##
  ## ```nim
  ## import gui_assert/talking_head
  ## import gui_assert_sadtalker
  ##
  ## let reg = newRegistry()
  ## registerSadTalker(reg)
  ## generateTalkingHead(reg, "sadtalker", wav, mp4, opts)
  ## ```
  r.registerProvider(sadtalkerProvider())

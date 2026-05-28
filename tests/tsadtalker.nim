## Unit + integration tests for the SadTalker GuiAssert plugin.
##
## ## Pure tests (always run)
##
##   * `sadtalkerProvider()` produces a value with the correct name
##     and non-nil callbacks,
##   * `isAvailable()` returns false when the python binary or the
##     wrapper script are missing,
##   * `isAvailable()` returns true when both paths exist (we forge
##     dummies under tmp + point the env vars at them),
##   * `registerSadTalker` integrates with the registry (`hasProvider`
##     reports membership, `getProvider` returns the registered
##     value),
##   * the `generate` proc rejects requests with no `avatarImagePath`
##     before spawning Python.
##
## ## Live test (compile-time-gated)
##
## When compiled with `-d:sadtalkerLive` we end-to-end render a real
## talking head:
##
##   nim c -d:sadtalkerLive --hints:off --path:src --path:../GuiAssert/src \
##       tests/tsadtalker.nim
##
## Requirements:
##   * a working install under `.venv/` + `python/upstream/` (see
##     `scripts/install.sh`),
##   * an avatar fixture — `$GUI_ASSERT_SADTALKER_TEST_AVATAR` points
##     at a portrait PNG; with no override the test falls back to
##     SadTalker's bundled `python/upstream/examples/source_image/`,
##   * a narration WAV — `$GUI_ASSERT_SADTALKER_TEST_WAV` points at a
##     WAV; with no override the test falls back to SadTalker's
##     bundled `driven_audio/RD_Radio31_000.wav`.
##
## The live suite never silently skips: a missing prerequisite is a
## test failure (per the project's "no graceful skips" policy).  CI
## that does not have SadTalker installed simply does not pass
## `-d:sadtalkerLive`.

import std/[options, os, unittest]

import gui_assert/talking_head
import gui_assert_sadtalker

when defined(sadtalkerLive):
  import std/[json, osproc, streams, strformat, strutils, times]

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

proc thisRepoRoot(): string =
  ## `currentSourcePath` -> .../GuiAssert-SadTalker/tests/tsadtalker.nim
  currentSourcePath().parentDir().parentDir()

# ---------------------------------------------------------------------------
# Pure tests
# ---------------------------------------------------------------------------

suite "sadtalker provider value":

  test "sadtalkerProvider builds a provider with the canonical name":
    let p = sadtalkerProvider()
    check p.name == ProviderName
    check p.name == "sadtalker"
    check (not p.isAvailable.isNil)
    check (not p.generate.isNil)

  test "registerSadTalker exposes the plugin via the registry":
    let r = newRegistry()
    check (not hasProvider(r, "sadtalker"))
    registerSadTalker(r)
    check hasProvider(r, "sadtalker")
    let got = getProvider(r, "sadtalker")
    check got.name == "sadtalker"
    # Stock avatar must still be present (we layer plugins; we do not
    # replace the default registry).
    check hasProvider(r, "stock_avatar")

suite "sadtalker isAvailable":

  test "returns false when python / script paths are absent":
    let tmp = getTempDir() / "tsadtalker_avail_missing"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    # Point env vars at non-existent paths and confirm.
    putEnv(PythonOverrideEnvVar, tmp / "nope-python")
    putEnv(ScriptOverrideEnvVar, tmp / "nope-script.py")
    check (not sadtalkerIsAvailable())
    delEnv(PythonOverrideEnvVar)
    delEnv(ScriptOverrideEnvVar)

  test "returns true when both paths exist":
    let tmp = getTempDir() / "tsadtalker_avail_present"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let py = tmp / "python"
    let scr = tmp / "render.py"
    writeFile(py, "#!/bin/sh\nexit 0\n")
    writeFile(scr, "print('hello')\n")
    putEnv(PythonOverrideEnvVar, py)
    putEnv(ScriptOverrideEnvVar, scr)
    check sadtalkerIsAvailable()
    delEnv(PythonOverrideEnvVar)
    delEnv(ScriptOverrideEnvVar)

suite "sadtalker generate input validation":

  test "missing avatarImagePath raises TalkingHeadError":
    # Pretend the install is present so we reach the avatar check.
    let tmp = getTempDir() / "tsadtalker_no_avatar"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let py = tmp / "python"
    let scr = tmp / "render.py"
    writeFile(py, "#!/bin/sh\nexit 0\n")
    writeFile(scr, "print('hi')\n")
    putEnv(PythonOverrideEnvVar, py)
    putEnv(ScriptOverrideEnvVar, scr)
    try:
      let r = newRegistry()
      registerSadTalker(r)
      let nar = tmp / "n.wav"
      writeFile(nar, "RIFF")
      let outMp4 = tmp / "out.mp4"
      let opts = TalkingHeadOpts(avatarImagePath: none(string),
                                 cacheDir: some(tmp / "cache"))
      expect TalkingHeadError:
        generateTalkingHead(r, "sadtalker", nar, outMp4, opts)
    finally:
      delEnv(PythonOverrideEnvVar)
      delEnv(ScriptOverrideEnvVar)

  test "missing python binary surfaces a clear error":
    # Pretend the install is missing (env vars unset, pluginRoot's
    # default path won't have a .venv in a freshly-cloned tree
    # without the install script having been run).
    let tmp = getTempDir() / "tsadtalker_no_install"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    # Force pluginRoot to point somewhere with no .venv.
    putEnv(PluginRootEnvVar, tmp)
    try:
      let r = newRegistry()
      registerSadTalker(r)
      # Registering the provider should not throw, but dispatch
      # should fail availability first.
      check (not sadtalkerIsAvailable())
      let avatar = tmp / "a.png"
      writeFile(avatar, "PNG-bytes")
      let nar = tmp / "n.wav"
      writeFile(nar, "RIFF")
      let outMp4 = tmp / "out.mp4"
      let opts = TalkingHeadOpts(avatarImagePath: some(avatar),
                                 cacheDir: some(tmp / "cache"))
      expect TalkingHeadError:
        generateTalkingHead(r, "sadtalker", nar, outMp4, opts)
    finally:
      delEnv(PluginRootEnvVar)

# ---------------------------------------------------------------------------
# Live test — compile-time-gated.
# ---------------------------------------------------------------------------
when defined(sadtalkerLive):

  proc ffprobeJson(path: string): JsonNode =
    let ffprobe =
      block:
        let env = getEnv("FFPROBE_BIN")
        if env.len > 0 and fileExists(env): env
        else: findExe("ffprobe")
    doAssert ffprobe.len > 0 and fileExists(ffprobe),
      "ffprobe not on PATH; install ffmpeg to run the live SadTalker test."
    let p = startProcess(
      command = ffprobe,
      args = @["-hide_banner", "-v", "error", "-print_format", "json",
               "-show_streams", "-show_format", path],
      options = {poStdErrToStdOut}
    )
    let raw = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    doAssert code == 0, "ffprobe failed (" & $code & "): " & raw
    parseJson(raw)

  suite "sadtalker live talking-head render":

    test "renders a real talking head and round-trips the cache":
      let avatar =
        block:
          let env = getEnv("GUI_ASSERT_SADTALKER_TEST_AVATAR")
          if env.len > 0: env
          else: thisRepoRoot() / "python" / "upstream" / "examples" /
                "source_image" / "full_body_1.png"
      doAssert fileExists(avatar),
        "missing avatar fixture: " & avatar &
        " (set GUI_ASSERT_SADTALKER_TEST_AVATAR to a portrait PNG)"

      let narration =
        block:
          let env = getEnv("GUI_ASSERT_SADTALKER_TEST_WAV")
          if env.len > 0: env
          else: thisRepoRoot() / "python" / "upstream" / "examples" /
                "driven_audio" / "RD_Radio31_000.wav"
      doAssert fileExists(narration),
        "no narration WAV at " & narration &
        " (set GUI_ASSERT_SADTALKER_TEST_WAV to override)"

      doAssert sadtalkerIsAvailable(),
        "SadTalker not available — run scripts/install.sh first."

      let tmp = getTempDir() / "tsadtalker_live"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)

      let r = newRegistry()
      registerSadTalker(r)

      let outMp4 = tmp / "live.mp4"
      var opts = TalkingHeadOpts(
        avatarImagePath: some(avatar),
        device: "mps",
        cacheDir: some(tmp / "cache"),
        extraArgs: @["--still-mode", "--preprocess", "crop"],
      )

      let started = epochTime()
      generateTalkingHead(r, "sadtalker", narration, outMp4, opts)
      let dt = epochTime() - started
      echo &"  live SadTalker render took {dt:.1f}s"

      doAssert fileExists(outMp4), "no MP4 at " & outMp4
      let sz = getFileSize(outMp4)
      check sz > 1024
      echo &"  output: {sz} bytes"

      let probe = ffprobeJson(outMp4)
      var hasVideo = false
      for s in probe{"streams"}.items:
        if s{"codec_type"}.getStr() == "video": hasVideo = true
      check hasVideo

      let videoDur = parseFloat(probe{"format", "duration"}.getStr())
      let narProbe = ffprobeJson(narration)
      let narDur = parseFloat(narProbe{"format", "duration"}.getStr())
      echo &"  narration dur: {narDur:.3f}s; talking-head dur: {videoDur:.3f}s"
      check abs(videoDur - narDur) <= 0.5

      # Cache hit — a second call must return without spawning the
      # subprocess again (well under 5 s; a real hit is <1 s).
      let secondStart = epochTime()
      let outMp4_2 = tmp / "live2.mp4"
      generateTalkingHead(r, "sadtalker", narration, outMp4_2, opts)
      let secondDt = epochTime() - secondStart
      echo &"  second call (cache hit) took {secondDt:.3f}s"
      check secondDt < 5.0
      check fileExists(outMp4_2)
      check getFileSize(outMp4_2) == getFileSize(outMp4)

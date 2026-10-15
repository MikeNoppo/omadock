import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const file = process.env.DOCKTASKS || new URL("../../DockTasks.js", import.meta.url)
const M = vm.createContext({})
vm.runInContext(readFileSync(file, "utf8"), M)

test("normalizeTaskStatus: valid inputs and exit codes", () => {
  const successTask = M.normalizeTaskStatus("ghostty.desktop", "done", 0, "cargo build --release", 14)
  assert.equal(successTask.appId, "ghostty")
  assert.equal(successTask.status, "success")
  assert.equal(successTask.exitCode, 0)
  assert.equal(successTask.title, "cargo build --release")
  assert.equal(successTask.duration, 14)

  const failTask = M.normalizeTaskStatus("com.mitchellh.ghostty", "done", 101, "cargo test", 5)
  assert.equal(failTask.appId, "com.mitchellh.ghostty")
  assert.equal(failTask.status, "error")
  assert.equal(failTask.exitCode, 101)

  const runningTask = M.normalizeTaskStatus("Alacritty", "running", 0, "npm install", 0)
  assert.equal(runningTask.appId, "Alacritty")
  assert.equal(runningTask.status, "running")
})

test("normalizeTaskStatus: status keyword overrides and bounds", () => {
  const explicitErr = M.normalizeTaskStatus("foot", "error", 0, "make", 2)
  assert.equal(explicitErr.status, "error")

  const explicitRun = M.normalizeTaskStatus("kitty", "busy", 0, "sleep 10", 0)
  assert.equal(explicitRun.status, "running")

  const negativeDur = M.normalizeTaskStatus("xterm", "done", 0, "true", -10)
  assert.equal(negativeDur.duration, 0)

  const longTitle = "a".repeat(200)
  const clamped = M.normalizeTaskStatus("xterm", "done", 0, longTitle, 1)
  assert.equal(clamped.title.length, M.MAX_TASK_TITLE)

  assert.equal(M.normalizeTaskStatus("", "done", 0, "cmd", 0), null)
  assert.equal(M.normalizeTaskStatus(null, "done", 0, "cmd", 0), null)
})

test("withTaskStatus and clearTaskStatusFor", () => {
  let map = {}
  const t1 = M.normalizeTaskStatus("alacritty", "done", 0, "gcc -O3", 4)
  map = M.withTaskStatus(map, "alacritty", t1)
  assert.equal(map["alacritty"].title, "gcc -O3")

  // Clearing by exact ID
  map = M.clearTaskStatusFor(map, "alacritty")
  assert.equal(map["alacritty"], undefined)

  // Matching through aliases/prefixes (e.g. Alacritty vs alacritty)
  map = M.withTaskStatus(map, "Alacritty", t1)
  assert.ok(M.taskStatusFor(map, "alacritty"))
  map = M.clearTaskStatusFor(map, "alacritty")
  assert.equal(M.taskStatusFor(map, "Alacritty"), null)

  // AI assistant aliases: agy and org.omarchy.agy normalize to antigravity
  const tAgy = M.normalizeTaskStatus("agy", "done", 0, "agent test", 3)
  assert.equal(tAgy.appId, "antigravity")
  map = M.withTaskStatus(map, "agy", tAgy)
  assert.ok(M.taskStatusFor(map, "antigravity"))
  assert.ok(M.taskStatusFor(map, "org.omarchy.agy"))
  map = M.clearTaskStatusFor(map, "antigravity")
  assert.equal(M.taskStatusFor(map, "antigravity"), null)

  // Universal AI tools normalization
  assert.equal(M.normalizeTaskStatus("claude-code", "done", 0, "c", 1).appId, "claude")
  assert.equal(M.normalizeTaskStatus("com.anthropic.claude", "done", 0, "c", 1).appId, "claude")
  assert.equal(M.normalizeTaskStatus("aider-chat", "done", 0, "a", 1).appId, "aider")
  assert.equal(M.normalizeTaskStatus("cursor-bin", "done", 0, "c", 1).appId, "cursor")
  assert.equal(M.normalizeTaskStatus("com.codeium.windsurf", "done", 0, "w", 1).appId, "windsurf")
  assert.equal(M.normalizeTaskStatus("ollama-app", "done", 0, "o", 1).appId, "ollama")
  assert.equal(M.normalizeTaskStatus("github-copilot-cli", "done", 0, "g", 1).appId, "copilot")
  assert.equal(M.normalizeTaskStatus("open-interpreter", "done", 0, "i", 1).appId, "interpreter")

  // Primary + Fallback routing
  const tClaude = M.normalizeTaskStatus("claude|foot", "running", 0, "refactor", 0)
  assert.equal(tClaude.appId, "claude")
  assert.equal(tClaude.fallbackId, "foot")
  map = M.withTaskStatus(map, "claude", tClaude)

  // Case A: Claude IS present on dock -> Claude gets badge, Foot does NOT
  const dockWithClaude = { pinned: [{ appId: "claude" }], running: [{ appId: "foot" }] }
  assert.equal(M.taskStatusFor(map, "claude", dockWithClaude).appId, "claude")
  assert.equal(M.taskStatusFor(map, "foot", dockWithClaude), null)

  // Case B: Claude is NOT present on dock -> Foot (host terminal) gets badge
  const dockWithoutClaude = { pinned: [{ appId: "foot" }], running: [] }
  assert.equal(M.taskStatusFor(map, "claude", dockWithoutClaude).appId, "claude")
  assert.equal(M.taskStatusFor(map, "foot", dockWithoutClaude).appId, "claude")

  // Clearing by terminal clears the fallback task too
  map = M.clearTaskStatusFor(map, "foot")
  assert.equal(M.taskStatusFor(map, "foot", dockWithoutClaude), null)
})

test("a task never bleeds onto an app whose id merely contains its own", () => {
  // foot and footclient are two separate terminal apps on the same desktop;
  // a task filed under one must not badge the other. The alias bridge is the
  // dot boundary only, which is what a reverse-DNS desktop id looks like.
  const map = M.withTaskStatus({}, "foot", M.normalizeTaskStatus("foot", "done", 0, "cargo build", 3))
  assert.ok(M.taskStatusFor(map, "foot"))
  assert.equal(M.taskStatusFor(map, "footclient"), null)
  assert.equal(M.taskStatusFor(map, "kitty"), null)

  // The reverse-DNS form still reaches its bare name (both directions).
  const rdn = M.withTaskStatus({}, "com.mitchellh.ghostty", M.normalizeTaskStatus("com.mitchellh.ghostty", "done", 0, "test", 1))
  assert.ok(M.taskStatusFor(rdn, "ghostty"))
  const bare = M.withTaskStatus({}, "ghostty", M.normalizeTaskStatus("ghostty", "done", 0, "test", 1))
  assert.ok(M.taskStatusFor(bare, "com.mitchellh.ghostty"))
  // ...and a separate id that only shares a prefix stays untouched.
  assert.equal(M.taskStatusFor(bare, "ghostty-gui"), null)
})

test("resolveBadgeView: priorities and states", () => {
  const errTask = { status: "error", exitCode: 1, title: "test", duration: 1 }
  const runTask = { status: "running", exitCode: 0, title: "test", duration: 0 }
  const okTask = { status: "success", exitCode: 0, title: "test", duration: 5 }

  // Error takes priority even if notifications exist
  const viewErr = M.resolveBadgeView(3, errTask, false)
  assert.equal(viewErr.mode, "status")
  assert.equal(viewErr.glyph, "!")
  assert.equal(viewErr.color, "#f38ba8")

  // Notifications take priority over success or running tasks
  const viewNotifOverOk = M.resolveBadgeView(3, okTask, false)
  assert.equal(viewNotifOverOk.mode, "count")
  assert.equal(viewNotifOverOk.count, 3)

  // Success task when no notifications
  const viewOk = M.resolveBadgeView(0, okTask, false)
  assert.equal(viewOk.mode, "status")
  assert.equal(viewOk.glyph, "✓")
  assert.equal(viewOk.color, "#a6e3a1")

  // Running task
  const viewRun = M.resolveBadgeView(0, runTask, false)
  assert.equal(viewRun.mode, "status")
  assert.equal(viewRun.glyph, "●")
  assert.equal(viewRun.color, "#89b4fa")

  // Active match does not suppress task status badge
  const viewActive = M.resolveBadgeView(0, okTask, true)
  assert.equal(viewActive.mode, "status")
  assert.equal(viewActive.glyph, "✓")

  // Active match does not clear error task until focused handler clears it
  const viewActiveError = M.resolveBadgeView(0, errTask, true)
  assert.equal(viewActiveError.mode, "status")
  assert.equal(viewActiveError.glyph, "!")

  // Empty state
  const viewEmpty = M.resolveBadgeView(0, null, false)
  assert.equal(viewEmpty.mode, "none")
  assert.equal(viewEmpty.count, 0)
})

// Developer task and command completion HUD: models and state transitions.
//
// Plain JS with no Qt globals, so unit tests run it in the same vm context as
// DockModel.js, Plan.js, Buttons.js and SettingsSearch.js.

var MAX_TASK_TITLE = 120
var MAX_TASK_STATUS_ENTRIES = 64

function stripDesktopId(id) {
  if (typeof id === "object" && id !== null && id.appId) id = id.appId
  var value = String(id == null ? "" : id).trim()
  var raw = value.replace(/\.desktop$/i, "")
  if (/^(?:org\.omarchy\.)?agy$/i.test(raw)) return "antigravity"
  if (/^org\.omarchy\.btop(?:-.*)?$/i.test(raw)) return "btop"
  if (/^(?:com\.anthropic\.)?claude(?:-code)?$/i.test(raw)) return "claude"
  if (/^aider(?:-chat)?$/i.test(raw)) return "aider"
  if (/^(?:com\.cursor\.)?cursor(?:-bin)?$/i.test(raw)) return "cursor"
  if (/^(?:com\.codeium\.)?windsurf$/i.test(raw)) return "windsurf"
  if (/^ollama(?:-app)?$/i.test(raw)) return "ollama"
  if (/^(?:github-)?copilot(?:-cli)?$/i.test(raw)) return "copilot"
  if (/^open-?interpreter$/i.test(raw)) return "interpreter"
  return raw
}

function normalizeTaskStatus(appId, status, exitCode, title, duration) {
  var rawId = String(appId || "").trim()
  if (!rawId) return null
  var primary = rawId
  var fallback = ""
  if (rawId.indexOf("|") >= 0) {
    var parts = rawId.split("|")
    primary = stripDesktopId(parts[0])
    fallback = stripDesktopId(parts[1])
  } else {
    primary = stripDesktopId(rawId)
  }
  if (!primary && !fallback) return null
  var id = primary || fallback

  var st = String(status || "").toLowerCase().trim()
  var code = Math.round(Number(exitCode))
  if (!isFinite(code)) code = 0

  var resolved = "success"
  if (st === "error" || st === "fail" || st === "failed") {
    resolved = "error"
  } else if (st === "running" || st === "run" || st === "busy") {
    resolved = "running"
  } else if (st === "done" || st === "completed" || st === "finish" || st === "finished" || st === "success" || st === "ok") {
    resolved = (code === 0) ? "success" : "error"
  } else {
    resolved = (code === 0) ? "success" : "error"
  }

  var ttl = String(title || "").trim().slice(0, MAX_TASK_TITLE)
  var dur = Math.max(0, Math.round(Number(duration) || 0))

  return {
    appId: id,
    fallbackId: fallback,
    status: resolved,
    exitCode: code,
    title: ttl,
    duration: dur,
    timestamp: Date.now()
  }
}

function withTaskStatus(map, appId, taskObj) {
  var out = {}
  for (var k in (map || {})) out[k] = map[k]
  var id = stripDesktopId(appId)
  if (!id && taskObj) id = taskObj.appId
  if (!id) return out
  if (!taskObj) {
    delete out[id]
    return out
  }
  out[id] = taskObj
  var keys = Object.keys(out)
  if (keys.length > MAX_TASK_STATUS_ENTRIES) {
    delete out[keys[0]]
  }
  return out
}

function isAppMatchSimple(idA, idB) {
  if (!idA || !idB) return false
  var a = stripDesktopId(idA).toLowerCase()
  var b = stripDesktopId(idB).toLowerCase()
  if (a === b) return true
  if (a.indexOf(b) >= 0 || b.indexOf(a) >= 0) return true
  return false
}

function hasDockApp(dockModel, targetId) {
  if (!dockModel || !targetId) return false
  var list = (dockModel.pinned || []).concat(dockModel.running || [])
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (entry && (entry.appId === targetId || entry.id === targetId || isAppMatchSimple(entry.appId || entry.id, targetId))) {
      return true
    }
  }
  return false
}

function clearTaskStatusFor(map, appId) {
  var out = {}
  for (var k in (map || {})) out[k] = map[k]
  var id = stripDesktopId(appId)
  if (!id) return out
  delete out[id]
  for (var key in out) {
    var entry = out[key]
    if (key === id || isAppMatchSimple(key, id) || (entry && (isAppMatchSimple(entry.appId, id) || isAppMatchSimple(entry.fallbackId, id)))) {
      delete out[key]
    }
  }
  return out
}

function taskStatusFor(map, appId, dockModel) {
  if (!map || typeof map !== "object") return null
  var id = stripDesktopId(appId)
  if (!id) return null

  // Pass 1: exact or alias match on primary appId
  if (map[id]) return map[id]
  for (var key in map) {
    var entry = map[key]
    if (entry && isAppMatchSimple(entry.appId || key, id)) return entry
  }

  // Pass 2: match on fallbackId if primary is not present on the dock
  for (var key2 in map) {
    var entry2 = map[key2]
    if (entry2 && entry2.fallbackId && isAppMatchSimple(entry2.fallbackId, id)) {
      if (!dockModel || !hasDockApp(dockModel, entry2.appId)) {
        return entry2
      }
    }
  }

  return null
}

function resolveBadgeView(notificationCount, taskInfo, activeMatch) {
  var notif = Math.max(0, Math.round(Number(notificationCount) || 0))

  if (taskInfo) {
    if (taskInfo.status === "error") {
      return {
        glyph: "!",
        color: "#f38ba8",
        count: 0,
        mode: "status",
        status: "error"
      }
    }
    if (notif > 0) {
      return {
        glyph: "",
        color: "",
        count: notif,
        mode: "count",
        status: ""
      }
    }
    if (taskInfo.status === "running") {
      return {
        glyph: "●",
        color: "#89b4fa",
        count: 0,
        mode: "status",
        status: "running"
      }
    }
    if (taskInfo.status === "success") {
      return {
        glyph: "✓",
        color: "#a6e3a1",
        count: 0,
        mode: "status",
        status: "success"
      }
    }
  }

  if (notif > 0) {
    return {
      glyph: "",
      color: "",
      count: notif,
      mode: "count",
      status: ""
    }
  }

  return {
    glyph: "",
    color: "",
    count: 0,
    mode: "none",
    status: ""
  }
}

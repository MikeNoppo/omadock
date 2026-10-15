// Body for tests/live/tasks.sh (probe.sh's PROBE_BODY hook): the real dock,
// plus a reader that reports what every tile's task HUD actually *resolved to*
// after the task IPC calls the suite makes.
//
// Why read the resolved values and not just the IPC answer: `reportTask` only
// proves the state landed in sharedState. What a user sees is the tile's
// `taskInfo` binding through DockTasks.taskStatusFor, the `badgeView` it
// resolves, and the BadgeMark that draws it - three reactive bindings that a
// scripted `reportTask` call has to reach for the feature to exist at all. A
// BadgeMark whose colour never resolves is exactly the Qt 6.12 failure mode
// this repo pins its imports against, and it is silent over IPC, so it is read
// here as a value (`badge.resolved`) as well as asserted from the pixels-free
// property `visible`.
//
// Markers are returned as JSON from the fixture's IPC handler, so the suite
// asserts on numbers and strings rather than scraping the log.

  Od.DockHost { id: host }

  function dock() {
    var list = host.orderedDocks ? host.orderedDocks() : []
    return list.length > 0 ? list[0] : null
  }

  // One entry per tile: what the item resolved, and one per badge: what the
  // drawn mark resolved. Detection is by the properties each component owns,
  // not by an id, so a rename or a re-layout cannot silently disable the read.
  function walk(o, depth, out) {
    if (!o || depth > 16) return
    if (o.appId !== undefined && o.windowList !== undefined && o.magnifyScale !== undefined) {
      out.items.push({
        appId: String(o.appId),
        notifications: Number(o.notificationCount) || 0,
        hasTask: o.taskInfo !== null && o.taskInfo !== undefined,
        taskStatus: o.taskInfo ? String(o.taskInfo.status) : "",
        taskTitle: o.taskInfo ? String(o.taskInfo.title) : "",
        taskExit: o.taskInfo ? Number(o.taskInfo.exitCode) : -1,
        taskDuration: o.taskInfo ? Number(o.taskInfo.duration) : -1,
        badgeMode: o.badgeView ? String(o.badgeView.mode) : "",
        badgeCount: o.badgeView ? Number(o.badgeView.count) : -1,
        badgeGlyph: o.badgeView ? String(o.badgeView.glyph) : "",
        badgeColor: o.badgeView ? String(o.badgeView.color) : ""
      })
    }
    // BadgeMark owns badgeColor and shownGlyph; nothing else in the tree does.
    if (o.badgeColor !== undefined && o.shownGlyph !== undefined) {
      // Named inkText, not ink: a JS object literal key spelled the same as its
      // local (`ink: ink`) is indistinguishable from a self-binding `x: x` to
      // tests/unit/test_qml_self_binding.py, whose scan cannot tell a JS object
      // literal from a QML object declaration.
      var inkText = ""
      var ch0 = o.children || []
      for (var k = 0; k < ch0.length; k++) {
        if (ch0[k] && ch0[k].text !== undefined) inkText = String(ch0[k].text)
      }
      out.badges.push({
        glyph: String(o.glyph),
        shownGlyph: String(o.shownGlyph),
        shownCount: Number(o.shownCount),
        badgeColor: String(o.badgeColor),
        resolved: String(o.color),
        visible: String(o.visible),
        expr: (o.level > 0.01 && o.anchorRef !== null) ? "true" : "false",
        level: Number(o.level),
        opacity: Number(o.opacity),
        hasAnchor: o.anchorRef !== null && o.anchorRef !== undefined,
        ink: inkText
      })
    }
    var ch = o.children || []
    for (var i = 0; i < ch.length; i++) walk(ch[i], depth + 1, out)
  }

  IpcHandler {
    target: "omadock-test"

    function read(step: string, arg: string): string {
      var d = dock()
      if (!d) return JSON.stringify({ ok: false, why: "no dock" })
      if (step === "items") {
        var out = { items: [], badges: [] }
        walk(d.contentItemRef, 0, out)
        return JSON.stringify({ ok: true, count: out.items.length,
          items: out.items, badges: out.badges })
      }
      return JSON.stringify({ ok: false, why: "unknown step " + step })
    }
  }

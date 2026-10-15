#!/usr/bin/env bash
# Live: the developer task HUD works end to end through the IPC surface a CLI
# wrapper uses, and the dock stays clean while it does.
#
# What it proves, in order:
#   1. reportTask lands: taskStatus() reads the task back with the status, exit
#      code, title and duration the caller sent.
#   2. The tile that owns the task resolves it: the dock item's own `taskInfo`
#      and `badgeView` are read out of the running dock (tasks-shell.qml), so a
#      broken binding cannot pass on the IPC answer alone. Only the reported app
#      resolves a task; every other tile resolves null.
#   3. The badge the user sees is drawable: the glyph, the status colour, the
#      resolved QColor and the text it actually set are all read from the live
#      BadgeMark. A colour that never resolved is the silent failure class this
#      repo pins its QtQuick imports against, and it is invisible over IPC.
#   4. Each status maps to the documented look (running ●, success ✓, error !).
#   5. An empty app id is refused ("invalid"), and clearTask empties both the
#      state and the tile.
#   6. The dock's log gains no error line across all of it.
#
# `visible` is NOT asserted here, and the reason is structural: Qt Quick
# cascades `Item.visible` down the tree, and this harness hides the probe dock
# on purpose (autohide on, hide() called) so it never appears on the owner's
# screen - so every tile and badge inside it reads visible=false however well it
# drew. The badge's OWN rule is asserted instead (`expr`, level > 0.01 with an
# anchor); a pixel-level visibility proof needs the dock on a headless output,
# which is what tests/live/interactions.sh does.
#
# Non-intrusive: a hidden second Quickshell instance on a byte-copy of the
# config under a redirected HOME (tests/live/probe.sh). Nothing is shown on the
# owner's screen and the owner's own config is only read.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/live/probe.sh
. ./probe.sh

PROBE_BODY="$PWD/tasks-shell.qml"
export PROBE_BODY

fail=0
note() { echo "   $*"; }
red() { echo "   FAIL: $*" >&2; fail=1; }

# Error lines the dock logged: the class a broken binding or an unresolved
# colour produces. Counted before and after, so a pre-existing line cannot pass
# the check for us.
errlines() {
  grep -ciE "TypeError|ReferenceError|Unable to assign|is not a|Cannot read property" \
    "$(probe_log)" 2>/dev/null || true
}

# The dock's tiles and badges as they are right now, or "" if the call failed.
read_items() { qs -p "$PROBE_DIR" ipc call omadock-test read items "" 2>/dev/null; }

# A call that only settles after the dock has processed the change (its model
# updates on a debounce, and a shared-state change reaches the tiles through
# pullSharedState). Retry the whole predicate rather than sleeping a fixed time.
wait_for() {
  local i
  for i in $(seq 25); do
    "$@" && return 0
    sleep 0.2
  done
  return 1
}

# Predicates used with wait_for: they must run in THIS shell, because the
# probe helpers are shell functions and $PROBE_DIR is not exported.
answered() { [ -n "$(read_items)" ]; }
state_empty() { [ "$(probe_ipc taskStatus 2>/dev/null)" = "{}" ]; }
no_tile_task() {
  read_items | python3 -c '
import json,sys
busy = [i["appId"] for i in json.load(sys.stdin).get("items") or [] if i.get("hasTask")]
sys.exit(0 if not busy else 1)' 2>/dev/null
}

# The app tile to file tasks against: one that is present in two consecutive
# reads, so a tile that is still settling cannot pick itself and then vanish.
pick_target() {
  local a b
  a=$(read_items | python3 -c 'import json,sys;print(" ".join(i["appId"] for i in json.load(sys.stdin).get("items") or [] if i.get("appId")))' 2>/dev/null)
  sleep 0.4
  b=$(read_items | python3 -c 'import json,sys;print(" ".join(i["appId"] for i in json.load(sys.stdin).get("items") or [] if i.get("appId")))' 2>/dev/null)
  for id in $a; do
    case " $b " in *" $id "*) echo "$id"; return 0 ;; esac
  done
  return 1
}

echo "-- task HUD: reportTask -> tile binding -> badge -> clearTask"
if ! probe_start; then
  echo "   FAIL: the probe never started" >&2
  probe_cleanup >/dev/null 2>&1
  exit 1
fi

target=$(pick_target)
if [ -z "$target" ]; then
  red "the dock exposed no stable app tile to report a task against"
  probe_cleanup >/dev/null 2>&1
  exit 1
fi
note "reporting tasks against the real tile \"$target\""
before=$(errlines)

# The feature is inert by default: no tile resolves a task before one is sent.
wait_for answered || red "the fixture never answered"
read_items | python3 -c '
import json,sys
d = json.load(sys.stdin)
busy = [i["appId"] for i in d.get("items") or [] if i.get("hasTask")]
if busy: raise SystemExit("tiles already carry a task: %s" % ", ".join(busy))
if not (d.get("badges") or []): raise SystemExit("the fixture found no badge at all")
' 2>&1 | sed 's/^/   /' >&2
[ "${PIPESTATUS[0]}" = "0" ] || fail=1

# One status -> its documented glyph and colour, read back from the IPC state,
# the tile's binding and the drawn badge.
expect_task() {
  local st=$1 code=$2 title=$3 dur=$4 glyph=$5 colour=$6 rep tid ok
  rep=$(probe_ipc reportTask "$target" "$st" "$code" "$title" "$dur" 2>/dev/null)
  [ "$rep" = "ok" ] || { red "reportTask $st answered \"$rep\""; return 0; }

  tid=$(probe_ipc taskStatus 2>/dev/null | python3 -c '
import json,sys
want = sys.argv[1]
hit = [v for k, v in json.load(sys.stdin).items() if v.get("appId") == want]
if not hit: raise SystemExit("no task stored for %s" % want)
t = hit[0]
print("%s|%s|%s|%s" % (t["status"], t["exitCode"], t["title"], t["duration"]))
' "$target" 2>/dev/null)
  case "$tid" in
    "") red "taskStatus() held no task for $target" ;;
    "$st|$code|$title|$dur") note "taskStatus: $st, exit $code, \"$title\", ${dur}s" ;;
    *) red "taskStatus() read back \"$tid\", wanted \"$st|$code|$title|$dur\"" ;;
  esac

  ok=1
  for _ in $(seq 25); do
    read_items | python3 -c '
import json,sys
d = json.load(sys.stdin)
want, st, glyph, colour = sys.argv[1:5]
items = d.get("items") or []
mine = [i for i in items if i.get("appId") == want]
if not mine: raise SystemExit("the tile for %s vanished" % want)
it = mine[0]
if not it.get("hasTask"): raise SystemExit("tile %s resolved no task" % want)
if it.get("taskStatus") != st: raise SystemExit("tile resolved status %r, wanted %r" % (it.get("taskStatus"), st))
if it.get("badgeMode") != "status": raise SystemExit("tile badge mode %r, wanted status" % it.get("badgeMode"))
if it.get("badgeGlyph") != glyph: raise SystemExit("tile badge glyph %r, wanted %r" % (it.get("badgeGlyph"), glyph))
if it.get("badgeColor") != colour: raise SystemExit("tile badge colour %r, wanted %r" % (it.get("badgeColor"), colour))
others = [i["appId"] for i in items if i.get("appId") != want and i.get("hasTask")]
if others: raise SystemExit("another tile resolved the task: %s" % ", ".join(others))
# The drawn mark: the badge that took this glyph, its resolved colour, the text
# it set, and its own visibility rule (visible itself cascades from the hidden
# probe dock - see the header).
drawn = [b for b in (d.get("badges") or []) if b.get("shownGlyph") == glyph]
if not drawn: raise SystemExit("no BadgeMark took glyph %r" % glyph)
b = drawn[0]
if b.get("ink") != glyph: raise SystemExit("the badge drew %r, wanted %r" % (b.get("ink"), glyph))
if b.get("badgeColor") != colour: raise SystemExit("the badge took colour %r, wanted %r" % (b.get("badgeColor"), colour))
r = str(b.get("resolved") or "")
if not r.startswith("#") or r == "#00000000":
    raise SystemExit("the badge colour never resolved (%r)" % b.get("resolved"))
if b.get("expr") != "true": raise SystemExit("the badge is not drawable (level %r, anchor %r)" % (b.get("level"), b.get("hasAnchor")))
if float(b.get("level") or 0) <= 0.01: raise SystemExit("the badge level never rose (%r)" % b.get("level"))
' "$target" "$st" "$glyph" "$colour" 2>"/tmp/omadock-task-check.$$" && ok=0 && break
    sleep 0.2
  done
  if [ "$ok" != "0" ]; then
    red "the $st task did not reach the tile and its badge:"
    sed 's/^/     /' "/tmp/omadock-task-check.$$" >&2
  else
    note "the tile bound the task and a BadgeMark drew \"$glyph\" in $colour"
  fi
  rm -f "/tmp/omadock-task-check.$$"
}

expect_task running 0 "Sleep 40" 0 "●" "#89b4fa"
expect_task success 0 "cargo build --release" 14 "✓" "#a6e3a1"
expect_task error 2 "cargo test" 11 "!" "#f38ba8"

# An empty app id is not a task.
rep=$(probe_ipc reportTask "" done 0 "orphan" 0 2>/dev/null)
[ "$rep" = "invalid" ] || red "reportTask with an empty app id answered \"$rep\", wanted invalid"
note "an empty app id is refused (invalid)"

# clearTask empties the state and the tile together.
probe_ipc clearTask "$target" >/dev/null 2>&1
if wait_for state_empty; then
  note "clearTask emptied the task state"
else
  red "clearTask left the task in the state: $(probe_ipc taskStatus 2>/dev/null)"
fi
if wait_for no_tile_task; then
  note "clearTask emptied the tile"
else
  red "clearTask left the task on a tile"
fi

# The existing IPC surface still answers after all of it.
probe_ipc state 2>/dev/null | grep -q '"docks"' || red "state no longer answers after the task calls"

after=$(errlines)
if [ "$after" -le "$before" ]; then
  note "the dock's log gained no error line ($before -> $after)"
else
  red "the dock's log gained $((after - before)) error line(s):"
  grep -iE "TypeError|ReferenceError|Unable to assign|is not a|Cannot read property" "$(probe_log)" | tail -5 | sed 's/^/     /' >&2
fi

probe_cleanup || fail=1
if [ "$fail" = "0" ]; then
  echo "TASKS PASSED: the task HUD lands, binds on the tile, draws and clears"
else
  echo "TASKS FAILED" >&2
fi
exit $fail

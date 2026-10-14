#!/bin/sh
# OmaDock Task Reporter & Wrapper
#
# Reports command execution status (running/success/error), duration, and exit code
# to OmaDock's Task HUD via Quickshell IPC.
#
# Usage as a command wrapper:
#   scripts/omadock-task.sh cargo build --release
#   scripts/omadock-task.sh npm test
#
# Usage as direct IPC caller:
#   scripts/omadock-task.sh report <appId> <status> <exitCode> <title> <duration>
#   scripts/omadock-task.sh clear <appId>

call_ipc() {
  if command -v qs >/dev/null 2>&1; then
    qs -p /usr/share/omarchy/shell ipc call omadock "$@" 2>/dev/null
  fi
}

detect_terminal() {
  if [ -n "$OMADOCK_APP" ]; then
    echo "$OMADOCK_APP"
    return
  fi

  ai_app=""
  if [ -n "$AI_AGENT" ]; then
    ai_app="$AI_AGENT"
  elif [ -n "$ANTIGRAVITY_AGENT" ]; then
    ai_app="antigravity"
  elif [ -n "$CLAUDE_CODE" ] || [ -n "$CLAUDE_SESSION_ID" ]; then
    ai_app="claude"
  elif [ -n "$AIDER_ANALYTICS" ] || [ -n "$AIDER_DIR" ] || [ -n "$AIDER_MODEL" ]; then
    ai_app="aider"
  elif [ -n "$CURSOR_VERSION" ] || [ -n "$CURSOR_PROJECT_DIR" ]; then
    ai_app="cursor"
  elif [ -n "$WINDSURF_VERSION" ]; then
    ai_app="windsurf"
  elif [ -n "$OPEN_INTERPRETER" ]; then
    ai_app="interpreter"
  fi

  curr=$$
  term_app=""
  while [ -n "$curr" ] && [ "$curr" -gt 1 ] 2>/dev/null; do
    comm=$(cat "/proc/$curr/comm" 2>/dev/null)
    case "$comm" in
      agy|antigravity)
        [ -z "$ai_app" ] && ai_app="antigravity"
        ;;
      claude|claude-code)
        [ -z "$ai_app" ] && ai_app="claude"
        ;;
      aider|aider-chat)
        [ -z "$ai_app" ] && ai_app="aider"
        ;;
      ollama)
        [ -z "$ai_app" ] && ai_app="ollama"
        ;;
      cursor|cursor-bin)
        [ -z "$ai_app" ] && ai_app="cursor"
        ;;
      windsurf)
        [ -z "$ai_app" ] && ai_app="windsurf"
        ;;
      gemini|gemini-cli)
        [ -z "$ai_app" ] && ai_app="gemini"
        ;;
      aichat)
        [ -z "$ai_app" ] && ai_app="aichat"
        ;;
      sgpt)
        [ -z "$ai_app" ] && ai_app="sgpt"
        ;;
      mods)
        [ -z "$ai_app" ] && ai_app="mods"
        ;;
      interpreter|open-interpreter)
        [ -z "$ai_app" ] && ai_app="interpreter"
        ;;
      fabric)
        [ -z "$ai_app" ] && ai_app="fabric"
        ;;
      copilot|github-copilot)
        [ -z "$ai_app" ] && ai_app="copilot"
        ;;
      mentat)
        [ -z "$ai_app" ] && ai_app="mentat"
        ;;
      ghostty|kitty|alacritty|foot|footclient|wezterm|wezterm-gui|konsole|gnome-terminal*|tilix|xterm|xfce4-terminal|kgx|st)
        if [ -z "$term_app" ]; then
          term_app="$comm"
        fi
        ;;
    esac
    curr=$(awk '{print $4}' "/proc/$curr/stat" 2>/dev/null)
  done

  if [ -n "$ai_app" ] && [ -n "$term_app" ]; then
    echo "${ai_app}|${term_app}"
    return
  fi
  if [ -n "$ai_app" ]; then
    echo "$ai_app"
    return
  fi
  if [ -n "$term_app" ]; then
    echo "$term_app"
    return
  fi
  if [ -n "$TERM_PROGRAM" ]; then
    echo "$TERM_PROGRAM"
    return
  fi
  echo "terminal"
}

case "$1" in
  report)
    shift
    call_ipc reportTask "$@"
    exit $?
    ;;
  clear)
    shift
    call_ipc clearTask "$@"
    exit $?
    ;;
  status)
    call_ipc taskStatus
    exit $?
    ;;
  hook)
    shift
    cat >/dev/null 2>&1
    case "$1" in
      pre)
        call_ipc reportTask antigravity running 0 "Thinking..." 0 >/dev/null 2>&1
        ;;
      stop)
        call_ipc reportTask antigravity success 0 "Ready" 0 >/dev/null 2>&1
        ;;
    esac
    echo "{}"
    exit 0
    ;;
  "")
    echo "Usage: omadock-task <command...> | report <args> | clear <appId> | hook <pre|stop>" >&2
    exit 1
    ;;
esac

# Running as a wrapper around an executable command
APP_ID=$(detect_terminal)
CMD_NAME="$*"
START_TIME=$(date +%s)

# Execute command
"$@"
EXIT_CODE=$?

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
[ "$DURATION" -lt 0 ] && DURATION=0

STATUS="done"
[ "$EXIT_CODE" -ne 0 ] && STATUS="error"

# Report final status
call_ipc reportTask "$APP_ID" "$STATUS" "$EXIT_CODE" "$CMD_NAME" "$DURATION" >/dev/null 2>&1

exit $EXIT_CODE

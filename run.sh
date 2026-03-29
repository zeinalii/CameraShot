#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$ROOT_DIR/CameraShot.app"
APP_BIN="$APP_PATH/Contents/MacOS/CameraShot"
BUNDLE_ID="com.camerashot.CameraShot"
OPENCODE_BIN="$(command -v opencode || true)"
OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
STATE_DIR="${HOME}/.camerashot"
OPENCODE_PID_FILE="${STATE_DIR}/opencode-serve.pid"
OPENCODE_LOG_FILE="${STATE_DIR}/opencode-serve.log"

usage() {
  cat <<'EOF'
Usage:
  ./run.sh                  # Open existing app
  ./run.sh --build          # Build app first, then open
  ./run.sh --no-server      # Open app without starting opencode HTTP server
EOF
}

ensure_app_exists() {
  if [[ ! -x "$APP_BIN" ]]; then
    echo "CameraShot.app not found. Building first..."
    make -C "$ROOT_DIR" build
  fi
}

stop_running_app() {
  # Avoid LaunchServices stale-handle issues when rebuilding/relaunching.
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  pkill -x CameraShot >/dev/null 2>&1 || true
}

launch_app() {
  # First try normal LaunchServices open.
  if open -a "$APP_PATH" >/dev/null 2>&1; then
    return
  fi

  # If LaunchServices returns -600, force a fresh instance.
  if open -n "$APP_PATH" >/dev/null 2>&1; then
    return
  fi

  # Last fallback: execute binary directly.
  "$APP_BIN" >/dev/null 2>&1 &
}

is_server_listening() {
  lsof -nP -iTCP:"$OPENCODE_PORT" -sTCP:LISTEN 2>/dev/null | awk '{print $1}' | grep -q '^opencode$'
}

start_opencode_server() {
  if [[ -z "$OPENCODE_BIN" ]]; then
    echo "Warning: opencode binary not found in PATH; HTTP server not started."
    return
  fi

  mkdir -p "$STATE_DIR"

  if is_server_listening; then
    return
  fi

  if [[ -f "$OPENCODE_PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$OPENCODE_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      return
    fi
    rm -f "$OPENCODE_PID_FILE"
  fi

  echo "Starting opencode HTTP server at http://${OPENCODE_HOST}:${OPENCODE_PORT} ..."
  nohup "$OPENCODE_BIN" serve --hostname "$OPENCODE_HOST" --port "$OPENCODE_PORT" >"$OPENCODE_LOG_FILE" 2>&1 &
  echo $! > "$OPENCODE_PID_FILE"

  for _ in $(seq 1 40); do
    if is_server_listening; then
      return
    fi
    sleep 0.2
  done

  echo "Warning: opencode server may not have started. Check: $OPENCODE_LOG_FILE"
}

START_SERVER=1
case "${1:-}" in
  "")
    ensure_app_exists
    ;;
  --build)
    stop_running_app
    make -C "$ROOT_DIR" build
    ;;
  --no-server)
    ensure_app_exists
    START_SERVER=0
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage
    exit 1
    ;;
esac

if [[ "$START_SERVER" == "1" ]]; then
  start_opencode_server
fi

launch_app
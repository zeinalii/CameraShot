#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$ROOT_DIR/CameraShot.app"
APP_BIN="$APP_PATH/Contents/MacOS/CameraShot"
BUNDLE_ID="com.camerashot.CameraShot"
CODEX_BIN="${CODEX_BIN:-$(command -v codex || true)}"

usage() {
  cat <<'EOF'
Usage:
  ./run.sh                  # Open existing app
  ./run.sh --build          # Build app first, then open
  ./run.sh --no-server      # Compatibility no-op; app uses Codex directly
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
  if [[ -n "$CODEX_BIN" ]]; then
    export CODEX_BIN
    launchctl setenv CODEX_BIN "$CODEX_BIN" >/dev/null 2>&1 || true
  fi

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

launch_app

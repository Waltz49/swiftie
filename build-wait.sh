#!/usr/bin/env bash
# Wait for other swift-build processes, then run a command (default: ss alias).

show_help() {
  printf '%s\n' \
    'Usage: build-wait.sh [-h|--help] [ss|fda|command [args...]]' \
    '' \
    'Wait until no process matches "swift-build" (pgrep -f), showing a single-line' \
    '"Running HH:MM:SS" status, then print "done" and run a command.' \
    '' \
    'With no arguments, or with ss, runs your shell ss alias (clear, prints alias, then build/run).' \
    'With fda, runs your shell fda alias the same way.' \
    'Any other command is executed after waiting.' \
    '' \
    'Examples:' \
    '  build-wait.sh' \
    '  build-wait.sh ss' \
    '  build-wait.sh fda' \
    '  build-wait.sh swift build' \
    "  build-wait.sh echo \"life is good\""
}

case "${1-}" in
  -h|--help)
    show_help
    exit 0
    ;;
esac

wait_for_swift_build() {
  while pgrep -f swift-build >/dev/null; do
    printf '\rRunning %s' "$(date '+%H:%M:%S')"
    sleep 1
  done
  printf '\r\033[K'
  echo done
}

# Run a user alias from bash login+interactive config (k/clear, alias print, body).
run_user_alias() {
  local name=$1
  bash -lic "$name"
}

wait_for_swift_build

case "${1-}" in
  ''|ss)
    run_user_alias ss
    ;;
  fda)
    run_user_alias fda
    ;;
  *)
    "$@"
    ;;
esac

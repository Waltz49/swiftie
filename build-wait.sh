#!/usr/bin/env bash
# Wait for other swift-build processes, then run a command (default: ss alias).

show_help() {
  printf '%s\n' \
    'Usage: build-wait.sh [-h|--help] [ss|fda|command [args...]]' \
    '' \
    'Wait until no process matches "swift-build" (pgrep -f), showing a single-line' \
    '"Waiting for build to finish: HH:MM:SS" status, then sync repo assets/ into' \
    'swift/Prowser/Resources/Assets/, print "Build completed", and run a command.' \
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

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Repo-root assets/ → SPM resource folder (see AppAssets.swift); not automatic otherwise.
sync_repo_assets_into_swift_bundle() {
  local src="$REPO_ROOT/assets"
  local dest="$REPO_ROOT/swift/Prowser/Resources/Assets"
  if [[ ! -d "$src" ]]; then
    echo "build-wait: no $src — skipping asset sync" >&2
    return 0
  fi
  mkdir -p "$dest"
  rsync -a "$src/" "$dest/"
  echo "build-wait: synced assets/ → swift/Prowser/Resources/Assets/"
}

wait_for_swift_build() {
  while pgrep -f swift-build >/dev/null; do
    printf '\rWaiting for build to finish: %s' "$(date '+%H:%M:%S')"
    sleep 1
  done
  printf '\r\033[K'
  echo "Build completed"
}

# Run a user alias from bash login+interactive config (k/clear, alias print, body).
run_user_alias() {
  local name=$1
  bash -lic "$name"
}

wait_for_swift_build
sync_repo_assets_into_swift_bundle

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

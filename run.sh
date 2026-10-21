#!/bin/bash
# Launch the Python Prowser app (prowser.py) using the repo virtualenv.

usage() {
    cat <<EOF
$(basename "$0") — run the Python Native Image Browser (prowser.py).

Activates venv_image_browser/ or venv/, then runs prowser.py with any arguments you pass.

Usage: $(basename "$0") [prowser.py options...]

Examples:
  $(basename "$0")
  $(basename "$0") ~/Pictures

Options:
  -h, --help    Show this help (does not pass through to prowser.py)

Setup: ./setup.sh
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

deactivate > /dev/null 2>&1

if [ -d "./venv_image_browser/" ]; then
    . ./venv_image_browser/bin/activate
else
    . ./venv/bin/activate
fi

python prowser.py "$@"

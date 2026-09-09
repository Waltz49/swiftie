#!/bin/bash
# Setup script for Native Image Browser
set -euo pipefail

PYTHON_CMD="python3.14"

echo "Setting up Native Image Browser..."
echo "================================================"

if ! command -v "$PYTHON_CMD" &> /dev/null; then
    echo "Error: $PYTHON_CMD is required but not found."
    echo "Install Python 3.14 (or change PYTHON_CMD in this script)."
    exit 1
fi

python_version=$("$PYTHON_CMD" -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
echo "Found Python $python_version"

echo "Creating virtual environment..."
"$PYTHON_CMD" -m venv venv_image_browser

# shellcheck disable=SC1091
source venv_image_browser/bin/activate

echo "Upgrading pip..."
pip install --upgrade pip --quiet

echo "Installing dependencies..."
echo "   - PySide6 (Qt for Python)"
echo "   - Pillow (Image processing)"
echo "   - mflux (Create menu image generation; large download)"

# regex before transformers avoids resolver backtracking on Python 3.14
pip install 'regex>=2025.10.22'
pip install -r minimal_requirements.txt

echo "Verifying install..."
python -c "import PySide6; import torch; import transformers; print('Core imports OK')"

echo ""
echo "Setup complete!"
echo ""
echo "To run the application:"
echo "   1. Activate the environment: source venv_image_browser/bin/activate"
echo "   2. Run the app: python prowser.py [optional_directory_path]"
echo ""
echo "Or use the convenience script: run.sh"
echo ""
echo "Press '/' or F1 in the app to see all keyboard shortcuts for the current view mode."
echo "================================================"

#!/usr/bin/env bash
# Start the ModelArray GUI (Flask + Waitress) inside an isolated venv.
#
# Usage:
#   bash gui/start_gui.sh          # creates venv on first run, then starts
#   bash gui/start_gui.sh --reset  # delete and recreate the venv
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

# ── Optional: reset venv ───────────────────────────────────────────────────────
if [[ "${1:-}" == "--reset" ]]; then
  echo "[GUI] Removing existing venv..."
  rm -rf "$VENV_DIR"
fi

# ── Create venv if missing ─────────────────────────────────────────────────────
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  echo "[GUI] Creating virtual environment in gui/.venv ..."
  python3 -m venv "$VENV_DIR"
  echo "[GUI] Installing dependencies..."
  "$VENV_DIR/bin/pip" install --quiet --upgrade pip
  "$VENV_DIR/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"
  echo "[GUI] Done."
fi

# ── Verify ─────────────────────────────────────────────────────────────────────
"$VENV_DIR/bin/python" -c "import flask, waitress" || {
  echo "[ERROR] venv broken — run:  bash gui/start_gui.sh --reset"
  exit 1
}

# ── Launch ─────────────────────────────────────────────────────────────────────
echo ""
echo "  ┌──────────────────────────────────────────┐"
echo "  │         ModelArray GUI — starting        │"
echo "  │   Open http://localhost:8080 in browser  │"
echo "  │   Press Ctrl+C to stop                   │"
echo "  └──────────────────────────────────────────┘"
echo ""

cd "$SCRIPT_DIR/.."   # run from the ModelArray root so relative paths work
exec "$VENV_DIR/bin/python" "$SCRIPT_DIR/app.py"

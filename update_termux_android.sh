#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="${HOME}/.${APP_NAME}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
START_SCRIPT="${INSTALL_DIR}/start.sh"
STOP_SCRIPT="${INSTALL_DIR}/stop.sh"
PYTHON_VENV_BIN="${INSTALL_DIR}/.venv/bin/python"
LOG_FILE="${INSTALL_DIR}/panel.log"

normalize_termux_shell_line_endings() {
  local file

  shopt -s nullglob
  for file in "${SCRIPT_DIR}"/*.sh; do
    sed -i 's/\r$//' "${file}" 2>/dev/null || true
  done
  shopt -u nullglob
}

normalize_termux_shell_line_endings

if [[ ! -f "${SCRIPT_DIR}/main.py" || ! -f "${SCRIPT_DIR}/panel_app.py" ]]; then
  echo "Required project files were not found next to update_termux.sh."
  exit 1
fi

if [[ ! -d "${INSTALL_DIR}" ]]; then
  echo "Install directory not found: ${INSTALL_DIR}"
  echo "Run install_termux.sh first."
  exit 1
fi

if [[ ! -x "${PYTHON_VENV_BIN}" ]]; then
  echo "Virtual environment not found in ${INSTALL_DIR}/.venv"
  echo "Run install_termux.sh first."
  exit 1
fi

echo "==> Stopping DNS Scout process"
if [[ -x "${STOP_SCRIPT}" ]]; then
  "${STOP_SCRIPT}" || true
fi

echo "==> Syncing updated project files"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude ".git/" \
    --exclude ".idea/" \
    --exclude "__pycache__/" \
    --exclude ".venv/" \
    --exclude "panel_config.json" \
    --exclude ".online_release" \
    --exclude "source/" \
    --exclude "panel.log" \
    --exclude "panel.pid" \
    --exclude "run_panel.sh" \
    --exclude "start.sh" \
    --exclude "stop.sh" \
    --exclude "status.sh" \
    "${SCRIPT_DIR}/" "${INSTALL_DIR}/"
else
  echo "rsync not found; using cp fallback."
  find "${INSTALL_DIR}" -mindepth 1 \
    ! -name ".venv" \
    ! -name "panel_config.json" \
    ! -name ".online_release" \
    ! -name "source" \
    ! -name "panel.log" \
    ! -name "panel.pid" \
    ! -name "run_panel.sh" \
    ! -name "start.sh" \
    ! -name "stop.sh" \
    ! -name "status.sh" \
    -exec rm -rf {} +
  find "${SCRIPT_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name ".git" \
    ! -name ".idea" \
    ! -name "__pycache__" \
    ! -name ".venv" \
    ! -name "source" \
    -exec cp -a {} "${INSTALL_DIR}/" \;
fi

echo "==> Updating Python dependencies"
if ! "${PYTHON_VENV_BIN}" -m pip install --upgrade pandas flask python-dateutil; then
  "${PYTHON_VENV_BIN}" -m pip install --index-url https://mirror-pypi.runflare.com/simple --upgrade pandas flask python-dateutil
fi

echo "==> Starting DNS Scout process"
if [[ -x "${START_SCRIPT}" ]]; then
  "${START_SCRIPT}"
else
  echo "Start script was not found after update: ${START_SCRIPT}"
  exit 1
fi

echo
echo "Update completed successfully."
echo "Log file: ${LOG_FILE}"

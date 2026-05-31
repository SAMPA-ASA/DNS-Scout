#!/usr/bin/env bash
set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="/opt/${APP_NAME}"
SERVICE_NAME="${APP_NAME}.service"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "==> Script directory: ${SCRIPT_DIR}"

if [[ ! -f "${SCRIPT_DIR}/main.py" || ! -f "${SCRIPT_DIR}/panel_app.py" ]]; then
  echo "Required project files were not found next to update.sh."
  exit 1
fi

if [[ ! -d "${INSTALL_DIR}" ]]; then
  echo "Install directory not found: ${INSTALL_DIR}"
  echo "Run install.sh first."
  exit 1
fi

echo "==> Syncing updated project files"
if command -v rsync >/dev/null 2>&1; then
  ${SUDO} rsync -a --delete \
    --exclude ".git/" \
    --exclude ".idea/" \
    --exclude "__pycache__/" \
    --exclude ".venv/" \
    --exclude "panel_config.json" \
    --exclude "source/" \
    "${SCRIPT_DIR}/" "${INSTALL_DIR}/"
else
  echo "rsync not found; using cp fallback."
  ${SUDO} find "${INSTALL_DIR}" -mindepth 1 \
    ! -name ".venv" \
    ! -name "panel_config.json" \
    ! -name "source" \
    -exec rm -rf {} +
  ${SUDO} find "${SCRIPT_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name ".git" \
    ! -name ".idea" \
    ! -name "__pycache__" \
    ! -name ".venv" \
    ! -name "source" \
    -exec cp -a {} "${INSTALL_DIR}/" \;
fi

if [[ -x "${INSTALL_DIR}/.venv/bin/python" ]]; then
  echo "==> Updating Python dependencies"
  if ! ${SUDO} "${INSTALL_DIR}/.venv/bin/python" -m pip install --upgrade pandas flask; then
    ${SUDO} "${INSTALL_DIR}/.venv/bin/python" -m pip install -i https://mirror-pypi.runflare.com/simple --upgrade pandas flask
  fi
else
  echo "Virtual environment not found in ${INSTALL_DIR}/.venv"
  echo "Run install.sh first."
  exit 1
fi

echo "==> Restarting ${SERVICE_NAME}"
${SUDO} systemctl daemon-reload
${SUDO} systemctl restart "${SERVICE_NAME}"

echo
${SUDO} systemctl status "${SERVICE_NAME}" --no-pager

echo
echo "Update completed successfully."

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

ensure_panel_firewall_rule() {
  local port="$1"
  local applied="false"

  if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "Warning: invalid panel port for firewall setup: ${port}"
    return 0
  fi

  if command -v ufw >/dev/null 2>&1; then
    if ${SUDO} ufw status 2>/dev/null | grep -q "Status: active"; then
      if ${SUDO} ufw allow "${port}/tcp" >/dev/null 2>&1; then
        echo "==> UFW rule ensured for TCP port ${port}"
        applied="true"
      else
        echo "Warning: could not add UFW rule for TCP port ${port}."
      fi
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    if ${SUDO} systemctl is-active --quiet firewalld; then
      if ${SUDO} firewall-cmd --quiet --add-port="${port}/tcp" && ${SUDO} firewall-cmd --quiet --permanent --add-port="${port}/tcp"; then
        echo "==> firewalld rule ensured for TCP port ${port}"
        applied="true"
      else
        echo "Warning: could not add firewalld rule for TCP port ${port}."
      fi
    fi
  fi

  if [[ "${applied}" != "true" ]]; then
    echo "Note: no active supported firewall manager detected (ufw/firewalld)."
  fi
}

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

PANEL_PORT="$(INSTALL_DIR="${INSTALL_DIR}" "${INSTALL_DIR}/.venv/bin/python" - <<'PY'
import json
import os
from pathlib import Path

cfg_path = Path(os.environ["INSTALL_DIR"]) / "panel_config.json"
try:
    payload = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
    port = int(payload.get("port", 0))
except Exception:
    print("")
else:
    print(port if 1 <= port <= 65535 else "")
PY
)"
if [[ -n "${PANEL_PORT}" ]]; then
  echo "==> Configuring firewall access for panel port ${PANEL_PORT}"
  ensure_panel_firewall_rule "${PANEL_PORT}"
fi

echo
${SUDO} systemctl status "${SERVICE_NAME}" --no-pager

echo
echo "Update completed successfully."

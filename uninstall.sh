#!/usr/bin/env bash
set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="/opt/${APP_NAME}"
SERVICE_NAME="${APP_NAME}.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "==> Uninstalling ${APP_NAME}"
echo "This will remove:"
echo "  - systemd service: ${SERVICE_FILE}"
echo "  - installed directory: ${INSTALL_DIR}"
echo "Project files in current repository will NOT be deleted."
echo

read -rp "Continue? [Y/n]: " CONFIRM
CONFIRM="$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')"
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "yes" ]]; then
  echo "Uninstall cancelled."
  exit 0
fi

if ${SUDO} systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
  echo "==> Stopping service"
  ${SUDO} systemctl stop "${SERVICE_NAME}" || true

  echo "==> Disabling service"
  ${SUDO} systemctl disable "${SERVICE_NAME}" || true
else
  echo "==> Service unit not found in systemd list. Skipping stop/disable."
fi

if [[ -f "${SERVICE_FILE}" ]]; then
  echo "==> Removing service file"
  ${SUDO} rm -f "${SERVICE_FILE}"
else
  echo "==> Service file not found. Skipping."
fi

echo "==> Reloading systemd"
${SUDO} systemctl daemon-reload
${SUDO} systemctl reset-failed || true

if [[ -d "${INSTALL_DIR}" ]]; then
  echo "==> Removing installed directory"
  ${SUDO} rm -rf "${INSTALL_DIR}"
else
  echo "==> Install directory not found. Skipping."
fi

echo
echo "Uninstall completed."
echo "You can run install again from your project folder:"
echo "  sudo bash ./install.sh"

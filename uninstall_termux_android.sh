#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="${HOME}/.${APP_NAME}"
PID_FILE="${INSTALL_DIR}/panel.pid"
LOG_FILE="${INSTALL_DIR}/panel.log"
START_SCRIPT="${INSTALL_DIR}/start.sh"
STOP_SCRIPT="${INSTALL_DIR}/stop.sh"
STATUS_SCRIPT="${INSTALL_DIR}/status.sh"

echo "==> Uninstalling ${APP_NAME} (Termux)"
echo "This will remove:"
echo "  - installed directory: ${INSTALL_DIR}"
echo "  - command symlinks: dns-scout-start, dns-scout-stop, dns-scout-status"
echo "Project files in current repository will NOT be deleted."
echo

read -rp "Continue? [Y/n]: " CONFIRM
CONFIRM="$(echo "${CONFIRM}" | tr '[:upper:]' '[:lower:]')"
if [[ -n "${CONFIRM}" && "${CONFIRM}" != "y" && "${CONFIRM}" != "yes" ]]; then
  echo "Uninstall cancelled."
  exit 0
fi

if [[ -x "${STOP_SCRIPT}" ]]; then
  echo "==> Stopping service process"
  "${STOP_SCRIPT}" || true
elif [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${PID_FILE}"
fi

if [[ -n "${PREFIX:-}" && -d "${PREFIX}/bin" ]]; then
  rm -f "${PREFIX}/bin/dns-scout-start" "${PREFIX}/bin/dns-scout-stop" "${PREFIX}/bin/dns-scout-status"
fi
if [[ -d "${HOME}/.local/bin" ]]; then
  rm -f "${HOME}/.local/bin/dns-scout-start" "${HOME}/.local/bin/dns-scout-stop" "${HOME}/.local/bin/dns-scout-status"
fi

if [[ -d "${INSTALL_DIR}" ]]; then
  echo "==> Removing installed directory"
  rm -rf "${INSTALL_DIR}"
else
  echo "==> Install directory not found. Skipping."
fi

echo
echo "Uninstall completed."

#!/usr/bin/env bash
set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="/opt/${APP_NAME}"
SERVICE_NAME="${APP_NAME}.service"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHON_BIN="python3"
PANEL_CONFIG_FILE="${INSTALL_DIR}/panel_config.json"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
TTY_INPUT="/dev/tty"

prompt_input() {
  local __result_var="$1"
  local __prompt="$2"
  local __silent="${3:-false}"
  local __value=""

  if [[ "${__silent}" == "true" ]]; then
    if [[ -r "${TTY_INPUT}" ]]; then
      IFS= read -r -s -p "${__prompt}" __value <"${TTY_INPUT}" || {
        echo
        echo "Input was cancelled or unavailable."
        exit 1
      }
    else
      IFS= read -r -s -p "${__prompt}" __value || {
        echo
        echo "Input was cancelled or unavailable."
        exit 1
      }
    fi
  else
    if [[ -r "${TTY_INPUT}" ]]; then
      IFS= read -r -p "${__prompt}" __value <"${TTY_INPUT}" || {
        echo
        echo "Input was cancelled or unavailable."
        exit 1
      }
    else
      IFS= read -r -p "${__prompt}" __value || {
        echo
        echo "Input was cancelled or unavailable."
        exit 1
      }
    fi
  fi

  printf -v "${__result_var}" '%s' "${__value}"
}

python_has_pip() {
  "${PYTHON_BIN}" -m pip --version >/dev/null 2>&1
}

python_has_venv() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  if "${PYTHON_BIN}" -m venv "${tmp_dir}/venv" >/dev/null 2>&1; then
    rm -rf -- "${tmp_dir}"
    return 0
  fi
  rm -rf -- "${tmp_dir}"
  return 1
}

install_python_runtime_packages() {
  local py_series
  py_series="$(${PYTHON_BIN} -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"

  if command -v apt-get >/dev/null 2>&1; then
    ${SUDO} apt-get update
    if ! ${SUDO} apt-get install -y python3-pip python3-venv; then
      echo "Default python3-venv package was unavailable. Trying versioned fallback."
      if ! ${SUDO} apt-get install -y python3-pip "python${py_series}-venv"; then
        ${SUDO} apt-get install -y "python${py_series}-full"
      fi
    fi
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    ${SUDO} dnf install -y python3-pip
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    ${SUDO} yum install -y python3-pip
    return
  fi

  if command -v pacman >/dev/null 2>&1; then
    ${SUDO} pacman -Sy --noconfirm python python-pip
    return
  fi

  if command -v zypper >/dev/null 2>&1; then
    ${SUDO} zypper --non-interactive install python3 python3-pip
    return
  fi

  if command -v apk >/dev/null 2>&1; then
    ${SUDO} apk add --no-cache python3 py3-pip
    return
  fi

  echo "No supported package manager found to install python dependencies automatically."
  echo "Please install python3, python3-venv, and python3-pip manually."
  exit 1
}

ensure_python_runtime_ready() {
  if python_has_venv && python_has_pip; then
    return
  fi

  echo "==> Ensuring python venv and pip"
  install_python_runtime_packages

  if ! python_has_pip; then
    "${PYTHON_BIN}" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi

  if ! python_has_venv; then
    echo "Failed to prepare Python venv support automatically."
    exit 1
  fi

  if ! python_has_pip; then
    echo "Failed to prepare Python pip automatically."
    exit 1
  fi
}

is_port_free() {
  local port="$1"
  "${PYTHON_BIN}" - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", port))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
}

pick_random_free_port() {
  "${PYTHON_BIN}" <<'PY'
import random
import socket

for _ in range(500):
    port = random.randint(12000, 49000)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", port))
        print(port)
        break
    except OSError:
        pass
    finally:
        s.close()
else:
    print(18080)
PY
}

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "==> Script directory: ${SCRIPT_DIR}"

if [[ ! -f "${SCRIPT_DIR}/main.py" ]]; then
  echo "main.py was not found next to install.sh."
  echo "Files in script directory:"
  ls -la -- "${SCRIPT_DIR}"
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/panel_app.py" ]]; then
  echo "panel_app.py was not found next to install.sh."
  echo "Files in script directory:"
  ls -la -- "${SCRIPT_DIR}"
  exit 1
fi

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "Python 3 is not installed."
  exit 1
fi

PY_MAJOR="$(${PYTHON_BIN} -c 'import sys; print(sys.version_info[0])')"
PY_MINOR="$(${PYTHON_BIN} -c 'import sys; print(sys.version_info[1])')"

if [[ "${PY_MAJOR}" -lt 3 || "${PY_MINOR}" -lt 10 ]]; then
  echo "Python 3.10+ is required."
  exit 1
fi

echo
prompt_input PANEL_USERNAME "Enter panel username: "
while [[ -z "${PANEL_USERNAME}" ]]; do
  echo "Username cannot be empty."
  prompt_input PANEL_USERNAME "Enter panel username: "
done

while true; do
  prompt_input PANEL_PASSWORD "Enter panel password: " true
  echo
  prompt_input PANEL_PASSWORD_CONFIRM "Confirm panel password: " true
  echo
  if [[ -z "${PANEL_PASSWORD}" ]]; then
    echo "Password cannot be empty."
    continue
  fi
  if [[ "${PANEL_PASSWORD}" != "${PANEL_PASSWORD_CONFIRM}" ]]; then
    echo "Passwords do not match. Please try again."
    continue
  fi
  break
done

SUGGESTED_PORT="$(pick_random_free_port)"
echo
echo "Suggested free port: ${SUGGESTED_PORT}"
while true; do
  prompt_input SELECTED_PORT "Press Enter to accept it or enter a custom port: "
  if [[ -z "${SELECTED_PORT}" ]]; then
    SELECTED_PORT="${SUGGESTED_PORT}"
  fi

  if ! [[ "${SELECTED_PORT}" =~ ^[0-9]+$ ]]; then
    echo "Invalid port. Please enter a number."
    continue
  fi
  if (( SELECTED_PORT < 1 || SELECTED_PORT > 65535 )); then
    echo "Port must be between 1 and 65535."
    continue
  fi

  if is_port_free "${SELECTED_PORT}"; then
    break
  fi
  echo "Port ${SELECTED_PORT} is already in use. Please choose another port."
done

echo "==> Preparing install directory"
${SUDO} mkdir -p "${INSTALL_DIR}"
${SUDO} rm -rf "${INSTALL_DIR:?}"/*
${SUDO} cp -a "${SCRIPT_DIR}/." "${INSTALL_DIR}/"

ensure_python_runtime_ready

echo "==> Creating virtual environment"
if [[ ! -d "${INSTALL_DIR}/.venv" ]]; then
  ${SUDO} "${PYTHON_BIN}" -m venv "${INSTALL_DIR}/.venv"
fi

${SUDO} "${INSTALL_DIR}/.venv/bin/python" -m pip install --upgrade pip

echo "==> Installing dependencies"
if ! ${SUDO} "${INSTALL_DIR}/.venv/bin/python" -m pip install pandas flask; then
  ${SUDO} "${INSTALL_DIR}/.venv/bin/python" -m pip install -i https://mirror-pypi.runflare.com/simple pandas flask
fi

echo "==> Generating panel configuration"
PANEL_PASSWORD_HASH="$(
  PANEL_PASSWORD="${PANEL_PASSWORD}" "${INSTALL_DIR}/.venv/bin/python" - <<'PY'
import os
from werkzeug.security import generate_password_hash

print(generate_password_hash(os.environ["PANEL_PASSWORD"]))
PY
)"

PANEL_SECRET_KEY="$("${INSTALL_DIR}/.venv/bin/python" - <<'PY'
import secrets

print(secrets.token_urlsafe(48))
PY
)"

PANEL_JSON="$(
  PANEL_USERNAME="${PANEL_USERNAME}" \
  PANEL_PASSWORD_HASH="${PANEL_PASSWORD_HASH}" \
  PANEL_SECRET_KEY="${PANEL_SECRET_KEY}" \
  SELECTED_PORT="${SELECTED_PORT}" \
  INSTALL_DIR="${INSTALL_DIR}" \
  "${INSTALL_DIR}/.venv/bin/python" - <<'PY'
import json
import os

print(json.dumps({
    "username": os.environ["PANEL_USERNAME"],
    "password_hash": os.environ["PANEL_PASSWORD_HASH"],
    "port": int(os.environ["SELECTED_PORT"]),
    "secret_key": os.environ["PANEL_SECRET_KEY"],
    "source_dir": f"{os.environ['INSTALL_DIR']}/source",
    "csv_config_path": f"{os.environ['INSTALL_DIR']}/csv_extractor_config.json",
    "scanner_config_path": f"{os.environ['INSTALL_DIR']}/scanner_config.json",
}, ensure_ascii=False, indent=2))
PY
)"

printf '%s\n' "${PANEL_JSON}" | ${SUDO} tee "${PANEL_CONFIG_FILE}" >/dev/null
unset PANEL_PASSWORD PANEL_PASSWORD_CONFIRM

echo "==> Creating systemd service"
SERVICE_CONTENT="$(
  cat <<EOF
[Unit]
Description=DNS Scout
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/panel_app.py --config ${PANEL_CONFIG_FILE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
)"
printf '%s\n' "${SERVICE_CONTENT}" | ${SUDO} tee "${SERVICE_FILE}" >/dev/null

echo "==> Reloading systemd"
${SUDO} systemctl daemon-reload

echo "==> Enabling service"
${SUDO} systemctl enable "${SERVICE_NAME}"

echo "==> Starting service"
${SUDO} systemctl restart "${SERVICE_NAME}"

echo
${SUDO} systemctl status "${SERVICE_NAME}" --no-pager

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="127.0.0.1"
fi

echo
echo "Installation completed."
echo "Open the panel and login to start scanning:"
echo "  http://${HOST_IP}:${SELECTED_PORT}"
echo
echo "To change panel username/password later via CLI:"
echo "  sudo ${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/manage_panel_auth.py --config ${PANEL_CONFIG_FILE}"

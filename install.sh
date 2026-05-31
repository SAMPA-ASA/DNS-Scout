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
UBUNTU_APT_MIRRORS=(
  "http://mirror-linux.runflare.com/ubuntu"
  "http://mirror.arvancloud.ir/ubuntu"
  "http://linux-mirror.liara.ir/repository/ubuntu"
  "http://linux-mirror.liara.ir/repository/ubuntu-security"
  "https://repo.abrha.net/ubuntu"
  "https://ubuntu.hostiran.ir/ubuntuarchive"
  "https://archive.ubuntu.petiak.ir/ubuntu"
  "https://ubuntu-mirror.kimiahost.com"
  "https://ir.ubuntu.sindad.cloud/ubuntu"
  "http://mirror.faraso.org/ubuntu"
  "http://mirror.aminidc.com/ubuntu"
  "https://mirrors.pardisco.co/ubuntu"
  "https://mirror.0-1.cloud/ubuntu"
  "http://linuxmirrors.ir/pub/ubuntu"
  "http://repo.iut.ac.ir/repo/Ubuntu"
  "https://ubuntu.shatel.ir/ubuntu"
  "http://ubuntu.byteiran.com/ubuntu"
  "https://mirror.rasanegar.com/ubuntu"
)
PIP_INDEX_MIRRORS=(
  "https://mirror-pypi.runflare.com/simple"
  "https://package-mirror.liara.ir/repository/pypi"
  "https://mirror.abrha.net/repository/pypi/simple"
  "https://pypi.runflare.com/simple"
  "https://pypi.mirrors.chabokan.com/simple"
  "https://pypi.tuna.tsinghua.edu.cn/simple"
  "https://mirrors.aliyun.com/pypi/simple"
  "https://pypi.mirrors.ustc.edu.cn/simple"
)
APT_SOURCES_BACKUP_DIR=""
OFFICIAL_UBUNTU_APT_URL="http://archive.ubuntu.com/ubuntu"

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

is_ubuntu_system() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *ubuntu* ]]; then
      return 0
    fi
  fi
  return 1
}

list_ubuntu_apt_source_files() {
  local files=()
  shopt -s nullglob
  files=(/etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
  shopt -u nullglob
  printf '%s\n' "${files[@]}"
}

backup_ubuntu_apt_sources() {
  local file
  local rel_path
  local rel_dir

  if ! is_ubuntu_system; then
    return 1
  fi
  if [[ -n "${APT_SOURCES_BACKUP_DIR}" ]]; then
    return 0
  fi

  APT_SOURCES_BACKUP_DIR="$(mktemp -d)"
  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    rel_path="${file#/}"
    rel_dir="$(dirname -- "${rel_path}")"
    mkdir -p "${APT_SOURCES_BACKUP_DIR}/${rel_dir}"
    ${SUDO} cp -a "${file}" "${APT_SOURCES_BACKUP_DIR}/${rel_path}"
  done < <(list_ubuntu_apt_source_files)
}

restore_ubuntu_apt_sources() {
  local file
  local rel_path

  if [[ -z "${APT_SOURCES_BACKUP_DIR}" || ! -d "${APT_SOURCES_BACKUP_DIR}" ]]; then
    return 0
  fi

  while IFS= read -r file; do
    rel_path="${file#/}"
    if [[ -f "${APT_SOURCES_BACKUP_DIR}/${rel_path}" ]]; then
      ${SUDO} cp -a "${APT_SOURCES_BACKUP_DIR}/${rel_path}" "${file}"
    fi
  done < <(list_ubuntu_apt_source_files)

  rm -rf -- "${APT_SOURCES_BACKUP_DIR}"
  APT_SOURCES_BACKUP_DIR=""
}

switch_ubuntu_apt_to_official() {
  local file=""

  if ! is_ubuntu_system; then
    return 1
  fi

  echo "==> Trying official Ubuntu repositories first"
  while IFS= read -r file; do
    if [[ -f "${file}" ]]; then
      ${SUDO} sed -Ei \
        -e "s|https?://mirror-linux\\.runflare\\.com/ubuntu/?|${OFFICIAL_UBUNTU_APT_URL}|g" \
        -e "s|https?://mirror\\.arvancloud\\.ir/ubuntu/?|${OFFICIAL_UBUNTU_APT_URL}|g" \
        "${file}"
    fi
  done < <(list_ubuntu_apt_source_files)
}

switch_ubuntu_apt_mirror() {
  local mirror_url="$1"
  local file=""

  if ! is_ubuntu_system; then
    return 1
  fi

  echo "==> Switching Ubuntu APT sources to mirror: ${mirror_url}"
  while IFS= read -r file; do
    if [[ -f "${file}" ]]; then
      ${SUDO} sed -Ei \
        -e "s|https?://([[:alnum:]-]+\\.)*archive\\.ubuntu\\.com/ubuntu/?|${mirror_url}|g" \
        -e "s|https?://security\\.ubuntu\\.com/ubuntu/?|${mirror_url}|g" \
        -e "s|https?://mirror-linux\\.runflare\\.com/ubuntu/?|${mirror_url}|g" \
        -e "s|https?://mirror\\.arvancloud\\.ir/ubuntu/?|${mirror_url}|g" \
        "${file}"
    fi
  done < <(list_ubuntu_apt_source_files)
}

try_apt_install_python_packages() {
  local py_series="$1"
  if ${SUDO} apt-get install -y python3-pip python3-venv; then
    return 0
  fi

  echo "Default python3-venv package was unavailable. Trying versioned fallback."
  if ${SUDO} apt-get install -y python3-pip "python${py_series}-venv"; then
    return 0
  fi

  ${SUDO} apt-get install -y "python${py_series}-full"
}

install_python_runtime_packages() {
  local py_series
  local mirror
  local apt_sources_were_backed_up="false"
  py_series="$(${PYTHON_BIN} -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"

  if command -v apt-get >/dev/null 2>&1; then
    if is_ubuntu_system; then
      backup_ubuntu_apt_sources
      apt_sources_were_backed_up="true"
      switch_ubuntu_apt_to_official
    fi

    if ${SUDO} apt-get update && try_apt_install_python_packages "${py_series}"; then
      if [[ "${apt_sources_were_backed_up}" == "true" ]]; then
        restore_ubuntu_apt_sources
      fi
      return
    fi

    if is_ubuntu_system; then
      for mirror in "${UBUNTU_APT_MIRRORS[@]}"; do
        switch_ubuntu_apt_mirror "${mirror}"
        if ${SUDO} apt-get update && try_apt_install_python_packages "${py_series}"; then
          if [[ "${apt_sources_were_backed_up}" == "true" ]]; then
            restore_ubuntu_apt_sources
          fi
          return
        fi
      done
      if [[ "${apt_sources_were_backed_up}" == "true" ]]; then
        restore_ubuntu_apt_sources
      fi
    fi

    echo "Failed to install python runtime packages via APT."
    return 1
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
  return 1
}

ensure_python_runtime_ready() {
  if python_has_venv && python_has_pip; then
    return
  fi

  echo "==> Ensuring python venv and pip"
  if ! install_python_runtime_packages; then
    echo "Failed to prepare system python packages automatically."
    exit 1
  fi

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

pip_install_with_fallback() {
  local python_exec="$1"
  shift
  local mirror
  local pip_subcommand="${1:-}"

  if [[ -z "${pip_subcommand}" ]]; then
    return 1
  fi

  if ${SUDO} "${python_exec}" -m pip "$@"; then
    return 0
  fi

  for mirror in "${PIP_INDEX_MIRRORS[@]}"; do
    echo "Retrying pip command with mirror: ${mirror}"
    if [[ "${pip_subcommand}" == "install" ]]; then
      if ${SUDO} "${python_exec}" -m pip install --index-url "${mirror}" "${@:2}"; then
        return 0
      fi
      continue
    fi

    if ${SUDO} env PIP_INDEX_URL="${mirror}" "${python_exec}" -m pip "$@"; then
      return 0
    fi
  done

  return 1
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

if ! pip_install_with_fallback "${INSTALL_DIR}/.venv/bin/python" install --upgrade pip; then
  echo "Failed to upgrade pip using default index and fallback mirrors."
  exit 1
fi

echo "==> Installing dependencies"
if ! pip_install_with_fallback "${INSTALL_DIR}/.venv/bin/python" install pandas flask; then
  echo "Failed to install dependencies using default index and fallback mirrors."
  exit 1
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

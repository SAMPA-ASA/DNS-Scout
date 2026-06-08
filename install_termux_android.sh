#!/usr/bin/env bash

# Re-run with bash if invoked via a different shell.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="${HOME}/.${APP_NAME}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HELPERS_FILE="${SCRIPT_DIR}/termux_install_helpers.sh"
PYTHON_BIN="python"
PANEL_CONFIG_FILE="${INSTALL_DIR}/panel_config.json"
PID_FILE="${INSTALL_DIR}/panel.pid"
LOG_FILE="${INSTALL_DIR}/panel.log"
RUNNER_SCRIPT="${INSTALL_DIR}/run_panel.sh"
START_SCRIPT="${INSTALL_DIR}/start.sh"
STOP_SCRIPT="${INSTALL_DIR}/stop.sh"
STATUS_SCRIPT="${INSTALL_DIR}/status.sh"
META_FILE="${INSTALL_DIR}/.online_release"
TTY_INPUT="/dev/tty"

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

if [[ ! -f "${HELPERS_FILE}" ]]; then
  echo "Termux helper script was not found: ${HELPERS_FILE}"
  exit 1
fi

normalize_termux_shell_line_endings() {
  local file

  shopt -s nullglob
  for file in "${SCRIPT_DIR}"/*.sh; do
    sed -i 's/\r$//' "${file}" 2>/dev/null || true
  done
  shopt -u nullglob
}

normalize_termux_shell_line_endings

# shellcheck source=termux_install_helpers.sh
source "${HELPERS_FILE}"

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

  printf -v "${__result_var}" "%s" "${__value}"
}

python_has_pip() {
  command -v "${PYTHON_BIN}" >/dev/null 2>&1 && "${PYTHON_BIN}" -m pip --version >/dev/null 2>&1
}

python_has_venv() {
  if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    return 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  if "${PYTHON_BIN}" -m venv "${tmp_dir}/venv" >/dev/null 2>&1; then
    rm -rf -- "${tmp_dir}"
    return 0
  fi
  rm -rf -- "${tmp_dir}"
  return 1
}

pip_install_with_fallback() {
  local python_exec="$1"
  shift
  local mirror
  local pip_subcommand="${1:-}"

  if [[ -z "${pip_subcommand}" ]]; then
    return 1
  fi

  if "${python_exec}" -m pip "$@"; then
    return 0
  fi

  for mirror in "${PIP_INDEX_MIRRORS[@]}"; do
    echo "Retrying pip command with mirror: ${mirror}"
    if [[ "${pip_subcommand}" == "install" ]]; then
      if "${python_exec}" -m pip install --index-url "${mirror}" "${@:2}"; then
        return 0
      fi
      continue
    fi

    if env PIP_INDEX_URL="${mirror}" "${python_exec}" -m pip "$@"; then
      return 0
    fi
  done

  return 1
}

pip_install_host_with_fallback() {
  pip_install_with_fallback "${PYTHON_BIN}" "$@"
}

termux_ensure_package_list() {
  local pkg
  for pkg in "$@"; do
    if ! termux_ensure_packages "${pkg}"; then
      return 1
    fi
  done
}

python_can_import() {
  local python_exec="$1"
  local module_name="$2"

  "${python_exec}" - "${module_name}" <<'PY'
import importlib.util
import sys

module_name = sys.argv[1]
sys.exit(0 if importlib.util.find_spec(module_name) is not None else 1)
PY
}

ensure_python_runtime_ready() {
  if python_has_venv && python_has_pip; then
    return
  fi

  if ! termux_ensure_packages python; then
    echo "Failed to install Python from Termux repositories."
    exit 1
  fi

  if ! python_has_pip; then
    "${PYTHON_BIN}" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi

  if ! python_has_venv || ! python_has_pip; then
    echo "Failed to prepare Python venv/pip."
    exit 1
  fi
}

detect_python_bin() {
  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
    return
  fi
  PYTHON_BIN="python"
}

ensure_termux_pandas_ready() {
  echo "==> Preparing pandas/numpy for Termux"

  if python_can_import "${PYTHON_BIN}" pandas; then
    echo "pandas is already available in Termux Python."
    return 0
  fi

  echo "Trying native Termux/TUR packages first..."

  # tur-repo may contain scientific Python packages on some Termux setups.
  termux_ensure_packages tur-repo >/dev/null 2>&1 || true
  pkg update -y || true

  if termux_ensure_package_list python-numpy python-pandas; then
    if python_can_import "${PYTHON_BIN}" pandas; then
      echo "pandas was installed from Termux/TUR packages."
      return 0
    fi
  fi

  echo
  echo "Native python-pandas was not available or not importable."
  echo "Falling back to a Termux-compatible source build."
  echo "This may take a long time on Android, but avoids pip building cmake/ninja internally."
  echo

  if ! termux_ensure_package_list \
    build-essential \
    cmake \
    ninja \
    libopenblas \
    libandroid-execinfo \
    patchelf \
    binutils-is-llvm; then
    echo "Failed to install native build dependencies for pandas/numpy."
    exit 1
  fi

  if ! pip_install_host_with_fallback install -U \
    setuptools \
    wheel \
    packaging \
    pyproject-metadata \
    cython \
    meson-python \
    versioneer \
    tempita; then
    echo "Failed to install Python build helpers for pandas/numpy."
    exit 1
  fi

  local py_short
  py_short="$("${PYTHON_BIN}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

  if ! python_can_import "${PYTHON_BIN}" numpy; then
    echo "==> Building/installing numpy for Termux Python"
    if ! env MATHLIB=m LDFLAGS="-lpython${py_short}" \
      "${PYTHON_BIN}" -m pip install -U --no-build-isolation --no-cache-dir numpy; then
      echo "Failed to build/install numpy."
      exit 1
    fi
  fi

  echo "==> Building/installing pandas for Termux Python"
  if ! env LDFLAGS="-lpython${py_short}" \
    "${PYTHON_BIN}" -m pip install -U --no-build-isolation --no-cache-dir pandas; then
    echo "Failed to build/install pandas."
    exit 1
  fi

  if ! python_can_import "${PYTHON_BIN}" pandas; then
    echo "pandas installation finished but pandas is still not importable."
    exit 1
  fi

  echo "pandas is ready."
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

create_runtime_scripts() {
  cat >"${RUNNER_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${INSTALL_DIR}/.venv/bin/python" "${INSTALL_DIR}/panel_app.py" --config "${PANEL_CONFIG_FILE}"
EOF
  chmod +x "${RUNNER_SCRIPT}"

  cat >"${START_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="${PID_FILE}"
LOG_FILE="${LOG_FILE}"
RUNNER="${RUNNER_SCRIPT}"

if [[ -f "\${PID_FILE}" ]]; then
  old_pid="\$(cat "\${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "\${old_pid}" ]] && kill -0 "\${old_pid}" >/dev/null 2>&1; then
    echo "DNS Scout is already running (PID: \${old_pid})."
    exit 0
  fi
  rm -f "\${PID_FILE}"
fi

nohup "\${RUNNER}" >>"\${LOG_FILE}" 2>&1 &
new_pid="\$!"
echo "\${new_pid}" >"\${PID_FILE}"
sleep 1
if kill -0 "\${new_pid}" >/dev/null 2>&1; then
  echo "DNS Scout started (PID: \${new_pid})."
  exit 0
fi

echo "Failed to start DNS Scout. Check log: \${LOG_FILE}"
exit 1
EOF
  chmod +x "${START_SCRIPT}"

  cat >"${STOP_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="${PID_FILE}"

if [[ ! -f "\${PID_FILE}" ]]; then
  echo "DNS Scout is not running."
  exit 0
fi

pid="\$(cat "\${PID_FILE}" 2>/dev/null || true)"
if [[ -z "\${pid}" ]]; then
  rm -f "\${PID_FILE}"
  echo "Stale PID file removed."
  exit 0
fi

if ! kill -0 "\${pid}" >/dev/null 2>&1; then
  rm -f "\${PID_FILE}"
  echo "Process was not running. Stale PID file removed."
  exit 0
fi

kill "\${pid}" >/dev/null 2>&1 || true
for _ in {1..25}; do
  if ! kill -0 "\${pid}" >/dev/null 2>&1; then
    rm -f "\${PID_FILE}"
    echo "DNS Scout stopped."
    exit 0
  fi
  sleep 0.2
done

kill -9 "\${pid}" >/dev/null 2>&1 || true
rm -f "\${PID_FILE}"
echo "DNS Scout force-stopped."
EOF
  chmod +x "${STOP_SCRIPT}"

  cat >"${STATUS_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="${PID_FILE}"
LOG_FILE="${LOG_FILE}"

if [[ -f "\${PID_FILE}" ]]; then
  pid="\$(cat "\${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "\${pid}" ]] && kill -0 "\${pid}" >/dev/null 2>&1; then
    echo "DNS Scout is running (PID: \${pid})."
    echo "Log file: \${LOG_FILE}"
    exit 0
  fi
fi

echo "DNS Scout is not running."
echo "Log file: \${LOG_FILE}"
exit 1
EOF
  chmod +x "${STATUS_SCRIPT}"
}

create_termux_commands() {
  local bin_dir=""

  if [[ -n "${PREFIX:-}" && -d "${PREFIX}/bin" && -w "${PREFIX}/bin" ]]; then
    bin_dir="${PREFIX}/bin"
  elif [[ -w "${HOME}" ]]; then
    bin_dir="${HOME}/.local/bin"
    mkdir -p "${bin_dir}"
  fi

  if [[ -z "${bin_dir}" ]]; then
    echo "Skipping command symlinks: writable bin directory not found."
    return 0
  fi

  ln -sf "${START_SCRIPT}" "${bin_dir}/dns-scout-start"
  ln -sf "${STOP_SCRIPT}" "${bin_dir}/dns-scout-stop"
  ln -sf "${STATUS_SCRIPT}" "${bin_dir}/dns-scout-status"

  echo "==> Commands installed:"
  echo "  dns-scout-start"
  echo "  dns-scout-stop"
  echo "  dns-scout-status"
}

detect_python_bin

echo "==> Script directory: ${SCRIPT_DIR}"
if [[ ! -f "${SCRIPT_DIR}/main.py" || ! -f "${SCRIPT_DIR}/panel_app.py" ]]; then
  echo "Required project files were not found next to install_termux_android.sh."
  exit 1
fi

if [[ "${PREFIX:-}" != *"com.termux"* && ! -x "/data/data/com.termux/files/usr/bin/bash" ]]; then
  echo "This installer is intended for Termux on Android."
  exit 1
fi

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  if ! termux_ensure_packages python; then
    echo "Failed to install Python from Termux repositories."
    exit 1
  fi
  detect_python_bin
fi

ensure_python_runtime_ready

PY_MAJOR="$(${PYTHON_BIN} -c 'import sys; print(sys.version_info[0])')"
PY_MINOR="$(${PYTHON_BIN} -c 'import sys; print(sys.version_info[1])')"
if [[ "${PY_MAJOR}" -lt 3 || "${PY_MINOR}" -lt 10 ]]; then
  echo "Python 3.10+ is required."
  exit 1
fi

ensure_termux_pandas_ready

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
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_DIR:?}"/*
cp -a "${SCRIPT_DIR}/." "${INSTALL_DIR}/"

echo "==> Creating virtual environment"
"${PYTHON_BIN}" -m venv --system-site-packages "${INSTALL_DIR}/.venv"

if ! pip_install_with_fallback "${INSTALL_DIR}/.venv/bin/python" install --upgrade pip; then
  echo "Failed to upgrade pip using default index and fallback mirrors."
  exit 1
fi

echo "==> Installing dependencies"
if ! pip_install_with_fallback "${INSTALL_DIR}/.venv/bin/python" install flask python-dateutil; then
  echo "Failed to install Flask and pandas runtime dependencies using default index and fallback mirrors."
  exit 1
fi

echo "==> Verifying Python dependencies"
if ! "${INSTALL_DIR}/.venv/bin/python" - <<'PY'
import flask
import pandas
import dateutil

try:
    flask_version = flask.__version__
except AttributeError:
    flask_version = "unknown"

print("Flask:", flask_version)
print("python-dateutil:", dateutil.__version__)
print("pandas:", pandas.__version__)
PY
then
  echo "Dependency verification failed. Flask, python-dateutil, or pandas is not importable in the virtual environment."
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

printf '%s\n' "${PANEL_JSON}" >"${PANEL_CONFIG_FILE}"
unset PANEL_PASSWORD PANEL_PASSWORD_CONFIRM

create_runtime_scripts
create_termux_commands

echo "==> Starting DNS Scout"
"${START_SCRIPT}"

HOST_IP="127.0.0.1"
if command -v ifconfig >/dev/null 2>&1; then
  HOST_IP="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}' || true)"
fi
if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="127.0.0.1"
fi

echo
echo "Installation completed."
echo "Open the panel and login to start scanning:"
echo "  http://${HOST_IP}:${SELECTED_PORT}"
echo
echo "Control commands:"
echo "  dns-scout-start"
echo "  dns-scout-stop"
echo "  dns-scout-status"
echo
echo "View logs:"
echo "  tail -f ${LOG_FILE}"
echo
echo "To change panel username/password later via CLI:"
echo "  ${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/manage_panel_auth.py --config ${PANEL_CONFIG_FILE}"
echo
echo "Metadata file (for online update): ${META_FILE}"

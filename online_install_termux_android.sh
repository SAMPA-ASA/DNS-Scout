#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="${HOME}/.${APP_NAME}"
DEFAULT_REPO_URL="https://github.com/sampa-asa/dns-scout.git"
REPO_URL="${REPO_URL:-${DEFAULT_REPO_URL}}"
META_FILE="${INSTALL_DIR}/.online_release"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HELPERS_FILE="${SCRIPT_DIR}/termux_install_helpers.sh"

# shellcheck source=git_mirror_helpers.sh
source "${SCRIPT_DIR}/git_mirror_helpers.sh"

normalize_termux_shell_line_endings() {
  local file

  shopt -s nullglob
  for file in "${SCRIPT_DIR}"/*.sh; do
    sed -i 's/\r$//' "${file}" 2>/dev/null || true
  done
  shopt -u nullglob
}

normalize_termux_shell_line_endings

if [[ -f "${HELPERS_FILE}" ]]; then
  # shellcheck source=termux_install_helpers.sh
  source "${HELPERS_FILE}"
fi

if ! command -v git >/dev/null 2>&1; then
  if command -v termux_ensure_packages >/dev/null 2>&1; then
    if ! termux_ensure_packages git; then
      echo "Failed to install git from Termux repositories."
      exit 1
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    echo "==> Installing git"
    apt-get update
    apt-get install -y git
  elif command -v pkg >/dev/null 2>&1; then
    echo "==> Installing git"
    pkg update -y
    pkg install -y git
  else
    echo "git is required but not installed."
    exit 1
  fi
fi

BRANCH="${REPO_BRANCH:-$(resolve_default_branch_with_fallback "${REPO_URL}")}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT

echo "==> Repository: ${REPO_URL}"
echo "==> Branch: ${BRANCH}"
echo "==> Cloning latest source"
clone_repo_with_fallback "${REPO_URL}" "${BRANCH}" "${TMP_DIR}/repo"

pushd "${TMP_DIR}/repo" >/dev/null
echo "==> Running Termux installer"
if [[ -r /dev/tty ]]; then
  bash ./install_termux_android.sh </dev/tty
else
  bash ./install_termux_android.sh
fi
REMOTE_COMMIT="$(git rev-parse HEAD)"
popd >/dev/null

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "${INSTALL_DIR}"
tee "${META_FILE}" >/dev/null <<EOF
REPO_URL='${REPO_URL}'
BRANCH='${BRANCH}'
COMMIT='${REMOTE_COMMIT}'
UPDATED_AT='${TIMESTAMP}'
EOF

echo
echo "Online installation completed."
echo "Installed commit: ${REMOTE_COMMIT}"

#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="${HOME}/.${APP_NAME}"
META_FILE="${INSTALL_DIR}/.online_release"
DEFAULT_REPO_URL="https://github.com/sampa-asa/dns-scout.git"
REPO_URL="${REPO_URL:-${DEFAULT_REPO_URL}}"
HELPERS_FILE="${INSTALL_DIR}/termux_install_helpers.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=git_mirror_helpers.sh
source "${SCRIPT_DIR}/git_mirror_helpers.sh"

normalize_termux_shell_line_endings() {
  local file

  shopt -s nullglob
  for file in "${INSTALL_DIR}"/*.sh; do
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
  else
    echo "git is required but not installed."
    exit 1
  fi
fi

if [[ ! -d "${INSTALL_DIR}" ]]; then
  echo "Install directory not found: ${INSTALL_DIR}"
  echo "Run install_termux.sh or online_install_termux.sh first."
  exit 1
fi

KNOWN_REPO_URL=""
KNOWN_BRANCH=""
KNOWN_COMMIT=""
if [[ -f "${META_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${META_FILE}" || true
  KNOWN_REPO_URL="${REPO_URL:-}"
  KNOWN_BRANCH="${BRANCH:-}"
  KNOWN_COMMIT="${COMMIT:-}"
fi

if [[ -n "${KNOWN_REPO_URL}" ]]; then
  REPO_URL="${KNOWN_REPO_URL}"
fi
BRANCH="${REPO_BRANCH:-${KNOWN_BRANCH:-$(resolve_default_branch_with_fallback "${REPO_URL}")}}"

REMOTE_COMMIT="$(resolve_remote_commit_with_fallback "${REPO_URL}" "${BRANCH}")"
if [[ -z "${REMOTE_COMMIT}" ]]; then
  echo "Unable to resolve remote commit for ${REPO_URL} (${BRANCH})."
  exit 1
fi

LOCAL_COMMIT="${KNOWN_COMMIT}"
if [[ -z "${LOCAL_COMMIT}" && -d "${INSTALL_DIR}/.git" ]]; then
  LOCAL_COMMIT="$(git -C "${INSTALL_DIR}" rev-parse HEAD 2>/dev/null || true)"
fi

if [[ -n "${LOCAL_COMMIT}" && "${LOCAL_COMMIT}" == "${REMOTE_COMMIT}" ]]; then
  echo "Already up to date. Commit: ${LOCAL_COMMIT}"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT

echo "==> Repository: ${REPO_URL}"
echo "==> Branch: ${BRANCH}"
echo "==> Current commit: ${LOCAL_COMMIT:-unknown}"
echo "==> Remote commit: ${REMOTE_COMMIT}"
echo "==> Downloading update"
clone_repo_with_fallback "${REPO_URL}" "${BRANCH}" "${TMP_DIR}/repo"

pushd "${TMP_DIR}/repo" >/dev/null
echo "==> Running Termux updater"
bash ./update_termux.sh
popd >/dev/null

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tee "${META_FILE}" >/dev/null <<EOF
REPO_URL='${REPO_URL}'
BRANCH='${BRANCH}'
COMMIT='${REMOTE_COMMIT}'
UPDATED_AT='${TIMESTAMP}'
EOF

echo
echo "Update completed successfully."
echo "Installed commit: ${REMOTE_COMMIT}"

#!/usr/bin/env bash

# Re-run with bash if invoked via a different shell (e.g., `sh install_online.sh`).
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="/opt/${APP_NAME}"
DEFAULT_REPO_URL="https://github.com/sampa-asa/dns-scout.git"
REPO_URL="${REPO_URL:-${DEFAULT_REPO_URL}}"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required but not installed."
  exit 1
fi

resolve_default_branch() {
  local repo_url="$1"
  local branch
  branch="$(git ls-remote --symref "${repo_url}" HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')"
  if [[ -z "${branch}" ]]; then
    branch="main"
  fi
  printf '%s\n' "${branch}"
}

BRANCH="${REPO_BRANCH:-$(resolve_default_branch "${REPO_URL}")}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT

echo "==> Repository: ${REPO_URL}"
echo "==> Branch: ${BRANCH}"
echo "==> Cloning latest source"
git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${TMP_DIR}/repo"

pushd "${TMP_DIR}/repo" >/dev/null
echo "==> Running project installer"
if [[ -r /dev/tty ]]; then
  bash ./install.sh </dev/tty
else
  bash ./install.sh
fi
REMOTE_COMMIT="$(git rev-parse HEAD)"
popd >/dev/null

META_FILE="${INSTALL_DIR}/.online_release"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "==> Saving release metadata"
${SUDO} tee "${META_FILE}" >/dev/null <<EOF
REPO_URL='${REPO_URL}'
BRANCH='${BRANCH}'
COMMIT='${REMOTE_COMMIT}'
UPDATED_AT='${TIMESTAMP}'
EOF

echo
echo "Online installation completed."
echo "Installed commit: ${REMOTE_COMMIT}"

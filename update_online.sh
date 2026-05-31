#!/usr/bin/env bash
set -euo pipefail

APP_NAME="dns-scout"
INSTALL_DIR="/opt/${APP_NAME}"
META_FILE="${INSTALL_DIR}/.online_release"
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

if [[ ! -d "${INSTALL_DIR}" ]]; then
  echo "Install directory not found: ${INSTALL_DIR}"
  echo "Run install.sh or install_online.sh first."
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
BRANCH="${REPO_BRANCH:-${KNOWN_BRANCH:-$(resolve_default_branch "${REPO_URL}")}}"

REMOTE_COMMIT="$(git ls-remote "${REPO_URL}" "refs/heads/${BRANCH}" | awk '{print $1; exit}')"
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
git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${TMP_DIR}/repo"

pushd "${TMP_DIR}/repo" >/dev/null
echo "==> Running project updater"
bash ./update.sh
popd >/dev/null

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
${SUDO} tee "${META_FILE}" >/dev/null <<EOF
REPO_URL='${REPO_URL}'
BRANCH='${BRANCH}'
COMMIT='${REMOTE_COMMIT}'
UPDATED_AT='${TIMESTAMP}'
EOF

echo
echo "Update completed successfully."
echo "Installed commit: ${REMOTE_COMMIT}"

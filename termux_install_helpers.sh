#!/usr/bin/env bash

TERMUX_MAIN_PRIMARY_REPOSITORIES=(
  "${TERMUX_MAIN_REPOSITORY:-}"
  "https://packages.termux.dev/apt/termux-main"
  "https://packages-cf.termux.dev/apt/termux-main"
  "https://termux-main.pages.dev"
)

TERMUX_MAIN_FALLBACK_REPOSITORIES=(
  "https://grimler.se/termux/termux-main"
  "https://mirror.nevacloud.com/applications/termux/termux-main"
  "https://linux.domainesia.com/applications/termux/termux-main"
  "https://mirrors.ravidwivedi.in/termux/termux-main"
  "https://mirror.vern.cc/termux/termux-main"
  "https://mirror.csclub.uwaterloo.ca/termux/termux-main"
  "https://mirror.fcix.net/termux/termux-main"
  "https://ftp.fau.de/termux/termux-main"
  "https://mirrors.ustc.edu.cn/termux/termux-main"
  "https://mirror.sjtu.edu.cn/termux/termux-main"
  "https://mirrors.aliyun.com/termux/termux-main"
)

TERMUX_LEGACY_BOOTSTRAP_REPOSITORIES=(
  "https://termux.net"
)

TERMUX_APT_MISSING_PUBKEY=0

termux_normalize_repository_url() {
  local repo_url="$1"
  repo_url="${repo_url%/}"
  printf '%s\n' "${repo_url}"
}

termux_main_repository_pattern() {
  printf '%s\n' 'termux-main|packages\.termux\.dev/apt|packages-cf\.termux\.dev/apt|termux-main\.pages\.dev|termux\.net'
}

termux_list_all_main_repositories() {
  local repo_url

  for repo_url in "${TERMUX_MAIN_PRIMARY_REPOSITORIES[@]}" "${TERMUX_MAIN_FALLBACK_REPOSITORIES[@]}"; do
    [[ -n "${repo_url}" ]] && printf '%s\n' "${repo_url}"
  done
}

termux_strip_existing_main_repositories() {
  local file="$1"
  local tmp_file
  local repo_pattern

  [[ -f "${file}" ]] || return 0

  repo_pattern="$(termux_main_repository_pattern)"
  tmp_file="$(mktemp)"
  awk -v repo_pattern="${repo_pattern}" '
    $0 ~ /^[[:space:]]*deb[[:space:]]/ && $0 ~ repo_pattern { next }
    { print }
  ' "${file}" >"${tmp_file}"
  mv "${tmp_file}" "${file}"
}

termux_set_main_repository() {
  local repo_url
  repo_url="$(termux_normalize_repository_url "$1")"
  local apt_dir="${PREFIX:-}/etc/apt"
  local sources_list="${apt_dir}/sources.list"
  local sources_list_dir="${apt_dir}/sources.list.d"
  local target_line="deb ${repo_url} stable main"
  local file

  if [[ -z "${PREFIX:-}" || ! -d "${apt_dir}" ]]; then
    return 1
  fi

  mkdir -p "${sources_list_dir}"
  printf '%s\n' "${target_line}" >"${sources_list}"

  shopt -s nullglob
  for file in "${sources_list_dir}"/*.list; do
    termux_strip_existing_main_repositories "${file}"
  done
  shopt -u nullglob
}

termux_apt_update() {
  local output_file
  output_file="$(mktemp)"
  TERMUX_APT_MISSING_PUBKEY=0

  if apt-get update 2>&1 | tee "${output_file}"; then
    if grep -qE 'NO_PUBKEY [0-9A-F]+' "${output_file}"; then
      TERMUX_APT_MISSING_PUBKEY=1
      rm -f "${output_file}"
      return 1
    fi
    if grep -qE 'Failed to fetch|Unable to connect|Could not wait for server fd|Some index files failed to download' "${output_file}"; then
      rm -f "${output_file}"
      return 1
    fi
    rm -f "${output_file}"
    return 0
  fi

  if grep -qE 'NO_PUBKEY [0-9A-F]+' "${output_file}"; then
    TERMUX_APT_MISSING_PUBKEY=1
  fi

  rm -f "${output_file}"
  return 1
}

termux_package_installed() {
  local package="$1"
  dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q 'ok installed'
}

termux_packages_available() {
  local package

  for package in "$@"; do
    if ! apt-cache show "${package}" >/dev/null 2>&1; then
      return 1
    fi
  done
}

termux_refresh_keyring() {
  local repo_url
  local normalized_repo_url

  if ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi

  if apt-get install -y --reinstall ca-certificates termux-keyring; then
    return 0
  fi

  for repo_url in "${TERMUX_LEGACY_BOOTSTRAP_REPOSITORIES[@]}"; do
    [[ -z "${repo_url}" ]] && continue
    normalized_repo_url="$(termux_normalize_repository_url "${repo_url}")"
    echo "    Missing Termux repository key detected. Bootstrapping keyring from: ${normalized_repo_url}"

    if ! termux_set_main_repository "${normalized_repo_url}"; then
      continue
    fi

    if termux_apt_update && apt-get install -y --reinstall ca-certificates termux-keyring; then
      return 0
    fi
  done

  return 1
}

termux_install_packages_with_repo_fallback() {
  local -a packages=("$@")
  local repo_url
  local normalized_repo_url
  local attempt=1
  local total=0
  local keyring_refreshed=0

  if ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi

  while IFS= read -r repo_url; do
    [[ -n "${repo_url}" ]] && total=$((total + 1))
  done < <(termux_list_all_main_repositories)

  while IFS= read -r repo_url; do
    [[ -z "${repo_url}" ]] && continue
    normalized_repo_url="$(termux_normalize_repository_url "${repo_url}")"
    echo "==> Trying Termux main repository (${attempt}/${total}): ${normalized_repo_url}"

    if ! termux_set_main_repository "${normalized_repo_url}"; then
      echo "    Unable to update the Termux repository configuration."
      attempt=$((attempt + 1))
      continue
    fi

    if termux_apt_update && termux_packages_available "${packages[@]}" && apt-get install -y "${packages[@]}"; then
      return 0
    fi

    if [[ "${TERMUX_APT_MISSING_PUBKEY}" -eq 1 && "${keyring_refreshed}" -eq 0 ]]; then
      if termux_refresh_keyring; then
        keyring_refreshed=1
        echo "    Retrying the same repository after refreshing termux-keyring."
        termux_set_main_repository "${normalized_repo_url}" || true
        if termux_apt_update && termux_packages_available "${packages[@]}" && apt-get install -y "${packages[@]}"; then
          return 0
        fi
      fi
    fi

    echo "    Repository attempt failed. Trying another mirror."
    attempt=$((attempt + 1))
  done < <(termux_list_all_main_repositories)

  return 1
}

termux_ensure_packages() {
  local -a missing_packages=()
  local package

  for package in "$@"; do
    if ! termux_package_installed "${package}"; then
      missing_packages+=("${package}")
    fi
  done

  if [[ "${#missing_packages[@]}" -eq 0 ]]; then
    return 0
  fi

  echo "==> Installing required Termux packages: ${missing_packages[*]}"
  termux_install_packages_with_repo_fallback "${missing_packages[@]}"
}

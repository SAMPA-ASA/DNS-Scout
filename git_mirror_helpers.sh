#!/usr/bin/env bash

GITHUB_GIT_MIRROR_BASES=(
  "https://scorpian.ir/repos"
)

git_clone_candidates() {
  local repo_url="$1"
  local github_owner=""
  local github_repo=""
  local mirror_base
  local candidates=("${repo_url}")

  if [[ "${repo_url}" =~ ^https?://github\.com/([^/]+)/([^/]+?)(\.git)?$ ]]; then
    github_owner="${BASH_REMATCH[1]}"
    github_repo="${BASH_REMATCH[2]}"
  elif [[ "${repo_url}" =~ ^git@github\.com:([^/]+)/([^/]+?)(\.git)?$ ]]; then
    github_owner="${BASH_REMATCH[1]}"
    github_repo="${BASH_REMATCH[2]}"
  fi

  if [[ -n "${github_owner}" && -n "${github_repo}" ]]; then
    for mirror_base in "${GITHUB_GIT_MIRROR_BASES[@]}"; do
      candidates+=("${mirror_base}/${github_owner}/${github_repo}.git")
    done
  fi

  printf '%s\n' "${candidates[@]}"
}

resolve_default_branch_with_fallback() {
  local repo_url="$1"
  local candidate
  local branch

  while IFS= read -r candidate; do
    branch="$(git ls-remote --symref "${candidate}" HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')"
    if [[ -n "${branch}" ]]; then
      printf '%s\n' "${branch}"
      return 0
    fi
  done < <(git_clone_candidates "${repo_url}")

  printf '%s\n' "main"
}

resolve_remote_commit_with_fallback() {
  local repo_url="$1"
  local branch="$2"
  local candidate
  local remote_commit

  while IFS= read -r candidate; do
    remote_commit="$(git ls-remote "${candidate}" "refs/heads/${branch}" | awk '{print $1; exit}')"
    if [[ -n "${remote_commit}" ]]; then
      printf '%s\n' "${remote_commit}"
      return 0
    fi
  done < <(git_clone_candidates "${repo_url}")

  return 1
}

clone_repo_with_fallback() {
  local repo_url="$1"
  local branch="$2"
  local destination="$3"
  local candidate

  while IFS= read -r candidate; do
    echo "==> Trying clone source: ${candidate}"
    if git clone --depth 1 --branch "${branch}" "${candidate}" "${destination}"; then
      if [[ "${candidate}" != "${repo_url}" ]]; then
        echo "==> Cloned from fallback mirror: ${candidate}"
      fi
      return 0
    fi
  done < <(git_clone_candidates "${repo_url}")

  return 1
}

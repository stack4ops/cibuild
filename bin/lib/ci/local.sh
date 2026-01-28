#!/bin/sh
# Package cibuild/ci/local

# Local Pipeline Adapter

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_CI_LOADED-}" ] && return
# bool
_CIBUILD_CI_LOADED=1

# bool
_CIBUILD_CI_CANCELED=0

# string
_CIBUILD_CI_COMMIT=""

# string
_CIBUILD_CI_REF=""

cibuild_ci_type() { printf '%s\n' "local"; }

cibuild__get_project_path() {

  local upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
  local remote=''

  if [ -n "$upstream" ]; then
    remote=${upstream%%/*}
    url=$(git remote get-url "$remote" 2>/dev/null || true)
    if [ -n "$url" ]; then
      printf '%s\n' "$url" \
      | sed -r 's#.+://[^/]+/##; s#.+@[^:]+:##; s#\.git$##'
      return 0
    fi
  fi

  # any remote
  remote=$(git remote | head -n1)
  if [ -n "$remote" ]; then
    git remote get-url "$remote" \
    | sed -r 's#.+://[^/]+/##; s#.+@[^:]+:##; s#\.git$##'
    return 0
  fi

  printf '%s\n' "UNKNOWN_PROJECT_PATH" >&2
  return 1
}


cibuild_ci_process_tag() {
  local tag="$1" \
        date=$(date +%F) \
        datetime=$(date +%F_%H-%M-%S)

  sed_escape() {
    printf '%s' "$1" | sed 's/[&\/]/\\&/g'
  }
  
  printf '%s' "$tag" | sed \
    -e "s/__DATE__/$(sed_escape "$date")/g" \
    -e "s/__DATETIME__/$(sed_escape "$datetime")/g" \
    -e "s/__COMMIT__/$(sed_escape "$_CIBUILD_CI_COMMIT")/g" \
    -e "s/__REF__/$(sed_escape "$_CIBUILD_CI_REF")/g"
}

cibuild_ci_token() { return ""; }

cibuild__ci_cancel_requirements() { return 0; }

cibuild_ci_cancel() {
  cibuild__ci_cancel_requirements || return $?
  _CIBUILD_CI_CANCELED=1
}

cibuild_ci_canceled() { printf '%s\n' $_CIBUILD_CI_CANCELED; }

cibuild_ci_check_allowed() { return 1; }

cibuild_ci_commit() { printf '%s\n' $_CIBUILD_CI_COMMIT; }

cibuild_ci_ref() { printf '%s\n' $_CIBUILD_CI_REF; }

# native registry: in local adapter ci = local

cibuild_ci_registry() {
  printf '%s\n' "${CIBUILD_CI_REGISTRY:-localregistry.example.com:5000}"
}

cibuild_ci_registry_auth() {
  printf '%s\n' "${CIBUILD_CI_REGISTRY_AUTH:-1}"
}

cibuild_ci_registry_user() {
  if [ "$(cibuild_ci_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_CI_REGISTRY_USER:-admin}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_registry_pass() {
  if [ "$(cibuild_ci_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_CI_REGISTRY_PASS:-password}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_image_path() {
  printf '%s\n' "${CIBUILD_CI_IMAGE_PATH:-$(cibuild__get_project_path)}"
}

cibuild_ci_image() {
  printf '%s\n' "$(cibuild_ci_registry)/$(cibuild_ci_image_path)"
}

# base image data

cibuild_ci_base_registry_auth() {
  printf '%s\n' "${CIBUILD_BASE_REGISTRY_AUTH:-0}"
}

cibuild_ci_base_registry_user() {
  if [ "$(cibuild_ci_base_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_BASE_REGISTRY_USER:-$(cibuild_ci_registry_user)}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_base_registry_pass() {
  if [ "$(cibuild_ci_base_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_BASE_REGISTRY_PASS:-$(cibuild_ci_registry_password)}"
  else
    printf '%s\n' ""
  fi
}

# base registry, image path and tag: are processed from Dockerfile

# target image data

cibuild_ci_target_registry() {
  printf '%s\n' "${CIBUILD_TARGET_REGISTRY:-$(cibuild_ci_registry)}"
}

cibuild_ci_target_registry_auth() {
  printf '%s\n' "${CIBUILD_TARGET_REGISTRY_AUTH:-1}"
}

cibuild_ci_target_registry_user() {
  if [ "$(cibuild_ci_target_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_TARGET_REGISTRY_USER:-$(cibuild_ci_registry_user)}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_target_registry_pass() {
  if [ "$(cibuild_ci_target_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_TARGET_REGISTRY_PASS:-$(cibuild_ci_registry_pass)}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_target_image_path() {
  printf '%s\n' "${CIBUILD_TARGET_IMAGE_PATH:-$(cibuild__get_project_path)}"
}

cibuild_ci_target_tag() {
  printf '%s\n' $(cibuild_ci_process_tag "${CIBUILD_TARGET_TAG:-$(cibuild_core_base_tag)}")
}

cibuild_ci_target_image() {
  printf '%s\n' "$(cibuild_ci_target_registry)/$(cibuild_ci_target_image_path)"
}

cibuild_ci_target_image_full() {
  printf '%s\n' "$(cibuild_ci_target_registry)/$(cibuild_ci_target_image_path):$(cibuild_ci_target_tag)"
}

cibuild__ci_init() {

  cibuild_log_info "init ci: $(cibuild_ci_type)"

  if _CIBUILD_CI_COMMIT="$(git rev-parse HEAD 2>/dev/null)"; then
    :
  else
    _CIBUILD_CI_COMMIT=""
  fi

  if _CIBUILD_CI_REF="$(git branch --show-current 2>/dev/null)"; then
    :
  else
    _CIBUILD_CI_REF=""
  fi

  if [ -z "${_CIBUILD_CI_COMMIT:-}" ]; then
    cibuild_log_err "missing git commit, is this a git repo?"
    exit 1
  fi

  if [ -z "${_CIBUILD_CI_REF:-}" ]; then
    cibuild_log_err "missing git branch, is this a git repo?"
    exit 1
  fi

}

cibuild__ci_init

#!/bin/sh
# Package cibuild/ci/gitlab

# GitLab Pipeline Adapter

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

cibuild_ci_type() { printf '%s\n' "gitlab"; }

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

cibuild_ci_token() {
  printf '%s\n' "${CIBUILD_CI_TOKEN:-}"
}

cibuild__ci_cancel_requirements() {
  [ -n "$(cibuild_ci_token)" ] || return 2
  [ -n "${CI_API_V4_URL:-}" ] || return 3
  [ -n "${CI_PROJECT_ID:-}" ] || return 4
  [ -n "${CI_PIPELINE_ID:-}" ] || return 5
}

# cibuild_ci_cancel() {
#   cibuild__ci_cancel_requirements || return $?
#   local cancel_url="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}/cancel"
#   curl -sS -f -X POST \
#     -H "$(cibuild_ci_token_user): $(cibuild_ci_token)" \
#     "$cancel_url" \
#     >/dev/null || return 10
#   _CIBUILD_CI_CANCELED=1
# }

cibuild_ci_cancel() {
  cibuild__ci_cancel_requirements || return $?
  local cancel_url="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}/cancel"
  curl -sS -f -X POST \
    -H "Authorization: Bearer $(cibuild_ci_token)" \
    "$cancel_url" \
    >/dev/null || return 10
  _CIBUILD_CI_CANCELED=1
}

cibuild_ci_canceled() { printf '%s\n' $_CIBUILD_CI_CANCELED; }

cibuild_ci_allowed() {
  [ "${CI_PIPELINE_SOURCE:-}" = "schedule" ] || [ "${CI_PIPELINE_SOURCE:-}" = "web" ]
}

cibuild_ci_commit() { printf '%s\n' $_CIBUILD_CI_COMMIT; }

cibuild_ci_ref() { printf '%s\n' $_CIBUILD_CI_REF; }

# native registry in gitlab

cibuild_ci_registry() {
  printf '%s\n' "${CIBUILD_CI_REGISTRY:-$CI_REGISTRY}"
}

cibuild_ci_registry_auth() {
  printf '%s\n' "${CIBUILD_CI_REGISTRY_AUTH:-1}"
}

cibuild_ci_registry_user() {
  if [ "$(cibuild_ci_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_CI_REGISTRY_USER:-$CI_REGISTRY_USER}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_registry_pass() {
  if [ "$(cibuild_ci_registry_auth)" = "1" ]; then
    #printf '%s\n' "${CIBUILD_CI_REGISTRY_PASS:-$CI_REGISTRY_PASSWORD}"
    printf '%s\n' "${CIBUILD_CI_REGISTRY_PASS:-$(cibuild_ci_token)}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_image_path() {
  printf '%s\n' "${CIBUILD_CI_IMAGE_PATH:-$CI_PROJECT_PATH}"
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
  printf '%s\n' "${CIBUILD_TARGET_IMAGE_PATH:-$CI_PROJECT_PATH}"
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

  _CIBUILD_CI_COMMIT="${CI_COMMIT_SHA:-}"

  # target ref: normal branch or MR target
  _CIBUILD_CI_REF="${CI_COMMIT_REF_NAME:-$CI_MERGE_REQUEST_TARGET_BRANCH_NAME}"
}

cibuild__ci_init

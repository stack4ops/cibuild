#!/bin/sh
# Package cibuild/ci/github

# GitHub Actions Adapter

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

# fixing values for repeated tagging
_CIBUILD_DATE=""
_CIBUILD_DATE_TIME=""

cibuild_ci_type() { printf '%s\n' "github"; }

cibuild_ci_process_tag() {
  local tag="$1"

  sed_escape() {
    printf '%s' "$1" | sed 's/[&\/]/\\&/g'
  }
  
  printf '%s' "$tag" | sed \
    -e "s/__DATE__/$(sed_escape "$_CIBUILD_DATE")/g" \
    -e "s/__DATETIME__/$(sed_escape "$_CIBUILD_DATE_TIME")/g" \
    -e "s/__COMMIT__/$(sed_escape "$_CIBUILD_CI_COMMIT")/g" \
    -e "s/__REF__/$(sed_escape "$_CIBUILD_CI_REF")/g"
}

cibuild_ci_token() {
  printf '%s\n' "${CIBUILD_CI_TOKEN:-$GITHUB_TOKEN}"
}

cibuild__ci_cancel_requirements() {
  [ -n "$(cibuild_ci_token)" ] || return 2
  [ -n "${GITHUB_RUN_ID:-}" ] || return 3
  [ -n "${GITHUB_REPOSITORY:-}" ] || return 4
}

cibuild_ci_cancel() {

  cibuild__ci_cancel_requirements || return $?

  local owner_repo="$GITHUB_REPOSITORY"
  local run_id="$GITHUB_RUN_ID"
  local api_url="https://api.github.com/repos/$owner_repo/actions/runs/$run_id/cancel"

  curl -sS -f -X POST \
    -H "Authorization: Bearer $(cibuild_ci_token)" \
    -H "Accept: application/vnd.github.v3+json" \
    "$api_url" >/dev/null || return 4
  _CIBUILD_CI_CANCELED=1
}

cibuild_ci_canceled() { printf '%s\n' $_CIBUILD_CI_CANCELED; }

cibuild_ci_check_allowed() {
  [ "${GITHUB_EVENT_NAME:-}" = "schedule" ] || [ "${GITHUB_EVENT_NAME:-}" = "workflow_dispatch" ]
}

cibuild_ci_commit() { printf '%s\n' $_CIBUILD_CI_COMMIT; }

cibuild_ci_ref() { printf '%s\n' $_CIBUILD_CI_REF; }

# native registry in gitlab

cibuild_ci_registry() {
  printf '%s\n' "${CIBUILD_CI_REGISTRY:-ghcr.io}"
}

cibuild_ci_registry_auth() {
  printf '%s\n' "${CIBUILD_CI_REGISTRY_AUTH:-1}"
}

cibuild_ci_registry_user() {
  if [ "$(cibuild_ci_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_CI_REGISTRY_USER:-$GITHUB_ACTOR}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_registry_pass() {
  if [ "$(cibuild_ci_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_CI_REGISTRY_PASS:-$GITHUB_TOKEN}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_default_cache_registry() {
  printf '%s\n' "ci_registry"
}

cibuild_ci_image_path() {
  printf '%s\n' "${CIBUILD_CI_IMAGE_PATH:-$GITHUB_REPOSITORY}"
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
    printf '%s\n' "${CIBUILD_BASE_REGISTRY_USER:-$GITHUB_ACTOR}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_base_registry_pass() {
  if [ "$(cibuild_ci_base_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_BASE_REGISTRY_PASS:-$GITHUB_TOKEN}"
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
  printf '%s\n' "${CIBUILD_TARGET_IMAGE_PATH:-$GITHUB_REPOSITORY}"
}

cibuild_ci_build_tag() {
  printf '%s\n' ${CIBUILD_BUILD_TAG:-$(cibuild_ci_ref)}
}

cibuild_ci_target_image() {
  printf '%s\n' "$(cibuild_ci_target_registry)/$(cibuild_ci_target_image_path)"
}

cibuild_ci_target_image_full() {
  printf '%s\n' "$(cibuild_ci_target_registry)/$(cibuild_ci_target_image_path):$(cibuild_ci_build_tag)"
}

# release image data

cibuild_ci_release_registry() {
  printf '%s\n' "${CIBUILD_RELEASE_REGISTRY}"
}

cibuild_ci_release_registry_auth() {
  if [ -z "${CIBUILD_RELEASE_REGISTRY_USER:-}" ] || [ -z "${CIBUILD_RELEASE_REGISTRY_PASS:-}" ]; then
    printf '%s\n' ""
  else
    printf '%s\n' "${CIBUILD_RELEASE_REGISTRY_AUTH:-1}"
  fi
}

cibuild_ci_release_registry_user() {
  if [ "$(cibuild_ci_release_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_RELEASE_REGISTRY_USER:-}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_release_registry_pass() {
  if [ "$(cibuild_ci_release_registry_auth)" = "1" ]; then
    printf '%s\n' "${CIBUILD_RELEASE_REGISTRY_PASS:-}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_release_image_path() {
  printf '%s\n' "${CIBUILD_RELEASE_IMAGE_PATH:-$GITHUB_REPOSITORY}"
}

cibuild_ci_release_image() {
  printf '%s\n' "$(cibuild_ci_release_registry)/$(cibuild_ci_release_image_path)"
}

cibuild_ci_release_image_full() {
  printf '%s\n' "$(cibuild_ci_release_registry)/$(cibuild_ci_release_image_path):$(cibuild_ci_build_tag)"
}

cibuild__ci_get_base_cosign_annotations() {
  [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && \
    printf -- '-a\norg.opencontainers.image.source=%s/%s\n' \
      "${GITHUB_SERVER_URL}" "${GITHUB_REPOSITORY}"

  [ -n "${GITHUB_SHA:-}" ] && \
    printf -- '-a\norg.opencontainers.image.revision=%s\n' "${GITHUB_SHA}"

  [ -n "${GITHUB_REF_NAME:-}" ] && \
    printf -- '-a\norg.opencontainers.image.version=%s\n' "${GITHUB_REF_NAME}"

}

cibuild__ci_get_cosign_keyless_verify_args() {
  printf -- '--certificate-identity=%s/%s\n' \
    "${GITHUB_SERVER_URL}" \
    "${GITHUB_WORKFLOW_REF}"
  printf -- '--certificate-oidc-issuer=https://token.actions.githubusercontent.com\n'
}

cibuild__ci_cleanup_signatures() {
  local image="$1"
  local digest="$2"
  local sig_prefix
  sig_prefix=$(echo "$digest" | sed 's/:/-/')
  cibuild_log_debug "sig_prefix: ${sig_prefix}"
  
  if cibuild_is_ghcr "${image}"; then
    local repo="${image#ghcr.io/}"
    local owner="${repo%%/*}"
    local package="${repo#*/}"
    
    # find all versions with sig prefix and delete
    local versions
    versions=$(curl -sf \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "https://api.github.com/users/${owner}/packages/container/${package}/versions") || {
      cibuild_log_err "failed to fetch versions for ${package}"
      return 1
    }

    echo "$versions" \
      | jq -r ".[] | select((.metadata.container.tags // [])[] | startswith(\"${sig_prefix}\")) | .id" \
      | while read -r version_id; do
          if curl -sf -X DELETE \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            "https://api.github.com/users/${owner}/packages/container/${package}/versions/${version_id}"; then
            cibuild_log_info "deleted sig version ${version_id}"
          else
            cibuild_log_debug "failed to delete sig version ${version_id}"
          fi
        done
  else
    if regctl -v error tag rm "${image}:${sig_prefix}" 2>/dev/null; then
      cibuild_log_info "deleted ${image}:${sig_prefix}"
    fi
    if regctl -v error tag rm "${image}:${sig_prefix}.sig" 2>/dev/null; then
      cibuild_log_info "deleted ${image}:${sig_prefix}.sig"
    fi
  fi
}

cibuild__ci_cleanup_tag() {
  local image="$1"
  local tag="$2"

  if cibuild_is_ghcr "${image}"; then
    local repo="${image#ghcr.io/}"
    local owner="${repo%%/*}"
    local package="${repo#*/}"

    case "${tag}" in
      *-tmp)
        # move -tmp to platform digest so it gets deleted together with platform tag
        local platform_tag
        platform_tag=$(curl -sf \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          "https://api.github.com/users/${owner}/packages/container/${package}/versions" \
          | jq -r '
            .[] | 
            .metadata.container.tags[] | 
            select(test("-linux-")) |
            select(test("-tmp") | not)
          ' | head -1)

        if [ -n "${platform_tag}" ]; then
          cibuild_log_debug "moving ${tag} to ${platform_tag} version before delete"
          local platform_digest
          platform_digest=$(regctl -v error manifest head "${image}:${platform_tag}" 2>/dev/null) || true
          if [ -n "${platform_digest}" ]; then
            regctl -v error image copy "${image}@${platform_digest}" "${image}:${tag}" 2>/dev/null || true
          fi
        else
          cibuild_log_debug "no platform tag found to move ${tag} to"
        fi
        return 0  # tmp selbst nicht löschen - fliegt mit platform tag raus
        ;;
    esac

    local versions
    versions=$(curl -sf \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "https://api.github.com/users/${owner}/packages/container/${package}/versions") || {
      cibuild_log_err "failed to fetch versions for ${package}"
      return 1
    }

    local version_id
    version_id=$(echo "$versions" \
      | jq -r ".[] | select((.metadata.container.tags // [])[] | . == \"${tag}\") | .id" \
      | head -1)

    if [ -n "${version_id}" ]; then
      if curl -sf -X DELETE \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        "https://api.github.com/users/${owner}/packages/container/${package}/versions/${version_id}"; then
        cibuild_log_info "deleted tag ${tag} version ${version_id}"
      else
        cibuild_log_debug "failed to delete tag ${tag} version ${version_id}"
      fi
    else
      cibuild_log_debug "no version found for tag ${tag}"
    fi
  else
    if regctl -v error tag rm "${image}:${tag}" 2>/dev/null; then
      cibuild_log_info "deleted ${image}:${tag}"
    fi
  fi
}

# cibuild__ci_cleanup_tag() {
#   local image="$1"
#   local tag="$2"

#   if cibuild_is_ghcr "${image}"; then
#     local repo="${image#ghcr.io/}"
#     local owner="${repo%%/*}"
#     local package="${repo#*/}"

#     # tmp tags never delete
#     # pointing always to build_tag package
#     case "${tag}" in
#       *-tmp)
#         cibuild_log_debug "ghcr.io: skipping tmp tag delete - same version as build tag"
#         return 0
#         ;;
#     esac

#     local versions
#     versions=$(curl -sf \
#       -H "Authorization: Bearer ${GITHUB_TOKEN}" \
#       "https://api.github.com/users/${owner}/packages/container/${package}/versions") || {
#       cibuild_log_err "failed to fetch versions for ${package}"
#       return 1
#     }

#     local version_id
#     version_id=$(echo "$versions" \
#       | jq -r ".[] | select((.metadata.container.tags // [])[] | . == \"${tag}\") | .id \
#                | select(. != null)" \
#       | head -1)

#     if [ -n "${version_id}" ]; then
#       # ensure digest is only referred by this tag
#       local tag_count
#       tag_count=$(echo "$versions" \
#         | jq -r ".[] | select(.id == ${version_id}) | .metadata.container.tags | length")
      
#       if [ "${tag_count}" -gt 1 ]; then
#         cibuild_log_debug "ghcr.io: skipping delete - version ${version_id} has ${tag_count} tags"
#         return 0
#       fi

#       if curl -sf -X DELETE \
#         -H "Authorization: Bearer ${GITHUB_TOKEN}" \
#         "https://api.github.com/users/${owner}/packages/container/${package}/versions/${version_id}"; then
#         cibuild_log_info "deleted tag ${tag} version ${version_id}"
#       else
#         cibuild_log_debug "failed to delete tag ${tag} version ${version_id}"
#       fi
#     else
#       cibuild_log_debug "no version found for tag ${tag}"
#     fi
#   else
#     if regctl -v error tag rm "${image}:${tag}" 2>/dev/null; then
#       cibuild_log_info "deleted ${image}:${tag}"
#     fi
#   fi
# }

cibuild__ci_init() {

  cibuild_log_info "init ci: $(cibuild_ci_type)"

  _CIBUILD_CI_COMMIT="${GITHUB_SHA:-}"

  # target ref: normal branch or MR target
  _CIBUILD_CI_REF="${GITHUB_BASE_REF:-$GITHUB_REF_NAME}"

  if [ -z "$_CIBUILD_DATE" ]; then
    _CIBUILD_DATE=$(date +%F)
  fi

  if [ -z "$_CIBUILD_DATE_TIME" ]; then
     _CIBUILD_DATE_TIME=$(date +%F_%H-%M-%S)
  fi
}

cibuild__ci_init

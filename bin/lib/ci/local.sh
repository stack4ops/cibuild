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

# fixing values for repeated tagging
_CIBUILD_DATE=""
_CIBUILD_DATE_TIME=""

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
    printf '%s\n' "${CIBUILD_BASE_REGISTRY_PASS:-$(cibuild_ci_registry_pass)}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_default_cache_registry() {
  printf '%s\n' "target_registry"
}

cibuild_ci_default_cache_mode() {
  printf '%s\n' 'repo'
}

cibuild_ci_default_lock_mode() {
  printf '%s\n' 'tag'
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

cibuild_ci_build_tag() {
  printf '%s\n' ${CIBUILD_BUILD_TAG:-$(cibuild_ci_ref)}
}

cibuild_ci_target_image() {
  printf '%s\n' "$(cibuild_ci_target_registry)/$(cibuild_ci_target_image_path)"
}

cibuild_ci_target_image_full() {
  printf '%s\n' "$(cibuild_ci_target_registry)/$(cibuild_ci_target_image_path):$(cibuild_ci_build_tag)"
}

cibuild_ci_lock_commit() {
  local _build_lock_mode=$(cibuild_env_get 'build_lock_mode')
  local build_lock_mode=${_build_lock_mode:-$(cibuild_ci_default_lock_mode)}
  case "$build_lock_mode" in
    repo) printf '%s\n' "$(cibuild_ci_target_image)-lock:$(cibuild_ci_build_tag)-$(cibuild_ci_commit)" ;;
    tag)  printf '%s\n' "$(cibuild_ci_target_image):lock-$(cibuild_ci_build_tag)-$(cibuild_ci_commit)" ;;
    *)    cibuild_log_err "unsupported build_lock_mode $build_lock_mode"; exit 1 ;;
  esac
}

cibuild_ci_lock_latest() {
  local _build_lock_mode=$(cibuild_env_get 'build_lock_mode')
  local build_lock_mode=${_build_lock_mode:-$(cibuild_ci_default_lock_mode)}
  case "$build_lock_mode" in
    repo) printf '%s\n' "$(cibuild_ci_target_image)-lock:$(cibuild_ci_build_tag)-latest" ;;
    tag)  printf '%s\n' "$(cibuild_ci_target_image):lock-$(cibuild_ci_build_tag)-latest" ;;
    *)    cibuild_log_err "unsupported build_lock_mode $build_lock_mode"; exit 1 ;;
  esac
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
  printf '%s\n' "${CIBUILD_RELEASE_IMAGE_PATH:-$(cibuild__get_project_path)}"
}

cibuild_ci_release_image() {
  printf '%s\n' "$(cibuild_ci_release_registry)/$(cibuild_ci_release_image_path)"
}

cibuild_ci_release_image_full() {
  printf '%s\n' "$(cibuild_ci_release_registry)/$(cibuild_ci_release_image_path):$(cibuild_ci_build_tag)"
}

cibuild_ci_get_base_cosign_annotations() {
  printf -- '-a\norg.opencontainers.image.source=%s\n' "local"

  [ -n "${_CIBUILD_CI_COMMIT:-}" ] && \
    printf -- '-a\norg.opencontainers.image.revision=%s\n' "${_CIBUILD_CI_COMMIT}"

  [ -n "${_CIBUILD_CI_REF}" ] && \
    printf -- '-a\norg.opencontainers.image.version=%s\n' "${_CIBUILD_CI_REF}"
}

cibuild_ci_get_cosign_keyless_verify_args() {
  cibuild_log_err "keyless signing not supported in local adapter"
  return 1
}

cibuild_ci_cleanup_signatures() {
  local image="$1"
  local digest="$2"
  local sig_prefix
  sig_prefix=$(echo "$digest" | sed 's/:/-/')
  cibuild_log_debug "sig_prefix: ${sig_prefix}"
  if regctl -v error tag rm "${image}:${sig_prefix}" 2>/dev/null; then
    cibuild_log_info "deleted ${image}:${sig_prefix}"
  fi
  if regctl -v error tag rm "${image}:${sig_prefix}.sig" 2>/dev/null; then
    cibuild_log_info "deleted ${image}:${sig_prefix}.sig"
  fi
}

cibuild_ci_cleanup_tag() {
  local image="$1"
  local tag="$2"
  if regctl -v error tag rm "${image}:${tag}" 2>/dev/null; then
    cibuild_log_info "deleted ${image}:${tag}"
  fi
}

# Commit artifact-lock.<platform>.json back to the branch.
# No-op in local adapter — locks are stored in OCI registry only.
cibuild_ci_commit_lock_file() {
  cibuild_log_info "artifact-lock not committed locally"
}

# ---------------------------------------------------------------------------
# artifact-lock OCI transport layer
# ---------------------------------------------------------------------------

cibuild_ci_push_lock_artifact() {
  local platform_name="$1"
  local lock_file="/tmp/artifact-lock.${platform_name}.json"

  if [ ! -f "$lock_file" ]; then
    cibuild_log_err "cibuild_ci_push_lock_artifact: lock file not found: $lock_file"
    return 1
  fi

  local lock_ref="$(cibuild_ci_lock_commit)-${platform_name}"
  local latest_ref="$(cibuild_ci_lock_latest)-${platform_name}"

  cibuild_log_info "pushing artifact-lock to ${lock_ref}"

  local digest
  digest="$(regctl artifact put \
    --artifact-type "application/vnd.cibuild.artifact-lock+json" \
    --file-media-type "application/json" \
    --annotation "org.cibuild.commit=${_CIBUILD_CI_COMMIT}" \
    --annotation "org.cibuild.pipeline-id=local-$$" \
    --file "$lock_file" \
    --format '{{ .Manifest.GetDescriptor.Digest }}' \
    "$lock_ref")"

  if [ -z "$digest" ]; then
    cibuild_log_err "cibuild_ci_push_lock_artifact: regctl artifact put failed for ${lock_ref}"
    return 1
  fi

  cibuild_log_info "artifact-lock pushed: ${lock_ref} (${digest})"

  cibuild_log_info "tagging latest: ${latest_ref}"
  if ! regctl image copy "${lock_ref%:*}@${digest}" "$latest_ref"; then
    cibuild_log_err "cibuild_ci_push_lock_artifact: failed to tag latest for ${latest_ref}"
    return 1
  fi

  cibuild_log_info "artifact-lock latest updated: ${latest_ref}"
}

cibuild_ci_pull_lock_artifact() {
  local platform_name="$1" \
        out_file="/tmp/artifact-lock.${platform_name}.json" \
        signing_mode=$(cibuild_env_get 'build_cosign_signing_mode') \
        new_bundle_format=$(cibuild_env_get 'build_cosign_new_bundle_format') \
        verify=$(cibuild_env_get 'build_cosign_verify')

  local lock_ref="$(cibuild_ci_lock_commit)-${platform_name}"
  local latest_ref="$(cibuild_ci_lock_latest)-${platform_name}"

  if cibuild__ci_lock_commit_available "${platform_name}"; then
    if [ "${verify:-1}" = "1" ]; then
      cibuild_log_info "verifying artifact-lock ${lock_ref}"
      if ! cibuild_verify "${lock_ref}" "${signing_mode}" "${new_bundle_format}"; then
        cibuild_main_err "cibuild_verify failed: ${lock_ref}"
      fi
    fi
    cibuild_log_info "pulling artifact-lock from ${lock_ref}"
    if ! regctl artifact get "$lock_ref" > "$out_file"; then
      cibuild_log_err "cibuild_ci_pull_lock_artifact: regctl artifact get failed for ${lock_ref}, trying latest..."
    fi
  else
    if cibuild__ci_lock_latest_available "${platform_name}"; then
      if [ "${verify:-1}" = "1" ]; then
        cibuild_log_info "verifying artifact-lock ${latest_ref}"
        if ! cibuild_verify "${latest_ref}" "${signing_mode}" "${new_bundle_format}"; then
          cibuild_main_err "cibuild_verify failed: ${latest_ref}"
        fi
      fi
      cibuild_log_info "pulling artifact-lock from ${latest_ref}"
      if ! regctl artifact get "$latest_ref" > "$out_file"; then
        cibuild_log_err "cibuild_ci_pull_lock_artifact: regctl artifact get failed for ${latest_ref}"
      fi
    fi
  fi

  if [ ! -s "$out_file" ]; then
    cibuild_log_err "cibuild_ci_pull_lock_artifact: pulled file is empty: ${out_file}"
    return 1
  fi

  cibuild_log_info "artifact-lock pulled: ${out_file}"
}

cibuild_ci_condense_lock_artifacts() {
  local platforms="$*"

  if [ -z "$platforms" ]; then
    cibuild_log_err "cibuild_ci_condense_lock_artifacts: no platform names given"
    return 1
  fi

  if ! cibuild_function_exists cibuild_ci_commit_lock_file; then
    cibuild_log_err "cibuild_ci_condense_lock_artifacts: cibuild_ci_commit_lock_file not available in this adapter"
    return 1
  fi

  local failed=0
  for platform_name in $platforms; do
    cibuild_ci_pull_lock_artifact "$platform_name" || {
      cibuild_log_err "cibuild_ci_condense_lock_artifacts: failed to pull lock for ${platform_name}"
      failed=1
      continue
    }
    cibuild_ci_commit_lock_file "/tmp/artifact-lock.${platform_name}.json" || {
      cibuild_log_err "cibuild_ci_condense_lock_artifacts: failed to commit lock for ${platform_name}"
      failed=1
    }
  done

  if [ "$failed" -ne 0 ]; then
    cibuild_log_err "cibuild_ci_condense_lock_artifacts: one or more platforms failed"
    return 1
  fi

  cibuild_log_info "cibuild_ci_condense_lock_artifacts: all locks condensed into VCS"
}

cibuild_ci_lock_get() {
  local platform_name="$1"
  local field="$2"
  local lock_file="/tmp/artifact-lock.${platform_name}.json"

  if [ ! -f "$lock_file" ]; then
    cibuild_ci_pull_lock_artifact "$platform_name" || return 1
  fi

  jq -r ".${field} // empty" "$lock_file" || \
    cibuild_main_err "failed to get value ${field} for platform ${platform_name}"
}

cibuild__ci_lock_commit_available() {
  regctl -v error manifest head "$(cibuild_ci_lock_commit)-${1}" >/dev/null 2>&1
}

cibuild__ci_lock_latest_available() {
  regctl -v error manifest head "$(cibuild_ci_lock_latest)-${1}" >/dev/null 2>&1
}

cibuild_ci_lock_init() {
  local mandatory=${1:-0}
  local build_platforms build_native platforms platform platform_name
  build_platforms=$(cibuild_env_get 'build_platforms')
  build_native=$(cibuild_env_get 'build_native')
  platforms=""

  local build_lock_mode
  build_lock_mode=$(cibuild_env_get 'build_lock_mode')
  cibuild_log_info "build_lock_mode: ${build_lock_mode}"

  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(printf '%s' "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_name=$(printf '%s' "${platform}" | tr '/' '-')
    if cibuild__ci_lock_commit_available "${platform_name}" || \
       cibuild__ci_lock_latest_available "${platform_name}"; then
      cibuild_ci_pull_lock_artifact "${platform_name}"
    else
      cibuild_log_info "no artifact lock available for ${platform_name}"
      if [ "${mandatory}" = "1" ]; then
        cibuild_main_err "artifact locks are mandatory for this run, exit..."
      fi
    fi
  done
}

cibuild__ci_init() {
  cibuild_log_info "init ci: $(cibuild_ci_type)"

  # to avoid "dubious ownership" error in local adapter bind mounts
  git config --global safe.directory '*'

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

  if [ -z "$_CIBUILD_DATE" ]; then
    _CIBUILD_DATE=$(date +%F)
  fi

  if [ -z "$_CIBUILD_DATE_TIME" ]; then
    _CIBUILD_DATE_TIME=$(date +%F_%H-%M-%S)
  fi
}

cibuild__ci_init
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

# fixing values for repeated tagging
_CIBUILD_DATE=""
_CIBUILD_DATE_TIME=""

cibuild_ci_type() { printf '%s\n' "gitlab"; }

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
  printf '%s\n' "${CIBUILD_CI_TOKEN:-}"
}

cibuild__ci_cancel_requirements() {
  [ -n "$(cibuild_ci_token)" ] || return 2
  [ -n "${CI_API_V4_URL:-}" ] || return 3
  [ -n "${CI_PROJECT_ID:-}" ] || return 4
  [ -n "${CI_PIPELINE_ID:-}" ] || return 5
}

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

cibuild_ci_check_allowed() {
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
    printf '%s\n' "${CIBUILD_BASE_REGISTRY_PASS:-$(cibuild_ci_registry_pass)}"
  else
    printf '%s\n' ""
  fi
}

cibuild_ci_default_cache_registry() {
  printf '%s\n' "target_registry"
}

cibuild_ci_default_cache_mode() {
  printf '%s\n' 'tag'
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
  printf '%s\n' "${CIBUILD_TARGET_IMAGE_PATH:-$CI_PROJECT_PATH}"
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
  printf '%s\n' "${CIBUILD_RELEASE_IMAGE_PATH:-$CI_PROJECT_PATH}"
}

cibuild_ci_release_image() {
  printf '%s\n' "$(cibuild_ci_release_registry)/$(cibuild_ci_release_image_path)"
}

cibuild_ci_release_image_full() {
  printf '%s\n' "$(cibuild_ci_release_registry)/$(cibuild_ci_release_image_path):$(cibuild_ci_build_tag)"
}

cibuild_ci_get_base_cosign_annotations() {
  [ -n "${CI_PROJECT_URL:-}" ] && \
    printf -- '-a\norg.opencontainers.image.source=%s\n' "${CI_PROJECT_URL}"

  [ -n "${CI_COMMIT_SHA:-}" ] && \
    printf -- '-a\norg.opencontainers.image.revision=%s\n' "${CI_COMMIT_SHA}"

  [ -n "${CI_COMMIT_TAG:-}${CI_COMMIT_SHORT_SHA:-}" ] && \
    printf -- '-a\norg.opencontainers.image.version=%s\n' \
      "${CI_COMMIT_TAG:-${CI_COMMIT_SHORT_SHA}}"

  #[ -n "${CI_PIPELINE_CREATED_AT:-}" ] && \
  #  printf -- '-a\norg.opencontainers.image.created=%s\n' "${CI_PIPELINE_CREATED_AT}"
}

cibuild_ci_get_cosign_keyless_verify_args() {
  if [ -z "${SIGSTORE_ID_TOKEN:-}" ]; then
    cibuild_log_err "keyless signing requires SIGSTORE_ID_TOKEN - add id_tokens.SIGSTORE_ID_TOKEN.aud=sigstore to your gitlab-ci.yml"
    # >&2
    return 1
  fi
  printf -- '--certificate-identity=%s//.gitlab-ci.yml@refs/heads/%s\n' \
    "${CI_PROJECT_URL}" \
    "${CI_COMMIT_REF_NAME}"
  printf -- '--certificate-oidc-issuer=%s\n' \
    "${CI_SERVER_URL}"
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
# Uses [skip ci] to prevent pipeline loop.
# Requires CIBUILD_CI_TOKEN with write_repository scope.
cibuild_ci_commit_lock_file() {
    local lock_file="$1"
    local skip_ci=" [skip ci]"

    [ "$(cibuild_env_get 'skip_ci_on_commit_artifact_lock_file')" = "1" ] || skip_ci=""

    if [ ! -f "$lock_file" ]; then
        cibuild_log_err "lock file not found: $lock_file"
        return 1
    fi

    local BRANCH
    if [ "${CI_PIPELINE_SOURCE:-}" = "merge_request_event" ]; then
      BRANCH="${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-}"
    else
      BRANCH="${CI_COMMIT_BRANCH:-}"
    fi

    if [ -z "$BRANCH" ]; then
        cibuild_log_err "no branch context"
        return 0
    fi

    cibuild_log_info "fetching latest origin"

    if ! git fetch --prune --tags origin; then
        cibuild_log_err "git fetch failed"
        return 1
    fi

    if ! git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
        cibuild_log_err "remote branch '$BRANCH' not found"
        return 1
    fi

    if ! git checkout -B "$BRANCH" --track "origin/$BRANCH" 2>/dev/null; then
        if ! git checkout -B "$BRANCH" "origin/$BRANCH"; then
            cibuild_log_err "failed to checkout '$BRANCH'"
            return 1
        fi
    fi

    git add "$lock_file"

    if git diff --cached --quiet; then
        cibuild_log_info "artifact-lock unchanged: $lock_file"
        return 0
    fi

    if ! git commit -m "chore(lock): update ${lock_file}${skip_ci}"; then
        cibuild_log_err "git commit failed"
        return 1
    fi

    local i=1

    while [ "$i" -le 5 ]; do

        if git push origin "$BRANCH"; then
            cibuild_log_info "artifact-lock committed and pushed: $lock_file"
            return 0
        fi

        if [ "$i" -eq 5 ]; then
            cibuild_log_err "artifact-lock push failed after 5 attempts: $lock_file"
            return 1
        fi

        cibuild_log_info "push rejected, fetching and rebasing ($i/5)..."

        if ! git fetch --prune --tags origin; then
            cibuild_log_err "git fetch failed"
            return 1
        fi

        if ! git rebase "origin/$BRANCH"; then
            git rebase --abort 2>/dev/null || true
            cibuild_log_err "rebase failed"
            return 1
        fi

        sleep $((i * 2))

        i=$((i + 1))
    done
}

# ---------------------------------------------------------------------------
# artifact-lock OCI transport layer
#
# The artifact-lock.<platform>.json files are internal build coordination
# artefacts produced by each platform job and consumed by downstream jobs
# (verification, release, multi-arch index assembly). They are NOT image
# attestations (SBOM / provenance / vuln) and must not be mixed with those.
#
# Transport: OCI registry tags in the same image repository, using the
# naming scheme:
#
#   <image-repo>:<build-tag>-lock-<pipeline-id>-<platform-name>
#
# e.g.
#   registry.hrz.uni-marburg.de/ghcrio-cache/stack4ops/cibuilder:\
#     build-buildctl-lock-12345678-linux-amd64
#
# This keeps lock artefacts co-located with the images they describe,
# avoids a separate repository namespace, and lets the existing GC / keep /
# export machinery handle retention.
#
# Optional condensation into VCS (git commit) is a separate, explicit step
# that can be called after a merge, on a schedule, or manually — never
# forced during the pipeline that produced the lock, so the MR branch HEAD
# never moves due to a lock commit.
# ---------------------------------------------------------------------------

# Push an artifact-lock file to the OCI registry as a plain JSON blob.
# The tag encodes pipeline-id and platform so that parallel platform jobs
# never overwrite each other.
#
# Usage: cibuild_ci_push_lock_artifact <platform-name>
#   platform-name e.g. linux-amd64
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
    --annotation "org.cibuild.pipeline-id=${CI_PIPELINE_ID:-}" \
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

# Pull an artifact-lock file from the OCI registry into /tmp.
#
# Usage: lock_file=$(cibuild_ci_pull_lock_artifact <platform-name>)
cibuild_ci_pull_lock_artifact() {
  local platform_name="$1" \
        out_file="/tmp/artifact-lock.${platform_name}.json" \
        lock_ref="$(cibuild_ci_lock_commit)-${platform_name}" \
        latest_ref="$(cibuild_ci_lock_latest)-${platform_name}" \
        signing_mode=$(cibuild_env_get 'build_cosign_signing_mode') \
        new_bundle_format=$(cibuild_env_get 'build_cosign_new_bundle_format') \
        verify=$(cibuild_env_get 'build_cosign_verify')

  if [ "${verify:-1}" = "1" ]; then
    cibuild_log_info "verifying artifact-lock ${lock_ref}"
    if ! cibuild_verify "${lock_ref}" \
                 "${signing_mode}" \
                 "${new_bundle_format}"; then
      cibuild_log_err "cibuild_verify failed: ${lock_ref} try latest..."
    else
      if ! cibuild_verify "${latest_ref}" \
                 "${signing_mode}" \
                 "${new_bundle_format}"; then
        cibuild_main_err "cibuild_verify failed: ${latest_ref}"
      fi
    fi
  fi
  
  cibuild_log_info "pulling artifact-lock from ${lock_ref}"

  if ! regctl artifact get "$lock_ref" > "$out_file"; then
      cibuild_log_err "cibuild_ci_pull_lock_artifact: regctl artifact get failed for ${lock_ref} trying to get latest lock..."
  fi

  if ! regctl artifact get "$latest_ref" > "$out_file"; then
      cibuild_log_err "cibuild_ci_pull_lock_artifact: regctl artifact get failed for ${latest_ref}"
      return 1
  fi

  if [ ! -s "$out_file" ]; then
      cibuild_log_err "cibuild_ci_pull_lock_artifact: pulled file is empty: ${out_file}"
      return 1
  fi
  cibuild_log_info "artifact-lock pulled: ${out_file}"
}

# Condense artifact-lock files from the OCI registry back into VCS.
# This is an explicit, optional step — never called automatically during
# the pipeline that produced the locks. Call it after a merge, on a
# schedule, or manually.
#
# Pulls all platform locks for a given pipeline-id and build-tag from the
# registry, then commits them to the current branch via
# cibuild_ci_commit_lock_file (which must be implemented by the CI adapter).
#
# Usage: cibuild_ci_condense_lock_artifacts <platform-names...>
#
#   platform-names  space-separated list, e.g. "linux-amd64 linux-arm64"
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
      local out_file
      out_file=$(cibuild_ci_pull_lock_artifact "$platform_name") || {
          cibuild_log_err "cibuild_ci_condense_lock_artifacts: failed to pull lock for ${platform_name}"
          failed=1
          continue
      }

      cibuild_ci_commit_lock_file "$out_file" || {
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

# Read a field from artifact-lock.<platform_name>.json.
# Pulls from OCI registry if not already present locally.
# Usage: cibuild_ci_lock_get <platform_name> <field>
cibuild_ci_lock_get() {
  local platform_name="$1"
  local field="$2"
  local lock_file="/tmp/artifact-lock.${platform_name}.json"
  jq -r ".${field} // empty" "$lock_file" || cibuild_main_err "failed to get value ${field} for platform ${platform_name}"
}

cibuild__ci_lock_available() {
  regctl -v error manifest head "$(cibuild_ci_lock_commit)-${1}" || regctl -v error manifest head "$(cibuild_ci_latest_commit)-${1}" >/dev/null 2>&1
}

cibuild_ci_lock_init() {
  # check artifact-lock files
  
  local build_platforms=$(cibuild_env_get 'build_platforms')
  local build_native=$(cibuild_env_get 'build_native')
  local platforms=""
  
  local build_lock_mode=$(cibuild_env_get 'build_lock_mode')
  cibuild_log_info "build_lock_mode: ${build_lock_mode}"

  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_name=$(echo "${platform}" | tr '/' '-')
    if ! cibuild__ci_lock_available "${platform_name}"; then
      cibuild_log_info "artifact-lock for ${platform_name} not available: $(cibuild_ci_lock_commit)-${platform_name}"
    else
      cibuild_ci_pull_lock_artifact "${platform_name}"
    fi
  done
}

cibuild__ci_init() {

  cibuild_log_info "init ci: $(cibuild_ci_type)"

  _CIBUILD_CI_COMMIT="${CI_COMMIT_SHA:-}"

  if [ "${CI_PIPELINE_SOURCE:-}" = "merge_request_event" ]; then
    _CIBUILD_CI_REF="${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}"
  else
    _CIBUILD_CI_REF="${CI_COMMIT_REF_NAME:-}"
  fi
  
  cibuild_log_info "_CIBUILD_CI_REF=${_CIBUILD_CI_REF}"

  if [ -z "$_CIBUILD_DATE" ]; then
    _CIBUILD_DATE=$(date +%F)
  fi

  if [ -z "$_CIBUILD_DATE_TIME" ]; then
     _CIBUILD_DATE_TIME=$(date +%F_%H-%M-%S)
  fi

}

cibuild__ci_init


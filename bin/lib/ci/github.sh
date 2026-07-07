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

# native registry in github

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

cibuild_ci_default_cache_registry() {
  printf '%s\n' "ci_registry"
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

cibuild_ci_lock() {
  local _build_lock_mode=$(cibuild_env_get 'build_lock_mode')
  local build_lock_mode=${_build_lock_mode:-$(cibuild_ci_default_lock_mode)}
  case "$build_lock_mode" in
    repo) printf '%s\n' "$(cibuild_ci_target_image)-lock:$(cibuild_ci_build_tag)-$(cibuild_ci_commit)" ;;
    tag)  printf '%s\n' "$(cibuild_ci_target_image):lock-$(cibuild_ci_build_tag)-$(cibuild_ci_commit)" ;;
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
  printf '%s\n' "${CIBUILD_RELEASE_IMAGE_PATH:-$GITHUB_REPOSITORY}"
}

cibuild_ci_release_image() {
  printf '%s\n' "$(cibuild_ci_release_registry)/$(cibuild_ci_release_image_path)"
}

cibuild_ci_release_image_full() {
  printf '%s\n' "$(cibuild_ci_release_registry)/$(cibuild_ci_release_image_path):$(cibuild_ci_build_tag)"
}

cibuild_ci_get_base_cosign_annotations() {
  [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && \
    printf -- '-a\norg.opencontainers.image.source=%s/%s\n' \
      "${GITHUB_SERVER_URL}" "${GITHUB_REPOSITORY}"

  [ -n "${GITHUB_SHA:-}" ] && \
    printf -- '-a\norg.opencontainers.image.revision=%s\n' "${GITHUB_SHA}"

  [ -n "${GITHUB_REF_NAME:-}" ] && \
    printf -- '-a\norg.opencontainers.image.version=%s\n' "${GITHUB_REF_NAME}"

}

cibuild_ci_get_cosign_keyless_verify_args() {
  printf -- '--certificate-identity=%s/%s\n' \
    "${GITHUB_SERVER_URL}" \
    "${GITHUB_WORKFLOW_REF}"
  printf -- '--certificate-oidc-issuer=https://token.actions.githubusercontent.com\n'
}

cibuild_ci_cleanup_signatures() {
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

cibuild_ci_cleanup_tag() {
  local image="$1"
  local tag="$2"

  if cibuild_is_ghcr "${image}"; then
    local repo="${image#ghcr.io/}"
    local owner="${repo%%/*}"
    local package="${repo#*/}"

    case "${tag}" in
      *-cibuild-idx)
        # move -cibuild-idx to platform digest so it gets deleted together with platform tag
        local platform_tag
        platform_tag=$(curl -sf \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          "https://api.github.com/users/${owner}/packages/container/${package}/versions" \
          | jq -r '
            .[] | 
            .metadata.container.tags[] | 
            select(test("-linux-")) |
            select(test("-cibuild-idx") | not) |
            select(test("-cache") | not)
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
        return 0
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

# Uploads supply chain artifacts (SBOM/vuln/provenance/digests/cert) as
# assets on the GitHub Release matching the current tag. GitHub has no
# generic package registry equivalent to GitLab's, so a Release is the
# closest native analogue — this assumes a release for the tag already
# exists (no automatic release creation, upload is skipped non-fatally
# if none is found).
cibuild_ci_upload_supply_chain_artifacts() {
  local output_dir="${CIBUILD_OUTPUT_DIR:-.}" \
        upload_mode \
        tag_name="${GITHUB_REF_NAME:-}" \
        upload_url

  upload_mode=$(cibuild_env_get 'release_upload_supply_chain_artifacts' 2>/dev/null || true)

  [ "${upload_mode}" = "package" ] || return 0

  [ -n "${GITHUB_TOKEN:-}" ] || {
    cibuild_log_err "GITHUB_TOKEN not set — cannot upload supply chain artifacts"
    return 1
  }

  [ -n "${GITHUB_REPOSITORY:-}" ] || {
    cibuild_log_err "GITHUB_REPOSITORY not set — cannot upload supply chain artifacts"
    return 1
  }

  [ -n "${tag_name}" ] || {
    cibuild_log_err "GITHUB_REF_NAME not set — cannot upload supply chain artifacts"
    return 1
  }

  cibuild_log_info "uploading supply chain artifacts to GitHub Release ${tag_name}"

  upload_url=$(curl --silent --fail \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/${tag_name}" \
    | jq -r '.upload_url // empty' | sed 's/{?name,label}//')

  [ -n "${upload_url}" ] || {
    cibuild_log_err "no GitHub Release found for tag ${tag_name} — cannot upload supply chain artifacts"
    return 1
  }

  for file in sbom-linux-amd64.spdx.json sbom-linux-amd64.cdx.json sbom-linux-arm64.spdx.json sbom-linux-arm64.cdx.json vuln-linux-amd64.json vuln-linux-arm64.json provenance-linux-amd64.slsa.json provenance-linux-arm64.slsa.json digests.json cert.json; do

    [ -f "${output_dir}/${file}" ] || continue

    cibuild_log_info "uploading ${file}"
    curl --silent --fail \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --upload-file "${output_dir}/${file}" \
      "${upload_url}?name=${file}" \
      >/dev/null || cibuild_log_debug "upload of ${file} failed (non-fatal)"
  done

  cibuild_log_info "supply chain artifacts upload done"
}

# rebase from previous job commits
cibuild_ci_rebase_repo() {
    if [ -z "${GITHUB_REPOSITORY:-}" ] || [ -z "$(cibuild_ci_token)" ]; then
        cibuild_log_err "cibuild_ci_rebase_repo: GITHUB_REPOSITORY or GITHUB_TOKEN not set"
        return 1
    fi

    local BRANCH
    if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ "${GITHUB_EVENT_NAME:-}" = "pull_request_target" ]; then
        BRANCH="${GITHUB_HEAD_REF:-}"
    else
        BRANCH="${GITHUB_REF_NAME:-}"
    fi

    if [ -z "$BRANCH" ]; then
        cibuild_log_err "no branch context, skipping cibuild_ci_rebase_repo"
        return 0
    fi

    local remote_url="https://x-access-token:$(cibuild_ci_token)@github.com/${GITHUB_REPOSITORY}.git"

    git config --global user.email "cibuild@ci.github"
    git config --global user.name "cibuild"
    git config --global --add safe.directory "$PWD"

    if ! git remote set-url origin "$remote_url"; then
        cibuild_log_err "failed to update origin remote"
        return 1
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

    #
    # Remove colliding local branches.
    #
    # Example:
    #
    #   renovate
    #   renovate/group
    #   renovate/group/foo
    #
    # when checking out
    #
    #   renovate/group/foo/bar
    #
    local prefix=""
    local remainder="$BRANCH"

    while [ "$remainder" != "${remainder#*/}" ]; do
        local part="${remainder%%/*}"

        if [ -z "$prefix" ]; then
            prefix="$part"
        else
            prefix="$prefix/$part"
        fi

        if git show-ref --verify --quiet "refs/heads/$prefix"; then
            cibuild_log_info "removing colliding local branch '$prefix'"
            git branch -D "$prefix" || true
        fi

        remainder="${remainder#*/}"
    done

    if ! git checkout -B "$BRANCH" --track "origin/$BRANCH" 2>/dev/null; then
        if ! git checkout -B "$BRANCH" "origin/$BRANCH"; then
            cibuild_log_err "failed to checkout '$BRANCH'"
            return 1
        fi
    fi

    if ! git symbolic-ref -q HEAD >/dev/null; then
        cibuild_log_err "HEAD is detached"
        return 1
    fi

    local i=1

    while [ "$i" -le 5 ]; do

        cibuild_log_info "rebasing '$BRANCH' onto origin/$BRANCH"

        if ! git fetch --prune --tags origin; then
            cibuild_log_err "git fetch failed"
            return 1
        fi

        if git rebase "origin/$BRANCH"; then
            cibuild_log_info "repo rebased"
            return 0
        fi

        git rebase --abort 2>/dev/null || true
        git reset --hard "origin/$BRANCH" >/dev/null 2>&1 || true

        if [ "$i" -eq 5 ]; then
            cibuild_log_err "rebase failed after 5 attempts"
            return 1
        fi

        cibuild_log_info "rebase failed, retrying ($i/5)..."

        sleep $((i * 2))

        i=$((i + 1))
    done
}

# Commit artifact-lock.<platform>.json back to the branch.
# Uses [skip ci] to prevent pipeline loop.
# Requires GITHUB_TOKEN with contents:write permission.
cibuild_ci_commit_lock_file() {
    local lock_file="$1"
    local skip_ci=" [skip ci]"

    [ "$(cibuild_env_get 'skip_ci_on_commit_artifact_lock_file')" = "1" ] || skip_ci=""

    if [ ! -f "$lock_file" ]; then
        cibuild_log_err "lock file not found: $lock_file"
        return 1
    fi

    local BRANCH
    if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ "${GITHUB_EVENT_NAME:-}" = "pull_request_target" ]; then
      BRANCH="${GITHUB_HEAD_REF:-}"
    else
      BRANCH="${GITHUB_REF_NAME:-}"
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
#   <image-repo>:<build-tag>-lock-<run-id>-<platform-name>
#
# e.g.
#   ghcr.io/stack4ops/cibuilder:\
#     build-buildctl-lock-12345678-linux-amd64
#
# This keeps lock artefacts co-located with the images they describe,
# avoids a separate repository namespace, and lets the existing GC / keep /
# export machinery handle retention.
#
# Optional condensation into VCS (git commit) is a separate, explicit step
# that can be called after a merge, on a schedule, or manually — never
# forced during the pipeline that produced the lock, so the PR branch HEAD
# never moves due to a lock commit.
# ---------------------------------------------------------------------------

# Push an artifact-lock file to the OCI registry as a plain JSON blob.
# The tag encodes run-id and platform so that parallel platform jobs
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

  local lock_ref="$(cibuild_ci_lock)-${platform_name}"
  cibuild_log_info "pushing artifact-lock to ${lock_ref}"

  if ! regctl artifact put \
          --artifact-type "application/vnd.cibuild.artifact-lock+json" \
          --file-media-type "application/json" \
          --annotation "org.cibuild.commit=${_CIBUILD_CI_COMMIT}" \
          --annotation "org.cibuild.run-id=${GITHUB_RUN_ID:-}" \
          --file "$lock_file" \
          "$lock_ref"; then
      cibuild_log_err "cibuild_ci_push_lock_artifact: regctl artifact put failed for ${lock_ref}"
      return 1
  fi

  cibuild_log_info "artifact-lock pushed: ${lock_ref}"
}

# Pull an artifact-lock file from the OCI registry into /tmp.
#
# Usage: lock_file=$(cibuild_ci_pull_lock_artifact <platform-name>)
cibuild_ci_pull_lock_artifact() {
  local platform_name="$1" \
        out_file="/tmp/artifact-lock.${platform_name}.json" \
        lock_ref="$(cibuild_ci_lock)-${platform_name}" \
        signing_mode=$(cibuild_env_get 'build_cosign_signing_mode') \
        new_bundle_format=$(cibuild_env_get 'build_cosign_new_bundle_format') \
        verify=$(cibuild_env_get 'build_cosign_verify')

  if [ "${verify:-1}" = "1" ]; then
    cibuild_log_info "verifying artifact-lock ${lock_ref}"
    if ! cibuild_verify "${lock_ref}" \
                 "${signing_mode}" \
                 "${new_bundle_format}"; then
      cibuild_main_err "cibuild_verify failed: ${lock_ref}"
    fi
  fi
  
  cibuild_log_info "pulling artifact-lock from ${lock_ref}"

  if ! regctl artifact get "$lock_ref" > "$out_file"; then
      cibuild_log_err "cibuild_ci_pull_lock_artifact: regctl artifact get failed for ${lock_ref}"
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
# Pulls all platform locks for a given run-id and build-tag from the
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
  regctl -v error manifest head "$(cibuild_ci_lock)-${1}" >/dev/null 2>&1
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
      cibuild_log_info "artifact-lock for ${platform_name} not available: $(cibuild_ci_lock)-${platform_name}"
    else
      cibuild_ci_pull_lock_artifact "${platform_name}"
    fi
  done
}

cibuild__ci_init() {

  cibuild_log_info "init ci: $(cibuild_ci_type)"

  _CIBUILD_CI_COMMIT="${GITHUB_SHA:-}"

  # target ref: normal branch or PR base
  _CIBUILD_CI_REF="${GITHUB_BASE_REF:-$GITHUB_REF_NAME}"

  if [ -z "$_CIBUILD_DATE" ]; then
    _CIBUILD_DATE=$(date +%F)
  fi

  if [ -z "$_CIBUILD_DATE_TIME" ]; then
     _CIBUILD_DATE_TIME=$(date +%F_%H-%M-%S)
  fi

}

cibuild__ci_init
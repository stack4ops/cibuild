#!/bin/sh
# Package cibuild/release

# All releaseable artifacts and their attestations are signed
# by the same cryptographic identity to ensure a single, auditable trust root.

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_RELEASE_LOADED-}" ] && return
_CIBUILD_RELEASE_LOADED=1

cibuild__release_minortag_template=""
cibuild__release_minortag=""
cibuild__target_digest=""

# =============================================================================
# HELPERS (mostly unchanged from original)
# =============================================================================

cibuild__get_docker_attestation_digest() {
  local platform_image="$1" image_digest="$2"
  local ref="${platform_image}@${image_digest}"
  local ref_digest
  ref_digest=$(regctl -v error manifest head "${ref}")
  regctl -v error manifest get "${ref}@${ref_digest}" \
    --format '{{range .Manifests}}{{if eq (index .Annotations "vnd.docker.reference.type") "attestation-manifest"}}{{.Digest}}{{end}}{{end}}'
}

cibuild__release_provenance() {
  local platform_name=$1 image_ref=$2 \
        build_provenance=$(cibuild_env_get 'build_provenance') \
        build_client=$(cibuild_env_get 'build_client') \
        output_dir="${CIBUILD_OUTPUT_DIR:-.}"

  case "${build_client}" in
    buildctl|buildx) ;;
    *) return 0 ;;
  esac
  [ "${build_provenance}" = "1" ] || return 0

  local ref_digest attestation_digest
  ref_digest=$(regctl -v error manifest head "${image_ref}") || return 0
  attestation_digest=$(regctl -v error manifest get "${image_ref}@${ref_digest}" \
    --format '{{range .Manifests}}{{if eq (index .Annotations "vnd.docker.reference.type") "attestation-manifest"}}{{.Digest}}{{end}}{{end}}') || return 0

  [ -z "${attestation_digest}" ] && return 0

  regctl artifact get "${image_ref}@${attestation_digest}" \
    > "${output_dir}/provenance-${platform_name}.slsa.json" 2>/dev/null || return 0
  cibuild_log_info "provenance written: ${output_dir}/provenance-${platform_name}.slsa.json"
}

cibuild__release_copy_tag() {
  local copy_to_tag="$1" target_image=${2:-$(cibuild_ci_target_image)}
  if [ -z "${cibuild__target_digest:-}" ]; then
    cibuild_main_err "internal: cibuild__target_digest missing"
  fi
  if ! regctl -v error image copy \
    ${target_image}@${cibuild__target_digest} \
    ${target_image}:${copy_to_tag} >/dev/null 2>&1; then
    cibuild_log_err "failed to set tag ${target_image}:${copy_to_tag}"
    return 1
  fi
  return 0
}

cibuild__get_minor_tag() {
  local release_minor_tag_regex=$(cibuild_env_get 'release_minor_tag_regex') \
        base_image=$(cibuild_core_base_image) \
        base_tag=$(cibuild_core_base_tag)

  sed_escape() { printf '%s' "$1" | sed 's/[&\/]/\\&/g'; }

  [ -z "${release_minor_tag_regex:-}" ] && return 0
  [ -z "${cibuild__release_minortag_template:-}" ] && return 0

  local ref="${base_image}:${base_tag}"

  cibuild_log_debug "regex $release_minor_tag_regex"

  local current_digest
  current_digest=$(regctl -v error image digest "$ref" --platform=linux/amd64) || return 1

  cibuild_log_debug "current_digest $current_digest"

  local limit=$(cibuild_env_get 'release_minor_tag_paging_limit') \
        last="" seen_last="" all_tags=""
  while :; do
    local tags
    tags="$(regctl -v error tag ls "${base_image}" --limit "$limit" ${last:+--last "$last"})"
    [ -z "$tags" ] && break
    all_tags="$all_tags\n$tags"
    last="$(echo "$tags" | tail -n 1)"
    [ "$last" = "$seen_last" ] && break
    seen_last="$last"
  done

  local tags mt
  tags="$(printf "%b\n" "$all_tags" | sort -V -r | grep -P "$release_minor_tag_regex")"
  for mt in $tags; do
    local tag_digest
    tag_digest=$(regctl -v error image digest "${base_image}:${mt}" --platform=linux/amd64) || continue
    if [ "$tag_digest" = "$current_digest" ]; then
      local _mt
      _mt=$(cibuild_ci_process_tag $cibuild__release_minortag_template)
      cibuild__release_minortag=$(printf '%s' "$_mt" | sed -e "s/__MINORTAG__/$(sed_escape "$mt")/g")
      return 0
    fi
  done

  cibuild_log_err "could not get minor_tag from $base_tag"
  return 1
}

# =============================================================================
# CREATE INDEX — reads platform digests from artifact-lock files
# =============================================================================

cibuild__release_create_index() {
  local target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        release_docker_attestation_autodetect=$(cibuild_env_get 'release_docker_attestation_autodetect') \
        release_docker_attestation_manifest=$(cibuild_env_get 'release_docker_attestation_manifest') \
        target_registry=$(cibuild_ci_target_registry) \
        signature=$(cibuild_env_get 'release_cosign_signature') \
        remove_duplicated_signatures=$(cibuild_env_get 'release_cosign_remove_duplicated_signatures') \
        signing_mode=$(cibuild_env_get 'release_cosign_signing_mode') \
        signing_config=$(cibuild_env_get 'release_cosign_signing_config') \
        new_bundle_format=$(cibuild_env_get 'release_cosign_new_bundle_format') \
        annotations_path="${CIBUILD_LIB_PATH}/cosign_release_annotations.sh" \
        signing_recursive=$(cibuild_env_get 'release_cosign_signing_recursive') \
        verify$(cibuild_env_get 'release_cosign_verify') \
        release_cosign_verify_build_artifacts=$(cibuild_env_get 'release_cosign_verify_build_artifacts')
    
  # --- verify all platform images
  if [ "${release_cosign_verify_build_artifacts:-1}" = "1" ]; then
    cibuild_verify_all_platforms
  fi

  # --- build index from lock file digests ---
  local create_args="" \
        found=0 \
        platforms \
        lock_digest \
        image_ref
  
  platforms=$(echo "$build_platforms" | tr ',' ' ')

  for platform in $platforms; do
    platform_name=$(echo "$platform" | tr '/' '-')
    lock_digest=$(cibuild_ci_lock_get "${platform_name}" "image_digest") || continue
    # use digest reference — independent of tag state
    image_ref="${target_image}@${lock_digest}"
    if regctl -v error manifest head "${image_ref}" >/dev/null 2>&1; then
      create_args="$create_args --ref $image_ref --platform $platform"
      found=1
    else
      cibuild_main_err "platform manifest not found in registry: ${image_ref}"
    fi
  done

  if [ "$found" -eq 0 ]; then
    cibuild_main_err "no platform manifests found — cannot create index"
  fi

  local idx_tag="${build_tag}-cibuild-idx"

  if ! regctl -v error index create "$target_image:$idx_tag" $create_args; then
    cibuild_main_err "error creating image index ${target_image}:${idx_tag}"
  fi

  cibuild_log_info "image index created: ${target_image}:${idx_tag}"

  if [ "${release_docker_attestation_autodetect}" = "1" ] && [ "${target_registry}" = "docker.io" ]; then
    release_docker_attestation_manifest=1
  fi

  if [ "${release_docker_attestation_manifest}" = "1" ]; then
    set -- $platforms; first=$1; value=linux/amd64
    case " $platforms " in
      *" $value "*) platform="$value" ;;
      *) platform="$first" ;;
    esac
    platform_name=$(echo "${platform}" | tr '/' '-')
    local attestation_digest image_digest
    image_digest=$(cibuild_ci_lock_get "${platform_name}" "image_digest")
    attestation_digest=$(cibuild__get_docker_attestation_digest "${target_image}" "${image_digest}")
    if ! regctl -v error index add "${target_image}:${idx_tag}" \
      --ref "${target_image}@${attestation_digest}" \
      --desc-platform unknown/unknown \
      --desc-annotation vnd.docker.reference.type=attestation-manifest \
      --desc-annotation vnd.docker.reference.digest=${image_digest}; then
      cibuild_main_err "error adding docker attestation manifest"
    fi
  fi

  cibuild__target_digest=$(regctl -v error manifest head "${target_image}:${idx_tag}")
  cibuild_log_info "index digest: ${cibuild__target_digest}"

  if ! regctl -v error image copy \
    ${target_image}@${cibuild__target_digest} \
    ${target_image}:${build_tag} >/dev/null 2>&1; then
    cibuild_log_err "failed to set ${target_image}:${build_tag}"
  fi

  if [ "${remove_duplicated_signatures:-1}" = "1" ]; then
    cibuild_remove_signatures "${target_image}" "${cibuild__target_digest}"
  fi
  
  image_ref="${target_image}@${cibuild__target_digest}"

  if [ "${signature:-1}" = "1" ]; then
    cibuild_log_info "signing platform image ${image_ref}"
  
    if ! cibuild_sign  "${image_ref}" \
                "${signing_mode}" \
                "${signing_config}" \
                "${new_bundle_format}" \
                "${annotations_path}" \
                "${signing_recursive}"; then
      cibuild_main_err "cibuild_sign failed: ${image_ref}"
    fi
  fi

  if [ "${verify:-1}" = "1" ]; then
    cibuild_log_info "verifying platform image ${image_ref}"
    if ! cibuild_verify "${image_ref}" \
                 "${signing_mode}" \
                 "${new_bundle_format}"; then
      cibuild_main_err "cibuild_verify failed: ${image_ref}"
    fi
  fi
}

# =============================================================================
# IMAGE TAGS / MINOR TAG / VERSION TAGS (unchanged)
# =============================================================================

cibuild__release_image_tags() {
  local reg=$1
  local release_image_tags=${2:-$(cibuild_env_get 'release_image_tags')}
  local build_tag=$(cibuild_ci_build_tag)
  local tag
  IFS=',;'; set -- $release_image_tags; unset IFS
  for tag; do
    case "$tag" in
      *__MINORTAG__*) cibuild__release_minortag_template="$tag"; continue ;;
      *)
        local processed_tag=$(cibuild_ci_process_tag "$tag")
        cibuild__release_copy_tag "$processed_tag" "$reg" || \
          cibuild_log_err "error assigning tag $processed_tag"
        ;;
    esac
  done
}

cibuild__release_minor_tag() {
  local reg=$1
  local release_minor_tag_regex=$(cibuild_env_get 'release_minor_tag_regex')
  [ -z "${release_minor_tag_regex:-}" ] && return 0
  [ -z "${cibuild__release_minortag}" ] && ! cibuild__get_minor_tag && return 1
  cibuild__release_copy_tag "$cibuild__release_minortag" "${reg}"
}

cibuild__release_nix_version_tags() {
  local reg=$1
  local build_client=$(cibuild_env_get 'build_client')
  [ "${build_client}" = "nix" ] || return 0

  local target_image build_tag full_version minor_version variant
  target_image=$(cibuild_ci_target_image)
  build_tag=$(cibuild_ci_build_tag)

  full_version=$(regctl image config \
    "${target_image}:${build_tag}" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
    2>/dev/null | tr -d '[:space:]' || echo "")

  [ -z "${full_version}" ] && return 0

  minor_version=$(printf '%s\n' "${full_version}" | cut -d'.' -f1,2)
  variant=$(printf '%s\n' "$(cibuild_ci_build_tag)" | cut -d'-' -f2-)

  cibuild_log_info "nix version tags: ${full_version} (patch), ${minor_version} (minor)"
  cibuild__release_copy_tag "${full_version}-${variant}" "${reg}" || true
  cibuild__release_copy_tag "${minor_version}-${variant}" "${reg}" || true
}

cibuild__release_create_regctl_auth_config() {
  local logged_in=" "
  for registry in base_registry target_registry release_registry ci_registry; do
    case "$registry" in
      base_registry)    local reg=$(cibuild_core_base_registry);     local auth=$(cibuild_ci_base_registry_auth);    local user=$(cibuild_ci_base_registry_user);    local pass=$(cibuild_ci_base_registry_pass) ;;
      target_registry)  local reg=$(cibuild_ci_target_registry);     local auth=$(cibuild_ci_target_registry_auth);  local user=$(cibuild_ci_target_registry_user);  local pass=$(cibuild_ci_target_registry_pass) ;;
      release_registry) local reg=$(cibuild_ci_release_registry);    local auth=$(cibuild_ci_release_registry_auth); local user=$(cibuild_ci_release_registry_user); local pass=$(cibuild_ci_release_registry_pass) ;;
      ci_registry)      local reg=$(cibuild_ci_registry);            local auth=$(cibuild_ci_registry_auth);         local user=$(cibuild_ci_registry_user);         local pass=$(cibuild_ci_registry_pass) ;;
    esac
    case " $logged_in " in *" $reg "*) cibuild_log_debug "already logged in: $reg"; continue ;; esac
    if [ "$auth" = "1" ]; then
      regctl registry set "$reg" --hostname "$reg" --skip-check
      regctl registry login "$reg" --user "$user" --pass "$pass" --skip-check
      logged_in="$logged_in $reg"
    fi
  done
  regctl registry config
}

cibuild__mirror_registry_get_var() {
  local reg="$1" key="$2" prefix="CIBUILD_RELEASE_MIRROR_REGISTRY"
  if [ -n "$key" ]; then
    env | grep "^${prefix}_${reg}_${key}=" | cut -d'=' -f2-
  else
    env | grep "^${prefix}_${reg}=" | cut -d'=' -f2-
  fi
}

cibuild__release_mirrors() {
  local build_tag=$(cibuild_ci_build_tag) \
        target_image=$(cibuild_ci_target_image) \
        target_image_path=$(cibuild_ci_target_image_path)

  local registries
  registries=$(env | grep -E '^CIBUILD_RELEASE_MIRROR_REGISTRY_[A-Z]+=' \
    | sed 's/^CIBUILD_RELEASE_MIRROR_REGISTRY_//' | sed 's/=.*//')

  for registry in $registries; do
    local reg=$(cibuild__mirror_registry_get_var "${registry}") \
          user=$(cibuild__mirror_registry_get_var "${registry}" "USER") \
          pass=$(cibuild__mirror_registry_get_var "${registry}" "PASS") \
          _image_path=$(cibuild__mirror_registry_get_var "${registry}" "IMAGE_PATH") \
          _keep_build_tag=$(cibuild__mirror_registry_get_var "${registry}" "KEEP_BUILD_TAG") \
          _keep_image_tags=$(cibuild__mirror_registry_get_var "${registry}" "KEEP_IMAGE_TAGS") \
          image_tags=$(cibuild__mirror_registry_get_var "${registry}" "IMAGE_TAGS")

    local keep_build_tag=${_keep_build_tag:-1}
    local keep_image_tags=${_keep_image_tags:-1}

    if [ "${keep_build_tag}" = "0" ] && [ "${keep_image_tags}" = "0" ] && [ -z "${image_tags:-}" ]; then
      cibuild_log_err "cannot get tags for mirror — set KEEP_BUILD_TAG=1, KEEP_IMAGE_TAGS=1, or IMAGE_TAGS"
      return 1
    fi

    [ -f "${HOME}/.regctl/config.json" ] && rm "${HOME}/.regctl/config.json"
    if [ -n "${user}" ] && [ -n "${pass}" ]; then
      regctl registry set "$reg" --hostname "$reg" --skip-check
      regctl registry login "$reg" --user "$user" --pass "$pass" --skip-check
    fi

    local image_path=${_image_path:-$target_image_path}
    local mirror_image="${reg}/${image_path}"

    if ! regctl -v error image copy \
      --referrers --digest-tags \
      ${target_image}@${cibuild__target_digest} \
      ${mirror_image}@${cibuild__target_digest} >/dev/null 2>&1; then
      cibuild_log_err "failed to copy to mirror ${mirror_image}"
      return 1
    fi

    [ "${keep_build_tag:-1}" = "1" ] && \
      regctl -v error image copy \
        ${mirror_image}@${cibuild__target_digest} \
        ${mirror_image}:${build_tag} >/dev/null 2>&1 || true

    [ "${keep_image_tags:-1}" = "1" ] && \
      cibuild__release_image_tags "${mirror_image}" || \
      cibuild__release_image_tags "${mirror_image}" "${image_tags}"

    cibuild__release_minor_tag "${mirror_image}"
    cibuild__release_nix_version_tags "${mirror_image}"
  done
}

cibuild__release_clean_tags() {
  local target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        release_keep_platform_tags=$(cibuild_env_get 'release_keep_platform_tags') \
        release_keep_idx_tag=$(cibuild_env_get 'release_keep_idx_tag')

  local platforms idx_tag="${build_tag}-cibuild-idx"
  platforms=$(echo "$build_platforms" | tr ',' ' ')

  [ "$release_keep_idx_tag" = "0" ] && cibuild_ci_cleanup_tag "${target_image}" "${idx_tag}"

  if [ "${release_keep_platform_tags}" = "0" ]; then
    for platform in $platforms; do
      platform_name=$(echo "$platform" | tr '/' '-')
      cibuild_ci_cleanup_tag "${target_image}" "${build_tag}-${platform_name}"
    done
  fi
}

# =============================================================================
# RELEASE RUN ENTRYPOINT
# =============================================================================

cibuild_release_run() {
  local release_enabled=$(cibuild_env_get 'release_enabled') \
        signature=$(cibuild_env_get 'release_cosign_signature') \
        local build_client=$(cibuild_env_get 'build_client')

  if [ "${release_enabled:?}" != "1" ]; then
    cibuild_log_info "release run not enabled: skipped"
    return
  fi

  if [ "${signature:-1}" = "1" ]; then
    cibuild_check_signing_env
  fi

  if ! cibuild_core_run_script release pre; then
    exit 1
  fi

  cibuild__release_create_index

  cibuild__release_image_tags
  if [ "${build_client}" = "nix" ]; then
    cibuild__release_nix_version_tags
  else
    cibuild__release_minor_tag
  fi
  
  cibuild__release_mirrors

  cibuild__release_clean_tags

  if ! cibuild_core_run_script release post; then
    exit 1
  fi
}
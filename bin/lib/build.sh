#!/bin/sh
# Package cibuild/build

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_BUILD_LOADED-}" ] && return
_CIBUILD_BUILD_LOADED=1

# Retrieve the most recent cosign signature referrer digest for a given subject digest.
# Format awareness:
#   new bundle (default): ArtifactType = application/vnd.oci.empty.v1+json  (OCI 1.1 referrer)
#   old bundle (fallback or CIBUILD_COSIGN_NEW_BUNDLE_FORMAT=0):
#                         ArtifactType = application/vnd.dev.cosign.artifact.sig.v1+json
# If multiple signatures exist (e.g. from previous builds), take the last one.

cibuild__build_get_sig_digest() {
  local target_image="$1" \
        subject_digest="$2"
  local build_cosign_new_bundle_format
  build_cosign_new_bundle_format=$(cibuild_env_get 'build_cosign_new_bundle_format')

  local sig_digest primary_type fallback_type
  if [ "${build_cosign_new_bundle_format}" = "0" ]; then
    primary_type="application/vnd.dev.cosign.artifact.sig.v1+json"
    fallback_type="application/vnd.oci.empty.v1+json"
  else
    primary_type="application/vnd.oci.empty.v1+json"
    fallback_type="application/vnd.dev.cosign.artifact.sig.v1+json"
  fi

  # emit "ArtifactType Digest" per line, grep for desired type, extract digest
  local all_refs
  all_refs=$(regctl artifact list "${target_image}@${subject_digest}" \
    --format '{{range .Descriptors}}{{.ArtifactType}}{{" "}}{{.Digest}}{{"\n"}}{{end}}' \
    2>/dev/null || true)

  sig_digest=$(printf '%s\n' "${all_refs}" | grep "^${primary_type} " | awk '{print $2}' | tail -1)

  if [ -z "${sig_digest:-}" ]; then
    sig_digest=$(printf '%s\n' "${all_refs}" | grep "^${fallback_type} " | awk '{print $2}' | tail -1)
  fi

  printf '%s\n' "${sig_digest:-}"
}

# Write artifact-lock.<platform_name>.json and commit via CI adapter.
cibuild__build_write_artifact_lock() {
  local platform="$1" \
        platform_name="$2" \
        target_image="$3" \
        build_tag="$4" \
        image_digest="$5" \
        sbom_digest="${6:-}" \
        vuln_digest="${7:-}" \
        provenance_digest="${8:-}" \
        build_client="$9"

  local lock_file="artifact-lock.${platform_name}.json"
  local source_commit
  source_commit=$(cibuild_ci_commit)

  jq -n \
    --arg platform        "${platform}" \
    --arg platform_name   "${platform_name}" \
    --arg image           "${target_image}" \
    --arg build_tag       "${build_tag}" \
    --arg image_digest    "${image_digest}" \
    --arg sbom_digest        "${sbom_digest}" \
    --arg vuln_digest        "${vuln_digest}" \
    --arg provenance_digest  "${provenance_digest}" \
    --arg build_client    "${build_client}" \
    --arg source_commit   "${source_commit}" \
    --arg built_at        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      platform:      $platform,
      platform_name: $platform_name,
      image:         $image,
      build_tag:     $build_tag,
      image_digest:  $image_digest,
      referrers: {
        sbom:       $sbom_digest,
        vuln:       $vuln_digest,
        provenance: $provenance_digest
      },
      build_client:  $build_client,
      source_commit: $source_commit,
      built_at:      $built_at
    }' > "${lock_file}"

  cibuild_log_info "artifact-lock written: ${lock_file}"

  if cibuild_function_exists cibuild_ci_commit_lock_file; then
    cibuild_ci_commit_lock_file "${lock_file}" || \
      cibuild_log_err "artifact-lock commit failed (non-fatal)"
  else
    cibuild_log_info "cibuild_ci_commit_lock_file not implemented for this adapter — skipping commit"
  fi
}

# Get the real platform manifest digest (resolves inside buildctl index if needed).
# buildctl/buildx always write an index even for single-platform builds (attestations).
# nix/kaniko write the manifest directly.
cibuild__build_get_platform_digest() {
  local target_image="$1" \
        build_tag="$2" \
        platform_name="$3" \
        platform="$4" \
        build_client="$5"

  local ref="${target_image}:${build_tag}-${platform_name}"

  case "${build_client}" in
    buildctl|buildx)
      regctl manifest head "${ref}" --platform "${platform}" 2>/dev/null
      ;;
    *)
      regctl manifest head "${ref}" 2>/dev/null
      ;;
  esac
}

# =============================================================================
# SBOM + VULN referrers via trivy — for buildctl/buildx/kaniko build clients.
# nix generates its own referrers (bombon + vulnxscan) and passes them directly.
#
# Generates:
#   CycloneDX SBOM → pushed as application/vnd.cyclonedx+json referrer
#   Vuln report    → pushed as application/vnd.trivy.vuln+json referrer
#
# SPDX conversion stays in the release run (from the CycloneDX referrer).
# =============================================================================

# Push SBOM (CycloneDX) as OCI referrer, set _CIBUILD_SBOM_DIGEST.
# Usage: cibuild__build_push_sbom <target_image> <image_digest> <platform> <platform_name>
cibuild__build_push_sbom() {
  local image_ref="$1" platform="$2" platform_name="$3"
  _CIBUILD_SBOM_DIGEST=""

  [ "$(cibuild_env_get 'build_sbom')" = "1" ] || return 0
  command -v trivy >/dev/null 2>&1 || { cibuild_log_err "trivy not found — skipping SBOM (non-fatal)"; return 0; }

  local sbom_tmp
  sbom_tmp=$(mktemp)

  cibuild_log_info "generating SBOM (CycloneDX) for ${platform_name}"
  if ! trivy image \
    --platform "${platform}" \
    --format cyclonedx \
    --scanners "" \
    --quiet \
    --output "${sbom_tmp}" \
    "${image_ref}" 2>/dev/null; then
    cibuild_log_err "trivy SBOM failed (non-fatal)"
    rm -f "${sbom_tmp}"
    return 0
  fi

  if [ -s "${sbom_tmp}" ]; then
    local digest
    if digest=$(regctl artifact put \
      --artifact-type "application/vnd.cyclonedx+json" \
      --subject "${image_ref}" \
      --format '{{.Manifest.GetDescriptor.Digest}}' \
      < "${sbom_tmp}" 2>/dev/null); then
      _CIBUILD_SBOM_DIGEST="${digest}"
    else
      cibuild_log_err "SBOM push failed (non-fatal)"
    fi
    cibuild_log_info "SBOM pushed, digest: ${_CIBUILD_SBOM_DIGEST:-n/a}"
  fi
  rm -f "${sbom_tmp}"
}

# Push vuln report as OCI referrer, set _CIBUILD_VULN_DIGEST.
# Usage: cibuild__build_push_vuln <target_image> <image_digest> <platform> <platform_name>
cibuild__build_push_vuln() {
  local image_ref="$1" platform="$2" platform_name="$3"
  _CIBUILD_VULN_DIGEST=""

  [ "$(cibuild_env_get 'build_vuln')" = "1" ] || return 0
  command -v trivy >/dev/null 2>&1 || { cibuild_log_err "trivy not found — skipping vuln (non-fatal)"; return 0; }

  local vuln_tmp
  vuln_tmp=$(mktemp)

  cibuild_log_info "generating vuln report for ${platform_name}"
  if ! trivy image \
    --platform "${platform}" \
    --format json \
    --scanners vuln \
    --quiet \
    --output "${vuln_tmp}" \
    "${image_ref}" 2>/dev/null; then
    cibuild_log_err "trivy vuln scan failed (non-fatal)"
    rm -f "${vuln_tmp}"
    return 0
  fi

  if [ -s "${vuln_tmp}" ]; then
    local digest
    if digest=$(regctl artifact put \
      --artifact-type "application/vnd.trivy.vuln+json" \
      --subject "${image_ref}" \
      --format '{{.Manifest.GetDescriptor.Digest}}' \
      < "${vuln_tmp}" 2>/dev/null); then
      _CIBUILD_VULN_DIGEST="${digest}"
    else
      cibuild_log_err "vuln push failed (non-fatal)"
    fi
    cibuild_log_info "vuln pushed, digest: ${_CIBUILD_VULN_DIGEST:-n/a}"
  fi
  rm -f "${vuln_tmp}"
}


# Extract SLSA provenance from buildctl/buildx attestation-manifest and push as OCI referrer.
# buildctl writes provenance as a Docker attestation-manifest inside the index.
# We extract the SLSA payload and re-push as application/vnd.slsa.provenance+json referrer
# so it is accessible as a standard OCI referrer independent of the index format.
# Sets _CIBUILD_PROVENANCE_DIGEST on success.
# Usage: cibuild__build_push_provenance <target_image> <build_tag> <platform_name> <platform> <image_digest>
cibuild__build_push_provenance() {
  local target_image="$1" \
        build_tag="$2" \
        platform_name="$3" \
        platform="$4" \
        image_digest="$5"
  _CIBUILD_PROVENANCE_DIGEST=""

  [ "$(cibuild_env_get 'build_provenance')" = "1" ] || return 0

  local ref="${target_image}:${build_tag}-${platform_name}"

  # get the index digest (buildctl always writes an index)
  local index_digest
  index_digest=$(regctl -v error manifest head "${ref}" 2>/dev/null) || {
    cibuild_log_err "provenance: cannot get index digest for ${ref} (non-fatal)"
    return 0
  }

  # find the attestation-manifest inside the index
  local attestation_digest
  attestation_digest=$(regctl -v error manifest get "${ref}@${index_digest}" \
    --format '{{range .Manifests}}{{if eq (index .Annotations "vnd.docker.reference.type") "attestation-manifest"}}{{.Digest}}{{end}}{{end}}' \
    2>/dev/null) || {
    cibuild_log_err "provenance: cannot find attestation-manifest (non-fatal)"
    return 0
  }

  if [ -z "${attestation_digest}" ]; then
    cibuild_log_info "provenance: no attestation-manifest found for ${platform_name} (build_provenance may be disabled)"
    return 0
  fi

  # extract the SLSA provenance payload from the attestation-manifest
  local provenance_tmp
  provenance_tmp=$(mktemp)
  regctl artifact get "${target_image}@${attestation_digest}" \
    > "${provenance_tmp}" 2>/dev/null || {
    cibuild_log_err "provenance: artifact get failed (non-fatal)"
    rm -f "${provenance_tmp}"
    return 0
  }

  if [ ! -s "${provenance_tmp}" ]; then
    cibuild_log_err "provenance: empty payload (non-fatal)"
    rm -f "${provenance_tmp}"
    return 0
  fi

  # push as OCI referrer on the platform image digest
  local digest
  if digest=$(regctl artifact put \
    --artifact-type "application/vnd.slsa.provenance+json" \
    --subject "${target_image}@${image_digest}" \
    --format '{{.Manifest.GetDescriptor.Digest}}' \
    < "${provenance_tmp}" 2>/dev/null); then
    _CIBUILD_PROVENANCE_DIGEST="${digest}"
    cibuild_log_info "provenance pushed, digest: ${_CIBUILD_PROVENANCE_DIGEST}"
  else
    cibuild_log_err "provenance push failed (non-fatal)"
  fi
  rm -f "${provenance_tmp}"
}
# =============================================================================
# POST-BUILD: sign + write artifact-lock — shared across all build clients.
# Called at the end of each platform iteration.
# For buildctl/buildx/kaniko: generates SBOM + vuln referrers via trivy.
# For nix: sbom_digest + vuln_digest are passed in from the build loop.
# =============================================================================

cibuild__build_post_platform() {
  local platform="$1" \
        platform_name="$2" \
        target_image="$3" \
        build_tag="$4" \
        build_client="$5" \
        sbom_digest="${6:-}" \
        vuln_digest="${7:-}" \
        signature=$(cibuild_env_get 'build_cosign_signature') \
        remove_old_signatures=$(cibuild_env_get 'build_cosign_remove_old_signatures') \
        signing_mode=$(cibuild_env_get 'build_cosign_signing_mode') \
        signing_config=$(cibuild_env_get 'build_cosign_signing_config') \
        new_bundle_format=$(cibuild_env_get 'build_cosign_new_bundle_format') \
        annotations_path="${CIBUILD_LIB_PATH}/cosign_build_annotations.sh" \
        signing_recursive=$(cibuild_env_get 'build_cosign_signing_recursive') \
        verify$(cibuild_env_get 'build_cosign_verify')

  local image_digest
  image_digest=$(cibuild__build_get_platform_digest \
    "${target_image}" "${build_tag}" "${platform_name}" "${platform}" "${build_client}")

  if [ -z "${image_digest:-}" ]; then
    cibuild_main_err "could not resolve platform manifest digest for ${platform_name}"
  fi

  local image_ref="${target_image}@${image_digest}"

  cibuild_log_info "platform digest (${platform_name}): ${image_digest}"

  # generate SBOM + vuln referrers for non-nix clients (nix passes them in)
  if [ "${build_client}" != "nix" ]; then
    cibuild__build_push_sbom "${image_ref}" "${platform}" "${platform_name}"
    sbom_digest="${_CIBUILD_SBOM_DIGEST:-}"
    cibuild__build_push_vuln "${image_ref}" "${platform}" "${platform_name}"
    vuln_digest="${_CIBUILD_VULN_DIGEST:-}"
  fi

  # extract + push provenance for buildctl/buildx (attestation-manifest → OCI referrer)
  local provenance_digest=""
  case "${build_client}" in
    buildctl|buildx)
      cibuild__build_push_provenance \
        "${target_image}" "${build_tag}" "${platform_name}" "${platform}" "${image_digest}"
      provenance_digest="${_CIBUILD_PROVENANCE_DIGEST:-}"
      ;;
  esac

  if [ "${remove_old_signatures:-1}" = "1" ]; then
    cibuild_remove_signatures "${target_image}" "${image_digest}"
  fi

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

  cibuild__build_write_artifact_lock \
    "${platform}" \
    "${platform_name}" \
    "${target_image}" \
    "${build_tag}" \
    "${image_digest}" \
    "${sbom_digest}" \
    "${vuln_digest}" \
    "${provenance_digest}" \
    "${build_client}"
}

# =============================================================================
# Builder detection / creation (unchanged)
# =============================================================================

cibuild__build_detect_docker() {
  if ! timeout 5 docker info >/dev/null 2>&1; then
    return 1
  else
    return 0
  fi
}

cibuild__build_detect_kubernetes() {
  local build_buildkit_service_account=$(cibuild_env_get 'build_buildkit_service_account')
  if [ -z "${build_buildkit_service_account:-}" ]; then
    cibuild_main_err "CIBUILD_BUILD_BUILDKIT_SERVICE_ACCOUNT env var must not be empty"
    return 1
  fi
  echo "$build_buildkit_service_account" | base64 -d > /tmp/kubeconfig
  export KUBECONFIG=/tmp/kubeconfig
  if ! timeout 5 kubectl auth can-i create release -q >/dev/null 2>&1; then
    return 1
  else
    return 0
  fi
}

create_dockercontainer_builder() {
  local build_buildx_driver=$(cibuild_env_get 'build_buildx_driver')
  if [ "$(cibuild_ci_type)" = "local" ]; then
    if ! docker network inspect dind-net >/dev/null 2>&1; then
      cibuild_log_info "docker network create dind-net"
      docker network create dind-net
    fi
    if ! docker buildx create \
      --name ${build_buildx_driver} \
      --buildkitd-config "${CIBUILD_LIB_PATH}/res/buildkitd.local.toml" \
      --driver docker-container \
      --driver-opt "network=dind-net"; then
      cibuild_main_err "error creating builder $build_buildx_driver"
    fi
  else
    docker buildx create --name ${build_buildx_driver} --driver docker-container
  fi
}

create_remote_builder() {
  local build_buildx_driver=$(cibuild_env_get 'build_buildx_driver') \
        build_remote_buildkit=$(cibuild_env_get 'build_remote_buildkit') \
        build_buildkit_host=$(cibuild_env_get 'build_buildkit_host')
  if [ -z "${build_buildkit_host:-}" ]; then
    cibuild_main_err "CIBUILD_BUILDKIT_HOST env var must not be empty"
  fi
  driver_opts=""
  if [ "${build_remote_buildkit:-}" = "1" ]; then
    cibuild__build_create_cert_files
    driver_opts="--driver-opt cacert=/tmp/ca.pem,cert=/tmp/cert.pem,key=/tmp/key.pem"
  fi
  if ! docker buildx create \
    --name ${build_buildx_driver} \
    --driver remote ${driver_opts} \
    ${build_buildkit_host}; then
    cibuild_main_err "error creating builder $build_buildx_driver"
  fi
}

create_kubernetes_builder() {
  local build_buildx_driver=$(cibuild_env_get 'build_buildx_driver') \
        build_kubernetes_replicas=$(cibuild_env_get 'build_kubernetes_replicas')
  if ! cibuild__build_detect_kubernetes; then
    cibuild_main_err "error detecting kubernetes backend"
  fi
  if ! docker buildx create \
    --name "$build_buildx_driver" \
    --driver kubernetes \
    --driver-opt=replicas=${build_kubernetes_replicas:-1} \
    --buildkitd-config "${CIBUILD_LIB_PATH}/res/buildkitd.local.toml"; then
    cibuild_main_err "error creating builder $build_buildx_driver"
  fi
}

cibuild__build_create_builder() {
  local build_buildx_driver=$(cibuild_env_get 'build_buildx_driver')
  case "$build_buildx_driver" in
    dockercontainer) create_dockercontainer_builder ;;
    remote)          create_remote_builder ;;
    kubernetes)      create_kubernetes_builder ;;
    *)               cibuild_main_err "buildx_driver $build_buildx_driver not supported" ;;
  esac
  if ! docker buildx use ${build_buildx_driver}; then
    cibuild_main_err "error using builder ${build_buildx_driver}"
  fi
  if ! docker buildx inspect ${build_buildx_driver} --bootstrap; then
    cibuild_main_err "error bootstrapping builder ${build_buildx_driver}"
  fi
}

cibuild__build_create_cert_files() {
  local build_buildkit_client_ca=$(cibuild_env_get 'build_buildkit_client_ca') \
        build_buildkit_client_cert=$(cibuild_env_get 'build_buildkit_client_cert') \
        build_buildkit_client_key=$(cibuild_env_get 'build_buildkit_client_key')
  [ -z "${build_buildkit_client_ca}" ]   && cibuild_main_err "CIBUILD_BUILD_BUILDKIT_CLIENT_CA must not be empty"
  [ -z "${build_buildkit_client_cert}" ] && cibuild_main_err "CIBUILD_BUILD_BUILDKIT_CLIENT_CERT must not be empty"
  [ -z "${build_buildkit_client_key}" ]  && cibuild_main_err "CIBUILD_BUILD_BUILDKIT_CLIENT_KEY must not be empty"
  printf '%s\n' "$build_buildkit_client_ca"   | base64 -d > /tmp/ca.pem
  printf '%s\n' "$build_buildkit_client_cert" | base64 -d > /tmp/cert.pem
  printf '%s\n' "$build_buildkit_client_key"  | base64 -d > /tmp/key.pem
}

cibuild__build_get_build_args() {
  local build_args=$(cibuild_env_get 'build_args') \
        build_client=$(cibuild_env_get 'build_client') \
        build_arguments
  if [ "${build_client}" = "buildx" ]; then
    for build_arg in ${build_args:-}; do
      build_arguments="${build_arguments} --build-arg ${build_arg}"
    done
  else
    for build_arg in ${build_args:-}; do
      build_arguments="${build_arguments} --opt build-arg:${build_arg}"
    done
  fi
  printf '%s\n' "$build_arguments"
}

cibuild__build_get_cache_to_opt() {
  local build_client=$(cibuild_env_get 'build_client')
  [ "${build_client}" = "buildctl" ] && printf '%s\n' "--export-cache" || printf '%s\n' "--cache-to"
}

cibuild__build_get_cache_from_opt() {
  local build_client=$(cibuild_env_get 'build_client')
  [ "${build_client}" = "buildctl" ] && printf '%s\n' "--import-cache" || printf '%s\n' "--cache-from"
}

cibuild__build_get_import_cache_args() {
  local arch=$1 \
        build_tag=$(cibuild_ci_build_tag) \
        _build_import_cache=$(cibuild_env_get 'build_import_cache') \
        _build_cache_mode=$(cibuild_env_get 'build_cache_mode')
  local build_import_cache=${_build_import_cache:-$(cibuild_ci_default_cache_registry)}
  local build_cache_mode=${_build_cache_mode:-$(cibuild_ci_default_cache_mode)}
  local cache_image=""
  case "$build_import_cache" in
    "")             printf '%s\n' ""; return 0 ;;
    ci_registry)    cache_image=$(cibuild_ci_image) ;;
    target_registry) cache_image=$(cibuild_ci_target_image) ;;
    *)              printf '%s\n' "$(cibuild__build_get_cache_from_opt) ${build_import_cache}"; return 0 ;;
  esac
  case "$build_cache_mode" in
    repo) printf '%s\n' "$(cibuild__build_get_cache_from_opt) type=registry,ref=${cache_image}-cache:${build_tag}-${arch}" ;;
    tag)  printf '%s\n' "$(cibuild__build_get_cache_from_opt) type=registry,ref=${cache_image}:${build_tag}-${arch}-cache" ;;
    *)    cibuild_log_err "unsupported build_cache_mode $build_cache_mode"; exit 1 ;;
  esac
}

cibuild__build_get_export_cache_args() {
  local arch=$1 \
        build_tag=$(cibuild_ci_build_tag) \
        cache_mode=$(cibuild_env_get 'build_export_cache_mode') \
        _build_export_cache=$(cibuild_env_get 'build_export_cache') \
        _build_cache_mode=$(cibuild_env_get 'build_cache_mode')
  local build_export_cache=${_build_export_cache:-$(cibuild_ci_default_cache_registry)}
  local build_cache_mode=${_build_cache_mode:-$(cibuild_ci_default_cache_mode)}
  local cache_image=""
  case "$build_export_cache" in
    "")             printf '%s\n' ""; return 0 ;;
    ci_registry)    cache_image=$(cibuild_ci_image) ;;
    target_registry) cache_image=$(cibuild_ci_target_image) ;;
    *)              printf '%s\n' "$(cibuild__build_get_cache_to_opt) ${build_export_cache}"; return 0 ;;
  esac
  case "$build_cache_mode" in
    repo) printf '%s\n' "$(cibuild__build_get_cache_to_opt) type=registry,ref=${cache_image}-cache:${build_tag}-${arch},mode=${cache_mode}" ;;
    tag)  printf '%s\n' "$(cibuild__build_get_cache_to_opt) type=registry,ref=${cache_image}:${build_tag}-${arch}-cache,mode=${cache_mode}" ;;
    *)    cibuild_log_err "unsupported build_cache_mode $build_cache_mode"; exit 1 ;;
  esac
}

cibuild__build_get_provenance_args() {
  local build_provenance=$(cibuild_env_get 'build_provenance') \
        build_provenance_mode=$(cibuild_env_get 'build_provenance_mode') \
        build_client=$(cibuild_env_get 'build_client')
  case "${build_client}" in
    buildctl|buildx) ;;
    *) return 0 ;;
  esac
  if [ "${build_provenance}" = "1" ]; then
    if [ "${build_client}" = "buildctl" ]; then
      printf '%s\n' "--opt attest:provenance=mode=${build_provenance_mode:-max}"
    else
      printf '%s\n' "--provenance=mode=${build_provenance_mode:-max}"
    fi
  else
    printf '%s\n' ""
  fi
}

# =============================================================================
# DEBUG HELPER (unchanged from original)
# =============================================================================

cibuild__build_debug_buildkitd() {
  cibuild_log_dump "=== buildkitd/QEMU diagnostics ==="
  cibuild_log_dump "  ROOTLESSKIT_STATE_DIR: ${ROOTLESSKIT_STATE_DIR:-NOT SET}"
  cibuild_log_dump "  ROOTLESSKIT_PID:       ${ROOTLESSKIT_PID:-NOT SET}"
  cibuild_log_dump "  id:     $(id)"
  cibuild_log_dump "  subuid: $(grep "^$(id -un):" /etc/subuid 2>/dev/null || echo 'not found')"
  local daemonless_path
  daemonless_path="$(command -v buildctl-daemonless.sh 2>/dev/null || echo 'NOT IN PATH')"
  cibuild_log_dump "  buildctl-daemonless.sh: ${daemonless_path}"
  cibuild_log_dump "  buildkitd: $(command -v buildkitd 2>/dev/null || echo NOT FOUND) $(buildkitd --version 2>&1 || true)"
  cibuild_log_dump "  buildctl:  $(command -v buildctl 2>/dev/null || echo NOT FOUND) $(buildctl --version 2>&1 || true)"
  cibuild_log_dump "  BUILDKIT_HOST: ${BUILDKIT_HOST:-not set}"
  if [ -r /proc/sys/fs/binfmt_misc/status ]; then
    cibuild_log_dump "  binfmt_misc status: $(cat /proc/sys/fs/binfmt_misc/status)"
  fi
  cibuild_log_dump "=== end diagnostics ==="
}

# =============================================================================
# BUILD CLIENTS
# =============================================================================

cibuild__build_image_buildx() {
  local platforms platform \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_native=$(cibuild_env_get 'build_native') \
        build_opts=$(cibuild_env_get 'build_opts') \
        build_args=$(cibuild__build_get_build_args) \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        build_set_ci_secrets=$(cibuild_env_get 'build_set_ci_secrets') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        container_file=$(cibuild_core_container_file) \
        platform_name cache provenance_args no_cache
  local build_buildx_driver=$(cibuild_env_get 'build_buildx_driver')

  cibuild_log_info "build image with buildx"
  cibuild__build_create_builder

  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_name=$(echo "${platform}" | tr '/' '-')
    cache="$(cibuild__build_get_import_cache_args ${platform_name}) $(cibuild__build_get_export_cache_args ${platform_name})"
    provenance_args="$(cibuild__build_get_provenance_args)"
    . "${CIBUILD_LIB_PATH}/build_args.sh"
    [ "${build_use_cache}" = "0" ] && no_cache="--no-cache" || no_cache=""

    if ! docker buildx build \
      --builder "${build_buildx_driver}" \
      --platform "${platform}" \
      ${build_opts:-} \
      ${build_arguments} \
      ${no_cache} \
      ${cache} \
      --tag "${target_image}:${build_tag}-${platform_name}" \
      --file "${container_file}" \
      --push \
      "$@" \
      .; then
      cibuild_main_err "Build failed"
    fi

    # buildx: SBOM/vuln generated in release run by trivy
    cibuild__build_post_platform \
      "${platform}" "${platform_name}" "${target_image}" "${build_tag}" "buildx" "" ""
  done
}

cibuild__build_image_buildctl() {
  local platforms platform \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_native=$(cibuild_env_get 'build_native') \
        build_opts=$(cibuild_env_get 'build_opts') \
        build_args=$(cibuild__build_get_build_args) \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        build_set_ci_secrets=$(cibuild_env_get 'build_set_ci_secrets') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        container_file=$(cibuild_core_container_file) \
        platform_name cache provenance_args no_cache build_command
  local build_remote_buildkit=$(cibuild_env_get 'build_remote_buildkit') \
        build_buildkit_host=$(cibuild_env_get 'build_buildkit_host') \
        build_buildkit_tls=$(cibuild_env_get 'build_buildkit_tls')

  cibuild_log_info "build image with buildctl"
  [ -z "${build_buildkit_host:-}" ] && cibuild_main_err "CIBUILD_BUILDKIT_HOST must not be empty"

  if [ "${build_remote_buildkit:-}" = "1" ]; then
    build_command="buildctl --addr ${build_buildkit_host}"
    if [ "${build_buildkit_tls:-1}" = "1" ]; then
      cibuild__build_create_cert_files
      build_command="$build_command --tlscert /tmp/cert.pem --tlskey /tmp/key.pem --tlscacert /tmp/ca.pem"
    fi
  else
    build_command="buildctl-daemonless.sh"
  fi

  cibuild__build_debug_buildkitd

  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_name=$(echo "${platform}" | tr '/' '-')
    cache="$(cibuild__build_get_import_cache_args ${platform_name}) $(cibuild__build_get_export_cache_args ${platform_name})"
    provenance_args="$(cibuild__build_get_provenance_args)"
    . "${CIBUILD_LIB_PATH}/build_args.sh"
    [ "${build_use_cache}" = "0" ] && no_cache="--no-cache" || no_cache=""

    if ! $build_command \
      build \
      --frontend=dockerfile.v0 \
      --local context=. \
      --local dockerfile=. \
      --opt platform="${platform}" \
      --opt filename="./${container_file}" \
      ${provenance_args:-} \
      ${build_opts:-} \
      ${build_args:-} \
      ${no_cache:-} \
      ${cache:-} \
      --output "type=image,name=${target_image}:${build_tag}-${platform_name},oci-artifact=true,push=true" \
      "$@"; then
      cibuild_log_info "--- build FAILED for ${platform} ---"
      local qemu_arch
      case "${platform}" in
        linux/arm64)   qemu_arch="aarch64" ;;
        linux/arm/v7)  qemu_arch="arm" ;;
        linux/s390x)   qemu_arch="s390x" ;;
        linux/ppc64le) qemu_arch="ppc64le" ;;
        linux/riscv64) qemu_arch="riscv64" ;;
        linux/386)     qemu_arch="i386" ;;
        linux/amd64)   qemu_arch="" ;;
        *)             qemu_arch="" ;;
      esac
      [ -n "${qemu_arch:-}" ] && \
        cibuild_log_info "  qemu binary: $(ls -la /usr/local/bin/buildkit-qemu-${qemu_arch} 2>/dev/null || echo NOT FOUND)"
      cibuild_main_err "failed: $build_command"
    fi

    # buildctl: SBOM/vuln generated in release run by trivy
    cibuild__build_post_platform \
      "${platform}" "${platform_name}" "${target_image}" "${build_tag}" "buildctl" "" ""
  done
}

cibuild__build_image_kaniko() {
  local platforms platform \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_native=$(cibuild_env_get 'build_native') \
        build_opts=$(cibuild_env_get 'build_opts') \
        build_args=$(cibuild__build_get_build_args) \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        container_file=$(cibuild_core_container_file) \
        platform_name cache_args

  cibuild_log_info "build image with kaniko"

  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_name=$(echo "${platform}" | tr '/' '-')
    . "${CIBUILD_LIB_PATH}/build_args.sh"
    if [ "${build_use_cache}" = "0" ]; then
      cache_args="--cache=false"
    else
      cache_args="--cache=true --cache-repo=${target_image}-cache:${build_tag}-${platform_name}"
    fi

    if ! /kaniko/executor \
      --context dir:///repo/ \
      --dockerfile Dockerfile \
      --snapshot-mode redo \
      --destination "${target_image}:${build_tag}-${platform_name}" \
      ${cache_args} \
      --custom-platform $platform \
      --build-arg TARGETARCH="${platform##*/}" \
      ${build_args} \
      ${build_opts} \
      "$@"; then
      cibuild_main_err "kaniko build failed for ${platform}"
    fi

    cibuild__build_post_platform \
      "${platform}" "${platform_name}" "${target_image}" "${build_tag}" "kaniko" "" ""
  done
}

cibuild__build_image_nix() {
  local platforms platform \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_native=$(cibuild_env_get 'build_native') \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        nix_flake_attr_override=$(cibuild_env_get 'nix_flake_attr') \
        nix_flake_attr \
        nix_cache_url=$(cibuild_env_get 'nix_cache_url') \
        nix_sandbox=$(cibuild_env_get 'nix_sandbox') \
        platform_name nix_system nix_conf_dir nix_sandbox_val nix_opts

  cibuild_log_info "build image with nix"

  if [ ! -f "flake.lock" ]; then
    cibuild_log_info "flake.lock not found — running nix flake update"
    nix flake update --extra-experimental-features "nix-command flakes" || \
      cibuild_main_err "nix flake update failed"
  fi

  if [ -n "${nix_sandbox:-}" ]; then
    nix_sandbox_val="${nix_sandbox}"
  elif [ -n "${ROOTLESSKIT_PID:-}" ]; then
    nix_sandbox_val="true"
  else
    nix_sandbox_val="false"
  fi
  cibuild_log_info "nix sandbox: ${nix_sandbox_val}"

  nix_conf_dir="${HOME}/.config/nix"
  mkdir -p "${nix_conf_dir}"
  cat > "${nix_conf_dir}/nix.conf" <<EOF
experimental-features = nix-command flakes
sandbox = ${nix_sandbox_val}
build-users-group =
EOF

  if [ -n "${nix_cache_url:-}" ]; then
    printf 'substituters = https://cache.nixos.org %s\n' "${nix_cache_url}" >> "${nix_conf_dir}/nix.conf"
    printf 'trusted-substituters = https://cache.nixos.org %s\n' "${nix_cache_url}" >> "${nix_conf_dir}/nix.conf"
  fi

  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(printf '%s\n' "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_name=$(printf '%s\n' "${platform}" | tr '/' '-')

    case "${platform}" in
      linux/amd64) nix_system="x86_64-linux";  _nix_arch="amd64" ;;
      linux/arm64) nix_system="aarch64-linux";  _nix_arch="arm64" ;;
      *) cibuild_main_err "nix backend: unsupported platform ${platform}" ;;
    esac

    nix_flake_attr="${nix_flake_attr_override:-${build_tag}-${_nix_arch}}"
    [ "${build_use_cache}" = "0" ] && nix_opts="--option substitute false" || nix_opts=""

    cibuild_log_info "nix build .#${nix_flake_attr} for ${nix_system}"

    if ! nix build ".#\"${nix_flake_attr}\"" \
      --system "${nix_system}" ${nix_opts} --no-link --print-out-paths -L; then
      cibuild_main_err "nix build failed for ${nix_system}"
    fi

    nix_result=$(nix build ".#\"${nix_flake_attr}\"" \
      --system "${nix_system}" ${nix_opts} --no-link --print-out-paths 2>/dev/null)

    cibuild_log_info "pushing ${target_image}:${build_tag}-${platform_name}"
    if ! regctl image import "${target_image}:${build_tag}-${platform_name}" "${nix_result}"; then
      cibuild_main_err "regctl image import failed for ${platform_name}"
    fi

    # --- SBOM via bombon ---
    local sbom_digest="" vuln_digest=""
    local nix_sbom_attr="${nix_flake_attr}-sbom"
    cibuild_log_info "nix build .#${nix_sbom_attr} (SBOM via bombon)"

    nix_sbom_result=$(nix build ".#\"${nix_sbom_attr}\"" \
      --system "${nix_system}" ${nix_opts} --no-link --print-out-paths 2>/dev/null) || {
      cibuild_log_info "SBOM flake attr not found — skipping (non-fatal)"
      nix_sbom_result=""
    }

    if [ -n "${nix_sbom_result:-}" ]; then
      local sbom_file=""
      [ -f "${nix_sbom_result}" ]               && sbom_file="${nix_sbom_result}"
      [ -f "${nix_sbom_result}/sbom.cdx.json" ] && sbom_file="${nix_sbom_result}/sbom.cdx.json"

      if [ -f "${sbom_file}" ]; then
        cibuild_log_info "pushing SBOM for ${platform_name}"
        sbom_digest=$(regctl artifact put \
          --artifact-type "application/vnd.cyclonedx+json" \
          --subject "${target_image}:${build_tag}-${platform_name}" \
          --format '{{.Manifest.GetDescriptor.Digest}}' \
          < "${sbom_file}" 2>/dev/null) || { cibuild_log_err "SBOM push failed (non-fatal)"; sbom_digest=""; }
        cibuild_log_info "SBOM pushed, digest: ${sbom_digest:-n/a}"
      fi
    fi

    # --- Vuln report via vulnxscan ---
    nix_php_result=$(nix build ".#\"${nix_flake_attr}-php\"" \
      --system "${nix_system}" ${nix_opts} --no-link --print-out-paths 2>/dev/null) || {
      cibuild_log_err "php store path not found — skipping vulnxscan (non-fatal)"
      nix_php_result=""
    }

    if [ -n "${nix_php_result:-}" ]; then
      local vuln_tmp
      vuln_tmp=$(mktemp -d)
      export XDG_CACHE_HOME="${vuln_tmp}/.cache"
      local vuln_file="${vuln_tmp}/vulnreport.json"

      nix run "github:tiiuae/sbomnix#vulnxscan" \
        --extra-experimental-features "nix-command flakes" \
        -- "${nix_php_result}" --out "${vuln_file}" 2>/dev/null || \
        cibuild_log_err "vulnxscan failed (non-fatal)"

      if [ -f "${vuln_file}" ] && [ -s "${vuln_file}" ]; then
        vuln_digest=$(regctl artifact put \
          --artifact-type "application/vnd.sbomnix.vulnreport+json" \
          --subject "${target_image}:${build_tag}-${platform_name}" \
          --format '{{.Manifest.GetDescriptor.Digest}}' \
          < "${vuln_file}" 2>/dev/null) || { cibuild_log_err "vulnreport push failed (non-fatal)"; vuln_digest=""; }
        cibuild_log_info "vulnreport pushed, digest: ${vuln_digest:-n/a}"
      fi
      rm -rf "${vuln_tmp}"
    fi

    # nix: has sbom_digest + vuln_digest from build
    cibuild__build_post_platform \
      "${platform}" "${platform_name}" "${target_image}" "${build_tag}" \
      "nix" "${sbom_digest}" "${vuln_digest}"
  done
}

# =============================================================================
# BUILD RUN ENTRYPOINT
# =============================================================================

cibuild_build_run() {
  local build_enabled=$(cibuild_env_get 'build_enabled') \
        build_client=$(cibuild_env_get 'build_client') \
        signature=$(cibuild_env_get 'build_cosign_signature')
        
  if [ "${build_enabled:?}" != "1" ]; then
    cibuild_log_info "build run skipped"
    return
  fi

  if [ "${signature:-1}" = "1" ]; then
    cibuild_check_signing_env
  fi

  if ! cibuild_core_run_script build pre; then
    exit 1
  fi

  case "${build_client}" in
    buildx)
      if ! cibuild__build_detect_docker; then
        cibuild_main_err "buildx requires available dockerd"
      fi
      cibuild__build_image_buildx
      ;;
    buildctl)
      cibuild__build_image_buildctl
      ;;
    kaniko)
      cibuild__build_image_kaniko
      ;;
    nix)
      cibuild__build_image_nix
      ;;
    *)
      cibuild_main_err "build_client ${build_client} not supported"
      ;;
  esac

  if ! cibuild_core_run_script build post; then
    exit 1
  fi
}
#!/bin/sh
# Package cibuild/core

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_CORE_LOADED-}" ] && return
_CIBUILD_CORE_LOADED=1

# string
_CIBUILD_CORE_CONTAINER_FILE=""

# string
_CIBUILD_CORE_BASE_REGISTRY=""
# string
_CIBUILD_CORE_BASE_IMAGE_PATH=""
# string
_CIBUILD_CORE_BASE_TAG=""
# string
_CIBUILD_PUBKEY_FILE="/tmp/cibuild_cosign.pub"
# string
_CIBUILD_PRIVKEY_FILE="/tmp/cibuild_cosign.key"

cibuild_core_mask() { printf '%s\n' "$1" | sed 's/./*/g'; }

cibuild_core_is_secret_key() {
  case "$1" in
    *_pass|*_password|*_key|*_service_account)  return 0 ;;
    *) return 1 ;;
  esac
}

cibuild_core_mask_kv_if_secret() {
  key="${1%%=*}"
  val="${1#*=}"

  if cibuild_core_is_secret_key "$key"; then
    printf '%s=%s\n' "$key" "$(cibuild_core_mask "$val")"
  else
    printf '%s=%s\n' "$key" "$val"
  fi
}

cibuild__core_get_base_image() {
  local build_client=$(cibuild_env_get 'build_client')

  _CIBUILD_CORE_CONTAINER_FILE=$(cibuild_env_get "container_file")

  if [ -z "$_CIBUILD_CORE_CONTAINER_FILE" ]; then
    for container_file_candidate in "Containerfile" "Dockerfile"; do
      cibuild_log_debug "check container_file_candidate: '$container_file_candidate'"
      if [ -f "${container_file_candidate}" ]; then
        _CIBUILD_CORE_CONTAINER_FILE="${container_file_candidate}"
        cibuild_log_debug "found container_file: '$_CIBUILD_CORE_CONTAINER_FILE'"
      fi
    done
  else
    cibuild_log_debug "container_file set through config: '$_CIBUILD_CORE_CONTAINER_FILE'"
  fi

  if ! [ -f "${_CIBUILD_CORE_CONTAINER_FILE}" ]; then
    # nix backend: flake.nix replaces Containerfile — no containerfile required
    if [ "${build_client}" = "nix" ] && [ -f "flake.nix" ]; then
      cibuild_log_info "no containerfile found — using flake.nix (nix backend)"
      _CIBUILD_CORE_CONTAINER_FILE="flake.nix"
      return 0
    fi
    cibuild_main_err "no containerfile found"
  fi

  # nix backend with flake.nix: skip FROM line parsing
  if [ "${build_client}" = "nix" ]; then
    cibuild_log_info "nix backend: flake.nix found — skipping FROM line parsing"
    return 0
  fi

  _CIBUILD_CORE_BASE_REGISTRY=$(cibuild_env_get "base_registry")
  _CIBUILD_CORE_BASE_IMAGE_PATH=$(cibuild_env_get "base_image_path")
  _CIBUILD_CORE_BASE_TAG=$(cibuild_env_get "base_tag")
  
  # in multistage you can define a base image for the update check, maybe its not the last "FROM" image layer
  if [ -n "${_CIBUILD_CORE_BASE_IMAGE_PATH}" ] && [ -n "${_CIBUILD_CORE_BASE_TAG}" ] && [ -n "${_CIBUILD_CORE_BASE_REGISTRY}" ]; then
    cibuild_log_debug "base_image is predefined (recommanded in multistage builds)"
  else
    cibuild_log_debug "Extract the last FROM line"
    local from_count=$(grep -cE '^FROM[[:space:]]+' "$_CIBUILD_CORE_CONTAINER_FILE")
    if [ "$from_count" != "1" ]; then
      cibuild_log_info "Multistage ${_CIBUILD_CORE_CONTAINER_FILE}: last FROM is used as base image"
    fi
    local from_line=$(grep -E '^FROM[[:space:]]+' "${_CIBUILD_CORE_CONTAINER_FILE}" | tail -n 1)
    if [ -z "$from_line" ]; then
        cibuild_main_err "No FROM line found"
    fi
    # FROM <image> [AS stage]
    # We take the second field, unless it starts with -- (Docker options)
    local image=$(printf "%s" "$from_line" | awk '{print $2}')

    # Handle cases like: FROM --platform=linux/amd64 imagename AS builder
    case "$image" in
      --*)
        image=$(printf "%s" "$from_line" | awk '{print $3}')
        ;;
    esac

    # -----------------------------------
    #  Normalize Docker image reference
    # -----------------------------------

    local tag="latest"

    # Extract tag
    case "$image" in
      *:*)
        tag=$(printf "%s" "$image" | awk -F':' '{print $NF}')
        local image_no_tag=$(printf "%s" "$image" | sed "s/:$tag\$//")
        ;;
      *)
        local image_no_tag="$image"
        ;;
    esac

    # Detect registry:
    # Docker rule: the first component is a registry if it contains '.' or ':'
    local first_part=$(printf "%s" "$image_no_tag" | cut -d'/' -f1)

    case "$first_part" in
      *.*|*:* )
          local registry="$first_part"
          local remainder=$(printf "%s" "$image_no_tag" | cut -d'/' -f2-)
          ;;
      *)
          local registry="docker.io"
          local remainder="$image_no_tag"
          ;;
    esac

    # Add "library/" if there is no slash (Docker Hub implicit namespace)
    case "$remainder" in
      */*) local final_path="$remainder" ;;
      *)   local final_path="library/$remainder" ;;
    esac

    _CIBUILD_CORE_BASE_REGISTRY="${registry}"
    _CIBUILD_CORE_BASE_IMAGE_PATH="${final_path}"
    _CIBUILD_CORE_BASE_TAG="${tag}"
  fi
}

cibuild__core_get_auth_url_for_registry() {
  # set registry specific auth urls
  local reg="$1"
  case "$reg" in
    docker.io)
      printf '%s\n' "https://index.docker.io/v1/"
      return
      ;;
    localregistry.example.com\:5000)
      printf '%s\n' "https://localregistry.example.com:5000"
      return
      ;;
    *)
      printf '%s\n' "$reg"
      return
      ;;
  esac
}

cibuild__core_create_docker_auth_config() {

  local base_reg \
        base_user \
        base_pass \
        base_registry=$(cibuild_core_base_registry) \
        base_registry_auth=$(cibuild_ci_base_registry_auth) \
        base_registry_user=$(cibuild_ci_base_registry_user) \
        base_registry_pass=$(cibuild_ci_base_registry_pass) \
        target_reg \
        target_user \
        target_pass \
        target_registry=$(cibuild_ci_target_registry) \
        target_registry_auth=$(cibuild_ci_target_registry_auth) \
        target_registry_user=$(cibuild_ci_target_registry_user) \
        target_registry_pass=$(cibuild_ci_target_registry_pass) \
        ci_reg \
        ci_user \
        ci_pass \
        ci_registry=$(cibuild_ci_registry) \
        ci_registry_auth=$(cibuild_ci_registry_auth) \
        ci_registry_user=$(cibuild_ci_registry_user) \
        ci_registry_pass=$(cibuild_ci_registry_pass)

  # base_registry is not required for the nix backend — no FROM line, no base image
  local build_client_check=$(cibuild_env_get 'build_client')
  [ -z "$base_registry" ] && [ "${build_client_check}" != "nix" ] && cibuild_main_err 'missing base_registry'
  [ -z "$target_registry" ] && cibuild_main_err 'missing target_registry'
  [ -z "$ci_registry" ] && cibuild_main_err 'missing ci_registry'

  cibuild_log_dump "base_registry: $base_registry"
  cibuild_log_dump "base_registry_user: $base_registry_user"
  cibuild_log_dump "base_registry_pass: $(cibuild_core_mask $base_registry_pass)"
  cibuild_log_dump "target_registry: $target_registry"
  cibuild_log_dump "target_registry_user: $target_registry_user"
  cibuild_log_dump "target_registry_pass: $(cibuild_core_mask $target_registry_pass)"
  cibuild_log_dump "ci_registry: $ci_registry"
  cibuild_log_dump "ci_registry_user: $ci_registry_user"
  cibuild_log_dump "ci_registry_pass: $(cibuild_core_mask $ci_registry_pass)"
  cibuild_log_dump "github_token: $GITHUB_TOKEN"
  
  if [ ! -d "${HOME}/.docker" ]; then
    cibuild_log_debug "create ~/.docker directory"
    mkdir "${HOME}/.docker"
  fi
  
  cp "${CIBUILD_LIB_PATH}/res/docker.config.json" "${HOME}/.docker/config.json"
  
  # only add entry if not exists
  if ! grep -q "${target_registry}" "${HOME}/.docker/config.json"; then
    cibuild_log_debug "add ${target_registry}"
    target_reg=$(cibuild__core_get_auth_url_for_registry ${target_registry})
    if [ "${target_registry_auth}" = "1" ]; then
      target_user=${target_registry_user}
      target_pass=${target_registry_pass}
    fi
  else
    cibuild_log_debug "${target_registry} already exists: skip entry"
    target_reg="skiptargetregistry.local.com"
  fi
  
  sed -i "s|TARGET_REG|$target_reg|g" ${HOME}/.docker/config.json
  sed -i "s|TARGET_USER|$target_user|g" ${HOME}/.docker/config.json
  sed -i "s|TARGET_PASS|$target_pass|g" ${HOME}/.docker/config.json
  
  if [ -z "${base_registry}" ]; then
    cibuild_log_debug "base_registry empty — skipping (nix backend)"
    base_reg="skipbaseregistry.local.com"
  elif ! grep -q "${base_registry}" "${HOME}/.docker/config.json"; then
    cibuild_log_debug "add ${base_registry}"
    base_reg=$(cibuild__core_get_auth_url_for_registry ${base_registry})
    if [ "${base_registry_auth}" = "1" ]; then
      base_user=${base_registry_user}
      base_pass=${base_registry_pass}
    fi
  else
    cibuild_log_debug "${base_registry} already exists: skip entry"
    base_reg="skipbaseregistry.local.com"
  fi

  sed -i "s|BASE_REG|$base_reg|g" ${HOME}/.docker/config.json
  sed -i "s|BASE_USER|$base_user|g" ${HOME}/.docker/config.json
  sed -i "s|BASE_PASS|$base_pass|g" ${HOME}/.docker/config.json
  
  if ! grep -q "${ci_registry}" "${HOME}/.docker/config.json"; then
    cibuild_log_debug "add ${ci_registry}"
    ci_reg=$(cibuild__core_get_auth_url_for_registry ${ci_registry})
    if [ "${ci_registry_auth}" = "1" ]; then
      ci_user=${ci_registry_user}
      ci_pass=${ci_registry_pass}
    fi
  else
    cibuild_log_debug "${ci_registry} already exists: skip entry"
    ci_reg="skipciregistry.local.com"
  fi

  sed -i "s|CI_REG|$ci_reg|g" ${HOME}/.docker/config.json
  sed -i "s|CI_USER|$ci_user|g" ${HOME}/.docker/config.json
  sed -i "s|CI_PASS|$ci_pass|g" ${HOME}/.docker/config.json
  
  #cat ${HOME}/.docker/config.json
}

cibuild__core_create_regctl_auth_config() {
  
  local logged_in=" "\
        reg

  for registry in base_registry target_registry release_registry ci_registry; do
    case "$registry" in
      base_registry)
        local reg=$(cibuild_core_base_registry)
        local auth=$(cibuild_ci_base_registry_auth)
        local user=$(cibuild_ci_base_registry_user)
        local pass=$(cibuild_ci_base_registry_pass)
      ;;
      target_registry)
        local reg=$(cibuild_ci_target_registry)
        local auth=$(cibuild_ci_target_registry_auth)
        local user=$(cibuild_ci_target_registry_user)
        local pass=$(cibuild_ci_target_registry_pass)
      ;;
      ci_registry)
        local reg=$(cibuild_ci_registry)
        local auth=$(cibuild_ci_registry_auth)
        local user=$(cibuild_ci_registry_user)
        local pass=$(cibuild_ci_registry_pass)
      ;;
    esac
    if case " $logged_in " in *" $reg "*) true ;; *) false ;; esac; then
      cibuild_log_debug "already logged in: $reg"
    else
      if [ "$auth" = "1" ]; then
        regctl registry set "$reg" --hostname "$reg" --skip-check
        regctl registry login "$reg" --user "$user" --pass "$pass" --skip-check
        logged_in="$logged_in $reg"
      fi
    fi
  done
  regctl registry config
  #cat ${HOME}/.regctl/config.json
}

# public getters

cibuild_core_container_file() { printf '%s\n' "$_CIBUILD_CORE_CONTAINER_FILE"; }
# from Dockerfile|Containerfile
cibuild_core_base_registry() { printf '%s\n' "$_CIBUILD_CORE_BASE_REGISTRY"; }
cibuild_core_base_image_path() { printf '%s\n' "$_CIBUILD_CORE_BASE_IMAGE_PATH"; }
cibuild_core_base_tag() { printf '%s\n' "$_CIBUILD_CORE_BASE_TAG"; }
cibuild_core_base_image() { printf '%s\n' "${_CIBUILD_CORE_BASE_REGISTRY}/${_CIBUILD_CORE_BASE_IMAGE_PATH}"; }
cibuild_core_base_image_full() { printf '%s\n' "${_CIBUILD_CORE_BASE_REGISTRY}/${_CIBUILD_CORE_BASE_IMAGE_PATH}:${_CIBUILD_CORE_BASE_TAG}"; }

cibuild_core_get_platform_name() {
  local arch platform_name
  arch=$(uname -m)
  platform_name="linux-amd64"

  case "$arch" in
      x86_64)
          platform_name="linux-amd64"
          ;;
      aarch64 | arm64)
          platform_name="linux-arm64"
          ;;
      *)
          log 0 "unknown architecture: $arch"
          exit 1
          ;;
  esac
  printf '%s\n' "$platform_name"
}

cibuild_core_get_platform_arch() {
  local arch platform_arch
  arch=$(uname -m)
  platform_arch="linux/amd64"

  case "$arch" in
      x86_64)
          platform_arch="linux/amd64"
          ;;
      aarch64 | arm64)
          platform_arch="linux/arm64"
          ;;
      *)
          log 0 "unknown architecture: $arch"
          exit 1
          ;;
  esac
  printf '%s\n' "$platform_arch"
}

cibuild_core_run_script() {
  local run=$1
  local stage=$2
  local script=$(cibuild_env_get "${run}_${stage}_script")
  if [ -n "${script}" ]; then
    if [ -d "/tmp/cibuilder.locked" ]; then
      cibuild_log_err "cibuilder.locked: script execution is not allowed"
      return 0
    fi
    if [ -f "${script}" ]; then
      if [ ! -x "${script}" ]; then
        cibuild_log_err "${script} not executable"
        return 1
      fi
      cibuild_log_info "running ${script}"
      if ! . "./${script}"; then
        cibuild_log_err "failed ${script}"
      fi
    else
      cibuild_log_err "${script} not exists"
      return 1
    fi
  fi
  return 0
}

cibuild_function_exists() {
  type "$1" > /dev/null 2>&1
}

cibuild_is_ghcr() {
  case "$1" in
    ghcr.io/*) return 0 ;;
    *) return 1 ;;
  esac
}

cibuild_is_docker() {
  case "$1" in
    docker.io/*) return 0 ;;
    *) return 1 ;;
  esac
}

# =============================================================================
# COSIGN — shared signature cleanup helpers
# =============================================================================

# Delete cosign signature referrers for a given digest.
# Covers:
#   new bundle format (OCI 1.1): ArtifactType=application/vnd.oci.empty.v1+json
#                                 annotation dev.sigstore.bundle.content = dsse-envelope | message-signature
#   old bundle format:           ArtifactType=application/vnd.dev.cosign.artifact.sig.v1+json
cibuild_delete_cosign_sig_referrers() {
  local target_image=$1 image_digest=$2 artifact_type bundle_content

  regctl -v error artifact list "$target_image@$image_digest" \
    --format '{{range .Descriptors}}{{.ArtifactType}}{{"|"}}{{.Digest}}{{"\n"}}{{end}}' 2>/dev/null \
    | while IFS="|" read -r artifact_type ref_digest; do
        [ -z "$ref_digest" ] && continue
        case "${artifact_type}" in
          "application/vnd.dev.cosign.artifact.sig.v1+json")
            cibuild_log_debug "delete old-format cosign sig: ${ref_digest}"
            regctl -v error manifest delete "${target_image}@${ref_digest}" 2>/dev/null || true
            ;;
          "application/vnd.oci.empty.v1+json")
            bundle_content=$(regctl -v error manifest get "${target_image}@${ref_digest}" \
              --format '{{ index .Annotations "dev.sigstore.bundle.content" }}' 2>/dev/null)
            case "${bundle_content}" in
              dsse-envelope|message-signature)
                cibuild_log_debug "delete new-format cosign sig (${bundle_content}): ${ref_digest}"
                regctl -v error manifest delete "${target_image}@${ref_digest}" 2>/dev/null || true
                ;;
            esac
            ;;
        esac
      done
}

# Remove existing cosign signatures for a platform image digest before re-signing.
# Covers both storage formats:
#   legacy tag-based:  sha256-DIGEST / sha256-DIGEST.sig  → cibuild_ci_cleanup_signatures
#   OCI 1.1 referrer:  application/vnd.oci.empty.v1+json  → cibuild_delete_cosign_sig_referrers
# Usage: cibuild_remove_signatures <target_image> <image_digest>
cibuild_remove_signatures() {
  local target_image="$1" image_digest="$2"

  cibuild_log_debug "removing existing signatures for ${target_image}@${image_digest}"

  # legacy tag-based signatures (sha256-DIGEST / sha256-DIGEST.sig)
  cibuild_ci_cleanup_signatures "${target_image}" "${image_digest}"

  # OCI 1.1 referrer signatures (new bundle format)
  cibuild_delete_cosign_sig_referrers "${target_image}" "${image_digest}"
}

# =============================================================================
# COSIGN — shared sign (used by build and release run)
#
# Usage: cibuild_sign \
#   <image_ref> \
#   <signing_mode> \
#   <signing_config> \
#   <new_bundle_format> \
#   <annotions_path> \
#   <signing_recursive> \
#   <max_retries>
cibuild_sign() {
  local image_ref="$1" \
    signing_mode="$2" \
    signing_config="$3" \
    new_bundle_format="$4" \
    annotations_path="${5}" \
    signing_recursive="${6}" \
    max_retries=$(cibuild_env_get 'cosign_signing_max_retries') \
    retry_interval=$(cibuild_env_get 'cosign_signing_retry_interval') \
    try=1 \
    success=0

  export COSIGN_PASSWORD=""
  export COSIGN_NON_INTERACTIVE=1

  cibuild_log_debug "cibuild_sign: \
    image_ref=${image_ref} \
    signing_mode=${signing_mode} \
    signing_config=${signing_config} \
    new_bundle_format=${new_bundle_format} \
    annotations_path=${annotations_path} \
    signing_recursive=${signing_recursive}"

  . "${annotations_path}"

  local new_bundle_format_arg=""
  if [ "${new_bundle_format}" = "0" ] && [ "${signing_mode}" = "key" ]; then
    new_bundle_format_arg="--new-bundle-format=false"
  else
    new_bundle_format_arg="--new-bundle-format=true"
  fi

  cosign_signing_tmp=$(mktemp)

  if [ -z "${signing_config}" ]; then
    if [ "${signing_mode}" = "key" ]; then
      if [ "${new_bundle_format}" = "0" ]; then
        cibuild_log_debug "set --use-signing-config=false"
        signing_config_arg="--use-signing-config=false"
      else
        cibuild_log_debug "no signing config — create empty signing config for key mode (no Rekor/Fulcio)"
        cosign signing-config create \
          --no-default-rekor \
          --no-default-fulcio \
          --no-default-oidc \
          --no-default-tsa \
          --out "${cosign_signing_tmp}"
        signing_config_arg="--signing-config=${cosign_signing_tmp}"
      fi
    else
      cibuild_log_debug "no signing config — keep cosign defaults for keyless mode"
      signing_config_arg=""
    fi
  else
    cibuild_log_debug "using signing_config"
    printf '%s\n' "$signing_config" | base64 -d > "${cosign_signing_tmp}"
    signing_config_arg="--signing-config=${cosign_signing_tmp}"
  fi

  local recursive_arg=""
  [ "${signing_recursive}" = "1" ] && recursive_arg="--recursive"

  local key_arg=""
  [ "${signing_mode}" = "key" ] && key_arg="--key=${_CIBUILD_PRIVKEY_FILE} --tlog-upload=false"
 
  while [ "$try" -le "$max_retries" ]; do
    if cosign sign --yes \
      $key_arg \
      "$@" \
      ${recursive_arg} \
      ${signing_config_arg} \
      ${new_bundle_format_arg} \
      "${image_ref}"; then
      success=1
      break
    fi
    cibuild_log_debug "cosign sign failed (attempt ${try}/${max_retries})"
    try=$((try + 1))
    sleep ${retry_interval}
  done

  if [ "$success" -ne 1 ]; then
    cibuild_log_err "cosign sign failed after ${max_retries} attempts: ${image_ref}"
    return 1
  fi
  
  cibuild_log_info "signed: ${image_ref}"
}

# =============================================================================
# COSIGN — shared verify (used by build and release run)
#
# Usage: cibuild_verify \
#   <image_ref> \
#   <signing_mode> \
#   <new_bundle_format> \
#   <max_retries>
cibuild_verify() {
  local image_ref="$1" \
    signing_mode="$2" \
    new_bundle_format="$3" \
    max_retries=$(cibuild_env_get 'cosign_verify_max_retries') \
    retry_interval=$(cibuild_env_get 'cosign_verify_retry_interval') \
    try=1 \
    success=0

  cibuild_log_debug "cibuild_verify: \
    image_ref=${image_ref} \
    signing_mode=${signing_mode} \
    new_bundle_format=${new_bundle_format}"
    
  local verify_args=""
  if [ "${signing_mode}" = "keyless" ]; then
    if ! verify_args=$(cibuild_ci_get_cosign_keyless_verify_args); then
      return 1
    fi
  else
      verify_args="--key=${_CIBUILD_PUBKEY_FILE} --private-infrastructure"
  fi
  
  try=1
  success=0
  while [ "$try" -le "$max_retries" ]; do
    if cosign verify \
      $verify_args \
      ${new_bundle_format_arg} \
      "${image_ref}"; then
      success=1
      break
    fi
    cibuild_log_debug "cosign verify failed (attempt ${try}/${max_retries})"
    try=$((try + 1))
    sleep ${retry_interval}
  done
  if [ "$success" -ne 1 ]; then
    cibuild_log_err "cosign verify failed after ${max_retries} attempts: ${image_ref}"
    return 1
  fi

  cibuild_log_info "verified: ${image_ref}"
}

cibuild_verify_all_platforms() {
  local target_image=$(cibuild_ci_target_image) \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_cosign_signature=$(cibuild_env_get 'build_cosign_signature') \
        build_cosign_signing_mode=$(cibuild_env_get 'build_cosign_signing_mode') \
        build_cosign_new_bundle_format=$(cibuild_env_get 'build_cosign_new_bundle_format')

  local platforms lock_digest="" image_ref=""
  platforms=$(echo "$build_platforms" | tr ',' ' ')
  
  # --- verify all platform images
  if [ "${build_cosign_signature:-1}" = "1" ]; then
    # --- verify platform digests ---
    cibuild_log_info "verifying platform signatures from artifact-lock files"
    cibuild_cosign_prepare_pubkey
    for platform in $platforms; do
      platform_name=$(echo "$platform" | tr '/' '-')
      lock_digest=$(cibuild_ci_lock_get "${platform_name}" "image_digest") || continue
      # use digest reference — independent of tag state
      image_ref="${target_image}@${lock_digest}"
      if ! cibuild_verify "${image_ref}" \
                "${build_cosign_signing_mode}" \
                "${build_cosign_new_bundle_format}"; then
        cibuild_main_err "cibuild_verify failed: ${image_ref}"
      fi
    done
    cibuild_log_info "all platform signatures verified"
  else
    cibuild_info "platform images are not signed, nothing to do"
  fi
}

# =============================================================================
# COSIGN — shared public key preparation (used by build and release run)
#
# Priority:
#   1. CIBUILD_COSIGN_PUBLIC_KEY env var (base64) → /tmp/cibuild_cosign.pub
#   2. cosign.pub file in repo root               → /tmp/cibuild_cosign.pub
# =============================================================================

cibuild_cosign_prepare_pubkey() {
  local cosign_public_key
  cosign_public_key=$(cibuild_env_get 'cosign_public_key')

  if [ -n "${cosign_public_key:-}" ]; then
    cibuild_log_info "cosign pubkey: using CIBUILD_COSIGN_PUBLIC_KEY from environment"
    printf '%s\n' "${cosign_public_key}" | base64 -d > "${_CIBUILD_PUBKEY_FILE}"
    chmod 600 "${_CIBUILD_PUBKEY_FILE}"
  elif [ -f "cosign.pub" ]; then
    cibuild_log_info "cosign pubkey: using cosign.pub from repo root"
    cp cosign.pub "${_CIBUILD_PUBKEY_FILE}"
  else
    cibuild_main_err "cosign public key not found — set CIBUILD_COSIGN_PUBLIC_KEY or commit cosign.pub to repo root"
  fi
}

# =============================================================================
# COSIGN — shared private key preparation (used by build and release run)
#
# CIBUILD_COSIGN_PRIVATE_KEY env var (base64) → /tmp/cibuild_cosign.key
# =============================================================================

cibuild_cosign_prepare_privkey() {
  local cosign_private_key
  cosign_private_key=$(cibuild_env_get 'cosign_private_key')

  if [ -n "${cosign_private_key:-}" ]; then
    cibuild_log_info "cosign privkey: using CIBUILD_COSIGN_PRIVATE_KEY from environment"
    printf '%s\n' "${cosign_private_key}" | base64 -d > "${_CIBUILD_PRIVKEY_FILE}"
    chmod 600 "${_CIBUILD_PRIVKEY_FILE}"
  else
    cibuild_main_err "cosign private key not found — set CIBUILD_COSIGN_PRIVATE_KEY"
  fi
}

cibuild_check_signing_env() {
  local signature=$(cibuild_env_get 'build_cosign_signature')
  if [ "${signature:-1}" = "1" ]; then
    cibuild_cosign_prepare_privkey
    cibuild_cosign_prepare_pubkey
  fi
}

cibuild_base_init() {
  cibuild_env_apply_vars
  cibuild_log_init
}

cibuild_core_init() {
  [ "${_CIBUILD_CORE_INIT_DONE:-}" = "1" ] && return
  _CIBUILD_CORE_INIT_DONE=1

  cibuild_env_init
  cibuild_log_init
  cibuild_env_get_vars | while IFS= read -r kv; do
    if [ -n "$kv" ]; then
      line="$(cibuild_core_mask_kv_if_secret "$kv")"
      cibuild_log_dump "$line"
    fi
  done
  # from Dockerfile|Containerfile (skipped for nix backend)
  cibuild__core_get_base_image
  if [ "$(cibuild_env_get build_client)" != "nix" ]; then
    cibuild_log_debug "base image: $(cibuild_core_base_image_full)"
  else
    cibuild_log_debug "base image: n/a (nix backend — defined in flake.nix)"
  fi
  # from ci adapter
  cibuild_log_debug "target image: $(cibuild_ci_target_image_full)"
  # create auth files
  cibuild__core_create_docker_auth_config
  cibuild__core_create_regctl_auth_config
  # early check of signing env
  cibuild_check_signing_env
  # artifact-lock init
  cibuild_function_exists "cibuild_ci_lock_init" && cibuild_ci_lock_init
}
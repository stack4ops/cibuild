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
    cibuild_main_err "no containerfile found"
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

  [ -z "$base_registry" ] && cibuild_main_err 'missing base_registry'
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
  
  if ! grep -q "${base_registry}" "${HOME}/.docker/config.json"; then
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
  
  local logged_in=" "  reg

  for registry in base_registry target_registry ci_registry; do
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

#public functions

# cibuild_process_suffix_prefix_tag() {
#   local tag="$1"
#   local add_branch_name_to_tags=$(cibuild_env_get 'add_branch_name_to_tags') \
#         add_commit_sha_to_tags=$(cibuild_env_get 'add_commit_sha_to_tags') \
#         commit=$(cibuild_ci_commit) \
#         ref=$(cibuild_ci_ref)

#   if [ "${add_branch_name_to_tags:-}" = "prefix" ]; then
#     tag="${ref}-${tag}"
#   fi
#   if [ "${add_branch_name_to_tags:-}" = "suffix" ]; then
#     tag="${tag}-${ref}"
#   fi

#   if [ "${add_commit_sha_to_tags:-}" = "prefix" ]; then
#     tag="${commit}-${tag}"
#   fi
#   if [ "${add_commit_sha_to_tags:-}" = "suffix" ]; then
#     tag="${tag}-${commit}"
#   fi
#   printf '%s\n' "$tag"
# }

cibuild_core_get_platform_tag() {
  local arch platform_tag
  arch=$(uname -m)
  platform_tag="linux-amd64"

  case "$arch" in
      x86_64)
          platform_tag="linux-amd64"
          ;;
      aarch64 | arm64)
          platform_tag="linux-arm64"
          ;;
      *)
          log 0 "unknown architecture: $arch"
          exit 1
          ;;
  esac
  printf '%s\n' "$platform_tag"
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
  # from Dockerfile|Containerfile
  cibuild__core_get_base_image
  cibuild_log_debug "base image: $(cibuild_core_base_image_full)"
  # from ci adapter
  cibuild_log_debug "target image: $(cibuild_ci_target_image_full)"
  # create auth files
  cibuild__core_create_docker_auth_config
  cibuild__core_create_regctl_auth_config 
}
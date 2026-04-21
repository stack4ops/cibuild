#!/bin/sh
# Package cibuild/build

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_BUILD_LOADED-}" ] && return
_CIBUILD_BUILD_LOADED=1

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
    dockercontainer)
      create_dockercontainer_builder
      ;;
    remote)
      create_remote_builder
      ;;
    kubernetes)
      create_kubernetes_builder
      ;;
    *)
      cibuild_main_err "buildx_driver $build_buildx_driver not supported"
      ;;
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

  if [ -z "${build_buildkit_client_ca}" ]; then
    cibuild_main_err "CIBUILD_BUILD_BUILDKIT_CLIENT_CA env var must not be empty"
  fi
  
  if [ -z "${build_buildkit_client_cert}" ]; then
    cibuild_main_err "CIBUILD_BUILD_BUILDKIT_CLIENT_CERT env var must not be empty"
  fi

  if [ -z "${build_buildkit_client_key}" ]; then
    cibuild_main_err "CIBUILD_BUILD_BUILDKIT_CLIENT_KEY env var must not be empty"
  fi
  printf '%s\n' "$build_buildkit_client_ca" | base64 -d > /tmp/ca.pem
  printf '%s\n' "$build_buildkit_client_cert" | base64 -d > /tmp/cert.pem
  printf '%s\n' "$build_buildkit_client_key" | base64 -d > /tmp/key.pem
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

  if [ "${build_client}" = "buildctl" ]; then
    printf '%s\n' "--export-cache"
  else
    printf '%s\n' "--cache-to"
  fi
}

cibuild__build_get_cache_from_opt() {
  local build_client=$(cibuild_env_get 'build_client')

  if [ "${build_client}" = "buildctl" ]; then
    printf '%s\n' "--import-cache"
  else
    printf '%s\n' "--cache-from"
  fi
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
    "")
      printf '%s\n' ""
      return 0
      ;;
    ci_registry)
      cache_image=$(cibuild_ci_image)
      ;;
    target_registry)
      cache_image=$(cibuild_ci_target_image)
      ;;
    *)
      printf '%s\n' "$(cibuild__build_get_cache_from_opt) ${build_import_cache}"
      return 0
      ;;
    esac

    case "$build_cache_mode" in
      repo)
        printf '%s\n' "$(cibuild__build_get_cache_from_opt) type=registry,ref=${cache_image}-cache:${build_tag}-${arch}"    
      ;;
      tag)
        printf '%s\n' "$(cibuild__build_get_cache_from_opt) type=registry,ref=${cache_image}:${build_tag}-${arch}-cache"
      ;;
      *)
        cibuild_log_err "unsupported build_cache_mode $build_cache_mode"
        exit 1
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
    "")
      printf '%s\n' ""
      return 0
      ;;
    ci_registry)
      cache_image=$(cibuild_ci_image)
      ;;
    target_registry)
      cache_image=$(cibuild_ci_target_image)
      ;;
    *)
      printf '%s\n' "$(cibuild__build_get_cache_to_opt) ${build_export_cache}"
      return 0
      ;;
  esac

  case "$build_cache_mode" in
    repo)
      printf '%s\n' "$(cibuild__build_get_cache_to_opt) type=registry,ref=${cache_image}-cache:${build_tag}-${arch},mode=${cache_mode}"
      ;;
    tag)
      printf '%s\n' "$(cibuild__build_get_cache_to_opt) type=registry,ref=${cache_image}:${build_tag}-${arch}-cache,mode=${cache_mode}"
      ;;
    *)
      cibuild_log_err "unsupported build_cache_mode $build_cache_mode"
      exit 1
      ;;
  esac
}



cibuild__build_get_provenance_args() {
  local build_provenance=$(cibuild_env_get 'build_provenance') \
        build_provenance_mode=$(cibuild_env_get 'build_provenance_mode') \
        build_client=$(cibuild_env_get 'build_client')

  # provenance only meaningful with buildkit-based clients
  # nix: tbd (ZenDIS alignment pending)
  # kaniko: no provenance support
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

cibuild__build_image_buildx() {
  local platforms \
        platform \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_native=$(cibuild_env_get 'build_native') \
        build_opts=$(cibuild_env_get 'build_opts') \
        build_args=$(cibuild__build_get_build_args) \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        build_set_ci_secrets=$(cibuild_env_get 'build_set_ci_secrets') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        container_file=$(cibuild_core_container_file) \
        platform_name \
        cache \
        provenance_args \
        no_cache

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
    cibuild_log_debug "platform_name: $platform_name"

    cache="$(cibuild__build_get_import_cache_args ${platform_name}) $(cibuild__build_get_export_cache_args ${platform_name})"
    cibuild_log_debug "cache: $cache"

    provenance_args="$(cibuild__build_get_provenance_args)"
    cibuild_log_debug "provenance_args: $provenance_args"

    cibuild_log_debug "build_args: $build_args"
    cibuild_log_debug "build_opts: $build_opts"
    
    . "${CIBUILD_LIB_PATH}/build_args.sh"

    if [ "${build_use_cache}" = "0" ]; then
      no_cache="--no-cache"
    else
      no_cache=""
    fi

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
  done
}

cibuild__build_image_buildctl() {
  local platforms \
        platform \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_native=$(cibuild_env_get 'build_native') \
        build_opts=$(cibuild_env_get 'build_opts') \
        build_args=$(cibuild__build_get_build_args) \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        build_set_ci_secrets=$(cibuild_env_get 'build_set_ci_secrets') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        container_file=$(cibuild_core_container_file) \
        platform_name \
        cache \
        provenance_args \
        no_cache \
        build_command
  
  local build_remote_buildkit=$(cibuild_env_get 'build_remote_buildkit') \
        build_buildkit_host=$(cibuild_env_get 'build_buildkit_host') \
        build_buildkit_tls=$(cibuild_env_get 'build_buildkit_tls')

  cibuild_log_info "build image with buildctl"

  if [ "${build_remote_buildkit:-}" = "1" ]; then
    cibuild_log_info "build image with remote buildctl"
  else
    cibuild_log_info "build image with embedded buildctl-daemonless.sh"
  fi
  
  if [ -z "${build_buildkit_host:-}" ]; then
    cibuild_main_err "CIBUILD_BUILDKIT_HOST env var must not be empty"
  fi

  if [ "${build_remote_buildkit:-}" = "1" ]; then
    if [ -z "${build_buildkit_host:-}" ]; then
      cibuild_main_err "buildkit_host BUILDKIT_HOST required on remote_buildkit=1"
    fi
    build_command="buildctl --addr ${build_buildkit_host}"
    if [ "${build_buildkit_tls:-1}" = "1" ]; then
      cibuild__build_create_cert_files
      build_command="$build_command --tlscert /tmp/cert.pem --tlskey /tmp/key.pem --tlscacert /tmp/ca.pem"
    fi
  else
    build_command="buildctl-daemonless.sh"
  fi
  
  # build oci image for each arch (Unfortunately docker references attestations in a (forced) image-index for each image)
  # in release run a clean oci multiarch image index is created for final tagging 
  # and an optional docker attestation manifest for ui
  
  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_name=$(echo "${platform}" | tr '/' '-')
    cibuild_log_debug "platform_name: $platform_name"

    cache="$(cibuild__build_get_import_cache_args ${platform_name}) $(cibuild__build_get_export_cache_args ${platform_name})"
    cibuild_log_debug "cache: $cache"

    provenance_args="$(cibuild__build_get_provenance_args)"
    cibuild_log_debug "provenance_args: $provenance_args"

    cibuild_log_debug "build_args: $build_args"
    cibuild_log_debug "build_opts: $build_opts"
    
    . "${CIBUILD_LIB_PATH}/build_args.sh"
    
    if [ "${build_use_cache}" = "0" ]; then
      no_cache="--no-cache"
    else
      no_cache=""
    fi

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
      cibuild_main_err "failed: $build_command"   
    fi
  done

}

cibuild__build_image_kaniko() {
  local platforms \
        platform \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_native=$(cibuild_env_get 'build_native') \
        build_opts=$(cibuild_env_get 'build_opts') \
        build_args=$(cibuild__build_get_build_args) \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        container_file=$(cibuild_core_container_file) \
        platform_name \
        cache_args
  
  cibuild_log_info "build image with kaniko"
  
  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_name=$(echo "${platform}" | tr '/' '-')
    cibuild_log_debug "platform_name: $platform_name"
    cibuild_log_debug "build_args: $build_args"
    cibuild_log_debug "build_opts: $build_opts"

    . "${CIBUILD_LIB_PATH}/build_args.sh"

    if [ "${build_use_cache}" = "0" ]; then
      cache_args="--cache=false"
    else
      cache_args="--cache=true --cache-repo=${target_image}-cache:${build_tag}-${platform_name}"
    fi
    
    cibuild_log_debug ${cache_args}
    
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
      cibuild_main_err "kaniko build failed for ${platform}";
    fi
  done
 
}

cibuild__build_image_nix() {
  local platforms \
        platform \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_native=$(cibuild_env_get 'build_native') \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        nix_flake_attr=$(cibuild_env_get 'nix_flake_attr') \
        nix_cache_url=$(cibuild_env_get 'nix_cache_url') \
        nix_cache_token=$(cibuild_env_get 'nix_cache_token') \
        nix_sandbox=$(cibuild_env_get 'nix_sandbox') \
        platform_name \
        nix_system \
        nix_conf_dir \
        nix_sandbox_val

  cibuild_log_info "build image with nix"

  # --- sandbox autodetect ---
  # if ROOTLESSKIT_PID is set we are running inside rootlesskit
  # which provides user namespaces — nix sandbox can use mount namespaces
  if [ -n "${nix_sandbox:-}" ]; then
    nix_sandbox_val="${nix_sandbox}"
  elif [ -n "${ROOTLESSKIT_PID:-}" ]; then
    nix_sandbox_val="true"
    cibuild_log_info "nix sandbox: true (rootlesskit detected)"
  else
    nix_sandbox_val="false"
    cibuild_log_info "nix sandbox: false (no rootlesskit)"
  fi

  # --- write nix.conf ---
  nix_conf_dir="${HOME}/.config/nix"
  mkdir -p "${nix_conf_dir}"
  cat > "${nix_conf_dir}/nix.conf" <<EOF
experimental-features = nix-command flakes
sandbox = ${nix_sandbox_val}
EOF

  # --- configure Attic cache if set ---
  if [ -n "${nix_cache_url:-}" ]; then
    cibuild_log_info "nix cache: ${nix_cache_url}"

    # write netrc for authenticated cache access
    if [ -n "${nix_cache_token:-}" ]; then
      cache_host=$(printf '%s\n' "${nix_cache_url}" | sed 's|https\?://||' | cut -d'/' -f1)
      mkdir -p "${HOME}/.config/nix"
      printf 'machine %s password %s\n' "${cache_host}" "${nix_cache_token}" \
        > "${HOME}/.config/nix/netrc"
      printf 'netrc-file = %s/.config/nix/netrc\n' "${HOME}" >> "${nix_conf_dir}/nix.conf"
    fi

    # append substituters
    printf 'substituters = https://cache.nixos.org %s\n' "${nix_cache_url}" \
      >> "${nix_conf_dir}/nix.conf"
    printf 'trusted-substituters = https://cache.nixos.org %s\n' "${nix_cache_url}" \
      >> "${nix_conf_dir}/nix.conf"
  fi

  cibuild_log_debug "nix.conf:"
  cibuild_log_debug "$(cat ${nix_conf_dir}/nix.conf)"

  # --- platform loop ---
  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(printf '%s\n' "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_name=$(printf '%s\n' "${platform}" | tr '/' '-')
    cibuild_log_debug "platform: ${platform} → platform_name: ${platform_name}"

    # map OCI platform to nix system
    case "${platform}" in
      linux/amd64)  nix_system="x86_64-linux"  ;;
      linux/arm64)  nix_system="aarch64-linux"  ;;
      *)
        cibuild_main_err "nix backend: unsupported platform ${platform}"
        ;;
    esac

    cibuild_log_info "nix build .#${nix_flake_attr} for ${nix_system}"

    # build nix flake → OCI archive in ./result
    if [ "${build_use_cache}" = "0" ]; then
      nix_opts="--option substitute false"
    else
      nix_opts=""
    fi

    if ! nix build \
      ".#${nix_flake_attr}" \
      --system "${nix_system}" \
      ${nix_opts} \
      --no-link \
      --print-out-paths \
      -L; then
      cibuild_main_err "nix build failed for ${nix_system}"
    fi

    # get store path of built OCI archive
    nix_result=$(nix build \
      ".#${nix_flake_attr}" \
      --system "${nix_system}" \
      ${nix_opts} \
      --no-link \
      --print-out-paths 2>/dev/null)

    cibuild_log_debug "nix result path: ${nix_result}"

    # push result to target registry via regctl
    cibuild_log_info "pushing ${target_image}:${build_tag}-${platform_name}"

    if ! regctl image import \
      "oci-archive:${nix_result}" \
      "${target_image}:${build_tag}-${platform_name}"; then
      cibuild_main_err "regctl image import failed for ${platform_name}"
    fi


    # --- push store paths to cache after successful build via nix copy ---
    # nix copy works with any nix-compatible cache (attic, cachix, s3)
    # no extra binary needed — nix is already installed
    if [ -n "${nix_cache_url:-}" ]; then
      cibuild_log_info "pushing nix store paths to cache: ${nix_cache_url}"
      # netrc is already written above for authenticated substituter access
      # nix copy picks it up automatically for push as well
      nix copy --to "${nix_cache_url}" "${nix_result}" ||         cibuild_log_err "nix copy to cache failed (non-fatal)"
    fi

  done
}


cibuild_build_run() {
  local build_enabled=$(cibuild_env_get 'build_enabled') \
        build_client=$(cibuild_env_get 'build_client')

  if [ "${build_enabled:?}" != "1" ]; then
    cibuild_log_info "build run skipped"
    return
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
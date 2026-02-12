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

  if ! timeout 5 kubectl auth can-i create deploy -q >/dev/null 2>&1; then
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
  #cat /tmp/ca.pem
  printf '%s\n' "$build_buildkit_client_cert" | base64 -d > /tmp/cert.pem
  #cat /tmp/cert.pem
  printf '%s\n' "$build_buildkit_client_key" | base64 -d > /tmp/key.pem
  #cat /tmp/key.pem
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
        build_import_cache=$(cibuild_env_get 'build_import_cache')

  case "$build_import_cache" in
    "")
      printf '%s\n' ""
      ;;
    ci_registry)
      printf '%s\n' "$(cibuild__build_get_cache_from_opt) type=registry,ref=$(cibuild_ci_image)-${arch}-cache:${build_tag}"
      ;;
    target_registry)
      printf '%s\n' "$(cibuild__build_get_cache_from_opt) type=registry,ref=$(cibuild_ci_target_image)-${arch}-cache:${build_tag}"
      ;;
    *)
      printf '%s\n' "$(cibuild__build_get_cache_from_opt) ${build_import_cache}"
      ;;
    esac
}

cibuild__build_get_export_cache_args() {
  local arch=$1 \
        build_tag=$(cibuild_ci_build_tag) \
        cache_mode=$(cibuild_env_get 'build_export_cache_mode') \
        build_export_cache=$(cibuild_env_get 'build_export_cache')

  case "$build_export_cache" in
    "")
      printf '%s\n' ""
      ;;
    ci_registry)
      printf '%s\n' "$(cibuild__build_get_cache_to_opt) type=registry,ref=$(cibuild_ci_image)-${arch}-cache:${build_tag},mode=${cache_mode}"
      ;;
    target_registry)
      printf '%s\n' "$(cibuild__build_get_cache_to_opt) type=registry,ref=$(cibuild_ci_target_image)-${arch}-cache:${build_tag},mode=${cache_mode}"
      ;;
    *)
      printf '%s\n' "$(cibuild__build_get_cache_to_opt) ${build_export_cache}"
      ;;
    esac
}

cibuild__build_get_sbom_args() {
  local build_sbom=$(cibuild_env_get 'build_sbom') \
        build_client=$(cibuild_env_get 'build_client')
  if [ "${build_sbom}" = "1" ]; then
    if [ "${build_client}" = "buildctl" ]; then
      printf '%s\n' "--opt attest:sbom="
    else
      printf '%s\n' "--sbom=true"
    fi
  fi
}

cibuild__build_get_provenance_args() {
  local build_provenance=$(cibuild_env_get 'build_provenance') \
        build_provenance_mode=$(cibuild_env_get 'build_provenance_mode') \
        build_client=$(cibuild_env_get 'build_client')
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
        build_http_proxy=$(cibuild_env_get 'build_http_proxy') \
        build_https_proxy=$(cibuild_env_get 'build_https_proxy') \
        build_no_proxy=$(cibuild_env_get 'build_no_proxy') \
        build_all=$(cibuild_env_get 'build_all_proxy') \
        build_opts=$(cibuild_env_get 'build_opts') \
        build_args=$(cibuild__build_get_build_args) \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        container_file=$(cibuild_core_container_file) \
        platform_tag \
        cache \
        sbom_args \
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
    platform_tag=$(echo "${platform}" | tr '/' '-')
    cibuild_log_debug "platform_tag: $platform_tag"

    cache="$(cibuild__build_get_import_cache_args ${platform_tag}) $(cibuild__build_get_export_cache_args ${platform_tag})"
    cibuild_log_debug "cache: $cache"
    
    sbom_args="$(cibuild__build_get_sbom_args)"
    cibuild_log_debug "sbom_args: $sbom_args"

    provenance_args="$(cibuild__build_get_provenance_args)"
    cibuild_log_debug "provenance_args: $provenance_args"

    cibuild_log_debug "build_args: $build_args"

    cibuild_log_debug "build_opts: $build_opts"

    cibuild_log_debug "build_http_proxy: $build_http_proxy"
    cibuild_log_debug "build_https_proxy: $build_https_proxy"
    cibuild_log_debug "build_no_proxy: $build_no_proxy"
    cibuild_log_debug "build_all_proxy: $build_all_proxy"
    
    if [ "${build_use_cache}" = "0" ]; then
      no_cache="--no-cache"
    else
      no_cache=""
    fi

    if ! docker buildx build \
      --builder "${build_buildx_driver}" \
      --platform "${platform}" \
      ${sbom_args:-} \
      ${provenance_args:-} \
      ${build_opts:-} \
      --build-arg "HTTP_PROXY=${build_http_proxy}" \
      --build-arg "HTTPS_PROXY=${build_https_proxy}" \
      --build-arg "NO_PROXY=${build_no_proxy}" \
      --build-arg "ALL_PROXY=${build_all_proxy}" \
      ${build_arguments} \
      ${no_cache} \
      ${cache} \
      --tag "${target_image}-${platform_tag}:${build_tag}" \
      --file "${container_file}" \
      --push \
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
        build_http_proxy=$(cibuild_env_get 'build_http_proxy') \
        build_https_proxy=$(cibuild_env_get 'build_https_proxy') \
        build_no_proxy=$(cibuild_env_get 'build_no_proxy') \
        build_all=$(cibuild_env_get 'build_all_proxy') \
        build_opts=$(cibuild_env_get 'build_opts') \
        build_args=$(cibuild__build_get_build_args) \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        container_file=$(cibuild_core_container_file) \
        platform_tag \
        cache \
        sbom_args \
        provenance_args \
        no_cache \
        build_command
  
  local build_remote_buildkit=$(cibuild_env_get 'build_remote_buildkit') \
        build_buildkit_host=$(cibuild_env_get 'build_buildkit_host') \
        build_buildkit_tls=$(cibuild_env_get 'build_buildkit_tls')

  cibuild_log_info "build image with buildctl"

  # see: https://hub.docker.com/r/moby/buildkit
  
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
  # in deploy run a clean oci multiarch image index is created for final tagging 
  # and an optional docker attestation manifest for ui
  
  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_tag=$(echo "${platform}" | tr '/' '-')
    cibuild_log_debug "platform_tag: $platform_tag"

    cache="$(cibuild__build_get_import_cache_args ${platform_tag}) $(cibuild__build_get_export_cache_args ${platform_tag})"
    cibuild_log_debug "cache: $cache"
    
    sbom_args="$(cibuild__build_get_sbom_args)"
    cibuild_log_debug "sbom_args: $sbom_args"

    provenance_args="$(cibuild__build_get_provenance_args)"
    cibuild_log_debug "provenance_args: $provenance_args"

    cibuild_log_debug "build_args: $build_args"

    cibuild_log_debug "build_opts: $build_opts"

    cibuild_log_debug "build_http_proxy: $build_http_proxy"
    cibuild_log_debug "build_https_proxy: $build_https_proxy"
    cibuild_log_debug "build_no_proxy: $build_no_proxy"
    cibuild_log_debug "build_all_proxy: $build_all_proxy"

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
      ${sbom_args:-} \
      ${provenance_args:-} \
      ${build_opts:-} \
      --opt build-arg:HTTP_PROXY=${build_http_proxy} \
      --opt build-arg:HTTPS_PROXY=${build_https_proxy} \
      --opt build-arg:NO_PROXY=${build_no_proxy} \
      --opt build-arg:ALL_PROXY=${build_all_proxy} \
      ${build_args:-} \
      ${no_cache:-} \
      ${cache:-} \
      --output type=image,name="${target_image}-${platform_tag}:${build_tag:?}",oci-artifact=true,push=true; then
      cibuild_main_err "failed: $build_command"
      
    fi
  done

}

cibuild__build_image_kaniko() {
  local platforms \
        platform \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_native=$(cibuild_env_get 'build_native') \
        build_http_proxy=$(cibuild_env_get 'build_http_proxy') \
        build_https_proxy=$(cibuild_env_get 'build_https_proxy') \
        build_no_proxy=$(cibuild_env_get 'build_no_proxy') \
        build_all=$(cibuild_env_get 'build_all_proxy') \
        build_opts=$(cibuild_env_get 'build_opts') \
        build_args=$(cibuild__build_get_build_args) \
        build_use_cache=$(cibuild_env_get 'build_use_cache') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        container_file=$(cibuild_core_container_file) \
        platform_tag \
        cache_args
  
  cibuild_log_info "build image with kaniko"
  
  if [ "${build_native}" = "1" ]; then
    platforms=$(cibuild_core_get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi

  for platform in ${platforms}; do
    platform_tag=$(echo "${platform}" | tr '/' '-')
    cibuild_log_debug "platform_tag: $platform_tag"
    
    cibuild_log_debug "build_args: $build_args"

    cibuild_log_debug "build_opts: $build_opts"

    cibuild_log_debug "image_tag: $image_tag"

    cibuild_log_debug "build_http_proxy: $build_http_proxy"
    cibuild_log_debug "build_https_proxy: $build_https_proxy"
    cibuild_log_debug "build_no_proxy: $build_no_proxy"
    cibuild_log_debug "build_all_proxy: $build_all_proxy"

    if [ "${build_use_cache}" = "0" ]; then
      cache_args="--cache=false"
    else
      cache_args="--cache=true --cache-repo=${target_image}-${build_tag}-${platform_tag}-cache"
    fi
    
    cibuild_log_debug ${cache_args}
    
    if ! /kaniko/executor \
      --context dir:///repo/ \
      --dockerfile Dockerfile \
      --snapshot-mode redo \
      --destination "${target_image}-${platform_tag}:${build_tag}" \
      ${cache_args} \
      --custom-platform $platform \
      --build-arg TARGETARCH="${platform##*/}" \
      --build-arg HTTP_PROXY="${build_http_proxy}" \
      --build-arg HTTPS_PROXY="${build_https_proxy}" \
      --build-arg NO_PROXY="${build_no_proxy}" \
      --build-arg ALL_PROXY="${build_all_proxy}" \
      ${build_args} \
      ${build_opts}; then
      cibuild_main_err "kaniko build failed for ${platform}";
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
    *)
      cibuild_main_err "build_client ${build_client} not supported"
    ;;
  esac

  if ! cibuild_core_run_script build post; then
    exit 1
  fi
}

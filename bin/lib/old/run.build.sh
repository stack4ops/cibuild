#!/bin/sh

cache_args=''
cache_to_opt='--cache-to'
cache_from_opt='--cache-from'
build_arguments=''

if [ "${build_client}" = "buildctl" ]; then
  cache_to_opt='--export-cache'
  cache_from_opt='--import-cache'
fi

no_cache=""

if [ "${use_cache:?}" = "0" ]; then
  no_cache="--no-cache"
fi

create_cert_files() {
  if [ -z "${BUILDKIT_CLIENT_CA:-}" ]; then
    log 0 "BUILDKIT_CLIENT_CA env var must not be empty"
    exit 1
  fi
  
  if [ -z "${BUILDKIT_CLIENT_CERT:-}" ]; then
    log 0 "BUILDKIT_CLIENT_CERT env var must not be empty"
    exit 1
  fi

  if [ -z "${BUILDKIT_CLIENT_KEY:-}" ]; then
    log 0 "BUILDKIT_CLIENT_KEY env var must not be empty"
    exit 1
  fi
  
  if [ "${cibuild_pipeline_env}" = "local" ]; then
    log 1 "pipeline ${cibuild_pipeline_env}"
  else
    log 1 "pipeline ${cibuild_pipeline_env}"
  fi
  echo "${BUILDKIT_CLIENT_CA}" | base64 -d > /tmp/ca.pem
  echo "${BUILDKIT_CLIENT_CERT}" | base64 -d > /tmp/cert.pem
  echo "${BUILDKIT_CLIENT_KEY}" | base64 -d > /tmp/key.pem
}

create_dockercontainer_builder() {
  log 1 "start: create_dockercontainer_builder"
  if [ "${cibuild_pipeline_env}" = "local" ]; then
    if ! docker network inspect dind-net >/dev/null 2>&1; then
      log 1 "docker network create dind-net"
      docker network create dind-net
    fi
    if ! docker buildx create \
      --name ${buildx_driver} \
      --buildkitd-config "${libpath}"/buildkitd.local.toml \
      --driver docker-container \
      --driver-opt "network=dind-net"; then
      log 0 "error creating builder $buildx_driver"
      exit 1
    fi
  else
    docker buildx create --name ${buildx_driver} --driver docker-container ${custom_buildkitd_config}
  fi
}

create_remote_builder() {
  log 1 "start: create_remote_builder"
  if [ -z "${BUILDKIT_HOST:-}" ]; then
    log 0 "BUILDKIT_HOST env var must not be empty"
    exit 1
  fi
  
  driver_opts=""
  if [ "${remote_buildkit:-}" = "1" ]; then
    create_cert_files
    driver_opts="--driver-opt cacert=/tmp/ca.pem,cert=/tmp/cert.pem,key=/tmp/key.pem"
  fi
  
  if ! docker buildx create \
    --name ${buildx_driver} \
    --driver remote ${driver_opts} \
    ${BUILDKIT_HOST}; then
    log 0 "error creating builder $buildx_driver"
    exit 1
  fi
  
}

create_kubernetes_builder() {
  log 1 "start: create_kubernetes_builder"

  if [ -z "${BUILDKIT_SERVICE_ACCOUNT:-}" ]; then
    log 0 "BUILDKIT_SERVICE_ACCOUNT env var must not be empty"
    exit 1
  fi

  echo "$BUILDKIT_SERVICE_ACCOUNT" | base64 -d > /tmp/kubeconfig

  export KUBECONFIG=/tmp/kubeconfig

  if ! docker buildx create \
    --name "$buildx_driver" \
    --driver kubernetes \
    --driver-opt=replicas=${build_kubernetes_replicas:-2} \
    --buildkitd-config "${libpath}"/buildkitd.local.toml; then
    log 0 "error creating builder $buildx_driver"
    exit 1
  fi

}

create_builder() {
  log 2 "start: create builder"
  case "$buildx_driver" in
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
      log 0 "buildx_driver $buildx_driver not supported"
      exit 1
      ;;
  esac
  
  if ! docker buildx use ${buildx_driver}; then
    log 0 "error using builder ${buildx_driver}"
    exit 1
  fi
  if ! docker buildx inspect ${buildx_driver} --bootstrap; then
    log 0 "error bootstrapping builder ${buildx_driver}"
    exit 1
  fi

}

prepare_build_args() {
  log 2 "prepare_build_args: ${build_args}"
  if [ "${build_client}" = "buildx" ]; then
    for build_arg in ${build_args:-}; do
      build_arguments="${build_arguments} --build-arg ${build_arg}"
    done
  else
    for build_arg in ${build_args:-}; do
      build_arguments="${build_arguments} --opt build-arg:${build_arg}"
    done
  fi
}

get_repo_registry_export_cache() {
  arch="$1"
  cache_tag="${build_tag:?}-cache-${arch}"
  if [ "${cibuild_pipeline_env:?}" = "ci" ]; then  
    ret="${cache_to_opt} type=registry,ref=${CI_REGISTRY_IMAGE:?}:${cache_tag},mode=${export_cache_mode}"
  else
    ret="${cache_to_opt} type=registry,ref=${local_registry}/${target_image_path}:${cache_tag},mode=${export_cache_mode}"
  fi
  echo "${ret}"
}

get_target_registry_export_cache() {
  arch="$1"
  cache_tag="${build_tag:?}-cache-${arch}"
  ret="${cache_to_opt} type=registry,ref=${target_image:?}:${cache_tag},mode=${export_cache_mode}"
  echo "${ret}"
}

get_export_cache_args() {
  arch=$1
  case "$export_cache" in
    "")
      echo ""
      ;;
    repo_registry)
      echo $(get_repo_registry_export_cache "$arch")
      ;;
    target_registry)
      echo $(get_target_registry_export_cache "$arch")
      ;;
    *)
      echo "--export-cache ${export_cache}"
      ;;
    esac
}

get_repo_registry_import_cache() {
  arch="$1"
  cache_tag="${build_tag:?}-cache-${arch}"
  if [ "${cibuild_pipeline_env:?}" = "ci" ]; then  
    ret="${cache_from_opt} type=registry,ref=${CI_REGISTRY_IMAGE:?}:${cache_tag}"
  else
    ret="${cache_from_opt} type=registry,ref=${local_registry}/${target_image_path}:${cache_tag}"
  fi
  echo "${ret}"
}

get_target_registry_import_cache() {
  arch="$1"
  cache_tag="${build_tag:?}-cache-${arch}"
  ret="${cache_from_opt} type=registry,ref=${target_image:?}:${cache_tag}"
  echo "${ret}"
}

get_import_cache_args() {
  arch=$1
  case "$import_cache" in
    "")
      echo ""
      ;;
    repo_registry)
      echo $(get_repo_registry_import_cache "$arch")
      ;;
    target_registry)
      echo $(get_target_registry_import_cache "$arch")
      ;;
    *)
      echo "--import-cache ${import_cache}"
      ;;
    esac
}

get_sbom_args() {
  if [ "${sbom}" = "1" ]; then
    if [ "${build_client}" = "buildctl" ]; then
      echo "--opt attest:sbom="
    else
      echo "--sbom="
    fi
  fi
}

get_provenance_args() {
  if [ "${provenance}" = "1" ]; then
    if [ "${build_client}" = "buildctl" ]; then
      echo "--opt attest:provenance=mode=${provenance_mode:-max}"
    else
      echo "--provenance=mode=${provenance_mode:-max}"
    fi
  fi
}

build_image_buildx() {
  log 1 "build image with buildx"
  
  create_builder
  
  platforms=''
  
  if [ "${build_native}" = "1" ]; then
    platforms=$(get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi

  log 1 "building for platforms: $platforms"
  
  for platform in ${platforms}; do
    platform_tag=$(echo "${platform}" | tr '/' '-')
    cache="$(get_import_cache_args ${platform_tag}) $(get_export_cache_args ${platform_tag})"
    sbom_args="$(get_sbom_args)"
    provenance_args="$(get_provenance_args)"
    image_tag="${build_tag}-${platform_tag}"
    
    if ! docker buildx build \
      --builder "${buildx_driver}" \
      --platform "${platform}" \
      ${sbom_args:-} \
      ${provenance_args:-} \
      ${build_opts:-} \
      --build-arg "HTTP_PROXY=${proxies}" \
      --build-arg "HTTPS_PROXY=${proxies}" \
      --build-arg "http_proxy=${proxies}" \
      --build-arg "https_proxy=${proxies}" \
      ${build_arguments} \
      ${no_cache} \
      ${cache} \
      --tag "${target_image}:${image_tag:?}" \
      --file "${container_file:?}" \
      --push \
      .; then
      log 0 "Build failed"
      exit 1
    fi
  done
}

build_image_buildctl() {
  # see: https://hub.docker.com/r/moby/buildkit
  if [ "${remote_buildkit:-}" = "1" ]; then
    log 1 "build image with remote buildctl"
  else
    log 1 "build image with embedded buildctl-daemonless.sh"
  fi
  
  if [ -z "${BUILDKIT_HOST:-}" ]; then
    log 0 "BUILDKIT_HOST env var must not be empty"
    exit 1
  fi

  prepare_build_args
  
  build_command=''

  if [ "${remote_buildkit:-}" = "1" ]; then
    if [ -z "${buildkit_host:-}" ]; then
      log 0 "buildkit_host BUILDKIT_HOST required on remote_buildkit=1"
      exit 1
    fi
    build_command="buildctl --addr ${BUILDKIT_HOST}"
    if [ "${buildkit_tls:-1}" = "1" ]; then
      create_cert_files
      build_command="$build_command --tlscert /tmp/cert.pem --tlskey /tmp/key.pem --tlscacert /tmp/ca.pem"
    fi
  else
    build_command="buildctl-daemonless.sh"
  fi
  
  # build oci image for each arch (Unfortunately docker references attestations in a (forced) image-index for each image)
  # in deploy run a clean oci multiarch image index is created for final tagging 
  # and an optional docker attestation manifest for ui

  platforms=''
  
  if [ "${build_native}" = "1" ]; then
    platforms=$(get_platform_arch)
  else
    platforms=$(echo "${build_platforms}" | tr ',' ' ')
  fi
  
  log 1 "building for platforms: $platforms"

  for platform in ${platforms}; do
    platform_tag=$(echo "${platform}" | tr '/' '-')
    cache="$(get_import_cache_args ${platform_tag}) $(get_export_cache_args ${platform_tag})"
    sbom_args="$(get_sbom_args)"
    provenance_args="$(get_provenance_args)"
    image_tag="${build_tag}-${platform_tag}"
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
      --opt build-arg:HTTP_PROXY=${proxies} \
      --opt build-arg:HTTPS_PROXY=${proxies} \
      --opt build-arg:http_proxy=${proxies} \
      --opt build-arg:https_proxy=${proxies} \
      ${build_arguments:-} \
      ${no_cache:-} \
      ${cache:-} \
      --output type=image,name="${target_image}:${image_tag:?}",oci-artifact=true,push=true; then
      log 0 "failed: $build_command"
      exit 1
    fi
  done
}

build() {
  log 1 "building"

  if [ "${cibuild_build_enabled:?}" != "1" ]; then
    log 1 "build run skipped"
    return
  fi
  log 2 "run: build"
  if [ "${build_client}" = "buildx" ]; then
    if [ "${dind_enabled:-0}" != "1" ]; then
      log 0 "buildx requires DIND_ENABLED=1"
      exit 1
    fi
    build_image_buildx
  else
    build_image_buildctl
  fi
}

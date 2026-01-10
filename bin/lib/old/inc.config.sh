#!/bin/sh

get_platform_tag() {
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
  echo "$platform_tag"
}

get_platform_arch() {
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
  echo "$platform_arch"
}

check_arg() {
  if [ -z "${1:-}" ]; then
    log 0 "Missing value for ${2:-parameter}"
    usage
    exit 2
  fi
}

override_defaults_with_config_file() {
  log 2 "start: override_defaults_with_config_file"

  #  check env
  if [ "$cibuild_pipeline_env" = "local" ]; then
    log 2 "set local env"
    if [ -n "${config_file_local:-}" ] && [ ! -f "${config_file_local}" ]; then
      log 0 "no $config_file_local found."
      exit 2
    else
      log 2 "Use ${config_file_local} config file"
      . "${config_file_local}"
      return
    fi
  else
    log 2 "set ci env"
    if [ -n "${config_file:-}" ] && [ ! -f "${config_file}" ]; then
      log 0 "no $config_file found."
      exit 2
    else
      log 2 "Use ${config_file} config file"
      . "${config_file}"
      return
    fi
  fi
}

override_config_with_environment() {
  log 2 "start: override_config_with_environment"
  cibuild_loglevel=${CIBUILD_LOGLEVEL:-$cibuild_loglevel}
  cibuild_logcolor=${CIBUILD_LOGCOLOR:-$cibuild_logcolor}
  if [ "$cibuild_loglevel" = "3" ]; then
    log 3 "+++ START: PRINTENV ++++"
    printenv
    log 3 "+++ END: PRINTENV ++++"
  fi
  
  cibuild_check_enabled=${CHECK_STAGE:-$cibuild_check_enabled}
  cibuild_build_enabled=${BUILD_STAGE:-$cibuild_build_enabled}
  cibuild_build_force=${BUILD_FORCE:-$cibuild_build_force}
  cibuild_test_enabled=${TEST_STAGE:-$cibuild_test_enabled}
  cibuild_deploy_enabled=${DEPLOY_STAGE:-$cibuild_deploy_enabled}

  ## BASE REGISTRY AUTH
  base_registry_user=${BASE_REGISTRY_USER:-$base_registry_user}
  base_registry_pass=${BASE_REGISTRY_PASS:-$base_registry_pass}
  ## 

  ## TARGET REGISTRY AUTH
  target_registry_user=${TARGET_REGISTRY_USER:-$target_registry_user}
  target_registry_pass=${TARGET_REGISTRY_PASS:-$target_registry_pass}
  ## TARGET IMAGE
  target_registry=${TARGET_REGISTRY:-$target_registry}
  target_registry_auth_url=${TARGET_REGISTRY_AUTH_URL:-$target_registry_AUTH_URL}
  target_image_path=${TARGET_IMAGE_PATH:-$target_image_path}
  target_tag=${TARGET_TAG:-$target_tag}

  ## TEST CONFIG
  test_file=${TEST_FILE:-$test_file}
  test_backend=${TEST_BACKEND:-$test_backend}
  test_run_timeout=${TEST_RUN_TIMEOUT:-$test_run_timeout}
  ## DOCKER BUILD CONFIG
  export_cache=${EXPORT_CACHE:-$export_cache}
  export_cache_mode=${EXPORT_CACHE_MODE:-$export_cache_mode}
  import_cache=${IMPORT_CACHE:-$import_cache}
  additional_tags=${ADDITIONAL_TAGS:-$additional_tags}
  date_tag=${DATE_TAG:-$date_tag}
  date_tag_with_time=${DATE_TAG_WITH_TIME:-$date_tag_with_time}
  minor_tag_regex=${MINOR_TAG_REGEX:-$minor_tag_regex}
  build_platforms=${BUILD_PLATFORMS:-$build_platforms}
  build_native=${BUILD_NATIVE:-$build_native}
  proxies=${PROXIES:-$proxies} # maybe use https_proxy env var?
  container_file=${CONTAINER_FILE:-$container_file}
  build_args=${BUILD_ARGS:-$build_args}
  remote_buildkit=${REMOTE_BUILDKIT:-$remote_buildkit}
  buildkit_host=${BUILDKIT_HOST:-$buildkit_host}
  buildkit_tls=${BUILDKIT_TLS:-$buildkit_tls}
  dind_enabled=${DIND_ENABLED:-$dind_enabled}
  docker_host=${DOCKER_HOST:-$docker_host}
  docker_tls_certdir=${DOCKER_TLS_CERTDIR:-$docker_tls_certdir}
  build_client=${BUILD_CLIENT:-$build_client}
  buildx_driver=${BUILDX_DRIVER:-$buildx_driver}
  build_tag=${BUILD_TAG:-$build_tag}
  add_branch_name_to_tags=${ADD_BRANCH_NAME_TO_TAGS:-$add_branch_name_to_tags}
  add_commit_sha_to_tags=${ADD_COMMIT_SHA_TO_TAGS:-$add_commit_sha_to_tags}
  use_cache=${USE_CACHE:-${use_cache:-1}}
  docker_attestation_autodetect=${DOCKER_ATTESTATION_AUTODETECT:-$docker_attestation_autodetect}
  docker_attestation_manifest=${DOCKER_ATTESTATION_MANIFEST:-$docker_attestation_manifest}
  keep_arch_index=${KEEP_ARCH_INDEX:-$keep_arch_index}

  ## GITLAB API CONFIG
  cibuild_cancel_token=${CIBUILD_CANCEL_TOKEN:-$cibuild_cancel_token}
  gitlab_server_host=${CI_SERVER_HOST:-$gitlab_server_host}
  gitlab_project_id=${CI_PROJECT_ID:-$gitlab_project_id}
  gitlab_api_version=${GITLAB_API_VERSION:-$gitlab_api_version}

}

setup_environment() {

  # Get configuration
  override_defaults_with_config_file
  override_config_with_environment

}

while [ $# -gt 0 ]; do
  case $1 in
    -h | --help)
      usage
      exit 2
      ;;
    -s | --stage)
      check_arg "$2"
      stage=$2
      shift
      ;;
    -v | --version)
      echo " $(basename "${0}") ${version:?}"
      exit 2
      ;;
    -*)
      echo "Invalid option: ${1}."
      usage
      exit 2
      ;;
    *)
      echo "Invalid option: ${1}."
      usage
      exit 2
      ;;
  esac
  shift
done

cibuild_check_enabled_arg() {
  if [ -z "${stage:-}" ]; then
    log 0 "missing required -s | --stage STAGE parameter: check|build|test|deploy|main"
    exit 1
  fi
}

cibuild_check_enabled_arg

setup_project_folder() {
  project_folder="$(pwd)"
  
  # deprecated?
  if [ -f "${project_folder}/cibuild.buildkitd.toml" ]; then
    custom_buildkitd_config="--buildkit-config ${project_folder}/cibuild/buildkitd.toml"
  fi
}

setup_project_folder

parse_container_file() {
  log 2 "start: check_container_file"
  if [ -z "$container_file" ]; then
    for container_file_candidate in "Containerfile" "Dockerfile"; do
      log 2 "check container_file_candidate: '$container_file_candidate'"
      if [ -f "${container_file_candidate}" ]; then
        container_file="${container_file_candidate}"
        log 2 "found container_file: '$container_file'."
      fi
    done
  else
    log 2 "container_file set trough config: '$container_file'"
  fi

  if ! [ -f "${container_file}" ]; then
    log 0 "no containerfile found"
    exit 1
  fi

  # in multistage Dockerfiles baseimage and tag MUST be predefined
  if [ -n "${base_image_path}" ] && [ -n "${base_tag}" ] && [ -n "${base_registry}" ]; then
    log 2 "base_image is predefined (required in multistage builds)"
    full="${base_registry}/${base_image_path}:${base_tag}"
    log 2 "$full"
  else
    log 2 "Extract the last FROM line"
    from_count=$(grep -cE '^FROM[[:space:]]+' "$container_file")
    log 1 "$from_count"
    if [ "$from_count" != "1" ]; then
      log 1 "Multistage ${container_file}: last FROM is used as base image"
    fi
    from_line=$(grep -E '^FROM[[:space:]]+' "${container_file}" | tail -n 1)
    if [ -z "$from_line" ]; then
        log 0 "No FROM line found"
        exit 1
    fi
    # FROM <image> [AS stage]
    # We take the second field, unless it starts with -- (Docker options)
    image=$(printf "%s" "$from_line" | awk '{print $2}')

    # Handle cases like: FROM --platform=linux/amd64 imagename AS builder
    case "$image" in
      --*)
        image=$(printf "%s" "$from_line" | awk '{print $3}')
        ;;
    esac

    # -----------------------------------
    #  Normalize Docker image reference
    # -----------------------------------

    tag="latest"

    # Extract tag
    case "$image" in
      *:*)
        tag=$(printf "%s" "$image" | awk -F':' '{print $NF}')
        image_no_tag=$(printf "%s" "$image" | sed "s/:$tag\$//")
        ;;
      *)
        image_no_tag="$image"
        ;;
    esac

    # Detect registry:
    # Docker rule: the first component is a registry if it contains '.' or ':'
    first_part=$(printf "%s" "$image_no_tag" | cut -d'/' -f1)

    case "$first_part" in
      *.*|*:* )
          registry="$first_part"
          remainder=$(printf "%s" "$image_no_tag" | cut -d'/' -f2-)
          ;;
      *)
          registry="docker.io"
          remainder="$image_no_tag"
          ;;
    esac

    # Add "library/" if there is no slash (Docker Hub implicit namespace)
    case "$remainder" in
      */*) final_path="$remainder" ;;
      *)   final_path="library/$remainder" ;;
    esac

    base_registry="${registry}"
    base_image_path="${final_path}"
    base_tag="${tag}"

    full="${base_registry}/${base_image_path}:${tag}"
    log 2 "$full"   
  fi
  
}

get_auth_url_for_registry() {
  # set registry specific auth urls
  reg="$1"
  case "$reg" in
    docker.io)
      echo "https://index.docker.io/v1/"
      return
      ;;
    localregistry.example.com\:5000)
      echo "https://localregistry.example.com:5000"
      return
      ;;
    *)
      echo "$reg"
      return
      ;;
  esac
}

url_encode_project() {
  log 2 "urlencode project"
  repository=$(git remote get-url origin | sed -e 's/git@[^:]\+:\(.*\)\.git/\1/g')
  repository_url_encoded=$(echo "$repository" | jq -sRr @uri | sed 's/%0A//')
  log 2 "urlencoded project: ${repository_url_encoded}"
}

gather_image_informations() {
  log 2 "start: gather_image_informations"
  if [ -z "${base_image_path}" ]; then
    log 0 "base_image_path must not be empty"
    exit 1
  fi

  if [ -z "${target_image_path}" ]; then
    log 0 "target_image_path must not be empty"
    exit 1
  fi

  if [ -z "${base_tag}" ]; then
    log 0 "base_tag must not be empty"
    exit 1
  fi

  if [ -z "${target_tag}" ]; then
    log 0 "target_tag must not be empty"
    exit 1
  fi

  base_image=${base_registry}/${base_image_path}
  target_image=${target_registry}/${target_image_path}
  target_tag=${target_tag:-$base_tag}
  build_tag=${build_tag:-"build-$target_tag"}
}

check_cibuild_pipeline_env() {
  log 2 "start: check_cibuild_pipeline_env"
  
  if [ -z "$cibuild_pipeline_env" ]; then
    if [ -z "${CI_JOB_ID:-}" ]; then
      cibuild_pipeline_env='local'
      cibuild_current_branch=$(git branch --show-current | xargs)
      cibuild_current_commit=$(git rev-parse HEAD | xargs)
    else
      cibuild_pipeline_env='ci'
      cibuild_current_branch=${CI_COMMIT_REF_NAME:-$CI_MERGE_REQUEST_TARGET_BRANCH_NAME}
      cibuild_current_commit=${CI_COMMIT_SHA}
    fi
  fi
  log 2 "cibuild_pipeline_env ${cibuild_pipeline_env}"
}

load_pipeline_cache() {
  log 2 "start: load_pipeline_cache in cibuild_pipeline_env $cibuild_pipeline_env"
  if [ "$cibuild_pipeline_env" = 'local' ]; then
    if [ -z "$cache_file" ]; then
      cache_file=${cache_folder}/$(
        tr -dc A-Za-z0-9 </dev/urandom | head -c 13
        echo
      )
      touch "$cache_file"
      chmod 755 "$cache_file"
    fi
  else
    cache_file=${cache_folder}/${CI_PIPELINE_ID}
    if [ ! -f "$cache_file" ]; then
      touch "$cache_file"
      chmod 755 "$cache_file"
    fi
  fi
  if [ ! -f "$cache_file" ]; then
    log 0 "cache_file $cache_file not exists"
  fi
  . "$cache_file"
}

log_config() {

  if [ "${cibuild_loglevel}" -lt 2 ]; then
    return
  fi
  
  log 2 "project_folder - $project_folder"
  log 2 "custom_buildkitd_config - $custom_buildkitd_config"
  log 2 "logging config - cibuild_loglevel: ${cibuild_loglevel}"
  log 2 "logging config - base_registry: ${base_registry}"
  log 2 "logging config - base_registry_auth_url: ${base_registry_auth_url}"
  log 2 "logging config - base_registry_pass: **********"
  log 2 "logging config - base_registry_user: ${base_registry_user}"
  log 2 "logging config - base_registry_pass: **********"
  log 2 "logging config - base_image_path: ${base_image_path}"
  log 2 "logging config - base_tag: ${base_tag}"
  log 2 "logging config - target_registry: ${target_registry}"
  log 2 "logging config - target_registry_auth_url: ${target_registry_auth_url}"
  log 2 "logging config - target_registry_user: ${target_registry_user}"
  log 2 "logging config - target_registry_pass: **********"
  log 2 "logging config - target_image_path: ${target_image_path}"
  log 2 "logging config - target_tag: ${target_tag}"
  log 2 "logging config - cibuild_build_force: ${cibuild_build_force}"
  log 2 "logging config - cibuild_pipeline_env: ${cibuild_pipeline_env}"
  log 2 "logging config - cibuild_current_branch: ${cibuild_current_branch}"
  log 2 "logging config - cibuild_current_commit: ${cibuild_current_commit}"
  log 2 "logging config - build_args: ${build_args}"
  log 2 "logging config - cibuild_cancel_token: **********"
  log 2 "logging config - gitlab_server_host: ${gitlab_server_host}"
  log 2 "logging config - gitlab_project_id: ${gitlab_project_id}"
  log 2 "logging config - gitlab_api_version: ${gitlab_api_version}"
  log 2 "logging config - proxies: ${proxies}"
  log 2 "logging config - container_file: ${container_file}"
  log 2 "logging config - test_file: ${test_file}"
  log 2 "logging config - test_backend: ${test_backend}"
  log 2 "logging config - test_run_timeout: ${test_run_timeout}"
  log 2 "logging config - additional_tags: ${additional_tags}"
  log 2 "logging config - date_tag: ${date_tag}"
  log 2 "logging config - date_tag_with_time: ${date_tag_with_time}"
  log 2 "logging config - build_platforms: ${build_platforms}"
  log 2 "logging config - build_native: ${build_native}"
  log 2 "logging config - remote_buildkit: ${remote_buildkit}"
  log 2 "logging config - buildkit_host: ${buildkit_host}"
  log 2 "logging config - buildkit_tls: ${buildkit_tls}"
  log 2 "logging config - dind_enabled: ${dind_enabled}"
  log 2 "logging config - docker_host: ${docker_host}"
  log 2 "logging config - docker_tls_certdir: ${docker_tls_certdir}"
  log 2 "logging config - build_client: ${build_client}"
  log 2 "logging config - buildx_driver: ${buildx_driver}"
  log 2 "logging config - add_branch_name_to_tags: ${add_branch_name_to_tags}"
  log 2 "logging config - add_commit_sha_to_tags: ${add_commit_sha_to_tags}"
  log 2 "logging config - use_cache: ${use_cache}"
  log 2 "logging config - docker_attestation_autodetect: ${docker_attestation_autodetect}"
  log 2 "logging config - docker_attestation_manifest: ${docker_attestation_manifest}"
  log 2 "logging config - keep_arch_index: ${keep_arch_index}"
  log 2 "logging config - export_cache:  ${export_cache}"
  log 2 "logging config - export_cache_mode:  ${export_cache_mode}"
  log 2 "logging config - import_cache: ${import_cache}"
  log 2 "logging config - base_image: ${base_image}"
  log 2 "logging config - target_image: ${target_image}"
  log 2 "logging config - target_tag: ${target_tag}"
  log 2 "logging config - cibuild_check_enabled: ${cibuild_check_enabled}"
  log 2 "logging config - cibuild_build_enabled: ${cibuild_build_enabled}"
  log 2 "logging config - cibuild_build_force: ${cibuild_build_force}"
  log 2 "logging config - cibuild_test_enabled: ${cibuild_test_enabled}"
  log 2 "logging config - cibuild_deploy_enabled: ${cibuild_deploy_enabled}"
}

check_setup() {
  # deprecated?
  # build_host=docker
  case "$cibuild_pipeline_env" in
    ci | CI)
      cache_folder='./cache'
      if [ ! -d "$cache_folder" ]; then
        log 2 "$cache_folder not exists...create"
        mkdir "$cache_folder"
      fi
      if [ -z "${cibuild_cancel_token}" ]; then
        log 0 "missing gitlab token: cibuild_cancel_token or CIBUILD_CANCEL_TOKEN with api permission"
        exit 1
      fi
      ;;
    *)
      cache_folder='/tmp'
      ;;
  esac

  log 2 "use cache_folder: ${cache_folder}"
  # deprecated?
  log 2 "use build_host: ${build_host}"

  if [ "${add_branch_name_to_tags:-}" = "prefix" ]; then
    target_tag=${cibuild_current_branch}-${target_tag}
    build_tag=${cibuild_current_branch}-${build_tag}
  fi
  if [ "${add_branch_name_to_tags:-}" = "suffix" ]; then
    target_tag=${target_tag}-${cibuild_current_branch}
    build_tag=${build_tag}-${cibuild_current_branch}
  fi

  if [ "${add_commit_sha_to_tags:-}" = "prefix" ]; then
    target_tag=${cibuild_current_commit}-${target_tag}
    build_tag=${cibuild_current_commit}-${build_tag}
  fi
  if [ "${add_commit_sha_to_tags:-}" = "suffix" ]; then
    target_tag=${target_tag}-${cibuild_current_commit}
    build_tag=${build_tag}-${cibuild_current_commit}
  fi

  # check integrity
  if [ "${cibuild_pipeline_env}" = "local" ] && [ "${target_registry}" = "${local_registry}" ]; then
    log 2 "target_registry=${local_registry} - setting insecure_tls=1"
    insecure_tls=1
  fi
}

create_docker_auth_config() {
  
  log 2 "start: create_docker_auth_config"

  if [ ! -d "${HOME}/.docker" ]; then
    log 2 "create ~/.docker directory"
    mkdir "${HOME}/.docker"
  fi
  
  # todo: for custom if exist: read BUILDCTL_DOCKER_CONFIG as base64
  cp "${libpath}/docker.config.json" "${HOME}/.docker/config.json"

  #chmod 600 "${HOME}/.docker/config.json"

  base_auth=""
  base_reg=""
  target_reg=""
  gitlab_reg=""
  target_user=""
  target_pass=""
  base_user=""
  base_pass=""
  gitlab_registry=${CI_REGISTRY:-"skipgitlabregistry.local.com"}
  gitlab_reg=""
  gitlab_user=""
  gitlab_pass=""
  
  # only add entry if not exists
  if ! grep -q "${target_registry}" "${HOME}/.docker/config.json"; then
    log 2 "add ${target_registry}"
    target_reg=$(get_auth_url_for_registry ${target_registry})
    if [ -n "${target_registry_user}" ] && [ -n "${target_registry_pass}" ]; then
      target_user=${target_registry_user}
      target_pass=${target_registry_pass}
    fi
  else
    log 2 "${target_registry} already exists: skip entry"
    target_reg="skiptargetregistry.local.com"
  fi

  sed -i "s|TARGET_REG|$target_reg|g" ${HOME}/.docker/config.json
  sed -i "s|TARGET_USER|$target_user|g" ${HOME}/.docker/config.json
  sed -i "s|TARGET_PASS|$target_pass|g" ${HOME}/.docker/config.json
  
  if ! grep -q "${base_registry}" "${HOME}/.docker/config.json"; then
    log 2 "add ${base_registry}"
    base_reg=$(get_auth_url_for_registry ${base_registry})
    if [ -n "${base_registry_user}" ] && [ -n "${base_registry_pass}" ]; then
      base_user=${base_registry_user}
      base_pass=${base_registry_pass}
    fi
  else
    log 2 "${base_registry} already exists: skip entry"
    base_reg="skipbaseregistry.local.com"
  fi

  sed -i "s|BASE_REG|$base_reg|g" ${HOME}/.docker/config.json
  sed -i "s|BASE_USER|$base_user|g" ${HOME}/.docker/config.json
  sed -i "s|BASE_PASS|$base_pass|g" ${HOME}/.docker/config.json
  
  if ! grep -q "${gitlab_registry}" "${HOME}/.docker/config.json"; then
    log 2 "add ${gitlab_registry}"
    gitlab_reg="${gitlab_registry}"
    if [ "${cibuild_pipeline_env}" = "ci" ] && [ -n "${CI_REGISTRY_USER}" ] && [ -n "${CI_REGISTRY_PASSWORD}" ]; then
      gitlab_user=${CI_REGISTRY_USER}
      gitlab_pass=${CI_REGISTRY_PASSWORD}
    fi
  else
    log 2 "${gitlab_registry} already exists: skip entry"
    gitlab_reg="skipgitlabregistry.local.com"
  fi
  
  sed -i "s|GITLAB_REG|$gitlab_reg|g" ${HOME}/.docker/config.json
  sed -i "s|GITLAB_USER|$gitlab_user|g" ${HOME}/.docker/config.json
  sed -i "s|GITLAB_PASS|$gitlab_pass|g" ${HOME}/.docker/config.json
}

create_regctl_auth_config() {

  log 2 "start: create_regctl_auth_config"

  regctl registry set ${local_registry} --tls insecure --skip-check
  regctl registry login ${local_registry} --user admin --pass password --skip-check
  if [ "${target_registry}" != "${local_registry}" ]; then
    regctl registry set "${target_registry}" --skip-check
    if [ -n "${target_registry_user}" ] && [ -n "${target_registry_pass}" ]; then
      regctl registry login "${target_registry}" --user ${target_registry_user} --pass ${target_registry_pass} --skip-check
    fi
  fi
  if [ "${base_registry}" != "${local_registry}" ]; then
    regctl registry set ${base_registry} --hostname ${base_registry} --skip-check
    if [ -n "${base_registry_user}" ] && [ -n "${base_registry_pass}" ]; then
      regctl registry login ${base_registry} --user ${base_registry_user} --pass ${base_registry_pass} --skip-check
    fi
  fi
  #cat ${HOME}/.regctl/config.json
  regctl registry config
}

setup_configuration() {
  log 2 "start: setup_configuration"
  check_cibuild_pipeline_env
  setup_environment
  check_setup
  parse_container_file
  gather_image_informations
  load_pipeline_cache
  create_docker_auth_config
  create_regctl_auth_config
  log_config
}

setup_configuration

#!/bin/sh
# Package cibuild/env

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_ENV_LOADED-}" ] && return
_CIBUILD_ENV_LOADED=1

# ---- Defaults (Go: var DefaultEnv = …) ----
_CIBUILD_DEFAULTS='
version=0.8.0
pipeline_env=
add_branch_name_to_tags=
add_commit_sha_to_tags=
docker_host=tcp://docker:2375
check_enabled=0
build_enabled=1
build_client=buildctl
build_remote_buildkit=0
build_buildkit_host=tcp://buildkit:1234
build_buildkit_tls=1
build_platforms=linux/amd64,linux/arm64
build_native=0
build_proxies=
build_opts=
build_archs=
build_use_cache=1
build_export_cache=ci_registry
build_export_cache_mode=max
build_import_cache=ci_registry
build_sbom=1
build_provenance=1
build_provenance_mode=max
build_tag=build
build_buildx_driver=dockercontainer
build_buildkit_service_account=
build_kubernetes_replicas=1
test_enabled=0
test_file=cibuild.test.sh
test_backend=docker
test_service_account=
test_run_timeout=60
deploy_enabled=1
deploy_docker_attestation_autodetect=1
deploy_docker_attestation_manifest=0
deploy_minor_tag_regex=
'

_CIBUILD_ENV_VARS=""

cibuild__env_detect_ci() {
  
  if [ -z "$_CIBUILD_PIPELINE_ENV" ]; then
    # automatic detection
    if [ -n "${GITLAB_CI:-}" ]; then
      _CIBUILD_PIPELINE_ENV=gitlab
    elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
      _CIBUILD_PIPELINE_ENV=github
    elif [ -n "${CIRCLECI:-}" ]; then
      cibuild_main_err "circleci not implemented yet"
    elif [ -n "${JENKINS_URL:-}" ]; then
      cibuild_main_err "jenkins not implemented yet"
    else
      _CIBUILD_PIPELINE_ENV=local
    fi
  fi
  
  # load generic config if exists
  generic_env_file="$(pwd)/cibuild.env"
  if [ -f "$generic_env_file" ]; then
    cibuild_log_info "loading adapter file: $generic_env_file"
    set -a
    . "$generic_env_file"
    set +a
  fi
  
  # load adapter env if exists in repo and export env vars
  adapter_env_file="$(pwd)/cibuild.${_CIBUILD_PIPELINE_ENV}.env"
  if [ -f "$adapter_env_file" ]; then
    cibuild_log_info "loading adapter file: $adapter_env_file"
    set -a
    . "$adapter_env_file"
    set +a
  fi

  # load ci adapter
  . "${CIBUILD_LIB_PATH}/ci/${_CIBUILD_PIPELINE_ENV}.sh"

}

cibuild__env_apply_vars() {
  _CIBUILD_ENV_VARS=
  
  while IFS= read -r line; do
    case $line in
      CIBUILD_*=*)
        key=${line%%=*}
        value=${line#*=}
        var=${key#CIBUILD_}
        var=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
        _CIBUILD_ENV_VARS="${_CIBUILD_ENV_VARS}${var}=${value}
"
        ;;
    esac
  done <<EOF
$(env)
EOF
}

cibuild__env_map_get() {
  local map=$1
  local key=$2
  local line k v

  while IFS= read -r line; do
    k=${line%%=*}
    [ "$k" = "$key" ] || continue
    v=${line#*=}
    printf '%s\n' "$v"
    return 0
  done <<EOF
$map
EOF
  return 1
}

cibuild_env_get() {
  local key="$1"
  local default="$2"
  local val

  val="$(cibuild__env_map_get "$_CIBUILD_ENV_VARS" "$key")"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
    return 0
  fi

  if [ -n "$default" ]; then
    printf '%s\n' "$default"
    return 0
  fi

  val="$(cibuild__env_map_get "$_CIBUILD_DEFAULTS" "$key")"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
    return 0
  fi

  return 1
}

cibuild_env_get_vars() {
  printf '%s\n' "$_CIBUILD_ENV_VARS" | sort
}

cibuild_env_init() {
  [ "${_CIBUILD_ENV_INIT_DONE:-}" = "1" ] && return
  _CIBUILD_ENV_INIT_DONE=1
  cibuild__env_detect_ci
  cibuild__env_apply_vars
  #cibuild__env_detect_kubernetes
}

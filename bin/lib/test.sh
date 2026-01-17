#!/bin/sh
# Package cibuild/test

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_TEST_LOADED-}" ] && return
_CIBUILD_TEST_LOADED=1

# can be used in test scripts
_test_id='' # ramdom test_id used also for port binding
_test_image=''
_host=''
_target_port=''
_publish=''
_container=''
_pod=''

# ---------- RUN HELPERS ----------
cibuild__test_run_docker() {
  local ep_spec \
        cmd \
        cid \
        state \
        i \
        test_run_timeout=$(cibuild_env_get 'test_run_timeout')

  ep_spec="${1:-keep}"
  shift

  if [ -n "${_target_port}" ]; then
    cibuild_log_debug "set publish port"
    _publish="-p ${_test_id}:${_target_port}"
  fi

  cmd="docker run -d --rm --name $_container $_publish"

  if [ "$ep_spec" = "keep" ] && [ $# -eq 0 ]; then
    cibuild_log_debug "no entrypoint and no cmd"
    $cmd "$_test_image" >/dev/null 2>&1
    return
  fi

  case "$ep_spec" in
    keep)
      cibuild_log_debug "keep entrypoint with cmd: $@"
      cid=$($cmd "$_test_image" "$@" >/dev/null 2>&1)
      ;;
    "")
      cibuild_log_debug "remove entrypoint and call: $@"
      cid=$($cmd "--entrypoint=''" "$_test_image" "$@" >/dev/null 2>&1)
      ;;
    *)
      cibuild_log_debug "entrypoint: $ep_spec cmd: $@"
      cid=$($cmd "--entrypoint=$ep_spec" "$_test_image" "$@")
      ;;
  esac
  
  if [ -z "${cid:-}" ]; then
    cibuild_main_err "[failed] container could not be started."
  fi
  
  i=1
  while [ "$i" -le "$test_run_timeout" ]; do
    status=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)
    running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)

    cibuild_log_info "check container state: status=$status running=$running (t=$i)"

    case "$status" in
      running)
        break
        ;;
      exited|dead)
        cibuild_log_err "[failed] container exited early (status=$status)"
        docker logs "$cid" 2>/dev/null || true
        docker rm -f "$cid" >/dev/null 2>&1
        exit 1
        ;;
      unknown)
        cibuild_main_err "[failed] container not found (cid=$cid)"
        ;;
    esac

    sleep 1
    i=$((i + 1))
  done

  if [ "$i" -gt "$test_run_timeout" ]; then
    cibuild_log_err "[failed] container did not reach running state within ${test_run_timeout}s"
    docker logs "$cid" 2>/dev/null || true
    docker rm -f "$cid" >/dev/null 2>&1
    exit 1
  fi

}

cibuild__test_run_kubernetes() {
  
  local ep_spec \
        cmd

  ep_spec="${1:-keep}"
  shift

  cmd="kubectl run $_pod --image=$_test_image --restart=Never"
  if [ "$ep_spec" = "keep" ] && [ $# -eq 0 ]; then
    cibuild_log_debug "no entrypoint and no cmd"
    $cmd 
    return
  fi

  case "$ep_spec" in
    keep)
      cibuild_log_debug "keep entrypoint with cmd: $@"
      $cmd -- "$@" 
      ;;
    "")
      cibuild_log_debug "remove entrypoint and call: $@"
      $cmd --command -- "$@"
      ;;
    *)
      cibuild_log_debug "entrypoint: $ep_spec cmd: $@"
      $cmd --command -- "$ep_spec" "$@"
      ;;
  esac
}

cibuild__test_detect_docker() {
  local timeout=30
  local i=0

  while [ "$i" -lt "$timeout" ]; do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  return 1
  # sleep 20
  # if ! timeout 20 docker info >/dev/null 2>&1; then
  #   return 1
  # else
  #   return 0
  # fi
}

cibuild__test_detect_kubernetes() {
  
  local test_service_account=$(cibuild_env_get 'test_service_account')

  if [ -z "${test_service_account:-}" ]; then
    cibuild_log_err "CIBUILD_TEST_SERVICE_ACCOUNT env var must not be empty"
    return 1
  fi

  echo "$test_service_account" | base64 -d > /tmp/kubeconfig
  export KUBECONFIG=/tmp/kubeconfig

  #if ! timeout 5 kubectl auth can-i get nodes -q >/dev/null 2>&1; then
  if ! timeout 5 kubectl auth can-i create pods -q >/dev/null 2>&1; then
    return 1
  else
    return 0
  fi
}

# ---------- ASSERT RESPONSE ----------
cibuild__test_assert_response_docker() {
  local ep_spec \
        assert_response \
        port_accessible \
        test_run_timeout=$(cibuild_env_get 'test_run_timeout') \
        i

  _target_port="$1"
  assert_response="$2"
  shift 2

  ep_spec="keep"
  case "$1" in
    keep|"")
      ep_spec="$1"
      shift
      ;;
    *)
      ep_spec="$1"
      shift
      ;;
  esac

  [ "$1" = "--" ] && shift

  cibuild__test_run_docker "$ep_spec" "$@"

  port_accessible=0
  i=1
  while [ $i -le 15 ]; do
    if nc -z "$_host" "$_test_id" 2>/dev/null; then
      port_accessible=1
      break
    fi
    sleep 1
    i=$((i+1))
  done

  if [ "$port_accessible" = 0 ]; then
    cibuild_log_err "[failed] could not access port ${_test_id}"
    docker rm -f "$_container" >/dev/null 2>&1
    exit 1
  fi

  if ! curl --silent -m 5 "http://${_host}:${_test_id}/" | grep "$assert_response" >/dev/null 2>&1; then
    cibuild_log_err "[failed] Test failed!"
    docker rm -f "$_container" >/dev/null 2>&1
    exit 1
  fi

  cibuild_log_info "[success] Test successful"
  docker rm -f "$_container" >/dev/null 2>&1
}

cibuild__test_assert_response_kubernetes() {
  local ep_spec \
        assert_response \
        test_run_timeout=$(cibuild_env_get 'test_run_timeout') \
        PF_PID \
        i

  _target_port="$1"
  assert_response="$2"
  shift 2

  ep_spec="keep"
  case "$1" in
    keep|"")
      ep_spec="$1"
      shift
      ;;
    *)
      ep_spec="$1"
      shift
      ;;
  esac

  [ "$1" = "--" ] && shift

  cibuild__test_run_kubernetes "$ep_spec" "$@"

  kubectl wait --for=condition=ready "pod/$_pod" "--timeout=${test_run_timeout}s"

  setsid kubectl port-forward "pod/$_pod" "$_test_id:$_target_port" >/dev/null 2>&1 &
  PF_PID=$!

  cleanup() {
    kill -TERM -- -"$PF_PID" 2>/dev/null || true
    sleep 1
    kill -KILL -- -"$PF_PID" 2>/dev/null || true
    kubectl delete pod "$_pod" --ignore-not-found >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM

  i=1
  while [ $i -le $test_run_timeout ]; do
    if nc -z "$_host" "$_test_id" 2>/dev/null; then
      break
    fi
    sleep 1
    i=$((i+1))
  done

  if [ $i -gt 15 ]; then
    cibuild_main_err "[failed] could not forward port"
  fi

  if ! curl --silent -m 5 "http://${_host}:${_test_id}/" | grep "$assert_response" >/dev/null 2>&1; then
    cibuild_main_err "[failed] Test failed!"
  fi

  cibuild_log_info "[success] Test successful"
}

# ---------- ASSERT LOG ----------
cibuild__test_assert_log_docker() {
  local pattern="$1"
  shift
  
  local ep_spec="keep"

  case "$1" in
    keep|"")
      ep_spec="$1"
      shift
      ;;
    *)
      ep_spec="$1"
      shift
      ;;
  esac

  [ "$1" = "--" ] && shift

  cibuild__test_run_docker "$ep_spec" "$@"
  
  docker logs "$_container"
  
  if ! docker logs "$_container" | grep -q "$pattern" >/dev/null 2>&1; then
    cibuild_log_err "[failed] Test docker log assertion failed: $pattern"
    docker rm -f "$_container"  >/dev/null 2>&1
    exit 1
  fi

  cibuild_log_info "[success] Test successful"
  docker rm -f "$_container"  >/dev/null 2>&1
}

cibuild__test_assert_log_kubernetes() {
  local pattern="$1"

  shift

  local ep_spec="keep" \
        test_run_timeout=$(cibuild_env_get 'test_run_timeout')
  
  case "$1" in
    keep|"")
      ep_spec="$1"
      shift
      ;;
    *)
      ep_spec="$1"
      shift
      ;;
  esac

  [ "$1" = "--" ] && shift

  cibuild__test_run_kubernetes "$ep_spec" "$@"

  kubectl wait --for=condition=ready "pod/$_pod" "--timeout=${test_run_timeout}s"
  
  #kubectl logs "$_pod"
  
  if ! kubectl logs "$_pod" | grep -q "$pattern" >/dev/null 2>&1; then
    cibuild_log_err "[failed] Test kubernetes log assertion failed: $pattern"
    kubectl delete pod "$_pod" --force  >/dev/null 2>&1
    exit 1
  fi

  cibuild_log_info "[success] Test successful"
  kubectl delete pod "$_pod" --force  >/dev/null 2>&1
}

# ------ PUBLIC GENERIC ASSERTION ------
assert_response() {
  local test_backend=$(cibuild_env_get 'test_backend')
        
  case "$test_backend" in 
    docker)
      if ! cibuild__test_detect_docker; then
        cibuild_main_err "test_backend $test_backend requires available dockerd"
      fi
      _host=docker
      cibuild__test_assert_response_docker "$@"
      ;;
    kubernetes)
      if ! cibuild__test_detect_kubernetes; then
        cibuild_main_err "test_backend $test_backend requires available kubernetes cluster"
      fi
      _host=127.0.0.1
      cibuild__test_assert_response_kubernetes "$@"
      ;;
    *)
      cibuild_main_err "test_backend $test_backend not supported"
      ;;
  esac
}

assert_log() {
  local test_backend=$(cibuild_env_get 'test_backend')
        
  case "$test_backend" in 
    docker)
      if ! cibuild__test_detect_docker; then
        cibuild_main_err "test_backend $test_backend requires available dockerd"
      fi
      _host=docker
      cibuild__test_assert_log_docker "$@"
      ;;
    kubernetes)
      if ! cibuild__test_detect_kubernetes; then
        cibuild_main_err "test_backend $test_backend requires kubernetes and serviceaccount"
      fi
      _host=127.0.0.1
      cibuild__test_assert_log_kubernetes "$@"
      ;;
    *)
      cibuild_main_err "test_backend $test_backend not supported"
      ;;
  esac
}

# ---------- RUN ----------

cibuild__test_image() {
  local target_image=$(cibuild_ci_target_image) \
        target_tag=$(cibuild_ci_target_tag) \
        build_tag=$(cibuild_env_get 'build_tag') \
        platform_tag=$(cibuild_core_get_platform_tag) \
        test_file=$(cibuild_env_get 'test_file')

  _test_id=$((1000 + RANDOM % 9999))
  _test_image="${target_image}:${build_tag}-${target_tag}-${platform_tag}"
  _container="testrun-${_test_id}" # docker
  _pod="testrun-${_test_id}" # kubernetes

  cibuild_log_debug "_test_id $_test_id"
  cibuild_log_debug "_test_image $_test_image"
  cibuild_log_debug "_container $_container"
  cibuild_log_debug "_pod $_pod"
  
  . "$(pwd)/${test_file}"
}

cibuild_test_run() {
  local test_enabled=$(cibuild_env_get 'test_enabled') \
        test_file=$(cibuild_env_get 'test_file')
  
  if [ "${test_enabled:?}" != "1" ]; then
    cibuild_log_info "test run not enabled: test run skipped"
    return
  fi
  
  if [ -z "${test_file:-}" ]; then
    cibuild_log_info "test_file variable empty: test run skipped"
  fi
  
  local test_file_path="$(pwd)/${test_file}"
  if [ ! -f "$test_file_path" ]; then
    cibuild_main_err "$test_file_path not exists."
  fi

  if [ ! -x "$test_file_path" ]; then
    cibuild_main_err "$test_file_path not executable."
  fi
  
  cibuild__test_image

}

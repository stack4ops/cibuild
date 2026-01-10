#!/bin/sh

# -----------------------------------------------------------------------------
# POSIX sh assertion library for Docker & Kubernetes
# -----------------------------------------------------------------------------


_test_id='' # ramdom test_id used also for port binding
_host
_target_port=''
_container=''
_pod=''

# ---------- RUN HELPERS ----------
_run_docker() {
  ep_spec="${1:-keep}"
  shift

  _publish=""

  if [ -n "${_target_port}" ]; then
    log 2 "set publish port"
    _publish="-p ${_test_id}:${_target_port}"
  fi

  cmd="docker run -d --rm --name $_container $_publish"

  if [ "$ep_spec" = "keep" ] && [ $# -eq 0 ]; then
    log 2 "no entrypoint and no cmd"
    $cmd "$test_image" >/dev/null 2>&1
    return
  fi

  case "$ep_spec" in
    keep)
      log 2 "keep entrypoint with cmd: $@"
      CID=$($cmd "$test_image" "$@" >/dev/null 2>&1)
      ;;
    "")
      log 2 "remove entrypoint and call: $@"
      CID=$($cmd "--entrypoint=''" "$test_image" "$@" >/dev/null 2>&1)
      ;;
    *)
      log 2 "entrypoint: $ep_spec cmd: $@"
      CID=$($cmd "--entrypoint=$ep_spec" "$test_image" "$@" >/dev/null 2>&1)
      ;;
  esac
  
  i=0
  while [ "$i" -lt 20 ]
  do
    state=$(docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null || echo false)
    log 1 "check State.Running: $state"
    if [ "$state" = "true" ]; then
      break
    fi

    sleep 1
    i=$((i + 1))
  done

  if [ "$i" -ge $test_run_timeout ]; then
    log 0 "[failed] container did not reach running state within $test_run_timeout seconds"
    docker logs "$CID" 2>/dev/null || true
    docker rm -f "$CID" >/dev/null 2>&1
    exit 1
  fi

}

_run_kubernetes() {
  ep_spec="${1:-keep}"
  shift

  cmd="kubectl run $_pod --image=$test_image --restart=Never"
  if [ "$ep_spec" = "keep" ] && [ $# -eq 0 ]; then
    log 2 "no entrypoint and no cmd"
    $cmd 
    return
  fi

  case "$ep_spec" in
    keep)
      log 2 "keep entrypoint with cmd: $@"
      $cmd -- "$@" 
      ;;
    "")
      log 2 "remove entrypoint and call: $@"
      $cmd --command -- "$@"
      ;;
    *)
      log 2 "entrypoint: $ep_spec cmd: $@"
      $cmd --command -- "$ep_spec" "$@"
      ;;
  esac
}

# ---------- ASSERT RESPONSE ----------
assert_response_docker() {
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

  _run_docker "$ep_spec" "$@"

  port_accessible=0
  i=1
  while [ $i -le 15 ]; do
    if nc -z "$host" "$_test_id" 2>/dev/null; then
      port_accessible=1
      break
    fi
    sleep 1
    i=$((i+1))
  done

  if [ "$port_accessible" = 0 ]; then
    log 0 "[failed] could not access port ${_test_id}"
    docker rm -f "$_container" >/dev/null 2>&1
    exit 1
  fi

  if ! curl --silent -m 5 "http://${host}:${_test_id}/" | grep "$assert_response" >/dev/null 2>&1; then
    log 0 "[failed] Test failed!"
    docker rm -f "$_container" >/dev/null 2>&1
    exit 1
  fi

  log 1 "[success] Test successful"
  docker rm -f "$_container" >/dev/null 2>&1
}

assert_response_kubernetes() {
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

  _run_kubernetes "$ep_spec" "$@"

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
    if nc -z "$host" "$_test_id" 2>/dev/null; then
      break
    fi
    sleep 1
    i=$((i+1))
  done

  if [ $i -gt 15 ]; then
    log 0 "[failed] could not forward port"
    exit 1
  fi

  if ! curl --silent -m 5 "http://${host}:${_test_id}/" | grep "$assert_response" >/dev/null 2>&1; then
    log 0 "[failed] Test failed!"
    exit 1
  fi

  log 1 "[success] Test successful"
}

# ---------- ASSERT LOG ----------
assert_log_docker() {
  pattern="$1"

  shift

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

  _run_docker "$ep_spec" "$@"
  
  docker logs "$_container"
  
  if ! docker logs "$_container" | grep -q "$pattern" >/dev/null 2>&1; then
    log 0 "[failed] Test docker log assertion failed: $pattern"
    docker rm -f "$_container"  >/dev/null 2>&1
    exit 1
  fi

  log 1 "[success] Test successful"
  docker rm -f "$_container"  >/dev/null 2>&1
}

assert_log_kubernetes() {
  pattern="$1"

  shift

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

  _run_kubernetes "$ep_spec" "$@"
  
  log 1 "${test_run_timeout}s"

  kubectl wait --for=condition=ready "pod/$_pod" "--timeout=${test_run_timeout}s"
  
  kubectl logs "$_pod"
  
  if ! kubectl logs "$_pod" | grep -q "$pattern" >/dev/null 2>&1; then
    log 0 "[failed] Test kubernetes log assertion failed: $pattern"
    kubectl delete pod "$_pod" --force  >/dev/null 2>&1
    exit 1
  fi

  log 1 "[success] Test successful"
  kubectl delete pod "$_pod" --force  >/dev/null 2>&1

}

# ---------- GENERIC ENTRY POINT ----------
assert_response() {
 
  if [ "$test_backend" = "docker" ]; then
    assert_response_docker "$@"
  else
    assert_response_kubernetes "$@"
  fi
}

assert_log() {
  if [ "$test_backend" = "docker" ]; then
    assert_log_docker "$@"
  else
    assert_log_kubernetes "$@"
  fi
}

image_test() {
  log 1 "start: test image"
   _test_id=$((1000 + RANDOM % 9999))
  test_image="${target_image:?}:${build_tag:?}-$(get_platform_tag)"
  log 1 "test_image: $test_image"
  case "${test_backend}" in
    docker)
      host=docker
      ;;
    kubernetes)
      if [ -z "${TESTSTAGE_SERVICE_ACCOUNT}" ]; then
        log 0 "TESTSTAGE_SERVICE_ACCOUNT required for ${test_backend}"
        exit 1
      fi
      host=127.0.0.1
      echo "$TESTSTAGE_SERVICE_ACCOUNT" | base64 -d > /tmp/kubeconfig
      export KUBECONFIG=/tmp/kubeconfig
      ;;
    *)
      log 0 "test_backend $test_backend not supported"
      exit 1
      ;;
  esac
  _container="testrun-${_test_id}" # docker
  _pod="testrun-${_test_id}" # kubernetes
  . "${test_file}"
}

test() {
  _test_id=''
  _target_port=''
  _container=''
 
  if [ "${cibuild_test_enabled:?}" != "1" ]; then
    log 1 "test run skipped"
    return
  fi
  log 1 ${test_file}
  if [ ! -f "${test_file}" ]; then
    log 1 "no test file"
    return
  fi
  if [ ! -x "${test_file}" ]; then
    log 1 "test file not executable"
    return
  fi
  log 1 "run: test"

  image_test

}

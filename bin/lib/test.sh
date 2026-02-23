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
  local entrypoint="$1" \
        cid \
        test_run_timeout=$(cibuild_env_get 'test_run_timeout') \
        target_registry=$(cibuild_ci_target_registry)

  #shift entrypoint
  shift

  if [ -n "${_target_port}" ]; then
    cibuild_log_debug "set publish port"
    _publish="-p ${_test_id}:${_target_port}"
  fi

  if [ "$entrypoint" = "keep" ] && [ $# -eq 0 ]; then
    cibuild_log_debug "no entrypoint and no cmd"
    cid=$(
      docker run -d --rm \
        --name "$_container" \
        ${_publish} \
        "$_test_image"
        2>/dev/null
    )
    cibuild_log_debug $cid
  else
    case "$entrypoint" in
      keep)
        cibuild_log_debug "keep entrypoint with cmd: $@"
        cid=$(
          docker run -d --rm \
          --name "$_container" \
          ${_publish} \
          "$_test_image" \
          "$@" \
          2>/dev/null
        )
        ;;
      "")
        cibuild_log_debug "remove entrypoint and call: $@"
        cid=$(
          docker run -d --rm \
          --name "$_container" \
          ${_publish} \
          --entrypoint='' \
          "$_test_image" \
          "$@" \
          2>/dev/null
        )
        ;;
      *)
        cibuild_log_debug "entrypoint: $entrypoint cmd: $@"
        cid=$(
          docker run -d --rm \
          --name "$_container" \
          ${_publish} \
          --entrypoint=$entrypoint \
          "$_test_image" \
          "$@" \
          2>/dev/null
        )
        ;;
    esac
  fi
  
  if [ -z "${cid:-}" ]; then
    cibuild_main_err "[failed] container could not be started."
  fi
  
  local i=1
  while [ "$i" -le "$test_run_timeout" ]; do
    status=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)
    running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)

    cibuild_log_info "check container state: status=$status running=$running (t=$i)"

    case "$status" in
      running)
        if docker logs "$_container" 2>/dev/null; then
          echo "container running and logs available"
          sleep 1
          break
        fi
        ;;
      exited|dead|removing)
        cibuild_log_err "[failed] container exited early (status=$status, cid=$cid)"
        docker logs "$cid" 2>/dev/null || true
        docker rm -f "$cid" >/dev/null 2>&1
        exit 1
        ;;
      unknown)
        cibuild_main_err "[failed] container not found (cid=$cid)"
        ;;
      *)
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
  local assert="$1" \
        entrypoint="$3" \
        test_run_timeout=$(cibuild_env_get 'test_run_timeout')
  
  # global
  _target_port="$2"
  
  shift 3
  
  cibuild_log_debug $_target_port
  cibuild_log_debug $assert

  if [ -n "$@" ]; then
    cibuild__test_run_docker "$entrypoint" "$@"
  else
    cibuild__test_run_docker "$entrypoint"
  fi

  local port_accessible=0
  local i=1
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

  if ! curl --silent -m 5 "http://${_host}:${_test_id}/" | grep "$assert" >/dev/null 2>&1; then
    cibuild_log_err "[failed] Test failed!"
    docker rm -f "$_container" >/dev/null 2>&1
    exit 1
  fi

  cibuild_log_info "[success] Test successful"
  docker rm -f "$_container" >/dev/null 2>&1
}

cibuild__test_assert_response_kubernetes() {
  local assert="$1" \
        entrypoint="$3" \
        test_run_timeout=$(cibuild_env_get 'test_run_timeout')
  
  # global
  _target_port="$2"
  
  shift 3
  
  cibuild_log_debug $_target_port
  cibuild_log_debug $assert

  if [ -n "$@" ]; then
    cibuild__test_run_kubernetes "$entrypoint" "$@"
  else
    cibuild__test_run_kubernetes "$entrypoint"
  fi

  kubectl wait --for=condition=ready "pod/$_pod" "--timeout=${test_run_timeout}s"

  setsid kubectl port-forward "pod/$_pod" "$_test_id:$_target_port" >/dev/null 2>&1 &
  local PF_PID=$!

  cleanup() {
    kill -TERM -- -"$PF_PID" 2>/dev/null || true
    sleep 1
    kill -KILL -- -"$PF_PID" 2>/dev/null || true
    kubectl delete pod "$_pod" --ignore-not-found >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM

  local i=1
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

  if ! curl --silent -m 5 "http://${_host}:${_test_id}/" | grep "$assert" >/dev/null 2>&1; then
    cibuild_main_err "[failed] Test failed!"
  fi

  cibuild_log_info "[success] Test successful"
}

# ---------- ASSERT LOG ----------
cibuild__test_assert_log_docker() {
  local assert="$1" \
        entrypoint="$2" \
        test_run_timeout=$(cibuild_env_get 'test_run_timeout') \
        test_log_timeout=$(cibuild_env_get 'test_log_timeout')
  
  shift 2

  cibuild_log_debug $assert

  if [ -n "$1" ]; then
    cibuild__test_run_docker "$entrypoint" "$@"
  else
    cibuild__test_run_docker "$entrypoint"
  fi
  
  local i=1
  local success=0

  while [ $i -le $test_log_timeout ]; do
    if docker logs "$_container" 2>&1 | grep -qF "$assert"; then
      success=1
      break
    fi
    sleep 1
    i=$((i+1))
  done
  
  if [ "$success" != "1" ]; then
    cibuild_log_err "[failed] Test docker log assertion failed: $assert"
    docker rm -f "$_container"  >/dev/null 2>&1
    exit 1
  fi

  cibuild_log_info "[success] Test successful"
  docker rm -f "$_container"  >/dev/null 2>&1
}

cibuild__test_assert_log_kubernetes() {
  local assert="$1" \
        entrypoint="$2" \
        test_run_timeout=$(cibuild_env_get 'test_run_timeout') \
        test_log_timeout=$(cibuild_env_get 'test_log_timeout')
  
  shift 2
  
  cibuild_log_debug $assert

  if [ -n "$1" ]; then
    cibuild__test_run_kubernetes "$entrypoint" "$@"
  else
    cibuild__test_run_kubernetes "$entrypoint"
  fi

  kubectl wait --for=condition=ready "pod/$_pod" "--timeout=${test_run_timeout}s"

  local i=1
  local success=0

  while [ $i -le $test_log_timeout ]; do
    if kubectl logs "$_pod" 2>&1 | grep -qF "$assert"; then
      success=1
      break
    fi
    sleep 1
    i=$((i+1))
  done
  
  if [ "$success" != "1" ]; then
    cibuild_log_err "[failed] Test kubernetes log assertion failed: $assert"
    kubectl delete pod "$_pod" --force  >/dev/null 2>&1
    exit 1
  fi
    
  cibuild_log_info "[success] Test successful"
  kubectl delete pod "$_pod" --force  >/dev/null 2>&1
}

# ------ PUBLIC GENERIC ASSERTION ------
assert_response() {
  if [ $# -lt 3 ]; then
    cibuild_main_err "Usage: assert_repspone assert port entrypoint:'keep'=keep entrypoint|''=remove entrypoint|'entrypoint p.e. /bin/sh' optional cmd params p.e. '-c' 'ls -lat'"
  fi
  local test_backend=$(cibuild_env_get 'test_backend') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        platform_name=$(cibuild_core_get_platform_name)
        
  _test_id=$((1000 + RANDOM % 9999))
  _test_image="${target_image}-${platform_name}:${build_tag}"
  _container="testrun-${_test_id}"
  _pod="testrun-${_test_id}"

  cibuild_log_debug "_test_id $_test_id"
  cibuild_log_debug "_test_image $_test_image"
  cibuild_log_debug "_container $_container"
  cibuild_log_debug "_pod $_pod"
  
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
  if [ $# -lt 2 ]; then
    cibuild_main_err "Usage: assert_log assert entrypoint:'keep'=keep entrypoint|''=remove entrypoint|'entrypoint p.e. /bin/sh' optional cmd params p.e. '-c' 'ls -lat'"
  fi
  local test_backend=$(cibuild_env_get 'test_backend') \
        target_image=$(cibuild_ci_target_image) \
        build_tag=$(cibuild_ci_build_tag) \
        platform_name=$(cibuild_core_get_platform_name)

  _test_id=$((1000 + RANDOM % 9999))
  _test_image="${target_image}-${platform_name}:${build_tag}"
  _container="testrun-${_test_id}"
  _pod="testrun-${_test_id}"

  cibuild_log_debug "_test_id $_test_id"
  cibuild_log_debug "_test_image $_test_image"
  cibuild_log_debug "_container $_container"
  cibuild_log_debug "_pod $_pod"
      
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
  mode=$1
  
  cibuild_log_debug "test mode: $mode"

  local test_script_file
  local test_assert_file
  test_script_file=$(cibuild_env_get 'test_script_file')
  test_assert_file=$(cibuild_env_get 'test_assert_file')

  case "$mode" in
    script)
      cibuild_log_debug "script"
      . "$(pwd)/${test_script_file}"
      ;;

    assert)
      cibuild_log_debug "assert"
      tmpfile=$(mktemp /tmp/cibuild_asserts.XXXXXX)
      #tmpfile="/tmp/cibuild_asserts.$$"
      jq -c '
      .[] |
      {
        type,
        entrypoint:
        (if has("entrypoint")
        then
          if (.entrypoint | type == "string")
          then .entrypoint
          else error("entrypoint must be string")
          end
        else
          "keep"
        end),
        port: (.port // ""),
        assert,
        cmd: (.cmd // [])
      }
      ' "$(pwd)/${test_assert_file}" > "$tmpfile" || exit 1

      while IFS= read -r item; do
      
        type=$(printf '%s\n' "$item" | jq -r '.type')
        entrypoint=$(printf '%s\n' "$item" | jq -r '.entrypoint')
        port=$(printf '%s\n' "$item" | jq -r '.port')
        assert=$(printf '%s\n' "$item" | jq -r '.assert')
        cmd_json=$(printf '%s\n' "$item" | jq -c '.cmd // []')

        set --
          while IFS= read -r arg; do
            set -- "$@" "$arg"
          done <<EOF
$(printf '%s\n' "$cmd_json" | jq -r '.[]')
EOF

      case "$type" in
        log)
          assert_log "$assert" "$entrypoint" "$@"
          ;;
        response)
          assert_response "$assert" "$port" "$entrypoint" "$@"
          ;;
        *)
          cibuild_main_err "unknown assert type: $type"
          ;;
      esac
    done < "$tmpfile"

      rm -f "$tmpfile"
      ;;
  esac
}

cibuild_test_run() {
  local test_enabled=$(cibuild_env_get 'test_enabled') \
        test_script_file=$(cibuild_env_get 'test_script_file') \
        test_assert_file=$(cibuild_env_get 'test_assert_file')
  
  if [ "${test_enabled:?}" != "1" ]; then
    cibuild_log_info "test run not enabled: test run skipped"
    return
  fi

  if ! cibuild_core_run_script test pre; then
    exit 1
  fi

  local test_script_file_path="$(pwd)/${test_script_file}"
  if [ ! -f "$test_script_file_path" ]; then
    cibuild_log_info "no test_script_file: ${test_script_file}"
  else
    if [ ! -x "$test_script_file_path" ]; then
      cibuild_main_err "${test_script_file} not executable."
    fi
    if [ -d "/tmp/cibuilder.locked" ]; then
      cibuild_log_err "cibuilder.locked: script execution is not allowed"
    else
      cibuild__test_image script
    fi
  fi

  local test_assert_file_path="$(pwd)/${test_assert_file}"
  if [ ! -f "$test_assert_file_path" ]; then
    cibuild_log_info "no test_assert_file: ${test_assert_file}"
  else
    cibuild__test_image assert
  fi

  if ! cibuild_core_run_script test post; then
    exit 1
  fi
}

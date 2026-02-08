#!/bin/sh

set -eu

PROJECT_DIR="${CI_PROJECT_DIR:-$(pwd)}"

# only dynamic cibuild loading libs if not locked
if [ ! -d "/tmp/cibuilder.locked" ]; then
    if [ -n "${CIBUILDER_BIN_URL:-}" ] || [ -n "${CIBUILDER_BIN_REF:-}" ]; then
        CIBUILDER_BIN_URL="${CIBUILDER_BIN_URL:-https://gitlab.com/stack4ops/public/cibuild/-/archive}"
        CIBUILDER_BIN_REF="${CIBUILDER_BIN_REF:-main}"

        echo "using CIBUILDER_BIN_URL: ${CIBUILDER_BIN_URL}"
        echo "using CIBUILDER_BIN_REF: ${CIBUILDER_BIN_REF}"
        
        cd /home/user

        if [ -d "bin" ]; then
            echo "delete existing /home/user/bin folder"
            rm -r "bin"
        fi

        curl -L -s "${CIBUILDER_BIN_URL}/${CIBUILDER_BIN_REF}/cibuild-${CIBUILDER_BIN_REF}.tar.gz" | tar xzf - --strip-components=1 "cibuild-${CIBUILDER_BIN_REF}/bin"
        chmod -R 755 "bin"
    fi
fi

# return to repo
cd "$PROJECT_DIR"

# set generic default BUILDKITD_FLAGS working mostly everywhere
export BUILDKITD_FLAGS="${BUILDKITD_FLAGS:--oci-worker-no-process-sandbox}"

: "${CIBUILD_RUN_CMD:?missing CIBUILD_RUN_CMD}"

exec_cmd() {
    if [ "${CIBUILDER_ROOTLESS_KIT:-1}" = "1" ]; then
        echo "running in rootlesskit"
        rootlesskit -- /bin/sh -c "cibuild -r $CIBUILD_RUN_CMD"
    else
        echo "running without rootlesskit"
        cibuild -r $CIBUILD_RUN_CMD
    fi
}

case "$CIBUILD_RUN_CMD" in
  check)  exec_cmd ;;
  build)  exec_cmd ;;
  test)   exec_cmd ;;
  deploy) exec_cmd ;;
  all)    exec_cmd ;;
  *)
    echo "unsupported CIBUILD_RUN_CMD: $CIBUILD_RUN_CMD"
    exit 1
    ;;
esac

# case "$CIBUILD_RUN_CMD" in
#   check)  rootlesskit -- /bin/sh -c 'cibuild -r check' ;;
#   build)  rootlesskit -- /bin/sh -c 'cibuild -r build' ;;
#   test)   rootlesskit -- /bin/sh -c 'cibuild -r test' ;;
#   deploy) rootlesskit -- /bin/sh -c 'cibuild -r deploy' ;;
#   all)    rootlesskit -- /bin/sh -c 'cibuild -r all' ;;
#   *)
#     echo "unsupported CIBUILD_RUN_CMD: $CIBUILD_RUN_CMD"
#     exit 1
#     ;;
# esac

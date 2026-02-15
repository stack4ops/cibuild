#!/bin/sh

# Package cibuild

# ---- imports ----
. "$CIBUILD_LIB_PATH/env.sh"
. "$CIBUILD_LIB_PATH/log.sh"
. "$CIBUILD_LIB_PATH/core.sh"
. "$CIBUILD_LIB_PATH/check.sh"
. "$CIBUILD_LIB_PATH/build.sh"
. "$CIBUILD_LIB_PATH/test.sh"
. "$CIBUILD_LIB_PATH/release.sh"

cibuild_main_err() { 
  cibuild_log_err "$1"
  exit 1
}

cibuild_core_init

CIBUILD_VERSION="0.8.0"

# Usage / help
usage() {
  echo ""
  echo "cibuild - CI build tool"
  echo ""
  echo "Run cibuild in $(pwd)"
  echo ""
  echo "Usage:"
  echo "  $(basename "$0") -r [RUN]"
  echo ""
  echo "Args:"
  echo "  -h, --help       Show this help"
  echo "  -v, --version    Show version"
  echo "  -r, --run        Run command: check|build|test|release|all"
  echo ""
}

# Parse flags
CIBUILD_RUN_CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -v|--version)
      echo "$CIBUILD_VERSION"
      exit 0
      ;;
    -r|--run)
      shift
      CIBUILD_RUN_CMD="$1"
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

# Dispatch commands (Cobra-like)
case "$CIBUILD_RUN_CMD" in
  check)
    cibuild_log_info "Running check..."
    cibuild_check_run
    ;;
  build)
    cibuild_log_info "Running build..."
    cibuild_build_run
    ;;
  test)
    cibuild_log_info "Running test..."
    cibuild_test_run
    ;;
  release)
    cibuild_log_info "Running release..."
    cibuild_release_run
    ;;
  all)
    cibuild_log_info "All runs..."
    cibuild_log_info "Running check..."
    cibuild_check_run
    cibuild_log_info "Running build..."
    cibuild_build_run
    cibuild_log_info "Running test..."
    cibuild_test_run
    cibuild_log_info "Running release..."
    cibuild_release_run
    ;;
  *)
    cibuild_log_info "Unknown run command: $CIBUILD_RUN_CMD"
    usage
    exit 1
    ;;
esac

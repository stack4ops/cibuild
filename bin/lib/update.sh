#!/bin/sh
# Package cibuild/update

# ---- Guard ----
[ -n "${_CIBUILD_UPDATE_LOADED-}" ] && return
_CIBUILD_UPDATE_LOADED=1

# ---------- TRIVY DB ----------
cibuild__update_trivy_db() {
  local update_trivy=$(cibuild_env_get 'update_trivy_db')

  if [ "${update_trivy}" != "1" ]; then
    cibuild_log_info "trivy db update not enabled: skipped"
    return
  fi

  if ! command -v trivy >/dev/null 2>&1; then
    cibuild_log_err "trivy not found — is this the release or update image?"
    return 1
  fi

  local cache_dir="${HOME}/.cache/trivy"

  cibuild_log_info "updating trivy vulnerability DB -> ${cache_dir}"
  trivy image --download-db-only --cache-dir "${cache_dir}"
  cibuild_log_info "trivy DB update done"

  cibuild_log_info "updating trivy Java DB -> ${cache_dir}"
  trivy image --download-java-db-only --cache-dir "${cache_dir}" || \
    cibuild_log_info "trivy Java DB update skipped (non-fatal)"
}

# ---------- RUN ----------
cibuild_update_run() {
  local update_enabled=$(cibuild_env_get 'update_enabled')

  if [ "${update_enabled}" != "1" ]; then
    cibuild_log_info "update run not enabled: skipped"
    return
  fi

  cibuild_log_info "Running update..."

  cibuild__update_trivy_db
}
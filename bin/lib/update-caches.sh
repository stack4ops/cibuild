#!/bin/sh
# Package cibuild/update-caches

# ---- Guard ----
[ -n "${_CIBUILD_UPDATE_CACHES_LOADED-}"] && return
_CIBUILD_UPDATE_CACHES_LOADED=1

# ---------- TRIVY DB ----------
cibuild__update_caches_trivy_db() {
  local update_trivy=$(cibuild_env_get 'update_caches_trivy_db')

  if [ "${update_trivy}" != "1" ]; then
    cibuild_log_info "trivy db update not enabled: skipped"
    return
  fi

  if ! command -v trivy >/dev/null 2>&1; then
    cibuild_log_err "trivy not found — is this the update-caches image?"
    return 1
  fi

  local cache_dir="${HOME}/.cache/trivy"

  cibuild_log_info "updating trivy vulnerability DB -> ${cache_dir}"
  trivy --quiet image --download-db-only --cache-dir "${cache_dir}"
  cibuild_log_info "trivy DB update done"
}

# ---------- RUN ----------
cibuild_update_caches_run() {
  local update_caches_enabled=$(cibuild_env_get 'update_caches_enabled')

  if [ "${update_caches_enabled}" != "1" ]; then
    cibuild_log_info "update-caches run not enabled: skipped"
    return
  fi

  cibuild_log_info "Running update-caches..."

  cibuild__update_caches_trivy_db
}
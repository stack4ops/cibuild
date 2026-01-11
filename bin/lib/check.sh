#!/bin/sh
# Package cibuild/check

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_CHECK_LOADED-}" ] && return
_CIBUILD_CHECK_LOADED=1

cibuild__check_base_image() {
  set -o pipefail
  local layers_base_image_cache \
        layers_target_image_cache \
        layers_intersection \
        difference_base_image_layers \
        rand \
        base_image=$(cibuild_core_base_image) \
        base_tag=$(cibuild_core_base_tag) \
        target_image=$(cibuild_ci_target_image) \
        target_tag=$(cibuild_ci_target_tag)
  
  rand=$RANDOM
  layers_base_image_cache="/tmp/base_image_layers_${rand}.json"
  layers_target_image_cache="/tmp/target_image_layers_${rand}.json"
  layers_intersection="/tmp/layers_intersection_${rand}.json"

  clean_up() {
    rm -f \
      "${layers_base_image_cache}" \
      "${layers_target_image_cache}" \
      "${layers_intersection}"
  }

  # --- base image ---
  if ! regctl -v error manifest get "${base_image:?}:${base_tag:?}" --format raw-body --platform local \
        | jq '[.layers[].digest]' >"${layers_base_image_cache}"; then
    cibuild_log_err "cannot get base image ${base_image}:${base_tag}. Abort"
    clean_up
    exit 1
  fi
  
  # --- target image ---
  if ! regctl -v error manifest get "${target_image:?}:${target_tag:?}" --format raw-body --platform local \
        | jq '[.layers[].digest]' >"${layers_target_image_cache}"; then
    cibuild_log_info "cannot get last target image ${target_image}:${target_tag}. Assume this is the first build"
    clean_up
    return 0
  fi

  # intersection of layer lists
  jq -s '.[0] - (.[0] - .[1])' \
    "${layers_target_image_cache}" \
    "${layers_base_image_cache}" \
    >"${layers_intersection}"

  cibuild_log_dump  "intersection of image layers"
  while IFS= read -r line; do
    cibuild_log_dump "$line"
  done <"$layers_intersection"
  
  # difference between base image and intersection
  difference_base_image_layers=$(
    jq -s '.[0] - .[1] | length' \
      "${layers_base_image_cache}" \
      "${layers_intersection}"
  )

  cibuild_log_dump "Difference between intersection and base_image layers"
  local diff=$(jq -s '.[0] - .[1]' \
    "${layers_base_image_cache}" \
    "${layers_intersection}"
  )
  cibuild_log_dump $diff

  if [ "$difference_base_image_layers" -gt 0 ]; then
    cibuild_log_info "found a difference in the base image layers, build new image"
    clean_up
    return 0
  else
    cibuild_log_info "found no difference in base image layers"
    clean_up
    return 2
  fi
}

cibuild_check_run() {
  local check_enabled=$(cibuild_env_get 'check_enabled') \
        base_image_check_ret \
        build_force=$(cibuild_env_get 'build_force')

  if [ "${check_enabled:?}" != "1" ]; then
    cibuild_log_info "check run skipped"
    return
  fi
  # only check in scheduled pipelines not commits or other triggers
  
  if [ "$(cibuild_ci_type)" != "local" ]; then
    if ! $(cibuild_ci_scheduled); then
      cibuild_log_info "check only in schedule ci pipeline or local"
      return
    fi
  fi

  cibuild__check_base_image

  base_image_check_ret=$?

  if [ "${base_image_check_ret}" = "2" ]; then
    if [ "${build_force}" = "1" ]; then
      cibuild_log_info "build force: pipeline not canceled"
    else
      if ! cibuild_ci_cancel; then
        cibuild_main_err "something went wrong during pipeline cancelation"
      fi
      exit 0
    fi
  fi
  cibuild_log_info "check ok"
}

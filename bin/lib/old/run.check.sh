#!/bin/sh

set -o pipefail

cancel_pipeline() {
  log 2 "cancel pipeline"
  #pipeline_canceled=1
  if [ "$cibuild_pipeline_env" = 'local' ]; then
    exit 0
  else
    : "${CI_API_V4_URL:?missing CI_API_V4_URL}"
    : "${CI_PROJECT_ID:?missing CI_PROJECT_ID}"
    : "${CI_PIPELINE_ID:?missing CI_PIPELINE_ID}"
    cancel_url="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}/cancel"
    if ! curl -sS -f -X POST \
      -H "PRIVATE-TOKEN: ${cibuild_cancel_token}" \
      "${cancel_url}" \
      >/dev/null; then
      log 0 "failed to cancel pipeline via GitLab API"
      exit 1
    fi
    exit 0
  fi
}

check_base_image() {

  log 1 "start: check_base_image"

  rand=$RANDOM
  layers_base_image_cache="${cache_folder:-/tmp}/base_image_layers_${rand}.json"
  layers_target_image_cache="${cache_folder:-/tmp}/target_image_layers_${rand}.json"
  layers_intersection="${cache_folder:-/tmp}/layers_intersection_${rand}.json"

  clean_up() {
    rm -f \
      "${layers_base_image_cache}" \
      "${layers_target_image_cache}" \
      "${layers_intersection}"
  }

  # --- base image ---
  if ! regctl -v error manifest get "${base_image:?}:${base_tag:?}" --format raw-body --platform local \
        | jq '[.layers[].digest]' >"${layers_base_image_cache}"; then
    log 0 "cannot get base image ${base_image}:${base_tag}. Abort"
    clean_up
    exit 1
  fi
  
  # --- target image ---
  if ! regctl -v error manifest get "${target_image:?}:${target_tag:?}" --format raw-body --platform local \
        | jq '[.layers[].digest]' >"${layers_target_image_cache}"; then
    log 1 "cannot get last target image ${target_image}:${target_tag}. Assume this is the first build"
    clean_up
    return 0
  fi

  # intersection of layer lists
  jq -s '.[0] - (.[0] - .[1])' \
    "${layers_target_image_cache}" \
    "${layers_base_image_cache}" \
    >"${layers_intersection}"

  if [ "${cibuild_loglevel}" = "3" ]; then
    log 3 "intersection of image layers"
    cat "${layers_intersection}"
  fi

  # difference between base image and intersection
  difference_base_image_layers=$(
    jq -s '.[0] - .[1] | length' \
      "${layers_base_image_cache}" \
      "${layers_intersection}"
  )

  if [ "${cibuild_loglevel}" = "3" ]; then
    log 2 "Difference between intersection and base_image layers"
    jq -s '.[0] - .[1]' \
      "${layers_base_image_cache}" \
      "${layers_intersection}"
  fi

  if [ "$difference_base_image_layers" -gt 0 ]; then
    log 1 "found a difference in the base image layers, build new image"
    clean_up
    return 0
  else
    log 1 "found no difference in base image layers"
    clean_up
    return 2
  fi
}

function check() {
  if [ "${cibuild_check_enabled:?}" != "1" ]; then
    log 1 "check run skipped"
    return
  fi

  # only check in scheduled pipelines not commits or other triggers
  if [ "${cibuild_pipeline_env}" = "ci" ] && [ "${CI_PIPELINE_SOURCE:-}" != "schedule" ]; then
    log 2 "check only in schedule ci pipeline or local"
    return
  fi

  log 1 "run: check"

  check_base_image

  base_image_check_ret=$?

  if [ "${base_image_check_ret}" = "2" ]; then
    if [ "${cibuild_build_force}" = "1" ]; then
      log 1 "build force: pipeline not canceled"
    else
      if ! cancel_pipeline; then
        log 0 "something went wrong during pipeline cancelation"
        exit 1
      fi
      exit 0
    fi
  fi
  log 1 "check ok"
}
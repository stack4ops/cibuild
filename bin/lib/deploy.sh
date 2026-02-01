#!/bin/sh
# Package cibuild/deploy

# All deployable artifacts and their attestations are signed 
# by the same cryptographic identity to ensure a single, auditable trust root.

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_DEPLOY_LOADED-}" ] && return
_CIBUILD_DEPLOY_LOADED=1

cibuild__get_docker_attestation_digest() {
  local target_image=$(cibuild_ci_target_image)
  local image_ref="$1"
  local ref_digest=$(regctl -v error manifest head ${image_ref})
  local attestation=$(regctl -v error manifest get "${target_image}@${ref_digest}" \
    --format '{{range .Manifests}}{{if eq (index .Annotations "vnd.docker.reference.type") "attestation-manifest"}}{{.Digest}}{{end}}{{end}}') \
    || {
      cibuild_log_err "error getting attestation digest"
      exit 1
    }

  printf '%s\n' "$attestation"
}

cibuild__deploy_copy_tag() {
  local copy_to_tag="$1" \
        target_image=$(cibuild_ci_target_image) \
        target_tag=$(cibuild_ci_target_tag)
        
  if ! regctl -v error image copy ${target_image}:${target_tag} ${target_image}:${copy_to_tag} >/dev/null 2>&1; then
      cibuild_log_err "failed to copy ${target_image}:${target_tag} to ${target_image}:${copy_to_tag}"
      return 1
  fi
  return 0
}

cibuild__deploy_create_index() {
  
  local target_image=$(cibuild_ci_target_image) \
        target_tag=$(cibuild_ci_target_tag) \
        platforms \
        build_platforms=$(cibuild_env_get 'build_platforms') \
        build_tag=$(cibuild_env_get 'build_tag') \
        image_tag \
        deploy_docker_attestation_autodetect=$(cibuild_env_get 'deploy_docker_attestation_autodetect') \
        deploy_docker_attestation_manifest=$(cibuild_env_get 'deploy_docker_attestation_manifest') \
        target_registry=$(cibuild_ci_target_registry) \
        ref_digest \
        image_digest \
        deploy_signature=$(cibuild_env_get 'deploy_signature')

  platforms=$(echo "$build_platforms" | tr ',' ' ')

  local create_args=""
  local found=0

  for platform in $platforms; do
    platform_tag=$(echo "$platform" | tr '/' '-')
    image_tag="${build_tag}-${target_tag}-${platform_tag}"
    ref="${target_image}:${image_tag}"

    if regctl -v error manifest head "$ref" >/dev/null 2>&1; then
      create_args="$create_args --ref $ref --platform $platform"
      found=1
    else
      cibuild_main_err "missing image $ref, skipping"
    fi
  done

  if [ "$found" -eq 0 ]; then
    cibuild_main_err "no platform images found, cannot create index ${target_image}:${target_tag}"
  fi

  if ! regctl -v error index create "$target_image:$target_tag" $create_args; then
    cibuild_main_err "error creating image index ${target_image}:${target_tag}"
  fi
  
  cibuild_log_debug "image index created: ${target_image}:${target_tag} for $platforms"

  if [ "${deploy_docker_attestation_autodetect}" = "1" ] && [ "${target_registry}" = "docker.io" ]; then
    cibuild_log_debug "docker.io detected as target_registry set deploy_docker_attestation_manifest=1"
    deploy_docker_attestation_manifest=1
  fi

  if [ "${deploy_docker_attestation_manifest}" = "1" ]; then
    cibuild_log_debug "add docker attestation manifest"
    # only one platform is required for referencing
    # if linux/amd64 is not found first platform im array is used
    set -- $platforms
    first=$1
    value=linux/amd64

    case " $platforms " in
      *" $value "*) platform="$value" ;;
      *) platform="$first" ;;
    esac
    platform_tag=$(echo "${platform}" | tr '/' '-')
    image_tag="${build_tag}-${target_tag}-${platform_tag}"

    #ref_digest=$(regctl -v error manifest head ${target_image}:${image_tag} --platform unknown/unknown)
    ref_digest=$(cibuild__get_docker_attestation_digest "${target_image}:${image_tag}")
    
    cibuild_log_debug "ref_digest: $ref_digest"
    image_digest=$(regctl -v error manifest head ${target_image}:${image_tag} --platform ${platform})

    if ! regctl -v error index add "${target_image}:${target_tag}" \
      --ref ${target_image}@${ref_digest} \
      --desc-platform unknown/unknown \
      --desc-annotation vnd.docker.reference.type=attestation-manifest \
      --desc-annotation vnd.docker.reference.digest=${image_digest}; then
      cibuild_main_err "error adding docker attestation manifest"
    fi
  fi

  target_digest=$(regctl -v error manifest head ${target_image}:${target_tag})
  cibuild_log_debug "target_digest 1: $target_digest"
  
  if [ "${deploy_signature:-0}" = "1" ]; then
    cibuild_log_debug "signing ${target_image}@${target_digest}"
    export COSIGN_PASSWORD="" && cosign sign --key /tmp/cosign.key "${target_image}@${target_digest}"
    cosign verify --key /tmp/cosign.pub "${target_image}@${target_digest}"
    cosign verify --key /tmp/cosign.pub "${target_image}:${target_tag}"
  fi
}

cibuild__deploy_additional_tags() {
  local deploy_additional_tags=$(cibuild_env_get 'deploy_additional_tags')
  local tag

  IFS=',;'
  set -- $deploy_additional_tags
  unset IFS
  
  for tag; do
    local processed_tag=$(cibuild_ci_process_tag "$tag")
    cibuild_log_debug "adding addtional tag $processed_tag"
    if ! cibuild__deploy_copy_tag "$processed_tag"; then
       cibuild_log_err "error assigning additional tag $processed_tag"
       continue
    fi
  done

}

cibuild__deploy_minor_tag() {

  local deploy_minor_tag_regex=$(cibuild_env_get 'deploy_minor_tag_regex') \
        base_image=$(cibuild_core_base_image) \
        base_tag=$(cibuild_core_base_tag) \
        ref \
        current_digest \

  if [ -z "${deploy_minor_tag_regex:-}" ]; then
    cibuild_log_debug "no minor tag regex defined. skipping get_minor_tag"
    return 0
  fi

  ref="${base_image}:${base_tag}"
  
  # retrieve digest for base_tag
  if ! current_digest=$(regctl -v error image digest "$ref"); then
    cibuild_log_err "failed to get digest for $ref"
    return 1
  fi

  cibuild_log_debug "current_digest: $current_digest"
  cibuild_log_debug "minor_tag_regex: ${deploy_minor_tag_regex}"

  # get tags, filter, reverse sorting
  local limit=$(cibuild_env_get 'deploy_minor_tag_paging_limit') \
        last="" \
        seen_last="" \
        all_tags=""
  while :; do
    local tags="$(regctl -v error tag ls "${base_image}" --limit "$limit" ${last:+--last "$last"})"

    # no more tags available
    [ -z "$tags" ] && break

    all_tags="$all_tags\n$tags"
    # store last tag
    last="$(echo "$tags" | tail -n 1)"
    cibuild_log_dump "$last"
    # no endless loop
    if [ "$last" = "$seen_last" ]; then
      cibuild_log_info "paging stalled at tag: $last" >&2
      break
    fi
    seen_last="$last"
  done 
  
  tags="$(printf "%b\n" "$all_tags" | sort -V -r | grep -E "$deploy_minor_tag_regex")"
  
  local mnt
  for mt in $tags; do
    if ! tag_digest=$(regctl -v error image digest "${base_image}:${mt}"); then
      cibuild_log_err "failed to get digest for ${base_image}:${mt}"
      continue
    fi

    cibuild_log_debug "$tag_digest - $mt"

    if [ "$tag_digest" = "$current_digest" ]; then
      cibuild_log_debug "found matching tag for $base_tag = $mt with same digest $current_digest"
      cibuild_log_debug "adding minor tag $mt"
      if ! cibuild__deploy_copy_tag "$mt"; then
        return 1
      else
        return 0
      fi
    fi
  done

  cibuild_log_err "could not get minor_tag from $base_tag"
  return 1
}

cibuild_deploy_run() {
  local deploy_enabled=$(cibuild_env_get 'deploy_enabled') \
        deploy_signature=$(cibuild_env_get 'deploy_signature') \
        deploy_cosign_private_key=$(cibuild_env_get 'deploy_cosign_private_key') \
        deploy_cosign_public_key=$(cibuild_env_get 'deploy_cosign_public_key')

  if [ "${deploy_enabled:?}" != "1" ]; then
    cibuild_log_info "deploy run not enabled: deploy run skipped"
    return
  fi
  if [ "${deploy_signature:-0}" = "1" ] && [ -z "${deploy_cosign_private_key:-}" ]; then
    cibuild_main_err "CIBUILD_DEPLOY_COSIGN_PRIVATE_KEY env var must not be empty"
    exit 1
  fi

  if [ "${deploy_signature:-0}" = "1" ] && [ -z "${deploy_cosign_public_key:-}" ]; then
    cibuild_main_err "CIBUILD_DEPLOY_COSIGN_PUBLIC_KEY env var must not be empty"
    exit 1
  fi

  printf '%s\n' "$deploy_cosign_private_key" | base64 -d > /tmp/cosign.key
  printf '%s\n' "$deploy_cosign_public_key" | base64 -d > /tmp/cosign.pub
  
  cibuild__deploy_create_index
  cibuild__deploy_additional_tags
  cibuild__deploy_minor_tag

}

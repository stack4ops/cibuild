#!/bin/sh

minor_tag_found=''

copy_tag() {
  _copy_to_tag=$1
  if ! regctl -v error image copy ${target_image:?}:${target_tag:?} ${target_image:?}:${_copy_to_tag}; then
      log 0 "failed to copy ${target_image:?}:${target_tag:?} to ${target_image:?}:${_copy_to_tag}"
      continue
  fi
}

function get_minor_tag {

  log 1 "start: get_minor_tag (regctl)"

  if [ -z "${minor_tag_regex:-}" ]; then
    log 1 "no minor tag regex defined. skipping get_minor_tag"
    return
  fi

  image="${base_image}"
  ref="${base_image}:${base_tag}"

  # Digest des Base-Tags ermitteln
  if ! current_digest=$(regctl -v error image digest "$ref"); then
    log 0 "failed to get digest for $ref"
    exit 1
  fi

  log 2 "current_digest: $current_digest"
  log 2 "minor_tag_regex: ${minor_tag_regex}"

  # Tags holen, filtern, Reihenfolge umdrehen
  limit=100
  last=""
  seen_last=""
  all_tags=""
  while :; do
    tags="$(regctl -v error tag ls "$image" --limit "$limit" ${last:+--last "$last"})"

    # keine Tags mehr
    [ -z "$tags" ] && break

    #log 2 "$tags"
    all_tags="$all_tags\n$tags"
    # letztes Tag merken
    last="$(echo "$tags" | tail -n 1)"

    # Schutz vor Endlosschleife
    if [ "$last" = "$seen_last" ]; then
      echo "paging stalled at tag: $last" >&2
      break
    fi
    seen_last="$last"
  done 
  
  tags="$(printf "%b\n" "$all_tags" | sort -V -r | grep -E "$minor_tag_regex")"

  for mt in $tags; do
    if ! tag_digest=$(regctl -v error image digest "${image}:${mt}"); then
      log 0 "failed to get digest for ${image}:${mt}"
      continue
    fi

    log 2 "$tag_digest - $mt"

    if [ "$tag_digest" = "$current_digest" ]; then
      log 2 "found matching tag for $base_tag = $mt with same digest $current_digest"
      minor_tag_found="$mt"
      return
    fi
  done

  log 0 "could not get minor_tag from $base_tag"
  exit 1
}

create_index() {
  log 2 "start: create_index"

  regctl -v error index create "${target_image:?}:${target_tag:?}"

  platforms=$(echo "${build_platforms}" | tr ',' ' ')
  for platform in ${platforms}; do
    platform_tag=$(echo "${platform}" | tr '/' '-')
    image_tag="${build_tag}-${platform_tag}"
    regctl -v error index add "${target_image:?}:${target_tag:?}" --ref "${target_image:?}:${image_tag}" --platform ${platform}
  done

  if [ "${docker_attestation_autodetect:-1}" = "1" ] && [ "${base_registry}" = "docker.io" ]; then
    log 2 "docker.io detected as base_registry set docker_attestation_manifest=1"
    docker_attestation_manifest=1
  fi
  if [ "${docker_attestation_manifest:-0}" = "1" ]; then
    # only amd64 required for referencing
    log 2 "add docker attestation manifest"
    ref_digest=$(regctl -v error manifest head ${target_image}:${build_tag:?}-linux-amd64 --platform unknown/unknown)
    image_digest=$(regctl -v error manifest head ${target_image}:${build_tag:?}-linux-amd64 --platform linux/amd64)
    log 2 "${ref_digest}"
    regctl -v error index add "${target_image:?}:${target_tag:?}" \
      --ref ${target_image:?}@${ref_digest} \
      --desc-platform unknown/unknown \
      --desc-annotation vnd.docker.reference.type=attestation-manifest \
      --desc-annotation vnd.docker.reference.digest=${image_digest}
  fi
  
  # todo: check if new index is ok before deleting arch indices
  if [ "${keep_arch_index:-0}" = "0" ]; then
    log 2 "delete image tag"
    for platform in ${platforms}; do
      platform_tag=$(echo "${platform}" | tr '/' '-')
      image_tag="${build_tag}-${platform_tag}"
      digest=$(regctl -v error manifest head ${target_image:?}:${image_tag:?})
      log 2 $digest
      regctl -v error manifest delete ${target_image:?}@${digest}
    done
  fi
}

deploy() {
  if [ "${cibuild_deploy_enabled:?}" != "1" ]; then
    log 2 "deploy run skipped"
    return
  fi
  log 2 "run: deploy"
  
  log 2 "target_tag: ${target_image:?}:${build_tag:?} to ${target_image:?}:${target_tag:?}"
  
  create_index
  
  get_minor_tag

  if [ -n "${minor_tag_found:-}" ]; then
    minor_tag=${minor_tag_found}
    if [ "${add_branch_name_to_tags:-}" = "prefix" ]; then
      minor_tag=${cibuild_current_branch}-${minor_tag}
    fi
    if [ "${add_branch_name_to_tags:-}" = "suffix" ]; then
      minor_tag=${minor_tag}-${cibuild_current_branch}
    fi
    log 2 "minor_tag: copy ${target_image}:${target_tag} to ${target_image}:${minor_tag}"
    copy_tag "${minor_tag}"
  fi
  
  additional_tags=$(echo -n ${additional_tags/%,\s*/ } | xargs)
  additional_tags=${additional_tags/%\;\s*/ }

  for tag in ${additional_tags:-}; do
    if [ -z "${tag:?}" ]; then
      continue
    fi
    if [ "${add_branch_name_to_tags:-}" = "prefix" ]; then
      tag=${cibuild_current_branch}-${tag}
    fi
    if [ "${add_branch_name_to_tags:-}" = "suffix" ]; then
      tag=${tag}-${cibuild_current_branch}
    fi
    log 2 "additional_tag: copy ${target_image}:${target_tag} to ${target_image}:${tag}"
    copy_tag "${tag}"
  done

  if [ "${date_tag:-}" = "1" ]; then
    if [ "${date_tag_with_time:-}" = "1" ]; then
      copy_tag $(date +%F_%H-%M-%S)
    else
      copy_tag $(date +%F)
    fi
  fi

}

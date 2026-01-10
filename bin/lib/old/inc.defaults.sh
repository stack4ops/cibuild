#!/bin/sh

# NOT CONFIGURABLE GLOBALS
cibuild_version='0.8.0'
config_file='cibuild.cfg'
config_file_local='cibuild.local.cfg'
local_registry='localregistry.example.com:5000'
project_folder=$(pwd)

## test
test_file='cibuild.test.sh'
test_backend='kubernetes'
test_run_timeout=60 #sec for waiting pod or container running state

# ## SCRIPT CONFIG
cibuild_loglevel=2
cibuild_logcolor=1
cibuild_pipeline_env=''
cibuild_current_branch='main'
cibuild_current_commit=''

# check run
cibuild_check_enabled=1
# build run
cibuild_build_enabled=1
# force build
cibuild_build_force=0
# test run
cibuild_test_enabled=1
# deploy run
cibuild_deploy_enabled=1

# misc
logtab=8

## BASE IMAGE
base_registry='docker.io'
base_registry_auth_url='https://index.docker.io/v1/' # real .entry in docker/config.json after login
base_registry_user=''
base_registry_pass=''
base_image_path=''
base_tag='latest'

## TARGET IMAGE
target_registry='docker.io'
target_registry_auth_url='https://index.docker.io/v1/' # real .entry in docker/config.json after login
target_registry_user=''
target_registry_pass=''
target_image_path=''
target_tag=''

## DOCKER BUILD CONFIG
additional_tags=''
date_tag_with_time=''
date_tag=''
build_tag=''
# ''|'prefix'|'suffix'
add_branch_name_to_tags=''
#minor_tag_regex="^[0-9]+\.[0-9]+\.[0-9]+$"
minor_tag_regex=''
build_platforms='linux/amd64,linux/arm64'
build_native='0' # ignores build_platforms for native build
proxies=''
build_args=''
remote_buildkit='0'
buildkit_host='tcp://buildkit:1234'
buildkit_tls='0'
dind_enabled='0'
docker_host='tcp://docker:2375'
docker_tls_certdir=''
build_client='buildctl' # buildctl|buildx (require DIND_ENABLED=1)
buildx_driver='dockercontainer' # dockercontainer|remote|kubernetes

# sbom
sbom='1'
provenance='1'
provenance_mode='max'
build_opts=''

# create docker_attestation_manifest for docker hub ui (target_registry=docker.io)
docker_attestation_autodetect='1'
# manual docker_attestation_manifest switch (requires docker_attestation_autodetect='0')
docker_attestation_manifest='0'
# token for target_registry needs deletion permissions for keep_arch_index='0'
keep_arch_index='1'

# target_registry
# repo_registry:
#   ci:       gitlab_registry
#   local:    local_registry

# In most cases same export and import targets
# Custom cache args can be used appended to "--export-cache | --import-cache"
# Empty string export|import cache is disabled
export_cache='repo_registry'
export_cache_mode='max'
import_cache='repo_registry'

# disable cache for build run completely: 
# - overrides import (not export)
# - disables local oci worker cache too (?)
use_cache=1

## GITLAB API CONFIG
cibuild_cancel_token=''

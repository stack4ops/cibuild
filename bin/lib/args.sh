# lib/secrets.sh – source with . 
#
# CIBUILD_BUILD_SECRET_NPM_TOKEN=xyz  --secret id=NPM_TOKEN,env=CIBUILD_BUILD_SECRET_NPM_TOKEN
# CIBUILD_BUILD_ARG_NODE_VERSION=20   --opt build-arg:NODE_VERSION=20  (buildctl)
#                                     --build-arg NODE_VERSION=20       (buildx)

set --
while IFS='=' read -r _key _value; do
  [ -z "$_value" ] && continue
  case "$_key" in
    CIBUILD_BUILD_SECRET_*)
      _name="${_key#CIBUILD_BUILD_SECRET_}"
      if [ "${build_client}" = "kaniko" ]; then
        cibuild_log_err "ignoring secret "${_name}" as secret mounts are not supported by kaniko. You have to pass it with CIBUILD_BUILD_ARG_${_name}"
      else
        set -- "$@" "--secret" "id=${_name},env=${_key}"
      fi
      ;;
    CIBUILD_BUILD_ARG_*)
      _name="${_key#CIBUILD_BUILD_ARG_}"
      case "${build_client}" in
        buildctl)
          set -- "$@" "--opt" "build-arg:${_name}=${_value}"
          ;;
        buildx|kaniko)
          set -- "$@" "--build-arg" "${_name}=${_value}"
          ;;
      esac
      ;;
  esac
done << EOF
$(env)
EOF

unset _key _value _name
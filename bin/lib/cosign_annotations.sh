# lib/cosign_annotations.sh – source with . 

set --
while IFS='=' read -r _key _value; do
  [ -z "$_value" ] && continue
  case "$_key" in
    CIBUILD_RELEASE_COSIGN_ANNOTATION_*)
      _name="${_key#CIBUILD_RELEASE_COSIGN_ANNOTATION_}"
      annotation_key1=$(echo "${_name}" | tr '[:upper:]' '[:lower:]' | sed 's/___/-/g')
      annotation_key=$(echo "${annotation_key1}" | tr '[:upper:]' '[:lower:]' | sed 's/__/./g')
      set -- "$@" "-a" "${annotation_key}=${_value}"
      ;;
  esac
done << EOF
$(env)
EOF

unset _key _value _name

# ci specific vars
if cibuild_function_exists cibuild_ci_get_base_cosign_annotations; then
  while IFS= read -r arg; do
    [ -n "$arg" ] && set -- "$@" $arg
  done << EOF
$(cibuild_ci_get_base_cosign_annotations)
EOF
fi

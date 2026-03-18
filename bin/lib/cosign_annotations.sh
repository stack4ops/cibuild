# lib/cosign_annotations.sh – source with . 
#
# CIBUILD_RELEASE_COSIGN_ANNOTATION_org=hrz.uni-marburg.de    -a org=hrz.uni-marburg.de
# CIBUILD_RELEASE_COSIGN_ANNOTATION_commit=$CI_COMMIT_SHA     -a commit=CI_COMMIT_SHA

set --
while IFS='=' read -r _key _value; do
  [ -z "$_value" ] && continue
  case "$_key" in
    CIBUILD_RELEASE_COSIGN_ANNOTATION_*)
      _name="${_key#CIBUILD_RELEASE_COSIGN_ANNOTATION_}"
      annotation_key=$(echo "${_name}" | tr '[:upper:]' '[:lower:]' | sed 's/__/./g')
      set -- "$@" "-a" "${annotation_key}=${_value}"
      ;;
  esac
done << EOF
$(env)
EOF

unset _key _value _name
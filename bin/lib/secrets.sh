#!/bin/sh

set --
while IFS= read -r _arg; do
  [ -z "$_arg" ] && continue
  set -- "$@" "$_arg"
done << EOF
$(env | while IFS='=' read -r _key _value; do
  case "$_key" in
    "${_secret_prefix:-CI_}"*)
      [ -z "$_value" ] && continue
      printf '%s\n' "--secret"
      printf '%s\n' "id=${_key},env=${_key}"
      ;;
  esac
done)
EOF
unset _arg _key _value _secret_prefix
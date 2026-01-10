#!/bin/sh
# Package cibuild/log

# ---- Guard (like init once) ----
[ -n "${_CIBUILD_LOG_LOADED-}" ] && return
_CIBUILD_LOG_LOADED=1

# internal constants
_LOG_ERROR=0
_LOG_INFO=1
_LOG_DEBUG=2
_LOG_DUMP=3

_LOG_LEVEL=1
_LOG_COLOR=1
_LOG_TAB=6

cibuild__log_color() {
  case "$1" in
    0) printf '\033[31m' ;; # error
    1) printf '\033[33m' ;; # info
    2) printf '\033[34m' ;; # debug
    3) printf '\033[35m' ;; # dump
    *) printf '\033[0m'  ;;
  esac
}

cibuild__get_log_tab() {
  num_character=${#1}
  spacing=''
  while [ "$num_character" -lt "$_LOG_TAB" ]; do
    spacing="${spacing} "
    num_character=$((num_character + 1))
  done
  echo "$spacing"
}

cibuild__log_level_name() {
  case "$1" in
    0) echo "error" ;;
    1) echo "info" ;;
    2) echo "debug" ;;
    3) echo "dump" ;;
    *) echo "log" ;;
  esac
}

cibuild__log_print() {
  level="$1"
  shift

  [ "$_LOG_LEVEL" -ge "$level" ] || return 0

  level_name="$(cibuild__log_level_name "$level")"
  #spacing=$(_get_log_tab "$level_name")
  spacing=" "
  if [ "$_LOG_COLOR" = "1" ]; then
    color_start="$(cibuild__log_color "$level")"
    color_reset="$(cibuild__log_color reset)"
  else
    color_start=""
    color_reset=""
  fi

  printf "%s[%s]%s%s%s\n" \
    "$color_start" \
    "$level_name" \
    "$spacing" \
    "$*" \
    "$color_reset"
}

cibuild_log_err()   { cibuild__log_print "$_LOG_ERROR" "$@"; }
cibuild_log_info()  { cibuild__log_print "$_LOG_INFO"  "$@"; }
cibuild_log_debug() { cibuild__log_print "$_LOG_DEBUG" "$@"; }
cibuild_log_dump()  { cibuild__log_print "$_LOG_DUMP"  "$@"; }

cibuild_log_init() {
  [ "${_CIBUILD_LOG_INIT_DONE:-}" = "1" ] && return
  _CIBUILD_LOG_INIT_DONE=1
  _LOG_LEVEL="$(cibuild_env_get log_level $_LOG_LEVEL)"
  _LOG_COLOR="$(cibuild_env_get log_color $_LOG_COLOR)"
  _LOG_TAB="$(cibuild_env_get log_tab $_LOG_TAB)"
}

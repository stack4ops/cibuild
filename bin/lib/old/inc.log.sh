#!/bin/sh

# Minimal Logging Utility – works everywhere (CI, Docker, local shell)

# Default loglevel (0=error,1=info,2=debug)
cibuild_loglevel=${cibuild_loglevel:-1}

# Minimum width for log level column
logtab=${logtab:-8}

# === COLOR HANDLER ===
# Uses ANSI escape codes instead of tput
set_color() {
  case $1 in
    0) printf '\033[31m' ;; # red     (error)
    1) printf '\033[33m' ;; # yellow  (info)
    2) printf '\033[34m' ;; # blue    (debug)
    3) printf '\033[35m' ;; # magenta (dump)
    99) printf '\033[0m'  ;; # reset
  esac
}

# === LOG LEVEL NAMES ===
get_loglevel() {
  case $1 in
    0) echo "error" ;;
    1) echo "info"  ;;
    2) echo "debug" ;;
    3) echo "dump"  ;;
  esac
}

# === SPACING ===
get_logtab() {
  num_character=${#1}
  spacing=''
  while [ "$num_character" -lt "$logtab" ]; do
    spacing="${spacing} "
    num_character=$((num_character + 1))
  done
  echo "$spacing"
}

# === MAIN LOG FUNCTION ===
log() {
  log_level_value=$1
  shift

  if [ "$cibuild_loglevel" -ge "$log_level_value" ]; then
    log_level_string=$(get_loglevel "$log_level_value")
    spacing=$(get_logtab "$log_level_string")
    # Only use colors if stdout is a terminal or in CI screen
    if [ "$cibuild_logcolor" = "1" ]; then
      color_start=$(set_color "$log_level_value")
      color_reset=$(set_color 99)
    else
      color_start=""
      color_reset=""
    fi

    printf "[%s%s%s]%s- %s\n" \
      "$color_start" "$log_level_string" "$color_reset" "$spacing" "$*"
  fi
}

#!/usr/bin/env bash
# deploy/lib/log.sh — coloured diagnostics on stderr

if [[ -n "${_LOG_LOADED:-}" ]]; then
  return 0
fi
readonly _LOG_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "error: This file is a library and must be sourced, not executed." >&2
  exit 1
fi

# Pre-set to empty so a failure during argument parsing — before setup_colors
# has run — still prints its message instead of tripping over `set -u`.
NOFORMAT='' RED='' GREEN='' YELLOW=''

# Colours are applied once the arguments are known, so --no-color is honoured.
setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' YELLOW=''
  fi
}

msg() { echo >&2 -e "${1-}"; }
warn() { msg "${YELLOW}warning: ${1-}${NOFORMAT}"; }
step() { msg "\n${GREEN}==>${NOFORMAT} ${1-}"; }

die() {
  msg "${RED}error: ${1-}${NOFORMAT}"
  exit "${2-1}"
}

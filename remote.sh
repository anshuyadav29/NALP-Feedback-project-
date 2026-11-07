#!/usr/bin/env bash
# deploy/lib/remote.sh — talking to the deployment target over SSH

if [[ -n "${_REMOTE_LOADED:-}" ]]; then
  return 0
fi
readonly _REMOTE_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "error: This file is a library and must be sourced, not executed." >&2
  exit 1
fi

# Path of the 1Password ssh/scp wrapper that supplies the host password.
readonly REMOTE_1PW_SHIM="${HOME}/.ssh/1pw/shim.sh"

# Multiplexing socket. Without it every single remote call would ask for the
# password again; with it the whole deployment costs one authentication.
REMOTE_CONTROL_PATH=""

# Loads the password wrapper when the current shell does not already provide it.
# Falls back to plain ssh, which still works with key authentication.
remote_init() {
  local target="$1"

  if [[ "$(type -t ssh)" != "function" ]] && [[ -r "${REMOTE_1PW_SHIM}" ]]; then
    # shellcheck source=/dev/null
    source "${REMOTE_1PW_SHIM}"
  fi

  REMOTE_CONTROL_PATH="$(mktemp -u "${TMPDIR:-/tmp}/deploy-${target}-XXXXXX.sock")"
  readonly REMOTE_CONTROL_PATH
}

# Closes the shared connection. Safe to call when none was opened.
remote_shutdown() {
  if [[ -n "${REMOTE_CONTROL_PATH}" ]] && [[ -S "${REMOTE_CONTROL_PATH}" ]]; then
    ssh -o ControlPath="${REMOTE_CONTROL_PATH}" -O exit "${REMOTE_TARGET}" 2>/dev/null || true
  fi
}

_remote_ssh_options() {
  # IdentitiesOnly stops the agent from offering every stored key in turn, which
  # would exhaust MaxAuthTries before the password prompt is ever reached.
  printf '%s\n' \
    -o IdentitiesOnly=yes \
    -o ControlMaster=auto \
    -o ControlPath="${REMOTE_CONTROL_PATH}" \
    -o ControlPersist=120 \
    -o ConnectTimeout=15
}

# Runs a command on the target and returns its exit code.
remote_run() {
  local -a options
  mapfile -t options < <(_remote_ssh_options)
  ssh "${options[@]}" "${REMOTE_TARGET}" "$@"
}

# Runs a command as root on the target. The account has passwordless sudo, which
# is checked during preflight.
remote_sudo() {
  remote_run "sudo -n $*"
}

# Copies a local file to the target.
remote_copy() {
  local source="$1" destination="$2"
  local -a options
  mapfile -t options < <(_remote_ssh_options)
  scp "${options[@]}" -q "${source}" "${REMOTE_TARGET}:${destination}"
}

# Writes stdin to a file on the target, creating it with the given mode before
# any content lands in it — secrets must never exist world-readable, not even
# briefly.
remote_write_file() {
  local destination="$1" mode="${2:-644}"
  remote_run "install -m ${mode} /dev/null '${destination}' && cat > '${destination}'"
}

# True when the given remote path exists.
remote_path_exists() {
  remote_run "test -e '$1'"
}

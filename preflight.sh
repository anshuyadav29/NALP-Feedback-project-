#!/usr/bin/env bash
# deploy/lib/preflight.sh — everything that must hold before anything is built

if [[ -n "${_PREFLIGHT_LOADED:-}" ]]; then
  return 0
fi
readonly _PREFLIGHT_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "error: This file is a library and must be sourced, not executed." >&2
  exit 1
fi

# Fails in seconds on a missing tool rather than after a full Gradle build.
preflight_local() {
  step "Checking local prerequisites"

  local tool
  for tool in git docker ssh scp openssl; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      die "Required tool not found: ${tool}"
    fi
  done

  if ! docker buildx version >/dev/null 2>&1; then
    die "docker buildx is required to build for ${BUILD_PLATFORM}"
  fi

  if ! docker info >/dev/null 2>&1; then
    die "The local Docker daemon is not reachable — is Docker Desktop running?"
  fi

  local branch
  branch="$(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD)"
  if [[ "${branch}" != "main" ]]; then
    warn "On branch '${branch}', not 'main' — that branch will be deployed."
  fi

  if ! git -C "${PROJECT_ROOT}" diff --quiet HEAD 2>/dev/null; then
    warn "Working tree has uncommitted changes; they will be deployed."
  fi

  msg "  source: $(build_describe_source)"
}

# Confirms the target can actually run what is about to be sent to it.
preflight_remote() {
  step "Checking target ${REMOTE_TARGET}"

  if ! remote_run true 2>/dev/null; then
    die "Cannot reach ${REMOTE_TARGET} over SSH"
  fi

  local architecture
  architecture="$(remote_run 'uname -m')"
  if [[ "${architecture}" != "aarch64" && "${architecture}" != "arm64" ]]; then
    die "Target reports '${architecture}', but the image is built for ${BUILD_PLATFORM}"
  fi

  if ! remote_run 'command -v docker' >/dev/null 2>&1; then
    die "Docker is not installed on ${REMOTE_TARGET}"
  fi

  # The account is not in the docker group, so every Docker call needs sudo.
  if ! remote_run 'sudo -n true' 2>/dev/null; then
    die "Passwordless sudo is required on ${REMOTE_TARGET} to drive Docker"
  fi

  if ! remote_run 'sudo -n docker compose version' >/dev/null 2>&1; then
    die "The Docker Compose plugin is missing on ${REMOTE_TARGET}"
  fi

  local description
  description="$(remote_run '. /etc/os-release && echo "${PRETTY_NAME}"')"
  msg "  target: ${architecture}, ${description}"

  preflight_port_free
}

# Port 80 has to be free, or nginx will fail to start after the image is built.
preflight_port_free() {
  local occupant
  occupant="$(remote_run "sudo -n ss -ltnp | grep ':80 ' || true")"

  if [[ -z "${occupant}" ]]; then
    return 0
  fi

  # Our own proxy re-binding the port on redeployment is expected.
  if remote_run "cd '${REMOTE_DIR}' 2>/dev/null && sudo -n docker compose ps --quiet proxy" >/dev/null 2>&1; then
    return 0
  fi

  die "Port 80 on ${REMOTE_TARGET} is already in use:
${occupant}"
}

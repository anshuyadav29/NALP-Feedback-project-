#!/usr/bin/env bash
# Deploys the current working tree to the Raspberry Pi.
#
# Builds locally for aarch64 and streams the image over SSH instead of pulling
# from the registry: the CI publishes linux/amd64 only, and it can build nothing
# that has not been pushed.

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

# Resolve sourced libraries relative to this file, so linting works from any
# working directory.
# shellcheck source-path=SCRIPTDIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly PROJECT_ROOT

readonly DEFAULT_TARGET="rpi5-1"
readonly DEFAULT_PUBLIC_HOST="issue-tracker.raspi01.local"
readonly REMOTE_DIR="issue-tracker"
readonly IMAGE_NAME="issue-tracker"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/remote.sh
source "${SCRIPT_DIR}/lib/remote.sh"
# shellcheck source=lib/build.sh
source "${SCRIPT_DIR}/lib/build.sh"
# shellcheck source=lib/preflight.sh
source "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/stack.sh
source "${SCRIPT_DIR}/lib/stack.sh"
# shellcheck source=lib/verify.sh
source "${SCRIPT_DIR}/lib/verify.sh"

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  remote_shutdown
}

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [options]

Builds the current working tree for aarch64 and deploys it to the Raspberry Pi
as a Docker Compose stack: the tracker, its PostgreSQL database, and an nginx
reverse proxy publishing it on port 80.

Options:
  -h, --help           Show this help and exit
  -v, --verbose        Enable debug output (set -x)
      --no-color       Disable coloured output
  -t, --target HOST    SSH target (default: ${DEFAULT_TARGET})
      --public-host H  Host name to serve (default: ${DEFAULT_PUBLIC_HOST})
      --skip-tests     Build without running the test suite
      --skip-mdns      Do not publish the mDNS alias on the target
      --skip-build     Reuse the image already present on the target
      --dry-run        Report what would happen, change nothing

Examples:
  $(basename "${BASH_SOURCE[0]}")
  $(basename "${BASH_SOURCE[0]}") --skip-tests
  $(basename "${BASH_SOURCE[0]}") --target rpi5-1 --public-host tracker.local

Notes:
  The database password and the MCP token are generated on the first deployment
  and stored in ~/${REMOTE_DIR}/.env on the target with mode 600. Later runs
  reuse them, so the database stays readable and configured MCP clients keep
  working. Only the proxy publishes a port; tracker and database stay on the
  internal network.

Environment:
  NO_COLOR             Disable coloured output when set
EOF
  exit 0
}

parse_params() {
  REMOTE_TARGET="${DEFAULT_TARGET}"
  PUBLIC_HOST="${DEFAULT_PUBLIC_HOST}"
  SKIP_TESTS=false
  SKIP_MDNS=false
  SKIP_BUILD=false
  DRY_RUN=false

  while :; do
    case "${1-}" in
      -h | --help) usage ;;
      -v | --verbose) set -x ;;
      --no-color) NO_COLOR=1 ;;
      -t | --target)
        REMOTE_TARGET="${2-}"
        shift
        ;;
      --public-host)
        PUBLIC_HOST="${2-}"
        shift
        ;;
      --skip-tests) SKIP_TESTS=true ;;
      --skip-mdns) SKIP_MDNS=true ;;
      --skip-build) SKIP_BUILD=true ;;
      --dry-run) DRY_RUN=true ;;
      -?*) die "Unknown option: $1" ;;
      *) break ;;
    esac
    shift
  done

  if [[ -z "${REMOTE_TARGET}" ]]; then
    die "Missing value for --target"
  fi
  if [[ -z "${PUBLIC_HOST}" ]]; then
    die "Missing value for --public-host"
  fi

  readonly REMOTE_TARGET PUBLIC_HOST SKIP_TESTS SKIP_MDNS SKIP_BUILD DRY_RUN
}

# Collects every host name the application must accept. The proxy forwards the
# Host header untouched, and the MCP endpoint answers 421 for anything it does
# not know — including the bare IP, which is the fallback when mDNS is silent.
resolve_public_names() {
  TARGET_ADDRESS="$(remote_run "hostname -I | awk '{print \$1}'")"
  readonly TARGET_ADDRESS

  PUBLIC_HOSTS="${PUBLIC_HOST},${PUBLIC_HOST}:80"
  PUBLIC_HOSTS+=",${TARGET_ADDRESS},${TARGET_ADDRESS}:80,localhost,localhost:80"
  readonly PUBLIC_HOSTS

  PUBLIC_ORIGINS="http://${PUBLIC_HOST},http://${TARGET_ADDRESS}"
  readonly PUBLIC_ORIGINS
}

report_dry_run() {
  local image="$1"

  msg "\nDry run — nothing was changed."
  msg "  would build   ${image} for ${BUILD_PLATFORM}"
  msg "  would deploy  to ${REMOTE_TARGET}:~/${REMOTE_DIR}"
  msg "  would serve   http://${PUBLIC_HOST}/ (fallback http://${TARGET_ADDRESS}/)"
  msg "  accepted hosts: ${PUBLIC_HOSTS}"
}

build_and_transfer() {
  local image="$1"

  if [[ "${SKIP_BUILD}" == "true" ]]; then
    warn "Skipping build — reusing ${image} on the target."
    return 0
  fi

  build_application "${SKIP_TESTS}"
  build_image "${image}" "$(build_locate_jar)"
  step "Transferring image to ${REMOTE_TARGET}"
  build_transfer_image "${image}"
}

main() {
  parse_params "$@"
  setup_colors

  remote_init "${REMOTE_TARGET}"
  preflight_local
  preflight_remote
  resolve_public_names

  local tag image
  tag="$(build_derive_tag)"
  image="${IMAGE_NAME}:${tag}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    report_dry_run "${image}"
    return 0
  fi

  build_and_transfer "${image}"
  stack_install "${image}"
  stack_publish_mdns
  verify_wait_for_health
  verify_endpoints
  verify_report "${image}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

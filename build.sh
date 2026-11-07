#!/usr/bin/env bash
# deploy/lib/build.sh — turning the working tree into an image for the target

if [[ -n "${_BUILD_LOADED:-}" ]]; then
  return 0
fi
readonly _BUILD_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "error: This file is a library and must be sourced, not executed." >&2
  exit 1
fi

# The Raspberry Pi runs aarch64. An Apple Silicon Mac builds that natively;
# an Intel Mac would emulate it and take considerably longer.
readonly BUILD_PLATFORM="linux/arm64"

# Derives the image tag from the commit being deployed, so the running container
# can always be traced back to a revision.
build_derive_tag() {
  local revision
  revision="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD)"

  if ! git -C "${PROJECT_ROOT}" diff --quiet HEAD 2>/dev/null; then
    printf '%s-dirty' "${revision}"
    return 0
  fi

  printf '%s' "${revision}"
}

# Reports what would actually be deployed, so a stale or diverged tree is
# visible before anything is built.
build_describe_source() {
  local branch revision subject
  branch="$(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD)"
  revision="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD)"
  subject="$(git -C "${PROJECT_ROOT}" log -1 --pretty=%s)"

  printf '%s @ %s — %s' "${branch}" "${revision}" "${subject}"
}

# Builds frontend and backend. The Gradle build copies the exported frontend into
# the backend resources, so a single task produces the complete artefact.
build_application() {
  local skip_tests="$1"
  local -a gradle_args=(clean build)

  if [[ "${skip_tests}" == "true" ]]; then
    gradle_args+=(-x test)
    warn "Tests skipped — the image is built from unverified code."
  fi

  msg "Building application (this also builds and embeds the frontend)…"
  (cd "${PROJECT_ROOT}" && ./gradlew "${gradle_args[@]}")
}

# Locates the runnable JAR, ignoring the -plain variant Gradle also produces.
# The root is a parameter so the lookup can be exercised without a real build.
build_locate_jar() {
  local root="${1:-${PROJECT_ROOT}}"
  local jar
  jar="$(find "${root}/backend/build/libs" -name '*.jar' ! -name '*-plain.jar' -print -quit)"

  if [[ -z "${jar}" ]]; then
    die "No runnable JAR found under backend/build/libs"
  fi

  printf '%s' "${jar}"
}

# Builds the container image for the target architecture and loads it into the
# local daemon so it can be exported.
build_image() {
  local image="$1" jar="$2"
  local jar_relative="${jar#"${PROJECT_ROOT}"/}"

  msg "Building image ${image} for ${BUILD_PLATFORM}…"
  docker buildx build \
    --platform "${BUILD_PLATFORM}" \
    --build-arg "JAR_FILE=${jar_relative}" \
    --build-arg "VERSION=${image##*:}" \
    --tag "${image}" \
    --load \
    "${PROJECT_ROOT}"
}

# Streams the image to the target. Docker save writes uncompressed layers, so
# compressing on the way saves most of the transfer.
build_transfer_image() {
  local image="$1"
  local size

  size="$(docker image inspect "${image}" --format '{{.Size}}')"
  msg "Transferring image (~$((size / 1024 / 1024)) MB uncompressed)…"

  docker save "${image}" | gzip -1 | remote_run "gunzip | sudo -n docker load"
}

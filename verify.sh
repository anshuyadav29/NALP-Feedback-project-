#!/usr/bin/env bash
# deploy/lib/verify.sh — proving the deployment actually works

if [[ -n "${_VERIFY_LOADED:-}" ]]; then
  return 0
fi
readonly _VERIFY_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "error: This file is a library and must be sourced, not executed." >&2
  exit 1
fi

readonly HEALTH_ATTEMPTS=40
readonly HEALTH_INTERVAL=5

# Polls the health endpoint, but also watches the container: a crashed
# application would otherwise be waited on until the timeout expires.
verify_wait_for_health() {
  step "Waiting for the application to become healthy"

  local attempt exited
  for ((attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++)); do
    if remote_run "curl -sf -o /dev/null http://localhost/actuator/health" 2>/dev/null; then
      msg "  healthy after $((attempt * HEALTH_INTERVAL))s"
      return 0
    fi

    exited="$(remote_run "cd '${REMOTE_DIR}' && sudo -n docker compose ps --status exited --quiet app" 2>/dev/null || true)"
    if [[ -n "${exited}" ]]; then
      verify_dump_logs
      die "The application container exited during startup"
    fi

    sleep "${HEALTH_INTERVAL}"
  done

  verify_dump_logs
  die "Application did not become healthy within $((HEALTH_ATTEMPTS * HEALTH_INTERVAL))s"
}

verify_dump_logs() {
  remote_run "cd '${REMOTE_DIR}' && sudo -n docker compose logs --tail 40 app" >&2 || true
}

verify_endpoints() {
  step "Verifying"

  local rest_status
  rest_status="$(remote_run "curl -sf -o /dev/null -w '%{http_code}' http://localhost/api/boards" || true)"
  if [[ "${rest_status}" == "200" ]]; then
    msg "  REST API responds"
  else
    warn "REST API answered ${rest_status:-nothing}"
  fi

  # An unauthenticated MCP call must be refused. If it is not, the token never
  # took effect and the whole LAN could delete boards through the endpoint.
  local mcp_status
  mcp_status="$(remote_run "curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost/mcp \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}'" || true)"
  if [[ "${mcp_status}" == "401" ]]; then
    msg "  MCP endpoint requires its token"
  else
    warn "MCP endpoint answered ${mcp_status:-nothing} instead of 401 — check MCP_AUTH_TOKEN"
  fi

  verify_name_resolution
}

# A two-label .local name is not something every resolver answers, so this is
# reported rather than assumed.
verify_name_resolution() {
  if ! command -v dscacheutil >/dev/null 2>&1; then
    return 0
  fi

  if dscacheutil -q host -a name "${PUBLIC_HOST}" 2>/dev/null | grep -q 'ip_address'; then
    msg "  ${PUBLIC_HOST} resolves from this machine"
    return 0
  fi

  warn "${PUBLIC_HOST} does not resolve from this machine."
  msg "    mDNS may need a moment, and not every resolver accepts a name below"
  msg "    the host's own .local name. Use http://${TARGET_ADDRESS}/ meanwhile, or add"
  msg "    '${TARGET_ADDRESS} ${PUBLIC_HOST}' to /etc/hosts."
}

verify_report() {
  local image="$1"
  local token
  token="$(remote_run "grep '^MCP_AUTH_TOKEN=' '${REMOTE_DIR}/.env' | cut -d= -f2")"

  cat >&2 <<EOF

${GREEN}Deployment complete.${NOFORMAT}

  Image      ${image}
  Source     $(build_describe_source)
  UI         http://${PUBLIC_HOST}/   (fallback: http://${TARGET_ADDRESS}/)
  MCP        http://${PUBLIC_HOST}/mcp

  Connect an agent:
    claude mcp add --transport http issue-tracker http://${PUBLIC_HOST}/mcp \\
      --header "Authorization: Bearer ${token}"

  Logs       ssh ${REMOTE_TARGET} "cd ${REMOTE_DIR} && sudo docker compose logs -f app"
  Restart    ssh ${REMOTE_TARGET} "cd ${REMOTE_DIR} && sudo docker compose restart app"
  Stop       ssh ${REMOTE_TARGET} "cd ${REMOTE_DIR} && sudo docker compose down"
EOF
}

# Deployment

Deploys the current working tree to the Raspberry Pi (`rpi5-1`, 192.168.1.242) as a
Docker Compose stack.

```bash
./deploy/deploy.sh
```

The tracker is then served at <http://issue-tracker.raspi01.local/>, with
<http://192.168.1.242/> as a fallback.

## What it does

1. Checks prerequisites on both machines — tools, Docker, target architecture,
   passwordless sudo, and whether port 80 is free.
2. Builds frontend and backend (`./gradlew clean build`, which embeds the exported
   frontend into the backend).
3. Builds a `linux/arm64` image tagged with the commit being deployed.
4. Streams the image over SSH — no registry involved.
5. Installs `compose.yml` and `nginx.conf` in `~/issue-tracker` on the target and
   starts the stack.
6. Publishes the mDNS alias, waits for the health check, and verifies the result.

### Why it builds locally

The CI publishes `linux/amd64` images only, while the Pi is `aarch64` — and the CI
can build nothing that has not been pushed. Building locally deploys exactly the
tree in front of you. An Apple Silicon Mac builds arm64 natively, so this costs no
emulation.

## The stack

| Service | Image | Published |
|---|---|---|
| `proxy` | nginx:1.27-alpine | port 80 |
| `app` | locally built | internal only |
| `db` | postgres:16-alpine | internal only |

Only the proxy is reachable from the network; the tracker and its database stay on
the internal Compose network. The database lives in the named volume `db-data` and
survives redeployment.

## Options

| Option | Effect |
|---|---|
| `-t, --target HOST` | SSH target (default `rpi5-1`) |
| `--public-host H` | Host name to serve (default `issue-tracker.raspi01.local`) |
| `--skip-tests` | Build without running the test suite |
| `--skip-build` | Reuse the image already on the target — for config-only changes |
| `--skip-mdns` | Leave the mDNS alias untouched |
| `--dry-run` | Report what would happen, change nothing |

## Secrets

The database password and the MCP token are generated on the **first** deployment
and stored in `~/issue-tracker/.env` on the target with mode `600`. Later runs reuse
them — rotating the database password would make the existing volume unreadable, and
a new MCP token would silently break every configured client.

The final report prints the ready-to-use `claude mcp add` command including the
token. To read it again later:

```bash
ssh rpi5-1 "grep MCP_AUTH_TOKEN issue-tracker/.env"
```

## Name resolution

`issue-tracker.raspi01.local` sits one level below the host's own mDNS name, and
Avahi only answers for its own name. The script therefore installs a systemd unit
(`issue-tracker-mdns.service`) that publishes the alias via `avahi-publish`.

Not every resolver accepts a two-label `.local` name. The script checks whether the
name resolves from your machine and says so. If it does not, either use
<http://192.168.1.242/> or add a hosts entry:

```
192.168.1.242 issue-tracker.raspi01.local
```

The alias is bound to the IP at deploy time — if the Pi's address changes, run the
deployment again.

## Notes on the reverse proxy

`nginx.conf` treats `/mcp` differently from the rest: response buffering is off and
the read timeout is raised to an hour. Both are required, not cosmetic — MCP streams
Server-Sent Events, and a confirmation dialog can keep a request open for up to five
minutes while it waits for the user. nginx's default 60-second timeout would cut
those off.

nginx accepts any host name and forwards it untouched; host validation happens in
the application via `MCP_ALLOWED_HOSTS`, which the script keeps in sync with
`--public-host` and the target's IP. Without that the MCP endpoint answers 421 (see
`docs/MCP.md`).

## Troubleshooting

```bash
ssh rpi5-1 "cd issue-tracker && sudo docker compose logs -f app"   # follow logs
ssh rpi5-1 "cd issue-tracker && sudo docker compose ps"            # container state
ssh rpi5-1 "cd issue-tracker && sudo docker compose restart app"   # restart
ssh rpi5-1 "cd issue-tracker && sudo docker compose down"          # stop everything
```

`down` keeps the data; `down -v` deletes the volume and with it the database.

## Tests

```bash
bats deploy/tests/deploy.bats
shellcheck --severity=warning deploy/deploy.sh deploy/lib/*.sh
```

The tests cover argument parsing, tag derivation, the accepted-host list and the JAR
lookup. Everything touching the network is stubbed — they never reach a real host.

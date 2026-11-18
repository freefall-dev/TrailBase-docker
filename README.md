# TrailBase Docker

Minimal, production-minded Docker images for [TrailBase](https://trailbase.io/), shipped in two flavors:

- **Rootless** (default, recommended) — runs as a dedicated non-root `trailbase` user.
- **Root** — runs as `root`, for environments where that's simpler or required.

Both use a multi-stage Alpine build that downloads a pinned TrailBase release (the static musl `trail` binary plus the prebuilt auth UI WASM component), **verifies their SHA-256 digests**, and ships only those files in the runtime image. An entrypoint script optionally bootstraps an admin user on every start.

## Features

- 🪶 Small Alpine-based image, multi-stage build (only the `trail` binary and auth UI in the final layer).
- 🔒 SHA-256 verification of the downloaded release during build (digests pinned in the Dockerfiles, refreshed by `bump.sh`).
- 👤 Rootless and root variants, kept isolated via distinct Compose project names.
- 🌱 Idempotent admin bootstrap — creates (or promotes) the admin only if needed.
- 🧹 Takes over the auto-generated `admin@localhost` account on first start, so no stray default admin remains.
- 🏗️ Multi-arch (`amd64` / `arm64`) via buildx `TARGETARCH`.
- ❤️ Built-in `HEALTHCHECK` hitting `/api/healthcheck`.
- 🛑 `tini` as PID 1 for clean signal handling.
- 💾 Persistent `traildepot` volume for databases, config, uploads, secrets and backups.

## Requirements

- Docker with Compose v2 (`docker compose`).
- Optionally buildx for multi-arch builds.

## Quick start

```bash
# 1. Configure
cp .env.example .env
# edit .env — at minimum set TB_ADMIN_EMAIL and TB_ADMIN_PASSWORD to bootstrap an admin

# 2. Build & run (rootless variant, default)
docker compose -f docker-compose.rootless.yml up -d --build

# 3. Open the admin UI
#    http://localhost:4000/_/admin/
```

For the root variant:

```bash
docker compose -f docker-compose.root.yml up -d --build
```

The two stacks use separate Compose project names (`trailbase` vs `trailbase-root`), so their containers and volumes stay isolated. Both default to port `4000`; set a different `TB_PORT_ROOT` to run them side by side.

## Configuration

Copy `.env.example` to `.env` and adjust. Compose reads `.env` automatically; **keep it out of version control** (already covered by `.gitignore`).

| Variable | Default | Description |
|---|---|---|
| `TB_VERSION` | `0.36.1` | TrailBase release to build (published tag without the leading `v`). Change it with `bump.sh`. |
| `CONTAINER_NAME` | `trailbase` | Base name for the container. |
| `TB_PORT` | `4000` | Port for the rootless stack (used inside the container and for the host mapping). |
| `TB_PORT_ROOT` | `4000` | Port for the root stack. |
| `TB_PUBLIC_URL` | *(empty)* | Public URL of the instance, passed as `--public-url`. Needed for auth email links and OAuth redirects. |
| `TB_ADMIN_EMAIL` | *(empty)* | Admin email to bootstrap. Leave blank to skip bootstrapping. |
| `TB_ADMIN_PASSWORD` | *(empty)* | Admin password. Required only when the user doesn't yet exist. |

### Admin bootstrap

On every start the entrypoint looks up `TB_ADMIN_EMAIL` in `traildepot/data/main.db`:

- **admin exists** → nothing happens (`TB_ADMIN_PASSWORD` is ignored).
- **user exists but is not an admin** → it is promoted with `trail admin promote`.
- **missing** → the admin is created with `TB_ADMIN_PASSWORD` (required in that case, otherwise the container exits with an error):
  - **fresh depot (first start)** → TrailBase auto-creates `admin@localhost` with a random password; the entrypoint takes that account over by renaming it to `TB_ADMIN_EMAIL` (`trail user change-email`) and setting `TB_ADMIN_PASSWORD` (`trail user change-password`). No stray default admin is left behind.
  - **existing depot** → the user is created with `trail user add` and promoted. ⚠️ `trail user add` is broken in TrailBase 0.36.x (it inserts into a column a migration removed); in that case the container exits with a hint — create the user in the admin UI and restart to have it promoted.
- `TB_ADMIN_EMAIL` blank → bootstrap is skipped entirely.

Passwords set through the CLI are not checked against TrailBase's password policy.

Without bootstrapping, TrailBase's own `admin@localhost` account remains; find its random password in the first start's log:

```bash
docker compose -f docker-compose.rootless.yml logs trailbase | grep -A2 "Created new admin user"
```

### TrailBase config overrides

TrailBase stores its settings in `traildepot/config.textproto` (editable from the admin UI). Any field can be overridden with a `TRAIL_<FIELD_PATH>` environment variable — add them under `environment:` in the Compose file, e.g. `TRAIL_SERVER_APPLICATION_NAME: "My App"`. Secrets such as OAuth client secrets or SMTP passwords belong in `traildepot/secrets/` or in those environment variables, never in the config file.

TrailBase has no equivalent of PocketBase's settings-encryption key; protect the `traildepot` volume instead.

## Running CLI commands

Any arguments given to the container are forwarded to `trail --depot=/app/traildepot` instead of starting the server:

```bash
# against the running container
docker compose -f docker-compose.rootless.yml exec trailbase /app/trail --depot=/app/traildepot admin list

# as a one-off container (stop the server first for write commands)
docker compose -f docker-compose.rootless.yml run --rm trailbase user change-password admin@example.com 'new-secret'
```

## Data persistence

Everything TrailBase writes lives in `/app/traildepot`, backed by the named Docker volume `traildepot`:

```
traildepot/
├── config.textproto   # settings
├── data/              # main.db, logs.db, session.db, queue.db
├── migrations/        # SQL migrations
├── uploads/           # file uploads
├── secrets/           # keys and secrets
├── backups/
└── wasm/              # WASM components (auth UI baked into the image)
```

Data survives container recreation. To develop migrations against the running instance, uncomment the bind mount in the Compose file:

```yaml
# - ./migrations:/app/traildepot/migrations
```

You can also bake `migrations` into the image by uncommenting the corresponding `COPY` line in the Dockerfile.

> **Note:** if you switch the named volume to a host bind mount (e.g. `./traildepot:/app/traildepot`) with the rootless image, make sure the host folder exists and is writable by the container user, or TrailBase fails with `PermissionDenied`. A bind mount also hides the auth UI component baked into the image; reinstall it with `trail components add trailbase/auth_ui`.

## Building for a specific version or architecture

```bash
# multi-arch build with buildx
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg TB_VERSION=0.36.1 \
  -f Dockerfile.rootless \
  -t trailbase:0.36.1 .
```

The Dockerfiles pin the SHA-256 digests of one release, so building another version with `--build-arg TB_VERSION=...` alone fails checksum verification. Use `bump.sh`.

### Bumping the pinned version

`bump.sh` rewrites the version in every file that pins it (`.env.example`, both
Dockerfiles, both Compose files, and this README), fetches the new release's
asset digests from the GitHub API into both Dockerfiles, and commits the result:

```bash
./bump.sh <new-version>
```

Pass `--no-commit` to rewrite the files without committing. The script refuses
to run on a dirty working tree when it would commit, so unrelated changes don't
end up in the bump. When adding a new file that pins the version, add it to the
`FILES` list at the top of the script.

## Health check

Both images define a `HEALTHCHECK` that polls `http://127.0.0.1:${TB_PORT}/api/healthcheck`. Check status with:

```bash
docker ps
docker inspect --format '{{.State.Health.Status}}' trailbase
```

## Managing the stack

```bash
# logs
docker compose -f docker-compose.rootless.yml logs -f

# stop
docker compose -f docker-compose.rootless.yml down

# stop and remove the data volume (destroys the database!)
docker compose -f docker-compose.rootless.yml down -v
```

## Project layout

```
.
├── Dockerfile.rootless          # non-root image (default)
├── Dockerfile.root              # root image
├── docker-compose.rootless.yml  # rootless stack (project: trailbase)
├── docker-compose.root.yml      # root stack (project: trailbase-root)
├── entrypoint.rootless.sh       # bootstrap + run (non-root)
├── entrypoint.root.sh           # bootstrap + run (root)
├── bump.sh                      # bump pinned version + digests
├── .env.example                 # configuration template
├── .gitattributes               # forces LF endings for shell/Docker files
└── .gitignore
```

> **Note:** shell scripts and Dockerfiles must keep LF line endings (enforced via `.gitattributes`) — CRLF endings break execution inside the Linux container.

## License

TrailBase is distributed under its own [license](https://github.com/trailbaseio/trailbase/blob/main/LICENSE). This repository contains only the Docker packaging.

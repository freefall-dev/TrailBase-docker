#!/bin/sh
# TrailBase container entrypoint (root variant).
# Runs on every start: conditionally bootstraps the admin user, then execs the
# server. POSIX sh (busybox ash on Alpine).
#
# Any arguments are forwarded to `trail` instead of starting the server, e.g.
#   docker compose -f docker-compose.root.yml run --rm trailbase admin list
set -e

DEPOT="/app/traildepot"
DB_FILE="${DEPOT}/data/main.db"
TB_PORT="${TB_PORT:-4000}"
# TrailBase auto-creates this admin (random password, printed to the log) on a fresh depot.
DEFAULT_ADMIN="admin@localhost"

trail() {
  /app/trail --depot="${DEPOT}" "$@"
}

# ---- one-off CLI command instead of the server ----
if [ "$#" -gt 0 ]; then
  exec /app/trail --depot="${DEPOT}" "$@"
fi

# ---- look up a user's admin flag: prints 1 (admin), 0 (user) or nothing (missing) ----
admin_flag() {
  [ -f "${DB_FILE}" ] || return 0
  # escape single quotes for the SQL string literal
  email_sql=$(printf '%s' "$1" | sed "s/'/''/g")
  sqlite3 "${DB_FILE}" \
    "SELECT CASE WHEN admin > 0 THEN 1 ELSE 0 END FROM _user WHERE email = '${email_sql}' LIMIT 1;" \
    2>/dev/null || true
}

# ---- admin bootstrap (always evaluated, before the server starts) ----
if [ -n "${TB_ADMIN_EMAIL}" ]; then
  FIRST_BOOT=0
  [ -f "${DB_FILE}" ] || FIRST_BOOT=1

  case "$(admin_flag "${TB_ADMIN_EMAIL}")" in
    1)
      echo "[entrypoint] Admin '${TB_ADMIN_EMAIL}' already exists — skipping creation."
      ;;
    0)
      echo "[entrypoint] User '${TB_ADMIN_EMAIL}' exists but is not an admin — promoting."
      trail admin promote "${TB_ADMIN_EMAIL}"
      ;;
    *)
      if [ -z "${TB_ADMIN_PASSWORD}" ]; then
        echo "[entrypoint] ERROR: admin '${TB_ADMIN_EMAIL}' does not exist and TB_ADMIN_PASSWORD is not set." >&2
        exit 1
      fi

      if [ "${FIRST_BOOT}" -eq 1 ]; then
        # Initialise the fresh depot. TrailBase creates the default admin
        # (admin@localhost, random password) here, which is then taken over:
        # renamed to TB_ADMIN_EMAIL and given TB_ADMIN_PASSWORD.
        echo "[entrypoint] Initialising new depot..."
        trail admin list > /dev/null 2>&1
      fi

      if [ "${FIRST_BOOT}" -eq 1 ] && [ "$(admin_flag "${DEFAULT_ADMIN}")" = "1" ]; then
        echo "[entrypoint] Creating admin '${TB_ADMIN_EMAIL}' from the default admin account..."
        if [ "${TB_ADMIN_EMAIL}" != "${DEFAULT_ADMIN}" ]; then
          trail user change-email "${DEFAULT_ADMIN}" "${TB_ADMIN_EMAIL}"
        fi
        trail user change-password "${TB_ADMIN_EMAIL}" "${TB_ADMIN_PASSWORD}"
      else
        echo "[entrypoint] Creating admin '${TB_ADMIN_EMAIL}'..."
        if ! trail user add "${TB_ADMIN_EMAIL}" "${TB_ADMIN_PASSWORD}"; then
          echo "[entrypoint] ERROR: 'trail user add' failed (it is broken in TrailBase 0.36.x)." >&2
          echo "[entrypoint] Create the user in the admin UI, then restart to promote it." >&2
          exit 1
        fi
        trail admin promote "${TB_ADMIN_EMAIL}"
      fi
      ;;
  esac
else
  echo "[entrypoint] TB_ADMIN_EMAIL not set — skipping admin bootstrap."
  echo "[entrypoint] On a fresh depot TrailBase creates '${DEFAULT_ADMIN}' and prints its password in the log."
fi

# ---- server flags ----
# --public-url is a global flag, so it must precede the `run` subcommand.
set --
if [ -n "${TB_PUBLIC_URL}" ]; then
  set -- --public-url="${TB_PUBLIC_URL}"
fi
set -- "$@" run --address="0.0.0.0:${TB_PORT}"

echo "[entrypoint] Starting TrailBase on 0.0.0.0:${TB_PORT}"
exec /app/trail --depot="${DEPOT}" "$@"

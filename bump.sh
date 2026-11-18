#!/bin/sh
# Bumps the pinned TrailBase release across every file that names it, refreshes
# the pinned SHA-256 digests in both Dockerfiles, then commits the result.
# Run on the host (Git Bash / Linux), not in the container. Needs curl.
#
#   ./bump.sh 0.36.2              bump and commit
#   ./bump.sh 0.36.2 --no-commit  rewrite the files only
set -e

# Every file carrying a hard-coded TB_VERSION. Keep this list in sync when
# adding a file that pins the version.
FILES=".env.example Dockerfile.root Dockerfile.rootless docker-compose.root.yml docker-compose.rootless.yml README.md"
DOCKERFILES="Dockerfile.root Dockerfile.rootless"

NEW_VERSION="$1"
COMMIT=1
[ "$2" = "--no-commit" ] && COMMIT=0

if [ -z "${NEW_VERSION}" ]; then
  echo "usage: $0 <version> [--no-commit]   e.g. $0 0.36.2" >&2
  exit 1
fi

# Published tag without the leading "v".
if ! echo "${NEW_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "[bump] ERROR: '${NEW_VERSION}' is not a MAJOR.MINOR.PATCH version." >&2
  exit 1
fi

cd "$(dirname "$0")"

# Dockerfile.rootless is the source of truth for what is currently pinned.
OLD_VERSION=$(sed -n 's/^ARG TB_VERSION=//p' Dockerfile.rootless)
if [ -z "${OLD_VERSION}" ]; then
  echo "[bump] ERROR: could not read the current version from Dockerfile.rootless." >&2
  exit 1
fi

if [ "${OLD_VERSION}" = "${NEW_VERSION}" ]; then
  echo "[bump] Already pinned to ${NEW_VERSION} — nothing to do."
  exit 0
fi

# A dirty tree would get swept into the bump commit.
if [ "${COMMIT}" -eq 1 ] && [ -n "$(git status --porcelain)" ]; then
  echo "[bump] ERROR: working tree is not clean. Commit or stash first, or pass --no-commit." >&2
  exit 1
fi

# ---- fetch the asset digests GitHub publishes for the new release ----
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/trailbaseio/trailbase/releases/tags/v${NEW_VERSION}") || {
  echo "[bump] ERROR: release v${NEW_VERSION} not found on GitHub." >&2
  exit 1
}

# Prints the sha256 of the named asset. Relies on GitHub listing "digest" after "name".
asset_sha() {
  echo "${RELEASE_JSON}" \
    | tr -d '\r' \
    | grep -E '"name":|"digest":' \
    | grep -A1 "\"name\": *\"$1\"" \
    | sed -n 's/.*"digest": *"sha256:\([0-9a-f]\{64\}\)".*/\1/p' \
    | head -n1
}

SHA_AMD64=$(asset_sha "trailbase_v${NEW_VERSION}_x86_64_linux.zip")
SHA_ARM64=$(asset_sha "trailbase_v${NEW_VERSION}_aarch64_linux.zip")
SHA_AUTH_UI=$(asset_sha "trailbase_v${NEW_VERSION}_wasm_auth_ui.zip")

for v in SHA_AMD64 SHA_ARM64 SHA_AUTH_UI; do
  eval "val=\${$v}"
  if [ -z "${val}" ]; then
    echo "[bump] ERROR: could not read the ${v} digest for v${NEW_VERSION}." >&2
    exit 1
  fi
done

echo "[bump] ${OLD_VERSION} -> ${NEW_VERSION}"
# Escape the dots so the old version matches literally.
OLD_PATTERN=$(echo "${OLD_VERSION}" | sed 's/\./\./g')
# shellcheck disable=SC2086
sed -i "s/${OLD_PATTERN}/${NEW_VERSION}/g" ${FILES}

# shellcheck disable=SC2086
sed -i \
  -e "s/^ARG TB_SHA256_AMD64=.*/ARG TB_SHA256_AMD64=${SHA_AMD64}/" \
  -e "s/^ARG TB_SHA256_ARM64=.*/ARG TB_SHA256_ARM64=${SHA_ARM64}/" \
  -e "s/^ARG TB_SHA256_AUTH_UI=.*/ARG TB_SHA256_AUTH_UI=${SHA_AUTH_UI}/" \
  ${DOCKERFILES}

# Catch any file the replacement missed (e.g. a version written differently).
# shellcheck disable=SC2086
if grep -n "${OLD_PATTERN}" ${FILES}; then
  echo "[bump] ERROR: ${OLD_VERSION} still present in the files above." >&2
  exit 1
fi

# shellcheck disable=SC2086
grep -n -e "${NEW_VERSION}" -e "^ARG TB_SHA256_" ${FILES}

if [ "${COMMIT}" -eq 0 ]; then
  echo "[bump] Files rewritten, not committed."
  exit 0
fi

# shellcheck disable=SC2086
git add ${FILES}
git commit -m "Bump TrailBase to ${NEW_VERSION}"
echo "[bump] Committed."

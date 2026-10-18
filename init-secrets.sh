#!/usr/bin/env bash
# Generates the secret files used by docker-compose.yml.
# Run on the OMV host as root:  sudo ./init-secrets.sh
# - Postgres password: random (you never need to know it)
# - Miniflux admin username/password: entered interactively
set -euo pipefail

MINIFLUX_UID=65534   # the miniflux image runs as USER 65534

cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo): chown is needed for the files Miniflux reads." >&2
  exit 1
fi

command -v openssl >/dev/null || { echo "openssl is missing." >&2; exit 1; }

if [[ -e secrets ]]; then
  echo "secrets/ already exists; not overwriting. Delete it manually to regenerate" >&2
  echo "(note: the DB password is already stored in the Postgres volume)." >&2
  exit 1
fi

read -rp "Miniflux admin username: " ADMIN_USER
if [[ ! "$ADMIN_USER" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then
  echo "Invalid name (3-32 chars: letters, digits, . _ -)." >&2
  exit 1
fi

read -rsp "Miniflux admin password: " ADMIN_PASS; echo
read -rsp "Repeat password: " ADMIN_PASS2; echo
if [[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]]; then
  echo "Passwords do not match." >&2
  exit 1
fi
if (( ${#ADMIN_PASS} < 12 )); then
  echo "Password too short (minimum 12 characters)." >&2
  exit 1
fi
if [[ "$ADMIN_PASS" == *$'\n'* ]]; then
  echo "Password cannot contain a newline." >&2
  exit 1
fi

umask 077
mkdir secrets

# hex => safe inside the connection URL, no escaping needed
DB_PASS="$(openssl rand -hex 32)"

# printf without a trailing newline, so values are read exactly
printf '%s' "$DB_PASS" > secrets/postgres_password
printf 'postgres://miniflux:%s@db/miniflux?sslmode=disable' "$DB_PASS" > secrets/miniflux_database_url
printf '%s' "$ADMIN_USER" > secrets/miniflux_admin_username
printf '%s' "$ADMIN_PASS" > secrets/miniflux_admin_password

unset DB_PASS ADMIN_PASS ADMIN_PASS2

# Postgres reads its secret as root in the entrypoint => stays root:root 600.
# Miniflux runs as 65534 => its files are owned by that UID, also 600.
chmod 700 secrets
chmod 600 secrets/*
chown "$MINIFLUX_UID:$MINIFLUX_UID" \
  secrets/miniflux_database_url secrets/miniflux_admin_username secrets/miniflux_admin_password

echo "OK: secrets/ created."
ls -l secrets

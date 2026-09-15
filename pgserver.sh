#!/usr/bin/env bash
# ============================================================================
# pgserver.sh — local pgbouncer proxy to RDS with auto-refreshing IAM token
# ============================================================================
# Your app connects to 127.0.0.1:6432 with NO password and NO code change.
# pgbouncer connects upstream to RDS using an IAM auth token that this script
# regenerates every PGBOUNCER_REFRESH_SECONDS (< the 15-min token lifetime)
# and reloads.
#
# LOCAL DEV ONLY. Binds to loopback. For prod/shared use, use AWS RDS Proxy.
#
# Prereqs: pgbouncer, aws cli (with your IAM creds), on the VPN, and the RDS CA:
#   curl -o ~/.aws/rds-global-bundle.pem \
#     https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
#
# Usage:
#   1. cp .env.example .env   and fill in PG_DATABASES / AWS_PROFILE / AWS_REGION.
#      .env is gitignored — real endpoints and usernames never get committed.
#   2. ./pgserver.sh
#   3. Point the app at: host=127.0.0.1 port=6432 dbname=<name> sslmode=disable
#      (traffic to RDS is still TLS — pgbouncer handles it; the loopback hop is local)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PGSERVER_ENV:-$SCRIPT_DIR/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example to .env and fill it in."
  exit 1
fi
# shellcheck source=/dev/null
set -a; source "$ENV_FILE"; set +a

: "${AWS_REGION:?set AWS_REGION in $ENV_FILE}"
: "${AWS_PROFILE:?set AWS_PROFILE in $ENV_FILE}"
: "${PG_DATABASES:?set PG_DATABASES in $ENV_FILE}"

LISTEN_ADDR="127.0.0.1"
LISTEN_PORT="${PGBOUNCER_LISTEN_PORT:-6432}"
CA_FILE="${RDS_CA_FILE:-$HOME/.aws/rds-global-bundle.pem}"
REFRESH_SECONDS="${PGBOUNCER_REFRESH_SECONDS:-600}"   # 10 min < 15-min token expiry

# PG_DATABASES is one line so it stays valid .env that docker compose can also read:
# rows split on ';', fields on '|' as name|host|port|dbname|db-user
IFS=';' read -r -a DATABASES <<<"$PG_DATABASES"
[ "${#DATABASES[@]}" -gt 0 ] || { echo "ERROR: PG_DATABASES is empty"; exit 1; }

command -v pgbouncer >/dev/null || { echo "ERROR: install pgbouncer (brew install pgbouncer / apt-get install pgbouncer)"; exit 1; }
command -v aws >/dev/null       || { echo "ERROR: aws cli not found"; exit 1; }
[ -f "$CA_FILE" ] || { echo "ERROR: RDS CA bundle missing at $CA_FILE"; exit 1; }

WORKDIR="$(mktemp -d)"
INI="$WORKDIR/pgbouncer.ini"
PIDFILE="$WORKDIR/pgbouncer.pid"
USERLIST="$WORKDIR/userlist.txt"
echo '"local_admin" ""' > "$USERLIST"

gen_token() { aws rds generate-db-auth-token --hostname "$1" --port "$2" --username "$3" --region "$AWS_REGION" --profile "$AWS_PROFILE"; }

write_config() {
  {
    echo "[databases]"
    for row in "${DATABASES[@]}"; do
      IFS='|' read -r name host port dbname dbuser <<<"$row"
      local tok; tok="$(gen_token "$host" "$port" "$dbuser")"
      echo "$name = host=$host port=$port dbname=$dbname user=$dbuser password='$tok'"
    done
    cat <<EOF

[pgbouncer]
listen_addr = $LISTEN_ADDR
listen_port = $LISTEN_PORT
auth_type = any
auth_file = $USERLIST
admin_users = local_admin
pool_mode = session
server_tls_sslmode = verify-full
server_tls_ca_file = $CA_FILE
pidfile = $PIDFILE
logfile = $WORKDIR/pgbouncer.log
ignore_startup_parameters = extra_float_digits,options
EOF
  } > "$INI"
}

cleanup() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

write_config
pgbouncer -d "$INI"
sleep 1
echo "pgbouncer up on $LISTEN_ADDR:$LISTEN_PORT  (refresh every ${REFRESH_SECONDS}s)"
echo "connect (the -d <name> is the pgbouncer alias, NOT the IAM user or real dbname):"
for row in "${DATABASES[@]}"; do
  IFS='|' read -r name host port dbname dbuser <<<"$row"
  echo "  psql -h $LISTEN_ADDR -p $LISTEN_PORT -d $name -U '$dbuser'"
done
echo "Ctrl-C to stop."

while true; do
  sleep "$REFRESH_SECONDS"
  write_config
  kill -HUP "$(cat "$PIDFILE")"     # reload config -> new upstream connections use fresh token
  echo "$(date '+%T') refreshed IAM tokens"
done

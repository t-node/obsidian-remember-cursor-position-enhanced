#!/usr/bin/env bash
# Start CouchDB and wait for admin ready. Used by setup-livesync-mobile-ready.ps1
set -euo pipefail
cd "$(dirname "$0")"
if [[ -z "${COUCHDB_PASSWORD:-}" ]]; then
  echo "COUCHDB_PASSWORD not set" >&2
  exit 1
fi
printf 'COUCHDB_USER=obsidian\nCOUCHDB_PASSWORD=%s\n' "$COUCHDB_PASSWORD" > .env
docker compose --env-file .env up -d
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "obsidian:${COUCHDB_PASSWORD}" http://127.0.0.1:5984/_up || true)
  if [[ "$code" == "200" ]]; then
    echo "CouchDB ready"
    exit 0
  fi
  sleep 2
done
echo "CouchDB did not become ready" >&2
docker compose logs --tail 20
exit 1

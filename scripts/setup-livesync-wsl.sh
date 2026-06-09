#!/usr/bin/env bash
# LiveSync CouchDB setup — run inside WSL Ubuntu (docker already working).
# Usage:
#   cd /mnt/c/obsidian-remember-cursor-position/scripts
#   chmod +x setup-livesync-wsl.sh
#   ./setup-livesync-wsl.sh
set -euo pipefail

SETUP_SCRIPT_VERSION="4-diagnostics"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/livesync"
VAULT_PATH="${VAULT_PATH:-/mnt/c/notes1}"
DATABASE="${DATABASE:-obsidian-vault}"

curl_with_auth() {
  # Avoid bash expanding $ inside passwords when calling curl -u user:pass
  local pass_file
  pass_file="$(mktemp)"
  chmod 600 "$pass_file"
  printf '%s' "$COUCHDB_PASSWORD" >"$pass_file"
  curl -s -u "obsidian" --pass @"$pass_file" "$@"
  local rc=$?
  rm -f "$pass_file"
  return $rc
}

dump_couchdb_diagnostics() {
  echo ""
  echo "========== DIAGNOSTICS =========="
  echo "Script version: $SETUP_SCRIPT_VERSION"
  echo "Compose dir:    $COMPOSE_DIR"
  echo "Password len:   ${#COUCHDB_PASSWORD} chars (value not printed)"
  if [[ -f "$COMPOSE_DIR/.env" ]]; then
    echo ".env file:      present ($(wc -c <"$COMPOSE_DIR/.env") bytes)"
  else
    echo ".env file:      MISSING"
  fi
  echo ""
  echo "--- docker compose ps ---"
  (cd "$COMPOSE_DIR" && docker compose ps -a) || true
  echo ""
  echo "--- container env (COUCHDB_* only) ---"
  docker inspect obsidian-livesync-couchdb --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^COUCHDB_' || echo "(container not found)"
  echo ""
  echo "--- docker compose.yml (volumes section) ---"
  grep -A6 'volumes:' "$COMPOSE_DIR/docker-compose.yml" || true
  if [[ -d "$COMPOSE_DIR/couchdb-local.d" ]]; then
    echo ""
    echo "WARNING: couchdb-local.d exists on disk (should NOT be mounted in compose):"
    ls -la "$COMPOSE_DIR/couchdb-local.d" || true
  fi
  echo ""
  echo "--- last 40 log lines ---"
  (cd "$COMPOSE_DIR" && docker compose logs --tail 40) || true
  echo ""
  echo "--- curl GET / (no auth) ---"
  curl -s -w "\nHTTP %{http_code}\n" http://127.0.0.1:5984/ || true
  echo ""
  echo "--- curl GET /_up (with auth) ---"
  local body code
  body="$(curl_with_auth -w '__HTTP__%{http_code}' http://127.0.0.1:5984/_up || true)"
  code="${body##*__HTTP__}"
  body="${body%__HTTP__*}"
  echo "HTTP $code"
  echo "$body"
  echo "================================="
  echo ""
}

write_compose_env() {
  local env_file="$COMPOSE_DIR/.env"
  local escaped
  escaped="$(printf '%s' "$COUCHDB_PASSWORD" | sed 's/"/\\"/g')"
  printf 'COUCHDB_USER=obsidian\nCOUCHDB_PASSWORD="%s"\n' "$escaped" >"$env_file"
  chmod 600 "$env_file"
}

echo ""
echo "========================================"
echo " LiveSync + RCP-E — WSL setup"
echo "  script $SETUP_SCRIPT_VERSION"
echo "========================================"
echo ""

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found in WSL. Install Docker in this distro first."
  exit 1
fi

read -rsp "CouchDB password for user obsidian (min 8 chars): " COUCHDB_PASSWORD
echo ""
if [[ ${#COUCHDB_PASSWORD} -lt 8 ]]; then
  echo "ERROR: password must be at least 8 characters."
  exit 1
fi

read -rsp "LiveSync E2E passphrase (same on all 4 devices, min 8 chars): " E2E_PASSPHRASE
echo ""
if [[ ${#E2E_PASSPHRASE} -lt 8 ]]; then
  echo "ERROR: E2E passphrase must be at least 8 characters."
  exit 1
fi

# --- RCP-E deploy (if node/npm available) ---
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  echo ""
  echo "[1/3] Building and deploying RCP-E..."
  export OBSIDIAN_VAULT_PLUGIN_DIR="$VAULT_PATH/.obsidian/plugins/remember-cursor-position-enhanced"
  cd "$REPO_ROOT"
  npm test
  npm run deploy
  echo "  RCP-E deployed."
else
  echo ""
  echo "[1/3] Skipping RCP-E deploy (node/npm not in WSL)."
  echo "  Run from PowerShell instead:"
  echo "    cd C:\\obsidian-remember-cursor-position"
  echo "    npm run deploy"
fi

configure_livesync_cors() {
  local cfg="http://127.0.0.1:5984/_node/_local/_config"
  curl_with_auth -sf -X PUT "${cfg}/chttpd/enable_cors" -d '"true"' >/dev/null
  curl_with_auth -sf -X PUT "${cfg}/cors/origins" \
    -d '"app://obsidian.md,capacitor://localhost,http://localhost,https://localhost"' >/dev/null
  curl_with_auth -sf -X PUT "${cfg}/cors/credentials" -d '"true"' >/dev/null
  curl_with_auth -sf -X PUT "${cfg}/cors/methods" \
    -d '"GET, PUT, POST, HEAD, DELETE"' >/dev/null
  curl_with_auth -sf -X PUT "${cfg}/cors/headers" \
    -d '"accept, authorization, content-type, origin, referer, x-requested-with"' >/dev/null
}

# --- CouchDB ---
echo ""
echo "[2/3] Starting CouchDB..."
export COUCHDB_PASSWORD
cd "$COMPOSE_DIR"

write_compose_env
echo "  Wrote $COMPOSE_DIR/.env (password length ${#COUCHDB_PASSWORD})"

docker compose --env-file .env up -d --force-recreate

echo "Waiting for CouchDB admin account (up to 90s)..."
auth_ok=0
attempt=0
for _ in $(seq 1 30); do
  attempt=$((attempt + 1))
  status="$(docker compose ps --format '{{.Status}}' 2>/dev/null | head -n1 || true)"
  if echo "$status" | grep -qi restarting; then
    echo "  attempt $attempt: container RESTARTING"
    docker compose logs --tail 10
    sleep 3
    continue
  fi
  root_code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5984/ || true)"
  up_raw="$(curl_with_auth -w '__HTTP__%{http_code}' http://127.0.0.1:5984/_up 2>/dev/null || true)"
  up_code="${up_raw##*__HTTP__}"
  up_body="${up_raw%__HTTP__*}"
  echo "  attempt $attempt: status=[$status] GET/=HTTP$root_code GET/_up=HTTP$up_code"
  if [[ -n "$up_body" && "$up_body" != "$up_raw" ]]; then
    echo "           _up body: $up_body"
  fi
  if [[ "$up_code" == "200" ]]; then
    auth_ok=1
    break
  fi
  sleep 3
done
if [[ $auth_ok -ne 1 ]]; then
  echo ""
  echo "ERROR: CouchDB admin login failed after 90s."
  dump_couchdb_diagnostics
  echo "Common fixes:"
  echo "  1. Password contains \$ or ! — script v4 handles this; confirm header shows: script 4-diagnostics"
  echo "  2. Stale volume — cd livesync && docker compose down -v && cd .. && bash setup-livesync-wsl.sh"
  echo "  3. Avoid \$ and ! in password for now if on older script"
  exit 1
fi

echo "  Admin OK. Enabling CORS for LiveSync..."
configure_livesync_cors

DB_URL="http://127.0.0.1:5984/${DATABASE}"
create_body="$(mktemp)"
create_raw="$(curl_with_auth -o "$create_body" -w '__HTTP__%{http_code}' -X PUT "$DB_URL" 2>/dev/null || true)"
create_code="${create_raw##*__HTTP__}"
if [[ "$create_code" == "201" || "$create_code" == "200" ]]; then
  echo "  Database created: $DATABASE"
elif [[ "$create_code" == "412" ]]; then
  echo "  Database already exists: $DATABASE"
else
  echo "ERROR: could not create database $DATABASE (HTTP $create_code)"
  cat "$create_body" 2>/dev/null || true
  dump_couchdb_diagnostics
  exit 1
fi
rm -f "$create_body"

# --- Tailscale IP (optional) ---
TAILSCALE_IP=""
if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
fi

LOCAL_URI="http://127.0.0.1:5984/${DATABASE}"
if [[ -n "$TAILSCALE_IP" ]]; then
  REMOTE_URI="http://${TAILSCALE_IP}:5984/${DATABASE}"
else
  REMOTE_URI="http://<TAILSCALE-IP>:5984/${DATABASE}"
fi

CHEAT="$VAULT_PATH/LIVESYNC-NEXT-STEPS.txt"
mkdir -p "$(dirname "$CHEAT")"

cat >"$CHEAT" <<EOF
================================================================================
LIVESYNC + RCP-E — YOUR VALUES (WSL setup, $(date '+%Y-%m-%d %H:%M'))
================================================================================

CouchDB runs in WSL Docker. Obsidian on Windows uses the same localhost URL.

CONNECTION — master laptop Obsidian:
  URI:        $LOCAL_URI
  Username:   obsidian
  Password:   (what you entered)
  E2E:        (what you entered)
  Mode:       LiveSync
  First sync: Overwrite remote with local

PHONE / TABLET / other laptop (after Tailscale on all devices):
  URI:        $REMOTE_URI

OBSIDIAN STEPS (master, ~5 min):
  1. Ctrl+R in Obsidian
  2. Install + enable Self-hosted LiveSync
  3. Connect with values above
  4. First sync: Overwrite remote with local
  5. Copy Setup URI → other 3 devices → Fetch from remote
  6. RCP-E state folder = cursor-state

OTHER DEVICES (~5 min each):
  - Pause Syncthing for this vault
  - Paste Setup URI, same E2E passphrase
  - BRAT: t-node/obsidian-remember-cursor-position-enhanced
  - Restart Obsidian

VERIFY:
  Phone: edit + scroll, wait 3s, close app
  Laptop: open note → text + scroll match

EOF

echo ""
echo "[3/3] Done."
echo ""
echo "========================================"
echo " CouchDB is running in WSL"
echo "========================================"
echo "  Local URI:  $LOCAL_URI"
echo "  User:       obsidian"
if [[ -n "$TAILSCALE_IP" ]]; then
  echo "  Tailscale:  $TAILSCALE_IP"
  echo "  Mobile URI: $REMOTE_URI"
fi
echo ""
echo "Cheat sheet: $CHEAT"
echo ""
echo "Next: open Obsidian on Windows → Ctrl+R → connect LiveSync with URI above."
echo ""

#!/usr/bin/env bash
# Brings up the real Amer Teams server stack (the same Docker deployment users run, LAN mode on http://localhost)
# and creates three accounts for the in-use UI test: admin, moh (driven by the app), bob (Python peer).
set -euo pipefail
cd "$(dirname "$0")/../deploy"
cp .env.example .env
sed -i "s/^DOMAIN=.*/DOMAIN=localhost/; s/^SERVER_NAME=.*/SERVER_NAME=amer.test/" .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/; s/^LIVEKIT_API_SECRET=.*/LIVEKIT_API_SECRET=$(openssl rand -hex 32)/" .env
bash setup.sh
export LAN_IP=127.0.0.1
C="docker compose -f docker-compose.yml -f docker-compose.local.yml"
$C up -d --build postgres redis synapse livekit orchestrator caddy
for i in $(seq 90); do curl -fsS http://localhost/_matrix/client/versions >/dev/null 2>&1 && break; sleep 2; done
reg() { $C exec -T synapse register_new_matrix_user -c /data/homeserver.yaml -u "$1" -p "$2" $3 http://localhost:8008; }
reg admin 'Admin-Pass-123!' --admin; reg moh 'Moh-Pass-123!' --admin; reg bob 'Bob-Pass-123!' --no-admin
TOKEN=$(curl -fsS -XPOST http://localhost/_matrix/client/v3/login -H 'Content-Type: application/json' \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"admin"},"password":"Admin-Pass-123!"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
sed -i '/^SYNAPSE_ADMIN_TOKEN=/d' .env; echo "SYNAPSE_ADMIN_TOKEN=$TOKEN" >> .env
$C up -d orchestrator
for i in $(seq 60); do curl -fsS http://localhost/api/healthz >/dev/null 2>&1 && break; sleep 2; done
curl -fsS http://localhost/api/healthz && echo " stack up"
grep -E '^LIVEKIT_API_(KEY|SECRET)=' .env >> "$GITHUB_ENV" 2>/dev/null || true

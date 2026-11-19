#!/usr/bin/env bash
# Creates the first administrator and gives the AI engine its admin token (for invite codes and user management).
set -euo pipefail
cd "$(dirname "$0")"; set -a; . ./.env; set +a
echo "Waiting for the chat server..."; for i in $(seq 60); do curl -fsS "https://${DOMAIN}/_matrix/client/versions" >/dev/null 2>&1 && break; sleep 3; done
read -rp "Admin username [admin]: " U; U=${U:-admin}
read -rsp "Admin password (10+ chars, upper, lower, number, symbol): " P; echo
docker compose exec -T synapse register_new_matrix_user -c /data/homeserver.yaml -u "$U" -p "$P" --admin http://localhost:8008
TOKEN=$(curl -fsS -XPOST "https://${DOMAIN}/_matrix/client/v3/login" -H 'Content-Type: application/json' \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$U\"},\"password\":\"$P\",\"initial_device_display_name\":\"Amer AI engine\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
sed -i '/^SYNAPSE_ADMIN_TOKEN=/d' .env; echo "SYNAPSE_ADMIN_TOKEN=$TOKEN" >> .env
docker compose up -d orchestrator
sleep 8
CODE=$(curl -fsS -XPOST "https://${DOMAIN}/api/v1/admin/invites" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"uses_allowed": 10, "expiry_days": 30}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' || true)
[ -n "$CODE" ] && echo "First invite code (10 sign-ups, valid 30 days): $CODE"
echo "Done. Sign in to the app as '$U'. More invite codes: Users > New invite code."

# Amer chat assistant: its own account, a secret for the AI engine, then start it (kept on re-runs)
if ! grep -q '^AMER_BOT_SECRET=' .env; then
  printf 'AMER_BOT_USER=amer\nAMER_BOT_PASSWORD=Am%s!Q\nAMER_BOT_SECRET=%s\n' "$(openssl rand -hex 10)" "$(openssl rand -hex 24)" >> .env
fi
. ./.env
docker compose exec -T synapse register_new_matrix_user -c /data/homeserver.yaml -u "$AMER_BOT_USER" -p "$AMER_BOT_PASSWORD" --no-admin http://localhost:8008 >/dev/null 2>&1 || true
docker compose up -d orchestrator amer-bot
echo "Amer assistant started: users can open Amer > Chat with Amer, or @mention Amer in a group."

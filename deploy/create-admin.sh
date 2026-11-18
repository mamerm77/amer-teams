#!/usr/bin/env bash
# Creates the first administrator and gives the AI engine its admin token (for invite codes and user management).
set -euo pipefail
cd "$(dirname "$0")"; set -a; . ./.env; set +a
read -rp "Admin username [admin]: " U; U=${U:-admin}
read -rsp "Admin password (10+ chars, upper, lower, number, symbol): " P; echo
docker compose exec -T synapse register_new_matrix_user -c /data/homeserver.yaml -u "$U" -p "$P" --admin http://localhost:8008
TOKEN=$(curl -fsS -XPOST "https://${DOMAIN}/_matrix/client/v3/login" -H 'Content-Type: application/json' \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$U\"},\"password\":\"$P\",\"initial_device_display_name\":\"Amer AI engine\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
sed -i '/^SYNAPSE_ADMIN_TOKEN=/d' .env; echo "SYNAPSE_ADMIN_TOKEN=$TOKEN" >> .env
docker compose up -d orchestrator
echo "Done. Sign in to the app as '$U', open Users, and create invite codes for your team."

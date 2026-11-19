#!/usr/bin/env bash
# One-time setup: generates secrets, Synapse config and LiveKit keys.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { cp .env.example .env
  sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
  sed -i "s/^LIVEKIT_API_SECRET=.*/LIVEKIT_API_SECRET=$(openssl rand -hex 32)/" .env
  echo "Created .env — edit DOMAIN, SERVER_NAME and ANTHROPIC_API_KEY, then re-run."; exit 0; }
grep -q '^AMER_ALERT_SECRET=' .env || echo "AMER_ALERT_SECRET=$(openssl rand -hex 24)" >> .env             # Alertmanager -> incidents (docs/OPERATOR_MODE.md)
(umask 077; grep '^AMER_ALERT_SECRET=' .env | cut -d= -f2- | tr -d '\n' > monitoring/amer_alert_secret)
grep -q '^AMER_FEDERATION_SECRET=' .env || echo "AMER_FEDERATION_SECRET=$(openssl rand -hex 24)" >> .env   # Synapse module <-> orchestrator
set -a; . ./.env; set +a
python3 - <<PY2
import re;p="livekit.yaml";s=open(p).read()
s=re.sub(r"keys:\n(  #.*\n)?  .*\n","keys:\n  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}\n",s);s=s.replace("api_key: LK_API_KEY","api_key: ${LIVEKIT_API_KEY}");open(p,"w").write(s)
PY2
if [ ! -f synapse/homeserver.yaml ]; then
  docker run --rm -v "$PWD/synapse:/data" -e SYNAPSE_SERVER_NAME="$SERVER_NAME" -e SYNAPSE_REPORT_STATS=no matrixdotorg/synapse:v1.120.0 generate
  # the container writes the files as its own user (991); take ownership to edit, and hand them back afterwards
  docker run --rm -v "$PWD/synapse:/data" alpine:3.20 chown -R "$(id -u):$(id -g)" /data
  python3 - "$POSTGRES_PASSWORD" <<'PY'
import sys,re
p="synapse/homeserver.yaml"; s=open(p).read(); pw=sys.argv[1]
s=re.sub(r"database:\n(  .*\n)+", f"""database:
  name: psycopg2
  args: {{user: synapse, password: {pw}, database: synapse, host: postgres, cp_min: 5, cp_max: 10}}
""", s)
s=s.replace("listeners:\n", "listeners:\n  - port: 9000\n    type: metrics\n    bind_addresses: ['0.0.0.0']\n", 1)
s=s.rstrip("\n")+"\n"
s+="""
# --- Amer Teams policy: encryption is mandatory ---
encryption_enabled_by_default_for_room_type: all
enable_registration: true
registration_requires_token: true
password_config:
  enabled: true
  policy: {enabled: true, minimum_length: 10, require_digit: true, require_symbol: true, require_lowercase: true, require_uppercase: true}
public_baseurl: https://%s/
max_upload_size: 200M
enable_metrics: true
user_directory: {enabled: true, search_all_users: true, prefer_local_users: true}
retention: {enabled: true, purge_jobs: [{interval: 1h}]}
# business messaging rates (Synapse default 0.2/s with burst 10 throttles active chats and meetings)
rc_message: {per_second: 10, burst_count: 100}
# public teams appear in Discover teams
room_list_publication_rules: [{action: allow}]
""" % __import__("os").environ.get("DOMAIN","localhost")
open(p,"w").write(s)
PY
  docker run --rm -v "$PWD/synapse:/data" alpine:3.20 chown -R 991:991 /data
fi
# partner policy (docs/PARTNERS.md): only active partner servers may federate; rooms are local unless shared.
# Added to existing installs too, so re-running setup.sh upgrades them.
if ! grep -q "amer_federation.AmerFederation" synapse/homeserver.yaml; then
  docker run --rm -v "$PWD/synapse:/data" alpine:3.20 chown -R "$(id -u):$(id -g)" /data
  cat >> synapse/homeserver.yaml <<YAML

# --- Amer Teams partner policy (docs/PARTNERS.md) ---
modules:
  - module: amer_federation.AmerFederation
    config: {orchestrator: "http://orchestrator:8080", secret: "${AMER_FEDERATION_SECRET}"}
YAML
  docker run --rm -v "$PWD/synapse:/data" alpine:3.20 chown -R 991:991 /data
fi
echo "Setup complete. Next:"
echo "  docker compose up -d"
echo "  ./create-admin.sh        # creates the first administrator and connects the AI engine to it"

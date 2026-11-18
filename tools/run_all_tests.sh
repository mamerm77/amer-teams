#!/bin/bash
# Runs every test suite against the live stack and prints a summary.
cd "$(dirname "$0")/.." && . /opt/amer/venv/bin/activate
E="env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy SSL_CERT_FILE=/opt/amer/ca.crt RUST_LOG=off"
(cd services/orchestrator && python -m pytest -q 2>&1 | tail -1 | sed 's/^/unit: /')
for t in e2e_real protocol_conformance registration_test meetings_test chat_features_test host_controls_test pq_hybrid_test sip_test monitoring_test call_trace_test ha_test; do
  (cd tests && $E OUT=/opt/amer/all_$t.json timeout 900 python -u $t.py > /opt/amer/all_$t.log 2>&1 < /dev/null)
  pkill -f "bin/uvicorn app.main:app --port 818" 2>/dev/null; pkill -f "/opt/amer/ha/Caddyfile" 2>/dev/null
  python3 -c "import json;R=json.load(open('/opt/amer/all_$t.json'));f=[r['check'] for r in R if not r['pass']];print('$t:',sum(r['pass'] for r in R),'/',len(R),'FAILED:'+str(f) if f else '')" 2>/dev/null || echo "$t: did not finish (see /opt/amer/all_$t.log)"
done

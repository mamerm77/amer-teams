"""Phone network (SIP) tests against the live LiveKit server and AI engine (no mocks).
Covers trunk and routing provisioning, security settings, policy, number validation, auditing and
the dial-out path. Placing audio on a real phone needs the LiveKit SIP service + a carrier trunk."""
import json, os, sys
import httpx, psycopg

ORCH, HS = "http://127.0.0.1:8080", "http://127.0.0.1:8008"
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)
h = httpx.Client(timeout=15)
login = lambda u, p: h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": p}).json()["access_token"]
A = {"Authorization": f"Bearer {login('admin', 'Adm1n-Pass!2026')}"}; M = {"Authorization": f"Bearer {login('moh', 'Pass-moh-123')}"}

# policy defaults
r = h.post(f"{ORCH}/v1/phone/dial", headers=M, json={"number": "+971501234567"})
check("1. Phone calls are off by default", r.status_code == 403, r.json().get("detail"))
r = h.put(f"{ORCH}/v1/phone/policy", headers=M, json={"enabled": True, "allowed_prefixes": ["+971"]})
check("2. Only admins can change phone policy", r.status_code == 403)
r = h.put(f"{ORCH}/v1/phone/policy", headers=A, json={"enabled": True, "allowed_prefixes": ["+971", "+20"]})
check("3. Admin enables phone calls for +971 and +20", r.status_code == 200)
r = h.post(f"{ORCH}/v1/phone/dial", headers=M, json={"number": "+971501234567"})
check("4. Dialling without a phone line gives a clear error", r.status_code == 503, r.json().get("detail"))

# trunk provisioning on the live media server
r = h.post(f"{ORCH}/v1/phone/trunks", headers=A, json={"name": "Test carrier", "address": "sip.carrier.example:5061", "numbers": ["+97125550100"],
        "auth_username": "amer", "auth_password": "trunk-secret", "allowed_inbound_addresses": ["198.51.100.0/24"]})
ids = r.json(); check("5. Admin creates outbound + inbound trunk and inbound routing rule", r.status_code == 200 and all(ids.get(k) for k in ("outbound_trunk_id", "inbound_trunk_id", "dispatch_rule_id")), ids)
t = h.get(f"{ORCH}/v1/phone/trunks", headers=A).json()
out = next((x for x in t["outbound"] if x["id"] == ids.get("outbound_trunk_id")), {})
inn = next((x for x in t["inbound"] if x["id"] == ids.get("inbound_trunk_id")), {})
check("6. Outbound trunk uses SIP over TLS", out.get("transport") == "SIP_TRANSPORT_TLS", out.get("transport"))
check("7. Both trunks require encrypted media (SRTP)", out.get("media_encryption") == inn.get("media_encryption") == "SIP_MEDIA_ENCRYPT_REQUIRE")
check("8. Inbound calls routed to their own phone room", any(d["id"] == ids.get("dispatch_rule_id") for d in t["dispatch_rules"]))
r = h.post(f"{ORCH}/v1/phone/trunks", headers=A, json={"name": "bad", "address": "x:5061", "numbers": ["0501234567"]})
check("9. Trunk numbers must be E.164", r.status_code == 400)

# number policy
cases = {"0501234567": 400, "+1900555123": 403, "+9719001234": 403, "+447911123456": 403, "+88216123456": 403}
res = {n: h.post(f"{ORCH}/v1/phone/dial", headers=M, json={"number": n}).status_code for n in cases}
check("10. Local format, premium, satellite and non-allowed countries refused", res == cases, res)

# dial-out path
r = h.post(f"{ORCH}/v1/phone/dial", headers=M, json={"number": "+971 50 123 4567"})
gw = r.json()
check("11. Allowed number accepted and sent to the SIP gateway", r.status_code in (200, 502),
      "call placed" if r.status_code == 200 else f"gateway not running here: {gw.get('detail', '')[:80]}")
if r.status_code == 200:
    check("11b. Phone call labelled not end-to-end", gw["e2ee"] == "not-possible")

with psycopg.connect("postgresql://amer:amer-pass@127.0.0.1/amer") as c:
    acts = c.execute("SELECT action, detail FROM audit_log WHERE action LIKE 'phone.%' ORDER BY id DESC LIMIT 10").fetchall()
check("12. Phone actions audited, numbers masked", any(a == "phone.trunk.create" for a, _ in acts) and all("501234567" not in d for _, d in acts),
      [f"{a}: {d}" for a, d in acts[:3]])

# clean up
for k in ("outbound_trunk_id", "inbound_trunk_id"):
    if ids.get(k): h.delete(f"{ORCH}/v1/phone/trunks/{ids[k]}", headers=A)
h.put(f"{ORCH}/v1/phone/policy", headers=A, json={"enabled": False, "allowed_prefixes": ["+971"]})
p = sum(x["pass"] for x in R); print(f"\n{p}/{len(R)} phone-network checks passed")
json.dump(R, open(os.getenv("OUT", "sip_results.json"), "w"), indent=1); sys.exit(0 if p == len(R) else 1)

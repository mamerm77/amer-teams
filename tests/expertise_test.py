"""Expertise map on the real stack (docs/EXPERTISE.md): publish, search ranking, withdraw."""
import asyncio, json, os, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Exp-Pass-123!"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Exp-Pass-123!"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def main():
    sfx = secrets.token_hex(3); tag = f"zz{sfx}"
    async with httpx.AsyncClient(timeout=20) as h:
        (A, a), (B, b), (C, c) = await tok(h, f"opt{sfx}"), await tok(h, f"ip{sfx}"), await tok(h, f"ask{sfx}")
        await h.put(f"{ORCH}/v1/expertise/me", headers=A, json={"topics": [f"{tag} roadm", "Coherent 800G", "  DWDM  "], "about": "Optical design"})
        await h.put(f"{ORCH}/v1/expertise/me", headers=B, json={"topics": [f"{tag} roadm integration", "IP/MPLS"]})
        me = (await h.get(f"{ORCH}/v1/expertise/me", headers=A)).json()
        check("1. Topics are published as the person typed them (tidied)", me["topics"] == ["coherent 800g", "dwdm", f"{tag} roadm"], me)
        r = (await h.get(f"{ORCH}/v1/expertise", headers=C, params={"q": f"{tag} roadm"})).json()
        check("2. Search ranks the exact match first", [x["user_id"] for x in r] == [a, b], [(x["user_id"], x["score"]) for x in r])
        await h.put(f"{ORCH}/v1/expertise/me", headers=A, json={"topics": []})
        r = (await h.get(f"{ORCH}/v1/expertise", headers=C, params={"q": f"{tag} roadm"})).json()
        check("3. Withdrawing removes the person from the map at once", [x["user_id"] for x in r] == [b], r)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/expertise_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())

"""Amer AI enclave proxy (docs/ENCRYPTED_AI.md).

Requests arrive encrypted to this process's own key, so the orchestrator in between relays ciphertext only and
never sees the text. This process decrypts, calls the model, and encrypts the answer to the requester's one-time
key. It writes no content anywhere: its log lines carry sizes, token counts and timing only.

Key and attestation: the X25519 key pair is made at start and kept in memory only. /attestation returns the public
key, the measurement (SHA-256 of this file, which the app pins) and the attestation type. On a confidential VM
(AMD SEV-SNP or Intel TDX) the type is the hardware report; on ordinary hardware it is "none", and the app then
uses this proxy only if the organisation allows an unattested proxy, labelled so.

Wire format (version 1):
  request:  {"v":1, "epk": b64(X25519 client one-time public key), "nonce": b64(12), "ct": b64(AES-256-GCM)}
            key = HKDF-SHA256(X25519(client_eph, enclave), salt = epk || enclave_pk, info = "amer-enclave-v1 request")
            plaintext = JSON {"prompt", "context", "system"}
  response: {"v":1, "nonce": b64(12), "ct": b64(...)} with key info = "amer-enclave-v1 response"
"""
import base64, hashlib, json, logging, os, pathlib, time
import httpx
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import serialization
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s enclave %(message)s")
log = logging.getLogger("enclave")
app = FastAPI(title="Amer AI enclave proxy")
_sk = X25519PrivateKey.generate()
PK = _sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
MEASUREMENT = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
ISSUED = int(time.time())
API_KEY = os.getenv("ANTHROPIC_API_KEY", ""); BASE = os.getenv("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
MODEL = os.getenv("LLM_MODEL", "claude-sonnet-4-5")
b64 = lambda b: base64.b64encode(b).decode(); unb64 = base64.b64decode

# the same redaction as Guardian (services/orchestrator/app/guardian.py): it must hold on this path too
import re
PII = [re.compile(p) for p in (r"\b\d{3}-\d{4}-\d{7}-\d\b", r"\b(?:\d[ -]?){13,19}\b", r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b")]
def redact(t: str) -> str:
    for p in PII: t = p.sub("[redacted]", t)
    return t

def derive(shared: bytes, epk: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=SHA256(), length=32, salt=epk + PK, info=info).derive(shared)

def attestation_type() -> str:
    return "sev-snp" if os.path.exists("/dev/sev-guest") else "tdx" if os.path.exists("/dev/tdx_guest") else "none"

@app.get("/attestation")
def attestation():
    return {"v": 1, "type": attestation_type(), "measurement": MEASUREMENT, "public_key": b64(PK), "issued_at": ISSUED,
            "report": None,           # the hardware report goes here on a confidential VM
            "note": "No confidential-computing hardware: this proxy is not hardware-attested." if attestation_type() == "none" else ""}

class Sealed(BaseModel):
    v: int = 1
    epk: str
    nonce: str
    ct: str

async def complete(system: str, prompt: str) -> tuple[str, dict]:
    if not API_KEY: return "The AI provider key is not set up on this server.", {}
    async with httpx.AsyncClient(timeout=60) as c:
        r = await c.post(f"{BASE}/v1/messages", headers={"x-api-key": API_KEY, "anthropic-version": "2023-06-01"},
                         json={"model": MODEL, "max_tokens": 1500, "system": system, "messages": [{"role": "user", "content": prompt}]})
    if r.status_code != 200: return f"The AI provider answered {r.status_code}.", {}
    j = r.json()
    return "".join(b.get("text", "") for b in j.get("content", [])), j.get("usage", {})

@app.post("/infer")
async def infer(req: Sealed):
    t0 = time.perf_counter()
    try:
        epk = unb64(req.epk)
        shared = _sk.exchange(X25519PublicKey.from_public_bytes(epk))
        body = json.loads(AESGCM(derive(shared, epk, b"amer-enclave-v1 request")).decrypt(unb64(req.nonce), unb64(req.ct), None))
    except Exception:
        raise HTTPException(400, "Could not decrypt the request")
    prompt = redact((f"Context:\n{body.get('context')}\n\n" if body.get("context") else "") + f"Request:\n{body.get('prompt', '')}")
    answer, usage = await complete(str(body.get("system") or "You are Amer, a helpful assistant. British English."), prompt)
    nonce = os.urandom(12)
    ct = AESGCM(derive(shared, epk, b"amer-enclave-v1 response")).encrypt(nonce, json.dumps({"answer": answer}).encode(), None)
    log.info("infer in=%dB out=%dB tokens=%s ms=%d", len(req.ct), len(ct), usage.get("output_tokens", 0) + usage.get("input_tokens", 0), (time.perf_counter() - t0) * 1000)
    return {"v": 1, "nonce": b64(nonce), "ct": b64(ct), "tokens": usage}

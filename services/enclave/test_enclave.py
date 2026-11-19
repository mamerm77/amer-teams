"""Enclave proxy: real X25519/HKDF/AES-GCM round trip; the orchestrator relays ciphertext only; no content in logs."""
import base64, json, logging, os
from fastapi.testclient import TestClient
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives import serialization
import enclave as E

def seal(att, body):
    pk = base64.b64decode(att["public_key"]); sk = X25519PrivateKey.generate()
    epk = sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    shared = sk.exchange(X25519PublicKey.from_public_bytes(pk))
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives.hashes import SHA256
    k = lambda info: HKDF(algorithm=SHA256(), length=32, salt=epk + pk, info=info).derive(shared)
    n = os.urandom(12)
    return {"v": 1, "epk": base64.b64encode(epk).decode(), "nonce": base64.b64encode(n).decode(),
            "ct": base64.b64encode(AESGCM(k(b"amer-enclave-v1 request")).encrypt(n, json.dumps(body).encode(), None)).decode()}, k

def test_round_trip_and_no_content_in_logs(monkeypatch, caplog):
    seen = {}
    async def fake(system, prompt): seen["prompt"] = prompt; return "Ciena is cheaper by 10%.", {"input_tokens": 12, "output_tokens": 7}
    monkeypatch.setattr(E, "complete", fake)
    c = TestClient(E.app); att = c.get("/attestation").json()
    assert att["type"] == "none" and len(att["measurement"]) == 64 and "not hardware-attested" in att["note"]
    req, k = seal(att, {"prompt": "Which vendor is cheaper?", "context": "Sara: Ciena quote is 10% lower"})
    assert b"Ciena" not in base64.b64decode(req["ct"])                     # what the orchestrator relays
    with caplog.at_level(logging.INFO, logger="enclave"):
        r = c.post("/infer", json=req).json()
    out = json.loads(AESGCM(k(b"amer-enclave-v1 response")).decrypt(base64.b64decode(r["nonce"]), base64.b64decode(r["ct"]), None))
    assert out["answer"] == "Ciena is cheaper by 10%." and "Ciena quote is 10% lower" in seen["prompt"]
    logs = " ".join(rec.getMessage() for rec in caplog.records)
    assert "Ciena" not in logs and "vendor" not in logs and "tokens=19" in logs           # sizes and counts only

def test_tampered_request_is_refused():
    c = TestClient(E.app); att = c.get("/attestation").json()
    req, _ = seal(att, {"prompt": "x"}); ct = bytearray(base64.b64decode(req["ct"])); ct[0] ^= 1
    assert c.post("/infer", json={**req, "ct": base64.b64encode(bytes(ct)).decode()}).status_code == 400

def test_guardian_redaction_applies(monkeypatch):
    seen = {}
    async def fake(system, prompt): seen["p"] = prompt; return "ok", {}
    monkeypatch.setattr(E, "complete", fake)
    c = TestClient(E.app); att = c.get("/attestation").json()
    req, _ = seal(att, {"prompt": "pay with 4111 1111 1111 1111"}); c.post("/infer", json=req)
    assert "4111" not in seen["p"] and "[redacted]" in seen["p"]

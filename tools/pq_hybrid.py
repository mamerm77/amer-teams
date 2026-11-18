"""Amer Teams post-quantum hybrid call keys — reference implementation (protocol amer-pq-hybrid-v1).

The media key for a call is derived from TWO independent secrets:
  K_c   32 random bytes, carried inside the Megolm-encrypted room event (classical: X25519/Curve25519 + AES-256)
  K_pq  32 random bytes, wrapped separately for every member device with ML-KEM-768 (FIPS 203)
  K     = HKDF-SHA256(salt = call_id, ikm = K_c || K_pq, info = "amer-call-key-v1|" + key_index, 32)
An attacker must break Megolm/Curve25519 AND ML-KEM-768 to obtain K ("hybrid", as in PQXDH / TLS X25519MLKEM768).

Per-device wrap (KEM-DEM):
  (ct, ss) = ML-KEM-768.Encaps(pk_device)
  okm      = HKDF-SHA256(salt = "amer-pq-wrap", ikm = ss, info = call_id|key_index|user_id|device_id, 64)
  w        = K_pq XOR okm[0:32]          (one-time pad: ss is fresh for every encapsulation)
  t        = HMAC-SHA256(okm[32:64], ct || w)   (tamper detection, checked before unwrap)

The Dart client (app/lib/services/pq_service.dart) implements the same steps; tests/pq_hybrid_test.py checks
both against shared test vectors (app/test/pq_vectors.json).
"""
import hashlib, hmac, os
from kyber_py.ml_kem import ML_KEM_768 as MLKEM

ALG = "amer-pq-hybrid-v1"

def hkdf(salt: bytes, ikm: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest(); out += t; i += 1
    return out[:length]

def keygen(seed: bytes | None = None):
    """Returns (pk, sk). seed = d||z (64 bytes) for deterministic test vectors."""
    if seed is None: return MLKEM.keygen()
    return MLKEM._keygen_internal(seed[:32], seed[32:64])

def _info(call_id, key_index, user_id, device_id):
    return f"{call_id}|{key_index}|{user_id}|{device_id}".encode()

def wrap(pk: bytes, k_pq: bytes, call_id: str, key_index: int, user_id: str, device_id: str, m: bytes | None = None):
    ss, ct = MLKEM._encaps_internal(pk, m) if m is not None else MLKEM.encaps(pk)
    okm = hkdf(b"amer-pq-wrap", ss, _info(call_id, key_index, user_id, device_id), 64)
    w = bytes(a ^ b for a, b in zip(k_pq, okm[:32]))
    t = hmac.new(okm[32:], ct + w, hashlib.sha256).digest()
    return {"ct": ct, "w": w, "t": t}

class TamperError(Exception): ...

def unwrap(sk: bytes, wrapped: dict, call_id: str, key_index: int, user_id: str, device_id: str) -> bytes:
    ss = MLKEM.decaps(sk, wrapped["ct"])
    okm = hkdf(b"amer-pq-wrap", ss, _info(call_id, key_index, user_id, device_id), 64)
    if not hmac.compare_digest(hmac.new(okm[32:], wrapped["ct"] + wrapped["w"], hashlib.sha256).digest(), wrapped["t"]):
        raise TamperError("PQ wrap failed authentication (wrong device, wrong call or tampered)")
    return bytes(a ^ b for a, b in zip(wrapped["w"], okm[:32]))

def call_key(k_c: bytes, k_pq: bytes, call_id: str, key_index: int) -> bytes:
    return hkdf(call_id.encode(), k_c + k_pq, f"amer-call-key-v1|{key_index}".encode(), 32)

def new_call_key_event(call_id, key_index, devices):
    """devices: list of (user_id, device_id, pk). Returns (event_content_with_bytes, K)."""
    k_c, k_pq = os.urandom(32), os.urandom(32)
    wraps = {f"{u}|{d}": wrap(pk, k_pq, call_id, key_index, u, d) for u, d, pk in devices}
    return {"call_id": call_id, "key_index": key_index, "alg": ALG, "kc": k_c, "wraps": wraps}, call_key(k_c, k_pq, call_id, key_index)

def open_call_key_event(ev, user_id, device_id, sk) -> bytes:
    w = ev["wraps"].get(f"{user_id}|{device_id}")
    if w is None: raise KeyError("No post-quantum wrap for this device")
    return call_key(ev["kc"], unwrap(sk, w, ev["call_id"], ev["key_index"], user_id, device_id), ev["call_id"], ev["key_index"])

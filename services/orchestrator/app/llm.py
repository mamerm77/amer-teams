import httpx
from . import config

class LLMError(Exception): ...

async def complete(system: str, user: str, max_tokens: int = 800) -> str:
    if not config.ANTHROPIC_API_KEY:
        raise LLMError("ANTHROPIC_API_KEY is not set on the server")
    async with httpx.AsyncClient(timeout=60) as c:
        r = await c.post(f"{config.LLM_BASE_URL}/v1/messages",
            headers={"x-api-key": config.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01"},
            json={"model": config.LLM_MODEL, "max_tokens": max_tokens, "system": system,
                  "messages": [{"role": "user", "content": user}]})
    if r.status_code != 200:
        raise LLMError(f"LLM error {r.status_code}: {r.text[:200]}")
    return "".join(b.get("text", "") for b in r.json()["content"])

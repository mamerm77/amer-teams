"""Guardian agent: policy gate applied before any content reaches the LLM or a tool."""
import re
from . import config

PII = [re.compile(p) for p in (r"\b\d{3}-\d{4}-\d{7}-\d\b",          # Emirates ID
                               r"\b(?:\d[ -]?){13,19}\b",             # card numbers
                               r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b")]  # IBAN

def check(text: str, labels: list[str] | None = None) -> tuple[bool, str]:
    for l in labels or []:
        if l.lower() in config.GUARDIAN_BLOCK_LABELS:
            return False, f"Blocked by policy: content labelled '{l}' cannot be sent to AI agents."
    return True, ""

def redact(text: str) -> str:
    for p in PII:
        text = p.sub("[redacted]", text)
    return text

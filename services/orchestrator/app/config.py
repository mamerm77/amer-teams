import os
SYNAPSE_URL = os.getenv("SYNAPSE_URL", "http://localhost:8008")
LIVEKIT_API_KEY = os.getenv("LIVEKIT_API_KEY", "devkey")
LIVEKIT_API_SECRET = os.getenv("LIVEKIT_API_SECRET", "devsecret-devsecret-devsecret-32")
LIVEKIT_PUBLIC_URL = os.getenv("LIVEKIT_PUBLIC_URL", "ws://localhost:7880")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
LLM_MODEL = os.getenv("LLM_MODEL", "claude-sonnet-4-5")
LLM_BASE_URL = os.getenv("LLM_BASE_URL", "https://api.anthropic.com")
GUARDIAN_BLOCK_LABELS = [s.strip().lower() for s in os.getenv("GUARDIAN_BLOCK_LABELS", "Confidential,Restricted").split(",") if s.strip()]
TOKEN_TTL_SECONDS = int(os.getenv("TOKEN_TTL_SECONDS", "3600"))
LIVEKIT_HTTP_URL = os.getenv("LIVEKIT_HTTP_URL", "http://livekit:7880")
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://amer:amer-pass@127.0.0.1:5432/amer")
SYNAPSE_ADMIN_TOKEN = os.getenv("SYNAPSE_ADMIN_TOKEN", "")
SERVER_NAME = os.getenv("SERVER_NAME", "amer.test")
ALERTMANAGER_URL = os.getenv("ALERTMANAGER_URL", "")

# Amer chat assistant (services/amer-bot): the bot authenticates to the orchestrator with this shared secret
AMER_BOT_SECRET = os.getenv("AMER_BOT_SECRET", "")
AMER_BOT_USER = os.getenv("AMER_BOT_USER", "amer")

FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends libolm-dev build-essential && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir "matrix-nio[e2e]==0.26.0" "httpx==0.28.1"
RUN useradd -r -u 10002 amer && mkdir -p /data/amer-bot && chown amer /data/amer-bot
USER amer
COPY bot.py /app/bot.py
ENV STORE_DIR=/data/amer-bot
CMD ["python", "-u", "/app/bot.py"]

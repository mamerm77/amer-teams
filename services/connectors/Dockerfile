FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends libolm-dev build-essential && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir "matrix-nio[e2e]" httpx fastapi uvicorn
WORKDIR /app
COPY formatters.py service.py ./
CMD ["python", "service.py"]

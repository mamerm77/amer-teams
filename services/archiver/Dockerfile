FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends libolm-dev build-essential && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir "matrix-nio[e2e]==0.26.0" "psycopg[binary]==3.3.9"
RUN useradd -r -u 10001 archiver && mkdir -p /data/archiver && chown archiver /data/archiver
USER archiver
COPY archiver.py /app/archiver.py
ENV STORE_DIR=/data/archiver
CMD ["python", "-u", "/app/archiver.py"]

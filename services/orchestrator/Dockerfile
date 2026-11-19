FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
COPY migrations ./migrations
# Agent Ops workspaces (agents write project files here; mount a volume)
RUN mkdir -p /data/agentops && chown 10001 /data/agentops
ENV AGENTOPS_DIR=/data/agentops HOME=/data/agentops
USER 10001
EXPOSE 8080
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8080","--proxy-headers"]

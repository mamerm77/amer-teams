#!/usr/bin/env bash
# Copies the server parts of the repo into installer/stage/server (used by CI and local builds).
set -e; cd "$(dirname "$0")"; rm -rf stage/server; mkdir -p stage/server
cp -r ../deploy stage/server/deploy; cp -r ../services stage/server/services; cp -r ../docs stage/server/docs
rm -rf stage/server/deploy/.env stage/server/deploy/synapse/homeserver.yaml stage/server/services/orchestrator/tests
find stage/server -name __pycache__ -prune -exec rm -rf {} +

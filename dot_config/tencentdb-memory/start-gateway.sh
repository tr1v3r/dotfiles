#!/bin/sh
set -eu
# Read only the two service-specific secrets, never the full DSH credential store.
TDAI_LLM_API_KEY=$(cat /run/secrets/deepseek_api_key)
TDAI_GATEWAY_API_KEY=$(cat /run/secrets/gateway_api_key)
: "${TDAI_LLM_API_KEY:?DeepSeek key is empty}"
: "${TDAI_GATEWAY_API_KEY:?Gateway token is empty}"
export TDAI_LLM_API_KEY TDAI_GATEWAY_API_KEY
umask 077
mkdir -p /opt/data/tdai-memory
exec node --import tsx/esm \
  /opt/tdai-gateway/node_modules/@tencentdb-agent-memory/memory-tencentdb/src/gateway/server.ts

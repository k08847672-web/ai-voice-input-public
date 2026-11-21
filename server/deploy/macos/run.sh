#!/bin/zsh
set -euo pipefail

umask 077
install_root="${VOICE_INPUT_INSTALL_ROOT:?VOICE_INPUT_INSTALL_ROOT is required}"
set -a
source "$install_root/adapter.env"
set +a

exec "$install_root/current/.venv/bin/uvicorn" voice_input_server.app:app \
  --app-dir "$install_root/current/src" \
  --host "${VOICE_INPUT_LISTEN_HOST:?VOICE_INPUT_LISTEN_HOST is required}" \
  --port "${VOICE_INPUT_LISTEN_PORT:-19001}" \
  --no-access-log

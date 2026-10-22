#!/usr/bin/env bash
# Deploys the Hangil backend and data to macserver.
#
#   usage: deploy.sh <oneload-backend checkout> <oneload-data checkout>
#
# Run by the self-hosted runner in the private oneload-backend repo, which checks out all three repos.
# Safe to run by hand on the server too.
#
#   ~/hangil-api        backend code + .venv            (from oneload-backend)
#   ~/hangil-data       maps/ and panos/                (from oneload-data)
#   ~/hangil-api.env    settings and secrets, generated from GitHub repository secrets; never edit by hand
#   ~/hangil-demo/      web client build (oneload-app) + Caddyfile, served on 127.0.0.1:4173
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

[[ $# -eq 2 ]] || { echo "usage: $0 <backend-dir> <data-dir>" >&2; exit 2; }
BACKEND_SRC="$(cd "$1" && pwd)"
DATA_SRC="$(cd "$2" && pwd)"
INFRA="$(cd "$(dirname "$0")" && pwd)"

APP="$HOME/hangil-api"
DATA="$HOME/hangil-data"
ENV_FILE="$HOME/hangil-api.env"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

rsync -a --delete --exclude .git --exclude .venv --exclude .env "$BACKEND_SRC/" "$APP/"

# Settings and secrets come only from GitHub repository secrets: the workflow maps each one to an APP_*
# variable, and every non-empty APP_* is written to $ENV_FILE without the prefix, replacing the old file.
# A manual run outside GitHub Actions keeps the current file.
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  (umask 077 && /usr/bin/python3 - "$ENV_FILE" <<'PY'
import json, os, sys
settings = {k.removeprefix("APP_"): v for k, v in os.environ.items() if k.startswith("APP_") and v}
with open(sys.argv[1], "w") as env_file:
    env_file.write("".join(f"{name}={json.dumps(value)}\n" for name, value in sorted(settings.items())))
PY
  )
  echo "Wrote $(grep -c . "$ENV_FILE" || true) setting(s) from repository secrets"
fi
touch "$ENV_FILE" && chmod 600 "$ENV_FILE"

cd "$APP"
docker compose -p hangil up -d --wait db
uv sync --frozen --no-dev

# Load the new maps with the new code before anything is switched over: a broken map stops here,
# while the running API keeps serving the previous data.
MAP_DIR="$DATA_SRC/maps" uv run --frozen --no-dev python -c \
  "from app.config import get_settings; from app.domain.mapdata import MapStore; \
print('maps OK:', [m.map_id + '@' + m.version for m in MapStore.load(get_settings().map_dir).all()])"
mkdir -p "$DATA"
rsync -a --delete --exclude .git "$DATA_SRC/maps" "$DATA_SRC/panos" "$DATA/"

uv run --frozen --no-dev --env-file "$ENV_FILE" alembic upgrade head

mkdir -p "$HOME/hangil-demo" "$AGENTS"
cp "$INFRA/Caddyfile" "$HOME/hangil-demo/Caddyfile"

stop_agent() {
  local label=$1
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || return 0
  # bootout returns before the job is gone, and bootstrapping it again too early fails with EIO.
  for _ in $(seq 40); do
    launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || return 0
    sleep 0.25
  done
}

start_agent() {
  local label=$1
  sed "s|__HOME__|$HOME|g" "$INFRA/launchd/$label.plist" > "$AGENTS/$label.plist"
  launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
}

stop_agent com.onetruck.hangil-api
start_agent com.onetruck.hangil-api

stop_agent com.onetruck.hangil-caddy
caddy stop >/dev/null 2>&1 || true # a Caddy started by hand (outside launchd) would keep the port
start_agent com.onetruck.hangil-caddy

for _ in $(seq 30); do
  if curl -fsS http://127.0.0.1:4173/api/v1/health; then
    echo && echo "Deployed backend $(git -C "$BACKEND_SRC" rev-parse --short HEAD 2>/dev/null || echo '?')," \
      "data $(git -C "$DATA_SRC" rev-parse --short HEAD 2>/dev/null || echo '?')"
    exit 0
  fi
  sleep 1
done
echo "API did not become healthy" >&2
tail -50 "$HOME/Library/Logs/hangil-api.log" >&2
exit 1

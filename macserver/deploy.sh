#!/usr/bin/env bash
# Deploys Hangil to macserver as the docker compose project "hangil" (db, api, caddy) plus Portainer:
# the server ends up running main of every repo.
#
#   usage: deploy.sh <oneload-backend> <oneload-data> <oneload-app> <oneload_agent>   (checkouts)
#
# Run by .github/workflows/deploy.yml in this repo, which oneload-backend, oneload-app and
# oneload_agent call on their own self-hosted runners. Safe to run by hand on the server too.
#
#   ~/hangil            compose.yaml, Caddyfile, web.Dockerfile   (from this repo)
#   ~/hangil-data       maps/ and panos/                          (from oneload-data, mounted read-only)
#   ~/hangil-api.env    settings and secrets, generated from GitHub repository secrets; never edit by hand
#   images              hangil-api (oneload-backend + oneload_agent), hangil-web (oneload-app + Caddy)
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

[[ $# -eq 4 ]] || { echo "usage: $0 <backend-dir> <data-dir> <web-dir> <agent-dir>" >&2; exit 2; }

# Three repos' runners can start a deploy; run one at a time on this machine.
if [[ -z "${HANGIL_DEPLOY_LOCKED:-}" ]]; then
  exec env HANGIL_DEPLOY_LOCKED=1 lockf -t 1800 "$HOME/.hangil-deploy.lock" "$0" "$@"
fi

export BACKEND_DIR="$(cd "$1" && pwd)"
DATA_SRC="$(cd "$2" && pwd)"
export WEB_DIR="$(cd "$3" && pwd)"
AGENT_SRC="$(cd "$4" && pwd)"
INFRA="$(cd "$(dirname "$0")" && pwd)"

PROJECT="$HOME/hangil"
DATA="$HOME/hangil-data"
ENV_FILE="$HOME/hangil-api.env"
compose() { docker compose --project-directory "$PROJECT" -f "$PROJECT/compose.yaml" "$@"; }
rev() { git -C "$1" rev-parse --short HEAD 2>/dev/null || echo '?'; }

# Settings and secrets come only from oneload-backend's repository secrets. When that repo deploys
# (HANGIL_WRITE_SETTINGS=true), every non-empty APP_* variable is written to $ENV_FILE without the
# prefix, replacing the old file. Deploys started from other repos and manual runs keep the file.
if [[ "${HANGIL_WRITE_SETTINGS:-}" == "true" ]]; then
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

# The API always runs oneload_agent's checked-out commit, whichever repo started the deploy. The pin
# is rewritten in this backend checkout only and never committed.
"$BACKEND_DIR/scripts/pin_agent.sh" "$(git -C "$AGENT_SRC" rev-parse HEAD)"

mkdir -p "$PROJECT" "$DATA"
cp "$INFRA/compose.yaml" "$INFRA/Caddyfile" "$INFRA/web.Dockerfile" "$PROJECT/"

compose build api caddy

# Load the new maps with the new image before anything is switched over: a broken map stops here,
# while the running API keeps serving the previous data.
compose run --rm --no-deps -v "$DATA_SRC/maps:/check:ro" -e MAP_DIR=/check api python -c \
  "from app.config import get_settings; from app.domain.mapdata import MapStore; \
print('maps OK:', [m.map_id + '@' + m.version for m in MapStore.load(get_settings().map_dir).all()])"
rsync -a --delete --exclude .git "$DATA_SRC/maps" "$DATA_SRC/panos" "$DATA/"

compose up -d --wait db
compose run --rm api alembic upgrade head
compose up -d --wait --remove-orphans
# The Caddyfile is a bind mount, so a changed file needs an explicit reload when caddy was not recreated.
compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

docker compose -f "$INFRA/portainer/compose.yaml" up -d
for image in hangil-api hangil-web; do
  docker image prune -f --filter "label=org.opencontainers.image.title=$image" >/dev/null
done

for _ in $(seq 30); do
  if curl -fsS http://127.0.0.1:4173/api/v1/health; then
    echo && echo "Deployed backend $(rev "$BACKEND_DIR"), agent $(rev "$AGENT_SRC"), data $(rev "$DATA_SRC")," \
      "web $(rev "$WEB_DIR")"
    exit 0
  fi
  sleep 1
done
echo "API did not become healthy" >&2
compose ps >&2
compose logs --tail 50 api >&2
exit 1

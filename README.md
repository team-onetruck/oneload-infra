# 한길 (Hangil) infra

How the Hangil demo runs on **macserver** (a team Mac on the tailnet) and how it gets deployed. No secrets live here; this repo is public.

Everything runs in Docker (Colima) as the compose project **`hangil`**, so the whole stack shows up in Portainer.

```mermaid
flowchart LR
    U["Browser"] -->|"https://baki-macbookpro.tail3286a4.ts.net:10000"| F["Tailscale Funnel :10000"]
    F --> C
    subgraph hangil["compose project: hangil"]
        C["caddy :4173"] -->|"/api/*"| A["api :8000"]
        A --> P[("db: Postgres 17 + pgvector")]
    end
    C -->|"/panos/*"| D["~/hangil-data/panos"]
    C -->|"everything else"| W["web build, inside the caddy image"]
    A -.->|"read-only"| M["~/hangil-data/maps"]
    T["Tailnet only :9443"] --> PT["Portainer"]
```

## Repositories

| Repo | Visibility | Holds |
| --- | --- | --- |
| [oneload-backend](https://github.com/team-onetruck/oneload-backend) | public | API code + `Dockerfile`, tests, CI |
| [oneload-data](https://github.com/team-onetruck/oneload-data) | public | maps and street-view photos |
| oneload-infra (this) | public | the shared deploy workflow, `macserver/compose.yaml`, Caddyfile, `web.Dockerfile`, `deploy.sh`, Portainer |
| [oneload-app](https://github.com/team-onetruck/oneload-app) | public | web client, built into the `hangil-web` image |
| [oneload_agent](https://github.com/team-onetruck/oneload_agent) | public | conversation and vision agent, installed into the `hangil-api` image |

## Deploying

There is one deploy, `.github/workflows/deploy.yml` in this repo (a reusable workflow). oneload-backend, oneload-app and oneload_agent call it from their CI after `main` passes, and it runs on **the caller's own self-hosted runner** on macserver (label `hangil`). It always deploys `main` of every repo, whichever one changed, by checking all of them out and running:

```sh
macserver/deploy.sh <backend-dir> <data-dir> <app-dir> <agent-dir>
```

In order, the script:

1. waits for any other deploy on the machine to finish (`lockf`), since three runners can start one;
2. writes `~/hangil-api.env` from repository secrets, only when oneload-backend started the deploy;
3. pins the backend checkout to the agent checkout's commit (`uv add`, never committed);
4. copies `compose.yaml`, `Caddyfile` and `web.Dockerfile` to `~/hangil`;
5. builds the `hangil-api` image (backend + agent) and the `hangil-web` image (app);
6. loads the new maps with the new image and stops if they are broken (the running API keeps its data);
7. syncs `maps/` and `panos/` to `~/hangil-data`, migrates the database, and runs `docker compose up -d --wait`;
8. reloads Caddy, makes sure Portainer is up, and prunes old images.

All containers use `restart: unless-stopped`, and Colima starts as a Homebrew service, so the stack comes back after a reboot.

| Change in | Deploys through |
| --- | --- |
| oneload-backend | its CI, on its runner `macserver-hangil` |
| oneload-app | its CI, on its runner `macserver-hangil-app` |
| oneload_agent | its CI, on its runner `macserver-hangil-agent` |
| oneload-data, this repo, a secret | no runner; by hand: `gh workflow run ci.yml -R team-onetruck/oneload-backend` |

**All team repos are public, and three of them have a runner on macserver.** The only guard is that fork PR workflows wait for a maintainer's approval: **never** approve a fork PR run that touches `.github/`.

## Looking at it

- **Portainer**: `https://baki-macbookpro.tail3286a4.ts.net:9443` (tailnet only). Containers → filter by stack `hangil` for status, logs, CPU and memory. Docker on this machine also runs the seoul-bike project.
- Shell: `cd ~/hangil && docker compose ps` / `docker compose logs -f api`.

Portainer asks for an admin account on the first visit and locks setup after 5 minutes; if that happens, `docker restart portainer-portainer-1` and open it again.

## Settings and secrets

GitHub repository secrets in oneload-backend. When oneload-backend deploys, `.github/workflows/deploy.yml` maps each one to an `APP_*` variable and `deploy.sh` writes them to `~/hangil-api.env` (mode 600, replaced), which the `api` service loads. Deploys started by the app or agent repos keep the file as it is. Add a setting with `gh secret set NAME -R team-onetruck/oneload-backend` plus the secret under `workflow_call.secrets` and one `APP_NAME: ${{ secrets.NAME }}` line in this repo's `deploy.yml`.

## Web client

Built from oneload-app's `main` on every deploy (`web.Dockerfile`: `pnpm install --frozen-lockfile`, `pnpm build`, result copied into a Caddy image). The server needs no Node, and the same image serves the build and proxies the API.

## Server setup notes

- Public: `tailscale funnel --bg --https=10000 http://127.0.0.1:4173`. Ports 443 and 8443 on this machine belong to another project.
- Portainer, tailnet only: `tailscale serve --bg --https=9443 http://127.0.0.1:9000`.
- Runners (label `hangil`, each installed with `./svc.sh install`): `macserver-hangil` for oneload-backend in `~/actions-runner-hangil`, `macserver-hangil-app` for oneload-app in `~/actions-runner-hangil-app`, `macserver-hangil-agent` for oneload_agent in `~/actions-runner-hangil-agent`. Every team repo requires maintainer approval before a fork PR's workflows run (Settings → Actions → "all outside contributors").
- Tools from Homebrew: `colima`, `docker`, `docker-compose`, `uv` (rewrites the agent pin during a deploy).

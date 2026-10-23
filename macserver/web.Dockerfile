# Web front door: builds an oneload-app checkout (build context "app", see compose.yaml) and serves
# the result with Caddy. Building here means the server needs no Node and every deploy is from source.
FROM node:22-alpine AS build
# Same pnpm as oneload-app's CI; the app's package.json does not pin one.
ARG PNPM_VERSION=11.13.0
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable && corepack install --global "pnpm@${PNPM_VERSION}"
WORKDIR /app
# Dependencies first, so a change that keeps the lockfile reuses the cached install.
COPY --from=app package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY --from=app . .
RUN pnpm build

FROM caddy:2-alpine
LABEL org.opencontainers.image.title=hangil-web
COPY --from=build /app/dist /srv/web

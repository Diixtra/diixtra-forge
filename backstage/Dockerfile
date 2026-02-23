# ── Stage 1: Build ────────────────────────────────────────────────
FROM node:22-bookworm-slim AS build

ENV PYTHON=/usr/bin/python3

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends python3 g++ build-essential && \
    rm -rf /var/lib/apt/lists/*

USER node
WORKDIR /app

# Copy yarn infrastructure first for better layer caching
COPY --chown=node:node .yarn ./.yarn
COPY --chown=node:node .yarnrc.yml yarn.lock package.json backstage.json ./
COPY --chown=node:node packages/backend/package.json packages/backend/package.json
COPY --chown=node:node packages/app/package.json packages/app/package.json

RUN --mount=type=cache,target=/home/node/.cache/yarn,sharing=locked,uid=1000,gid=1000 \
    yarn install --immutable

COPY --chown=node:node . .

RUN yarn tsc && yarn build:backend

# ── Stage 2: Install production deps (needs build tools for native modules) ──
FROM node:22-bookworm-slim AS deps

ENV PYTHON=/usr/bin/python3

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends python3 g++ build-essential && \
    rm -rf /var/lib/apt/lists/*

USER node
WORKDIR /app

COPY --from=build --chown=node:node /app/.yarn ./.yarn
COPY --from=build --chown=node:node /app/.yarnrc.yml /app/yarn.lock /app/package.json /app/backstage.json ./

ENV NODE_ENV=production

COPY --from=build --chown=node:node /app/packages/backend/dist/skeleton.tar.gz ./
RUN tar xzf skeleton.tar.gz && rm skeleton.tar.gz

RUN --mount=type=cache,target=/home/node/.cache/yarn,sharing=locked,uid=1000,gid=1000 \
    yarn workspaces focus --all --production

# ── Stage 3: Runtime (no build toolchain) ─────────────────────────
FROM node:22-bookworm-slim

USER node
WORKDIR /app

ENV NODE_ENV=production
ENV NODE_OPTIONS="--no-node-snapshot"

# Copy only node_modules with compiled native modules — no compilers
COPY --from=deps --chown=node:node /app/.yarn ./.yarn
COPY --from=deps --chown=node:node /app/.yarnrc.yml /app/yarn.lock /app/package.json /app/backstage.json ./
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --from=deps --chown=node:node /app/packages ./packages

# Copy backend bundle and config
COPY --from=build --chown=node:node /app/packages/backend/dist/bundle.tar.gz ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz

COPY --from=build --chown=node:node /app/app-config.yaml ./

EXPOSE 7007
CMD ["node", "packages/backend", "--config", "app-config.yaml"]

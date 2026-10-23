# Backend Dockerfile
# Multi-stage build for the SynapsVault Node.js/TypeScript backend
# (https://github.com/SynapsVault/backend). The build context is a checkout of
# that repository; this file lives in the deploy repo.
#
# Targets:
#   runtime (default)  API server: node dist/index.js on $PORT (3000)
#   migrate            One-shot Drizzle migrations (used as a k8s initContainer)

ARG NODE_VERSION=22
# Override when upstream peer dependency conflicts are resolved.
ARG NPM_FLAGS=--legacy-peer-deps

# ---------- Stage 1: All dependencies (build + migrate tooling) ----------
FROM node:${NODE_VERSION}-alpine AS deps
ARG NPM_FLAGS
WORKDIR /app

# Build tooling for any native modules
RUN apk add --no-cache python3 make g++

COPY package.json package-lock.json* ./
# Skip lifecycle scripts: the postinstall symlinks packages/registry-client,
# which is not copied yet. It is vendored explicitly below instead.
# `npm ci` needs a committed lockfile; fall back to `npm install` without one.
RUN if [ -f package-lock.json ]; then npm ci --ignore-scripts ${NPM_FLAGS} || npm ci --ignore-scripts --legacy-peer-deps; \
    else npm install --ignore-scripts --no-audit --no-fund ${NPM_FLAGS} || npm install --ignore-scripts --no-audit --no-fund --legacy-peer-deps; fi

# ---------- Stage 2: Production-only dependencies ----------
FROM node:${NODE_VERSION}-alpine AS prod-deps
ARG NPM_FLAGS
WORKDIR /app

RUN apk add --no-cache python3 make g++

COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev --ignore-scripts ${NPM_FLAGS} || npm ci --omit=dev --ignore-scripts --legacy-peer-deps; \
    else npm install --omit=dev --ignore-scripts --no-audit --no-fund ${NPM_FLAGS} || npm install --omit=dev --ignore-scripts --no-audit --no-fund --legacy-peer-deps; fi

COPY packages/registry-client ./packages/registry-client
RUN mkdir -p node_modules/@synapsvault && \
    cp -R packages/registry-client node_modules/@synapsvault/registry-client

# ---------- Stage 3: Build ----------
FROM node:${NODE_VERSION}-alpine AS build
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

RUN mkdir -p node_modules/@synapsvault && \
    rm -rf node_modules/@synapsvault/registry-client && \
    cp -R packages/registry-client node_modules/@synapsvault/registry-client

# The upstream build script tolerates type errors (`|| true`), so fail here if
# it did not actually produce the server entrypoint.
RUN npm run build && test -f dist/index.js

# ---------- Target: migrate ----------
# Slim image: only drizzle-kit, the drizzle config and the migrations are
# needed to run `drizzle-kit migrate`. Avoids shipping the full build stage
# (dev deps, sources, compilers) in the init container.
FROM node:${NODE_VERSION}-alpine AS migrate
ARG NPM_FLAGS
WORKDIR /app

ENV NODE_ENV=production

# Install drizzle-kit standalone (no app dependency tree required).
RUN npm install --no-audit --no-fund --ignore-scripts ${NPM_FLAGS} drizzle-kit

# Only the config and migrations are required at runtime.
COPY drizzle.config.ts ./drizzle.config.ts
COPY drizzle ./drizzle

USER node
CMD ["npx", "--no-install", "drizzle-kit", "migrate"]

# ---------- Target: runtime (default) ----------
FROM node:${NODE_VERSION}-alpine AS runtime
WORKDIR /app

# tini runs as PID 1 so it reaps zombies and forwards SIGTERM/SIGINT to Node,
# letting the server shut down gracefully during rollouts instead of being
# killed abruptly.
RUN apk add --no-cache tini

ENV NODE_ENV=production \
    PORT=3000

# Copy production dependencies and compiled output
COPY --from=prod-deps --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /app/package.json ./package.json

# Run as the unprivileged user that ships with the node image
USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -qO- "http://127.0.0.1:${PORT}/health" >/dev/null || exit 1

# tini as PID 1 forwards signals to node and reaps orphaned children.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/index.js"]

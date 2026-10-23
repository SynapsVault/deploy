# Multi-stage Dockerfile for the SynapsVault Vite frontend
# (https://github.com/SynapsVault/frontend). The build context is a checkout of
# that repository; this file lives in the deploy repo.

ARG NODE_VERSION=22
# Override when upstream peer dependency conflicts are resolved.
ARG NPM_FLAGS=--legacy-peer-deps

# Stage 1: Build the Vite application
FROM node:${NODE_VERSION}-alpine AS build
ARG NPM_FLAGS

WORKDIR /app

# Build-time configuration. Vite inlines VITE_* variables into the bundle, so
# they must be set here, not at container runtime. The default `/api` matches
# the Kubernetes ingress, which strips the prefix before forwarding to the
# backend.
ARG VITE_API_URL=/api
ARG VITE_NETWORK=testnet
ARG VITE_SENTRY_DSN=""
ENV VITE_API_URL=${VITE_API_URL} \
    VITE_NETWORK=${VITE_NETWORK} \
    VITE_SENTRY_DSN=${VITE_SENTRY_DSN}

# Install dependencies (leverage layer caching)
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci ${NPM_FLAGS} || npm ci --legacy-peer-deps; \
    else npm install --no-audit --no-fund ${NPM_FLAGS} || npm install --no-audit --no-fund --legacy-peer-deps; fi

# Copy source and build
COPY . .
RUN npm run build

# Stage 2: Serve static assets via nginx
FROM nginx:1.31-alpine AS runtime

# Serve the SPA on an unprivileged port; runtime config lives in writable /tmp.
RUN printf '%s\n' \
    'pid /tmp/nginx.pid;' \
    'events {}' \
    'http {' \
    '  include /etc/nginx/mime.types;' \
    '  client_body_temp_path /tmp/client_temp;' \
    '  proxy_temp_path /tmp/proxy_temp;' \
    '  fastcgi_temp_path /tmp/fastcgi_temp;' \
    '  uwsgi_temp_path /tmp/uwsgi_temp;' \
    '  scgi_temp_path /tmp/scgi_temp;' \
    '  server {' \
    '    listen 8080;' \
    '    root /usr/share/nginx/html;' \
    '    location = /config.js { alias /tmp/config.js; add_header Cache-Control "no-store"; }' \
    '    location / { try_files $uri $uri/ /index.html; }' \
    '  }' \
    '}' > /etc/nginx/nginx.conf \
    && apk add --no-cache jq

# Copy built assets from the build stage
COPY --from=build /app/dist /usr/share/nginx/html

# Runtime configuration. VITE_* values are baked in at build time, so staging
# and production would otherwise need separate images. Instead we generate
# /config.js at container start from env vars; the frontend reads
# window.__APP_CONFIG__ (see SynapsVault/frontend). Defaults mirror the
# build-time values above so an unconfigured container still works.
ENV APP_API_URL=/api \
    APP_NETWORK=testnet \
    APP_SENTRY_DSN=""

RUN printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'jq -n --arg apiUrl "$APP_API_URL" --arg network "$APP_NETWORK" --arg sentryDsn "$APP_SENTRY_DSN" "{apiUrl: \$apiUrl, network: \$network, sentryDsn: \$sentryDsn}" | sed "1s/^/window.__APP_CONFIG__ = /; \$s/\$/;/" > /tmp/config.js' \
    > /docker-entrypoint.d/40-generate-config.sh \
    && chmod +x /docker-entrypoint.d/40-generate-config.sh

USER 101
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/ >/dev/null || exit 1

CMD ["nginx", "-g", "daemon off;"]

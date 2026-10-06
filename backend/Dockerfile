# Backend Dockerfile
# Multi-stage build for the Node.js/TypeScript backend service.

# ---------- Stage 1: Dependencies ----------
FROM node:20-alpine AS deps
WORKDIR /app

# Install build tooling needed for native modules
RUN apk add --no-cache python3 make g++

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev && \
    cp -R node_modules /prod_node_modules && \
    npm ci

# ---------- Stage 2: Build ----------
FROM node:20-alpine AS build
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

RUN npm run build

# ---------- Stage 3: Runtime ----------
FROM node:20-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production \
    PORT=3000

# Install curl for the healthcheck
RUN apk add --no-cache curl

# Copy production dependencies and compiled output
COPY --from=deps /prod_node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/migrations ./migrations

# Create a non-root user and give it ownership of the app directory
RUN addgroup -g 1001 -S nodejs && \
    adduser -S -u 1001 -G nodejs nodejs && \
    chown -R nodejs:nodejs /app

USER nodejs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://localhost:3000/health || exit 1

# Run migrations, then start the compiled server
CMD ["sh", "-c", "npm run migrate && node dist/server.js"]
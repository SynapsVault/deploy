# Multi-stage Dockerfile for the Vite frontend
# Stage 1: Build the Vite application
FROM node:20-alpine AS build

WORKDIR /app

# Build-time argument for the backend API URL
ARG VITE_API_URL=/api
ENV VITE_API_URL=${VITE_API_URL}

# Install dependencies (leverage layer caching)
COPY package.json package-lock.json* ./
RUN npm ci || npm install

# Copy source and build
COPY . .
RUN npm run build

# Stage 2: Serve static assets via nginx
FROM nginx:1.27-alpine AS runtime

# Remove default nginx config
RUN rm -f /etc/nginx/conf.d/default.conf

# Custom nginx config (proxies /api to backend, SPA fallback)
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy built assets from the build stage
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
FROM node:20-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install

FROM node:20-bookworm-slim AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM node:20-bookworm-slim AS runtime
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends bash tmux curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production
COPY package.json ./
COPY --from=build /app/dist ./dist
COPY scripts ./scripts
RUN mkdir -p /state/spool /input
VOLUME ["/state", "/input"]
CMD ["node", "dist/src/main.js", "--daemon"]

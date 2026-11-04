# The application: the web app, the controller, and the evaluation suite. Build with
# `docker compose build`; see compose.yaml for the services it needs.

# Build stage: has the compiler that better-sqlite3 needs when no prebuilt binary matches.
# Base images are pinned by digest (same bytes for everyone); Dependabot proposes updates.
FROM node:24-bookworm-slim@sha256:c86ecead9e55a5210ac1727de38a4ca840bf03dcaf34dc9749addbf383b1920c AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# Manifests first, so dependencies are cached until a package.json or the lockfile changes.
COPY package.json package-lock.json ./
COPY apps/web/package.json apps/web/
COPY packages/controller/package.json packages/controller/
# The evaluation suite needs its dev tools (promptfoo, tsx), so dev dependencies are installed.
RUN npm ci --include=dev
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# Runtime stage: no compiler.
FROM node:24-bookworm-slim@sha256:c86ecead9e55a5210ac1727de38a4ca840bf03dcaf34dc9749addbf383b1920c
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    AGENTGATE_DATA_DIR=/data \
    AGENTGATE_REPO_ROOT=/app \
    AGENTGATE_SECRETS=env
COPY --from=build --chown=node:node /app /app
RUN mkdir /data && chown node:node /data
USER node
VOLUME /data
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/api/models/pull',{headers:{host:'localhost'}}).then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
# `next` directly: the workspace start script pins the host to 127.0.0.1, which a container cannot use.
WORKDIR /app/apps/web
CMD ["/app/node_modules/.bin/next", "start", "--hostname", "0.0.0.0", "--port", "3000"]

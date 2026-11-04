# The application image holds only what the server needs at runtime. The evaluation suite is a
# separate `evals` target, built only when it is asked for (CI, or `docker compose --profile evals`).
# Build with `docker compose build`; see compose.yaml for the services it needs.

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
# Building needs the dev tools (TypeScript, Tailwind); none of them reach the application image.
RUN npm ci --include=dev
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1 \
    AGENTGATE_STANDALONE=1
RUN npm run build \
 # Turbopack links native modules with absolute symlinks into this stage's node_modules, which
 # the application image does not have: copy the server with links resolved.
 && cp -rL apps/web/.next/standalone /standalone \
 && cp -r apps/web/.next/static /standalone/apps/web/.next/static

# Evaluation suite: Promptfoo and the real pipeline against the scanner. Not part of the app.
FROM build AS evals
ENV AGENTGATE_REPO_ROOT=/app
CMD ["npm", "run", "eval"]

# Application: the standalone server and its traced dependencies only. No compiler, no dev tools,
# no evaluation suite.
FROM node:24-bookworm-slim@sha256:c86ecead9e55a5210ac1727de38a4ca840bf03dcaf34dc9749addbf383b1920c
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    AGENTGATE_DATA_DIR=/data \
    AGENTGATE_SECRETS=env \
    HOSTNAME=0.0.0.0 \
    PORT=3000
COPY --from=build --chown=node:node /standalone /app
RUN mkdir /data && chown node:node /data
USER node
VOLUME /data
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/api/models/pull',{headers:{host:'localhost'}}).then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
WORKDIR /app/apps/web
CMD ["node", "server.js"]

# =============================================================================
# Multi-stage build: node:22-alpine to install dependencies, distroless to run.
#
# WHY DISTROLESS:
#   - No shell, no package manager, no busybox. A container escape has almost no
#     tooling to pivot with, and Trivy has far less to find in the base layer.
#   - Ships a 'nonroot' user at UID 65532, which is exactly what the pod security
#     context in charts/banking-application/values.yaml expects. If those two
#     numbers disagree the container fails to start with a permission error on
#     /tmp — a genuinely annoying failure to debug, so they are pinned together
#     deliberately.
# =============================================================================

# --- build stage -------------------------------------------------------------
FROM node:22-alpine AS build
WORKDIR /app

# Copy manifests first so the dependency layer caches independently of source.
COPY package*.json ./

# npm ci is preferred: it installs exactly the locked versions and fails if the
# lockfile and package.json disagree — which is what you want in CI.
# The fallback exists only so a fresh clone without a committed package-lock.json
# still builds. Commit the lockfile and the fallback never fires.
RUN npm ci --omit=dev --no-audit --no-fund \
 || npm install --omit=dev --no-audit --no-fund

COPY src ./src

# --- runtime stage -----------------------------------------------------------
FROM gcr.io/distroless/nodejs22-debian12:nonroot
WORKDIR /app

COPY --from=build --chown=65532:65532 /app/node_modules ./node_modules
COPY --from=build --chown=65532:65532 /app/src ./src
COPY --from=build --chown=65532:65532 /app/package.json ./package.json

# MUST match podSecurityContext runAsUser/runAsGroup/fsGroup in values.yaml.
USER 65532:65532

ENV NODE_ENV=production
EXPOSE 8080

# The distroless nodejs image already has `node` as its entrypoint, so CMD is
# just the script path.
CMD ["src/server.js"]

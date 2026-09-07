// =============================================================================
// Banking API — GET /api/shows
//
// Retrieves show data from the external TVMaze API, caches the response in Azure
// Blob Storage, and serves the cached copy while it is fresh.
//
// The assessment says the application logic is intentionally simple, so this is
// deliberately kept to one readable file. The interesting decisions are the
// PLATFORM ones, and they are commented inline below:
//
//   * NO SECRETS. Authentication to Blob Storage is Microsoft Entra Workload ID.
//     There is no storage key, no connection string and no client secret in this
//     container, in the Helm chart, or in the pipeline.
//   * LIVENESS never touches a dependency; READINESS does. See the probe
//     handlers at the bottom for why that distinction matters.
//   * A cache WRITE failure must never fail the user's request.
//   * All configuration arrives as environment variables from the Helm ConfigMap
//     (charts/banking-application/templates/configmap.yaml). Nothing is hardcoded.
// =============================================================================

import express from "express";
import { DefaultAzureCredential } from "@azure/identity";
import { BlobServiceClient } from "@azure/storage-blob";

// -----------------------------------------------------------------------------
// Configuration — every value comes from the ConfigMap, with safe local defaults
// -----------------------------------------------------------------------------
const {
  PORT = "8080",
  LOG_LEVEL = "info",
  APP_ENVIRONMENT = "local",
  STORAGE_ACCOUNT_NAME = "",
  CACHE_CONTAINER = "shows-cache",
  CACHE_TTL_SECONDS = "3600",
  TVMAZE_BASE_URL = "https://api.tvmaze.com",
  UPSTREAM_TIMEOUT_MS = "5000",
  POD_NAME = "local",
  NODE_NAME = "local",
  APPLICATIONINSIGHTS_CONNECTION_STRING = "",
} = process.env;

const CACHE_BLOB = "shows.json";
const TTL_SECONDS = Number(CACHE_TTL_SECONDS);
const TIMEOUT_MS = Number(UPSTREAM_TIMEOUT_MS);

// -----------------------------------------------------------------------------
// Structured logging
//
// One JSON object per line to stdout. Container Insights ingests stdout, and JSON
// means the fields are queryable in KQL directly rather than through brittle
// regex parsing. See docs/07-observability.md.
// -----------------------------------------------------------------------------
const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const threshold = LEVELS[LOG_LEVEL] ?? LEVELS.info;

function log(level, msg, extra = {}) {
  if ((LEVELS[level] ?? LEVELS.info) < threshold) return;
  process.stdout.write(
    JSON.stringify({
      ts: new Date().toISOString(),
      level,
      msg,
      env: APP_ENVIRONMENT,
      pod: POD_NAME,
      node: NODE_NAME,
      ...extra,
    }) + "\n",
  );
}

// -----------------------------------------------------------------------------
// Application Insights (optional)
//
// Started only when a connection string is present, and failures are swallowed:
// telemetry must never prevent the API from serving.
//
// setUseDiskRetryCaching(false) matters here — the SDK otherwise buffers failed
// telemetry to disk, which cannot work with readOnlyRootFilesystem: true in the
// pod security context.
//
// NOTE: the workspace has local_authentication_enabled = false, so the ingestion
// key inside this connection string is inert and the value is not really a
// secret. See docs/02-code-review-findings.md P2-3.
// -----------------------------------------------------------------------------
if (APPLICATIONINSIGHTS_CONNECTION_STRING) {
  try {
    const appInsights = await import("applicationinsights");
    appInsights.default
      .setup(APPLICATIONINSIGHTS_CONNECTION_STRING)
      .setUseDiskRetryCaching(false)
      .setSendLiveMetrics(false)
      .start();
    log("info", "application insights started");
  } catch (err) {
    log("warn", "application insights failed to start; continuing", { err: err.message });
  }
}

// -----------------------------------------------------------------------------
// Azure Blob Storage client — Workload Identity, no keys
//
// DefaultAzureCredential picks up the four environment variables that the AKS
// azure-wi-webhook injects into this pod: AZURE_CLIENT_ID, AZURE_TENANT_ID,
// AZURE_AUTHORITY_HOST and AZURE_FEDERATED_TOKEN_FILE. It reads the projected
// ServiceAccount token, presents it to Entra as a client assertion, and receives
// an access token scoped to storage.azure.net.
//
// Why DefaultAzureCredential rather than WorkloadIdentityCredential: it also
// works unchanged with `az login` locally and in CI. The trade-off is that it
// walks a credential chain, so a misconfiguration fails slowly and confusingly.
// In production, naming WorkloadIdentityCredential explicitly fails faster and
// louder — a reasonable change once local development no longer matters.
//
// The FQDN below resolves to a PRIVATE IP: Azure public DNS returns a CNAME to
// <account>.privatelink.blob.core.windows.net, and the private DNS zone linked
// to this VNet answers with the private endpoint's address. The app never has to
// know Private Link exists, and TLS still validates against the public name.
// -----------------------------------------------------------------------------
let container = null;
let blob = null;

if (STORAGE_ACCOUNT_NAME) {
  const credential = new DefaultAzureCredential();
  container = new BlobServiceClient(
    `https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net`,
    credential,
  ).getContainerClient(CACHE_CONTAINER);
  blob = container.getBlockBlobClient(CACHE_BLOB);
  log("info", "storage client configured", {
    account: STORAGE_ACCOUNT_NAME,
    container: CACHE_CONTAINER,
    ttlSeconds: TTL_SECONDS,
  });
} else {
  log("warn", "STORAGE_ACCOUNT_NAME is not set — caching disabled");
}

// -----------------------------------------------------------------------------
// Cache read
//
// Freshness is derived from the blob's own lastModified timestamp rather than a
// metadata field. That avoids an extra write and any clock-skew argument between
// the app and storage. The cost is coarseness: there is no per-entry TTL.
// -----------------------------------------------------------------------------
async function readCache() {
  if (!blob) return null;
  try {
    const props = await blob.getProperties();
    const ageSeconds = (Date.now() - props.lastModified.getTime()) / 1000;
    if (ageSeconds > TTL_SECONDS) {
      log("debug", "cache stale", { ageSeconds: Math.round(ageSeconds) });
      return null;
    }
    const buf = await blob.downloadToBuffer();
    return { shows: JSON.parse(buf.toString()), ageSeconds: Math.round(ageSeconds) };
  } catch (err) {
    // 404 is a cold cache, which is normal. Anything else — notably a 403
    // AuthorizationPermissionMismatch, meaning the managed identity is missing
    // its Storage Blob Data Contributor role assignment — must surface.
    if (err.statusCode === 404) {
      log("debug", "cache miss (cold)");
      return null;
    }
    throw err;
  }
}

// -----------------------------------------------------------------------------
// Cache write — asynchronous and deliberately non-fatal
//
// A Storage blip degrades caching; it must not fail the user's request. The
// consequence is that a persistent write failure is invisible from the outside,
// which is exactly why docs/07-observability.md alerts on cache write failures.
// -----------------------------------------------------------------------------
function writeCache(shows) {
  if (!blob) return;
  const body = JSON.stringify(shows);
  blob
    .upload(body, Buffer.byteLength(body), {
      blobHTTPHeaders: { blobContentType: "application/json" },
    })
    .then(() => log("debug", "cache written", { count: shows.length }))
    .catch((err) =>
      log("error", "cache write failed", { err: err.message, code: err.statusCode }),
    );
}

// -----------------------------------------------------------------------------
// Upstream fetch
//
// This is the only call that leaves the private network. It egresses via the
// node subnet's UDR to Azure Firewall in the hub, which allows exactly this one
// FQDN and denies (and logs) everything else.
//
// The AbortController timeout matters: a hung upstream must not exhaust the
// connection pool and turn a slow dependency into a total outage.
// -----------------------------------------------------------------------------
async function fetchUpstream() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${TVMAZE_BASE_URL}/shows?page=0`, {
      signal: controller.signal,
      headers: { accept: "application/json" },
    });
    if (!res.ok) throw new Error(`TVMaze responded ${res.status}`);
    const raw = await res.json();

    // Trim to the fields consumers need. The full payload is several megabytes;
    // caching a summary keeps blob size, transfer cost and response time sane.
    return raw.map((s) => ({
      id: s.id,
      name: s.name,
      language: s.language,
      genres: s.genres,
      status: s.status,
      premiered: s.premiered,
      rating: s.rating?.average ?? null,
      url: s.url,
    }));
  } finally {
    clearTimeout(timer);
  }
}

// -----------------------------------------------------------------------------
// Routes
// -----------------------------------------------------------------------------
const app = express();
app.disable("x-powered-by");

app.get("/api/shows", async (req, res) => {
  const started = Date.now();
  try {
    const cached = await readCache();
    if (cached) {
      log("info", "served from cache", { count: cached.shows.length, ms: Date.now() - started });
      return res
        .set("X-Cache", "HIT")
        .json({ count: cached.shows.length, source: "cache", shows: cached.shows });
    }

    const shows = await fetchUpstream();
    writeCache(shows); // fire and forget — see writeCache()
    log("info", "served from upstream", { count: shows.length, ms: Date.now() - started });
    return res
      .set("X-Cache", "MISS")
      .json({ count: shows.length, source: "upstream", shows });
  } catch (err) {
    log("error", "/api/shows failed", { err: err.message, code: err.statusCode });
    return res.status(502).json({ error: "upstream_unavailable" });
  }
});

// LIVENESS — "should Kubernetes restart this process?"
//
// Deliberately touches NO dependency. If Blob Storage or TVMaze is down, this
// process is still perfectly healthy; restarting it would achieve nothing and
// would turn a downstream blip into a cluster-wide crashloop. Putting a
// dependency check in a liveness probe is the classic Kubernetes mistake.
app.get("/healthz", (_req, res) => res.json({ status: "alive" }));

// READINESS — "should this pod receive traffic?"
//
// This one DOES check the Azure dependency, so a pod whose Workload Identity is
// broken (wrong federated credential subject, or a missing role assignment) is
// removed from the Service endpoints instead of serving errors to users.
//
// Trade-off: a global Storage outage takes every pod NotReady simultaneously and
// the Service ends up with no endpoints. The mitigations are a tolerant
// failureThreshold (set in values.yaml) and, as a future improvement, allowing a
// "degraded but serving stale cache" state to still report ready.
app.get("/readyz", async (_req, res) => {
  if (!container) {
    return res.status(503).json({ status: "not-ready", dependencies: { blob: "unconfigured" } });
  }
  try {
    await container.exists();
    return res.json({ status: "ready", dependencies: { blob: "ok" } });
  } catch (err) {
    log("warn", "readiness check failed", { err: err.message, code: err.statusCode });
    return res
      .status(503)
      .json({ status: "not-ready", dependencies: { blob: err.code || "error" } });
  }
});

// -----------------------------------------------------------------------------
// Start and shut down cleanly
//
// On SIGTERM, stop accepting new connections and let in-flight requests finish
// within terminationGracePeriodSeconds (30s in the chart). Without this, a
// rolling update drops requests that were already being served.
// -----------------------------------------------------------------------------
const server = app.listen(Number(PORT), () =>
  log("info", `listening on ${PORT}`, { logLevel: LOG_LEVEL }),
);

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    log("info", `${signal} received — draining`);
    server.close(() => {
      log("info", "shutdown complete");
      process.exit(0);
    });
    // Backstop: never hang past the grace period.
    setTimeout(() => process.exit(0), 25_000).unref();
  });
}

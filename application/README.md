# Banking API — `GET /api/shows`

A deliberately small Node.js service. It fetches show data from the external TVMaze API, caches the
response in Azure Blob Storage, and serves the cached copy while it is fresh.

The assessment states the application logic is intentionally simple and that effort belongs on platform
engineering — so this is one readable file. The decisions worth discussing are the platform ones, and
they are commented inline in [`src/server.js`](src/server.js).

## Endpoints

| Endpoint | Purpose | Response |
|---|---|---|
| `GET /api/shows` | The API. Serves from cache when fresh, otherwise fetches upstream and caches | `{"count":N,"source":"cache\|upstream","shows":[...]}` plus an `X-Cache: HIT\|MISS` header |
| `GET /healthz` | **Liveness.** Touches no dependency | `{"status":"alive"}` |
| `GET /readyz` | **Readiness.** Probes Blob Storage | `{"status":"ready","dependencies":{"blob":"ok"}}` or 503 |

### Why liveness and readiness differ

Liveness answers *"should Kubernetes restart this process?"*; readiness answers *"should this pod receive
traffic?"* A dependency failure is never a reason to restart — it is a reason to stop routing. Putting a
Blob Storage check in the liveness probe would turn a downstream blip into a cluster-wide crashloop.

So `/healthz` deliberately checks nothing, and `/readyz` deliberately checks Storage: a pod whose Workload
Identity is broken leaves the Service endpoint list instead of serving errors.

## Configuration

Everything arrives as environment variables from the Helm ConfigMap
([`charts/banking-application/templates/configmap.yaml`](../charts/banking-application/templates/configmap.yaml)).
Nothing is hardcoded and **nothing here is a secret**.

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | Must match `service.targetPort` in the chart |
| `LOG_LEVEL` | `info` | `debug` in non-prod, `info` in prod |
| `APP_ENVIRONMENT` | `local` | Included in every log line |
| `STORAGE_ACCOUNT_NAME` | *(empty)* | From the Terraform output `storage_account_name` |
| `CACHE_CONTAINER` | `shows-cache` | From the Terraform output `cache_container_name` |
| `CACHE_TTL_SECONDS` | `3600` | 60 in non-prod so cache behaviour is observable while testing |
| `TVMAZE_BASE_URL` | `https://api.tvmaze.com` | Must match the Azure Firewall application rule |
| `UPSTREAM_TIMEOUT_MS` | `5000` | A hung upstream must not exhaust the connection pool |
| `POD_NAME` / `NODE_NAME` | `local` | Injected via the downward API; used for log correlation |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | *(empty)* | Optional. Telemetry is skipped entirely if unset |

## Authentication — no secrets anywhere

The service authenticates to Blob Storage with **Microsoft Entra Workload ID**. There is no storage key,
no connection string and no client secret in this container, the Helm chart, or the pipeline.

At admission time the AKS `azure-wi-webhook` injects `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_AUTHORITY_HOST` and `AZURE_FEDERATED_TOKEN_FILE`, plus a projected ServiceAccount token.
`DefaultAzureCredential` reads that token, presents it to Entra as a client assertion, and receives an
access token scoped to `storage.azure.net`. The token lives about an hour and the kubelet rotates it.

Full walkthrough: [docs/01-architecture.md §5](../docs/01-architecture.md#5-identity-and-token-flow--workload-identity-end-to-end).

> **Authentication is not authorisation.** Federation gets the pod a valid token; it still needs the
> `Storage Blob Data Contributor` role assignment to actually read and write blobs. Without it you get
> `403 AuthorizationPermissionMismatch` — which is exactly Troubleshooting Scenario 1, and exactly the
> defect currently open as [P0-5](../docs/02-code-review-findings.md).

## Caching behaviour

- **Freshness** is derived from the blob's own `lastModified` timestamp rather than a metadata field — no
  extra write, and no clock-skew argument between the app and storage. The cost is coarseness: no
  per-entry TTL.
- **Writes are asynchronous and non-fatal.** A Storage blip degrades caching, it does not fail the API.
  The consequence is that a persistent write failure is invisible from outside, which is why cache write
  failures are on the alert list in [docs/07-observability.md](../docs/07-observability.md).
- **The payload is trimmed** to the fields consumers need. The raw TVMaze response is several megabytes;
  caching a summary keeps blob size, transfer cost and response time sane.
- **Two concurrent misses** both fetch and both write — last writer wins. Acceptable for idempotent,
  read-only public data.

## Local development

```bash
cd application
npm install          # generates package-lock.json — COMMIT IT (see below)
az login             # DefaultAzureCredential falls back to your az session

export STORAGE_ACCOUNT_NAME=<account>   # or omit to run with caching disabled
export CACHE_CONTAINER=shows-cache
export LOG_LEVEL=debug
npm start

curl -i localhost:8080/api/shows | head -20
curl -s localhost:8080/readyz
```

Running without `STORAGE_ACCOUNT_NAME` starts the service with caching disabled — `/api/shows` always
goes upstream and `/readyz` reports not-ready. Useful for testing the HTTP layer with no Azure access.

## Container image

```bash
docker build -t banking-application:local .
docker run --rm -p 8080:8080 -e STORAGE_ACCOUNT_NAME= banking-application:local
```

Two-stage build: `node:22-alpine` installs dependencies, `gcr.io/distroless/nodejs22-debian12:nonroot`
runs them. Distroless has no shell and no package manager, so a container escape has almost no tooling to
pivot with and Trivy has far less to find in the base layer.

**`USER 65532:65532` must match `podSecurityContext` in the chart's `values.yaml`.** If those two numbers
disagree the container fails to start with a permission error on `/tmp`.

## ⚠️ Commit the lockfile

`package-lock.json` is **not** in this commit, because generating a real one requires running `npm install`
against the registry — which I could not do here.

Run `npm install` once and commit the result. Until you do:

- `npm ci` in the pipeline's Validate and Security stages falls back to `npm install` (the pipeline already
  has `|| npm install` for this), so it still runs — but dependency versions are not reproducible.
- The Dockerfile has the same fallback, so the image still builds.
- **`npm audit` results and Trivy dependency findings will not be reproducible run to run**, which
  undermines the security gate. In a bank, an uncommitted lockfile is itself a finding.

## What is deliberately not here

Named as decisions rather than omissions:

| Not implemented | Why | When I'd add it |
|---|---|---|
| Unit tests | The pipeline's Validate stage runs lint only; the real gate is `scripts/smoke-test.sh` against a live deployment | Immediately, for anything with real business logic |
| Stale-while-revalidate | A cache miss during a TVMaze outage currently returns 502 | High priority — it converts an availability incident into a freshness one |
| Circuit breaker on TVMaze | The timeout covers the common case | When upstream reliability becomes a real problem |
| Distributed tracing (OpenTelemetry) | App Insights auto-collection covers the basics | To attribute latency to Blob vs TVMaze vs the app itself |
| `WorkloadIdentityCredential` explicitly | `DefaultAzureCredential` also works locally and in CI | In production — it fails faster and more clearly than walking the chain |

## Related documentation

- [docs/01-architecture.md](../docs/01-architecture.md) — request flow, DNS path, egress, identity
- [docs/03-design-decisions-and-tradeoffs.md §Q](../docs/03-design-decisions-and-tradeoffs.md) — application-level trade-offs
- [docs/05-troubleshooting-runbook.md](../docs/05-troubleshooting-runbook.md) — the 403, DNS and unhealthy-pod scenarios
- [scripts/smoke-test.sh](../scripts/smoke-test.sh) — the contract this service must satisfy

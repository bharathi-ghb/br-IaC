#!/usr/bin/env bash
# =============================================================================
# Smoke test - GET /api/shows and Azure integrations behind it
# =============================================================================
set -euo pipefail

NAMESPACE="${1:?namespace required}"
RELEASE="${2:?release name required}"
STORAGE_ACCOUNT="${3:-}"
CONTAINER="${4:-shows-cache}"

CURL_IMAGE="${CURL_IMAGE:-mcr.microsoft.com/azurelinux/base/core:3.0}"
TIMEOUT="${TIMEOUT:-300s}"

SERVICE="${RELEASE}"
BASE_URL="http://${SERVICE}.${NAMESPACE}.svc.cluster.local"

pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
info() { printf '\n== %s\n' "$1"; }

in_cluster() {
  kubectl run "smoke-$RANDOM" \
    --namespace "$NAMESPACE" \
    --image="$CURL_IMAGE" \
    --restart=Never \
    --rm -i \
    --quiet \
    --command -- "$@" 2>/dev/null
}

# -----------------------------------------------------------------------------
info "1/5 Waiting for the deployment to become available"
# -----------------------------------------------------------------------------
if kubectl -n "$NAMESPACE" rollout status "deployment/${RELEASE}" --timeout="$TIMEOUT"; then
  pass "rollout completed and pods are Ready"
else
  echo "--- pod state ---"    >&2
  kubectl -n "$NAMESPACE" get pods -o wide >&2
  echo "--- recent events ---" >&2
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -30 >&2
  fail "rollout did not complete - see pod events above"
fi

# -----------------------------------------------------------------------------
info "2/5 GET /api/shows (expect a populated response)"
# -----------------------------------------------------------------------------
RESPONSE="$(in_cluster curl -sS --max-time 30 -w '\nHTTP_STATUS:%{http_code}' "${BASE_URL}/api/shows" || true)"
STATUS="$(printf '%s' "$RESPONSE" | sed -n 's/.*HTTP_STATUS:\([0-9]*\)/\1/p')"
BODY="$(printf '%s' "$RESPONSE" | sed 's/HTTP_STATUS:[0-9]*//')"

[[ "$STATUS" == "200" ]] || fail "expected HTTP 200 from /api/shows, got '${STATUS:-no response}'"
pass "HTTP 200"

COUNT="$(printf '%s' "$BODY" | grep -o '"count":[0-9]*' | head -1 | cut -d: -f2 || echo 0)"
[[ "${COUNT:-0}" -gt 0 ]] || fail "response contained no shows (count=${COUNT:-0})"
pass "response contains ${COUNT} shows"

SOURCE="$(printf '%s' "$BODY" | grep -o '"source":"[a-z]*"' | head -1 | cut -d'"' -f4 || echo unknown)"
pass "served from: ${SOURCE}"

# -----------------------------------------------------------------------------
info "3/5 Second call should be served from the Blob Storage cache"
# -----------------------------------------------------------------------------
sleep 3
CACHE_HEADER="$(in_cluster curl -sS --max-time 30 -o /dev/null -D - "${BASE_URL}/api/shows" | grep -i '^x-cache:' | tr -d '\r' || true)"

if printf '%s' "$CACHE_HEADER" | grep -qi 'HIT'; then
  pass "X-Cache: HIT - Blob Storage read/write via Workload Identity confirmed"
else
  echo "  [WARN] expected a cache HIT, got '${CACHE_HEADER:-no header}'." >&2
  echo "         Check CACHE_TTL_SECONDS and the storage RBAC assignment." >&2
fi

# -----------------------------------------------------------------------------
info "4/5 Confirming the cached blob exists (control-plane check)"
# -----------------------------------------------------------------------------
if [[ -n "$STORAGE_ACCOUNT" ]]; then
  if az storage blob list \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$CONTAINER" \
        --auth-mode login \
        --query "[].name" -o tsv 2>/dev/null | grep -q .; then
    pass "cache container '${CONTAINER}' contains at least one blob"
  else
    echo "  [WARN] no blobs listed in '${CONTAINER}'." >&2
    echo "         Either the agent lacks Storage Blob Data Reader, or it has no" >&2
    echo "         network line of sight to the private endpoint." >&2
  fi
else
  echo "  [SKIP] no storage account supplied"
fi

# -----------------------------------------------------------------------------
info "5/5 Readiness endpoint dependency report"
# -----------------------------------------------------------------------------
READY_BODY="$(in_cluster curl -sS --max-time 15 "${BASE_URL}/readyz" || true)"
if printf '%s' "$READY_BODY" | grep -q '"status":"ready"'; then
  pass "application reports all dependencies healthy"
  printf '  %s\n' "$READY_BODY"
else
  fail "readiness endpoint did not report ready: ${READY_BODY:-no response}"
fi

printf '\nSmoke tests passed for release %s in namespace %s.\n' "$RELEASE" "$NAMESPACE"

# =============================================================================
# Helm rollback
# =============================================================================
set -euo pipefail

NAMESPACE="${1:?namespace required}"
RELEASE="${2:?release name required}"
REVISION="${3:-0}" # 0 means "previous revision" to helm

echo "== Release history before rollback"
helm history "$RELEASE" --namespace "$NAMESPACE" --max 10

echo
echo "== Rolling back ${RELEASE} to revision ${REVISION:-previous}"
helm rollback "$RELEASE" "$REVISION" \
  --namespace "$NAMESPACE" \
  --wait \
  --timeout 5m \
  --cleanup-on-fail

echo
echo "== Release history after rollback"
helm history "$RELEASE" --namespace "$NAMESPACE" --max 10

echo
echo "== Pod state"
kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=${RELEASE}" -o wide

echo
echo "Rollback complete. Confirm service health before closing the incident:"
echo "  scripts/smoke-test.sh ${NAMESPACE} ${RELEASE}"

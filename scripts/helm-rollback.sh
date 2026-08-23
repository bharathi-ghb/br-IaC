#!/usr/bin/env bash
# Shebang added - see docs/02 P1-12.
# =============================================================================
# Helm rollback
# =============================================================================
set -euo pipefail

NAMESPACE="${1:?namespace required}"
RELEASE="${2:?release name required}"
REVISION="${3:-0}" # 0 means "previous revision" to helm

# ROLLBACK NOTES - what this does, and the defect to fix.
#
# WHAT HELM ROLLBACK ACTUALLY DOES: it creates a NEW FORWARD REVISION whose content is
# the old one's. History is never rewound - so the audit trail stays complete and you
# can roll back the rollback.
#
# --cleanup-on-fail removes resources created during a failed rollback, so a failed
# recovery does not leave orphans behind.
#
# KNOWN DEFECT (docs/02 P1-14): REVISION DEFAULTS TO 0, which means "previous" to Helm.
# Two problems with that:
#   1. If the last three deploys failed, "previous" is also broken.
#   2. stage-deploy.yml runs "helm upgrade --atomic", which ALREADY rolls back on
#      failure. If --atomic already rolled back and this script then rolls back again,
#      you end up TWO revisions behind, in production, automatically.
#
# THE FIX - target the last KNOWN-GOOD revision, and no-op if already there:
#
#   CURRENT=$(helm history "$RELEASE" -n "$NAMESPACE" -o json | jq -r 'last | .revision')
#   LAST_GOOD=$(helm history "$RELEASE" -n "$NAMESPACE" -o json \
#     | jq -r '[.[]|select(.status=="deployed")]|last|.revision')
#   if [[ "$CURRENT" == "$LAST_GOOD" ]]; then
#     echo "Already at last-known-good revision $LAST_GOOD - nothing to do."; exit 0
#   fi
#   helm rollback "$RELEASE" "$LAST_GOOD" -n "$NAMESPACE" --wait --cleanup-on-fail
#
# WHAT ROLLBACK DOES NOT RECOVER - state OUTSIDE the release: database migrations, data
# the new version wrote to Blob, Azure resources Terraform changed, deleted PVC data.
# Nor can it go further back than revisionHistoryLimit retains ReplicaSets (5 on the
# Deployment; Helm keeps 10 releases). That is why anything with irreversible state
# needs expand/contract migrations - never a schema change the previous version cannot
# read - and why rollback is not always the safe option.

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

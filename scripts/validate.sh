#!/usr/bin/env bash
# =============================================================================
# Local validation - run this before pushing
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILED=0
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
check() { if "$@"; then echo "  ok"; else echo "  FAILED"; FAILED=1; fi }

step "Terraform format"
check terraform fmt -check -recursive infra/terraform

step "Terraform validate (per environment)"
for env in infra/terraform/environments/*/; do
  echo "  -> ${env}"

  terraform -chdir="$env" init -backend=false -input=false >/dev/null
  check terraform -chdir="$env" validate
done

step "tflint"
if command -v tflint >/dev/null 2>&1; then
  tflint --init >/dev/null 2>&1 || true
  check tflint --chdir=infra/terraform --recursive --format compact
else
  echo "  tflint not installed - skipping (the pipeline will still run it)"
fi

step "Helm lint"
check helm lint charts/banking-application --values charts/banking-application/values-nonprod.yaml \
  --set image.registry=example.azurecr.io \
  --set image.tag=local \
  --set config.storageAccountName=examplestorage \
  --set workloadIdentity.clientId="id"

step "Helm template render (nonprod and prod)"
for overlay in nonprod prod; do
  echo "  -> values-${overlay}.yaml"
  check helm template banking-application charts/banking-application \
    --namespace banking-application \
    --values "charts/banking-application/values-${overlay}.yaml" \
    --set image.registry=example.azurecr.io \
    --set image.tag=local \
    --set config.storageAccountName=examplestorage \
    --set workloadIdentity.clientId="id"
done

step "Shell scripts"
if command -v shellcheck >/dev/null 2>&1; then
  check shellcheck scripts/*.sh
else
  echo "  shellcheck not installed - skipping"
fi

if [[ "$FAILED" -ne 0 ]]; then
  printf '\n\033[31mValidation failed.\033[0m\n'
  exit 1
fi

printf '\n\033[32mAll validation passed.\033[0m\n'

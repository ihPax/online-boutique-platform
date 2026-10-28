#!/usr/bin/env bash
# Renderizza tutte le kustomization della piattaforma in una cartella.
# Uso: scripts/render.sh [output_dir]   (default: rendered)
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-rendered}"
mkdir -p "$out"
kustomize build platform/kustomize/overlays/dev  > "$out/dev.yaml"
kustomize build platform/kustomize/overlays/prod > "$out/prod.yaml"
kustomize build platform/observability           > "$out/observability.yaml"
kustomize build platform/argocd                  > "$out/argocd.yaml"
cp platform/argocd/bootstrap/root-app.yaml "$out/argocd-root.yaml"
for f in "$out"/*.yaml; do
  printf '%-40s %3s oggetti\n' "$f" "$(grep -c '^kind:' "$f")"
done

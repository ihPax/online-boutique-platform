#!/usr/bin/env bash
# PoC Krateo (opzionale): registra il blueprint come API self-service.
#  1. impacchetta il chart platform/krateo/blueprint e lo pubblica su GHCR (OCI)
#  2. installa core-provider (non tutto Krateo: niente portale, è una PoC)
#  3. applica la CompositionDefinition e aspetta la CRD generata
#  4. crea un'istanza di esempio (team-a) e mostra l'Application Argo CD risultante
#
# Prerequisiti: helm login su ghcr.io (helm registry login ghcr.io -u <user>),
# package GHCR "charts/online-boutique-env" pubblico, Argo CD già installato.
set -euo pipefail
cd "$(dirname "$0")/.."

OWNER="${OWNER:-ihpax}"
CORE_PROVIDER_VERSION="${CORE_PROVIDER_VERSION:-1.0.0}"
step() { printf '\n==> %s\n' "$*"; }

step "Pubblico il blueprint su oci://ghcr.io/$OWNER/charts"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
helm package platform/krateo/blueprint -d "$tmp"
helm push "$tmp"/online-boutique-env-*.tgz "oci://ghcr.io/$OWNER/charts"

step "core-provider $CORE_PROVIDER_VERSION"
helm repo add krateo https://charts.krateo.io >/dev/null
helm repo update >/dev/null
helm upgrade --install krateo-core-provider krateo/core-provider \
  --namespace krateo-system --create-namespace --version "$CORE_PROVIDER_VERSION" --wait

step "CompositionDefinition"
kubectl apply -f platform/krateo/compositiondefinition.yaml
kubectl -n krateo-system wait compositiondefinition/online-boutique-env \
  --for=condition=Ready --timeout=5m
kubectl get crd onlineboutiqueenvs.composition.krateo.io

step "Il ServiceAccount del controller generato deve poter creare Application in argocd"
echo "  kubectl -n krateo-system get sa,role,rolebinding | grep online-boutique-env"

step "Istanza di esempio"
scripts/create-secrets.sh boutique-team-a
kubectl apply -f platform/krateo/examples/team-a.yaml
kubectl -n krateo-system get onlineboutiqueenvs
echo "Application generata:"
kubectl -n argocd get application boutique-team-a -o wide || true

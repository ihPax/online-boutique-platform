#!/usr/bin/env bash
# PoC Krateo: registra il blueprint come API self-service e crea un ambiente.
#  1. installa solo core-provider (con chart-inspector), non tutto Krateo
#  2. applica la CompositionDefinition: Krateo genera la CRD OnlineBoutiqueEnv
#  3. crea l'istanza di esempio team-a: Krateo genera l'Application Argo CD,
#     Argo CD rilascia l'ambiente boutique-team-a
#
# Prerequisiti: kubectl, helm, Argo CD con l'AppProject online-boutique già presente,
# chart impacchettato in platform/krateo/dist/ e pushato su main.
#
# Uso: scripts/krateo-poc.sh            (crea)
#      scripts/krateo-poc.sh --cleanup  (rimuove istanza, definizione e core-provider)
set -euo pipefail
cd "$(dirname "$0")/.."

CORE_PROVIDER_VERSION="${CORE_PROVIDER_VERSION:-1.0.0}"
step() { printf '\n==> %s\n' "$*"; }

if [[ "${1:-}" == "--cleanup" ]]; then
  step "Rimuovo istanza, definizione e core-provider"
  kubectl delete -f platform/krateo/examples/team-a.yaml --ignore-not-found --wait=true
  kubectl delete -f platform/krateo/compositiondefinition.yaml --ignore-not-found --wait=true
  helm uninstall krateo-core-provider -n krateo-system || true
  echo "Il namespace boutique-team-a viene rimosso da Argo CD (finalizer dell'Application)."
  exit 0
fi

step "core-provider $CORE_PROVIDER_VERSION"
helm repo add krateo https://charts.krateo.io >/dev/null 2>&1 || true
helm repo update krateo >/dev/null
helm upgrade --install krateo-core-provider krateo/core-provider \
  --namespace krateo-system --create-namespace --version "$CORE_PROVIDER_VERSION" --wait --timeout 5m
kubectl -n krateo-system get pods

step "CompositionDefinition"
kubectl apply -f platform/krateo/compositiondefinition.yaml
kubectl -n krateo-system wait compositiondefinition/online-boutique-env \
  --for=condition=Ready --timeout=5m
kubectl get crd onlineboutiqueenvs.composition.krateo.io \
  -o jsonpath='{.metadata.name} versioni: {.spec.versions[*].name}{"\n"}'

step "Secret per il nuovo ambiente (fuori da Git, come per dev e prod)"
scripts/create-secrets.sh boutique-team-a

step "Istanza team-a"
kubectl apply -f platform/krateo/examples/team-a.yaml
kubectl -n krateo-system wait onlineboutiqueenv/boutique-team-a --for=condition=Ready --timeout=5m || true
kubectl -n krateo-system get onlineboutiqueenvs

step "Risultato"
kubectl -n argocd get application boutique-team-a || true
echo "Segui il rilascio:  kubectl -n boutique-team-a get pods -w"

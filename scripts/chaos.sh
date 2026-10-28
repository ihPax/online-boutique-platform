#!/usr/bin/env bash
# Scenari di guasto per la demo di troubleshooting. Ognuno ha inject e recover.
# Diagnosi e soluzione sono descritte in docs/runbook.md.
#
# Uso: scripts/chaos.sh <scenario> <inject|recover> [namespace]
#   redis-down     Redis a 0 repliche: il carrello va in errore.
#                  Argo CD NON lo ripara da solo (replicas non è dichiarato in Git).
#   cart-network   NetworkPolicy che isola cartservice: timeout dal frontend.
#                  Argo CD non la rimuove (oggetto extra, non gestito da Git).
#   drift          Modifica a mano l'env del frontend: Argo CD (selfHeal) la annulla.
set -euo pipefail

scenario="${1:-}"; action="${2:-}"; ns="${3:-boutique-dev}"
usage() { sed -n '2,12p' "$0"; exit 2; }
[[ -n "$scenario" && -n "$action" ]] || usage

case "$scenario/$action" in
  redis-down/inject)
    kubectl -n "$ns" scale deployment/redis-cart --replicas=0 ;;
  redis-down/recover)
    kubectl -n "$ns" scale deployment/redis-cart --replicas=1
    kubectl -n "$ns" rollout status deployment/redis-cart --timeout=120s ;;

  cart-network/inject)
    kubectl -n "$ns" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: chaos-isolate-cartservice
  labels:
    chaos: "true"
spec:
  podSelector:
    matchLabels:
      app: cartservice
  policyTypes: [Ingress]
  ingress: []
YAML
    ;;
  cart-network/recover)
    kubectl -n "$ns" delete networkpolicy chaos-isolate-cartservice --ignore-not-found ;;

  drift/inject)
    kubectl -n "$ns" set env deployment/frontend FRONTEND_MESSAGE="modifica manuale fuori da Git"
    echo "Ora guarda Argo CD: l'app va OutOfSync e selfHeal riporta lo stato di Git."
    echo "  kubectl -n argocd get application online-boutique-${ns#boutique-} -w" ;;
  drift/recover)
    echo "Niente da fare: ci pensa Argo CD (selfHeal)." ;;

  *) usage ;;
esac

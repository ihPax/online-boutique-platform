#!/usr/bin/env bash
# Crea il Secret "redis-auth" (password Redis) nei namespace indicati.
# Il valore non passa mai da Git né dal terminale: è generato qui e scritto
# direttamente nel cluster. Idempotente: se il Secret esiste non lo tocca,
# a meno di --rotate (che poi riavvia redis-cart e cartservice).
#
# Uso: scripts/create-secrets.sh [--rotate] boutique-dev [boutique-prod ...]
set -euo pipefail

rotate=false
if [[ "${1:-}" == "--rotate" ]]; then rotate=true; shift; fi
[[ $# -ge 1 ]] || { echo "uso: $0 [--rotate] <namespace>..." >&2; exit 2; }

for ns in "$@"; do
  # Il namespace normalmente lo crea Argo CD; qui lo creo se manca, così il
  # Secret è pronto prima del primo sync (Argo lo adotta: stesso nome).
  kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"

  if kubectl -n "$ns" get secret redis-auth >/dev/null 2>&1 && [[ "$rotate" == false ]]; then
    echo "[$ns] redis-auth esiste già (usa --rotate per cambiarlo)"
    continue
  fi

  password="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"
  kubectl -n "$ns" create secret generic redis-auth \
    --from-literal=password="$password" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - app.kubernetes.io/part-of=online-boutique -o yaml \
    | kubectl apply -f -
  unset password
  echo "[$ns] redis-auth creato"

  if [[ "$rotate" == true ]]; then
    # Redis legge la password solo all'avvio: riavvio entrambi i lati.
    kubectl -n "$ns" rollout restart deployment/redis-cart deployment/cartservice
    kubectl -n "$ns" rollout status deployment/redis-cart --timeout=120s
    kubectl -n "$ns" rollout status deployment/cartservice --timeout=180s
  fi
done

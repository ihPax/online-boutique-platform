#!/usr/bin/env bash
# Test funzionale end-to-end di un ambiente: home, prodotto, carrello, checkout
# e metriche. Usa un port-forward, quindi non dipende da DNS o Ingress.
#
# Uso: scripts/smoke-test.sh [namespace]   (default: boutique-dev)
set -euo pipefail

ns="${1:-boutique-dev}"
port="${LOCAL_PORT:-18080}"
mport="${LOCAL_METRICS_PORT:-19090}"
jar="$(mktemp)"
pf_log="$(mktemp)"
trap 'kill "${pf_pid:-}" 2>/dev/null || true; rm -f "$jar" "$pf_log"' EXIT

kubectl -n "$ns" port-forward svc/frontend "$port:80" "$mport:9090" >"$pf_log" 2>&1 &
pf_pid=$!
for _ in $(seq 1 20); do
  curl -fs "http://127.0.0.1:$port/_healthz" >/dev/null 2>&1 && break
  sleep 0.5
done

base="http://127.0.0.1:$port"
pass=0; fail=0
check() { # check <descrizione> <http_code_atteso> <curl args...>
  local desc="$1" want="$2"; shift 2
  local got
  got="$(curl -s -o /tmp/smoke-body.$$ -w '%{http_code}' -b "$jar" -c "$jar" "$@")"
  if [[ "$got" == "$want" ]]; then
    printf '  OK   %-38s %s\n' "$desc" "$got"; pass=$((pass+1))
  else
    printf '  FAIL %-38s atteso %s, ottenuto %s\n' "$desc" "$want" "$got"; fail=$((fail+1))
  fi
}

echo "Smoke test su $ns"
check "liveness /_healthz"              200 "$base/_healthz"
check "home page"                       200 "$base/"
check "pagina prodotto"                 200 "$base/product/OLJCESPC7Z"
check "aggiunta al carrello"            302 -X POST -d "product_id=OLJCESPC7Z&quantity=1" "$base/cart"
check "visualizza carrello"             200 "$base/cart"
year=$(( $(date +%Y) + 1 ))
check "checkout"                        200 -X POST \
  -d "email=smoke@example.com&street_address=Via+Roma+1&zip_code=37100&city=Verona&state=VR&country=Italy" \
  -d "credit_card_number=4432801561520454&credit_card_expiration_month=1&credit_card_expiration_year=$year&credit_card_cvv=672" \
  "$base/cart/checkout"
if grep -qi "order" /tmp/smoke-body.$$; then
  printf '  OK   %-38s\n' "conferma ordine nella pagina"; pass=$((pass+1))
else
  printf '  FAIL %-38s\n' "conferma ordine nella pagina"; fail=$((fail+1))
fi
rm -f /tmp/smoke-body.$$

orders="$(curl -s "http://127.0.0.1:$mport/metrics" | awk '/^frontend_orders_placed_total/{print $2}')"
if [[ -n "$orders" ]] && awk "BEGIN{exit !($orders >= 1)}"; then
  printf '  OK   %-38s %s\n' "metrica frontend_orders_placed_total" "$orders"; pass=$((pass+1))
else
  printf '  FAIL %-38s %s\n' "metrica frontend_orders_placed_total" "${orders:-assente}"; fail=$((fail+1))
fi

echo "Risultato: $pass ok, $fail falliti"
[[ "$fail" -eq 0 ]]

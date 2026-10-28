# Demo end-to-end

Durata indicativa: 30–35 minuti. Prima della demo: Application `Synced/Healthy`, almeno un'ora di traffico del load generator in dev (grafici pieni), Grafana e Argo CD aperti in due tab.

```bash
NS=boutique-dev
APP=online-boutique-dev
```

## 1. Repository e struttura (3 min)

```bash
git clone https://github.com/ihPax/online-boutique-platform.git && cd online-boutique-platform
tree -L 3 platform scripts .github
git diff --stat <commit-upstream>..HEAD -- src/       # unica modifica al codice: il frontend
```

Punti da dire: upstream intatto, piattaforma in `platform/`, una base e due overlay, Argo CD in pull, CI senza credenziali di cluster.

## 2. Build dell'immagine (3 min)

```bash
docker build -t online-boutique/frontend:demo src/frontend
```

Poi la versione automatica: ultimo run di `build-frontend` su GitHub Actions (build, Trivy, push su GHCR, commit del tag in `overlays/dev`).

## 3. Installazione (2 min)

Già installato; si mostra come:

```bash
scripts/create-secrets.sh boutique-dev boutique-prod
kubectl apply -f platform/argocd/bootstrap/root-app.yaml
kubectl -n argocd get applications
```

Da zero: `scripts/bootstrap-local.sh` (k3d).

## 4. Pod, service, ingress, configurazione (4 min)

```bash
kubectl -n $NS get deploy,pods,svc,ingress
kubectl get ns $NS --show-labels                         # PSA restricted
kubectl -n $NS get networkpolicy
kubectl -n $NS describe resourcequota environment-quota
kubectl -n $NS get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].env}' | jq
kubectl -n $NS get secret redis-auth                     # esiste, non è in Git
```

## 5. Endpoint applicativi (3 min)

Browser su `https://boutique-dev.homelab.local:<porta>` (banner "Ambiente DEV"): catalogo, prodotto, carrello, checkout. Poi:

```bash
scripts/smoke-test.sh $NS
```

## 6. Health check, log, metriche (5 min)

```bash
kubectl -n $NS describe pod -l app=frontend | grep -E 'Liveness|Readiness'
kubectl -n $NS logs deploy/frontend --since=2m | jq -c 'select(.message=="request complete") | {path: ."http.req.path", status: ."http.resp.status", ms: ."http.resp.took_ms"}' | head
kubectl -n $NS port-forward svc/frontend 9090:9090 &
curl -s localhost:9090/metrics | grep -E '^frontend_(orders|cart|http_requests_total)'
```

Grafana → dashboard "Online Boutique": richieste per route, errori, p95, ordini/min, repliche, restart. Prometheus → Alerts: regole `online-boutique.*` caricate e verdi.

## 7. Aggiornamento e rollout (4 min)

Opzione A, via CI (realistica): piccola modifica al frontend, push su `main`, la CI builda e aggiorna l'overlay dev, Argo CD fa il rollout.

Opzione B, più rapida in demo: cambio di configurazione in Git.

```bash
sed -i 's/Ambiente DEV/Ambiente DEV - release demo/' platform/kustomize/overlays/dev/frontend.yaml
git commit -am "dev: nuovo banner" && git push
kubectl -n argocd annotate application $APP argocd.argoproj.io/refresh=normal --overwrite
kubectl -n $NS rollout status deploy/frontend
kubectl -n $NS rollout history deploy/frontend
```

## 8. Guasto e troubleshooting (6 min)

Scenario principale, `redis-down`: il più istruttivo perché i pod sembrano sani.

```bash
scripts/chaos.sh redis-down inject
```

Percorso di diagnosi da mostrare (vedi [runbook, Frontend 5xx](runbook.md#frontend-5xx)):

1. Sintomo: errori nella home e sul carrello; dopo ~2 minuti alert `BoutiqueFrontendHighErrorRate`.
2. `kubectl -n $NS get pods`: tutto Running e Ready. Perché? La readiness del frontend non guarda i backend.
3. Log del frontend: `could not retrieve cart` con errore gRPC da cartservice.
4. Log di cartservice: errore di connessione a Redis.
5. `kubectl -n $NS get deploy redis-cart`: `0/0`. Causa trovata.
6. Argo CD dice `Synced`: `replicas` non è dichiarato in Git, quindi lo scale non è drift.
7. Ripristino: `scripts/chaos.sh redis-down recover`, smoke test verde, alert risolto.

Se c'è tempo: `cart-network` (timeout invece di errori immediati) o `drift` (Argo CD annulla da solo una modifica manuale).

## 9. Rollback (3 min)

Guasto introdotto da un deploy, poi rollback GitOps:

```bash
grep newTag platform/kustomize/overlays/dev/kustomization.yaml     # tag attuale, es. sha-a1b745d
sed -i 's/newTag: sha-a1b745d/newTag: sha-nonexist/' platform/kustomize/overlays/dev/kustomization.yaml
git commit -am "deploy(dev): frontend sha-nonexist" && git push
kubectl -n argocd annotate application $APP argocd.argoproj.io/refresh=hard --overwrite
kubectl -n $NS get pods -l app=frontend -w        # nuovo pod in ImagePullBackOff, il vecchio serve ancora
kubectl -n $NS describe pod -l app=frontend | grep -i -A2 'failed to pull'   # "not found": è il tag
scripts/smoke-test.sh $NS                          # 8/8: nessun disservizio
git revert --no-edit HEAD && git push
kubectl -n argocd annotate application $APP argocd.argoproj.io/refresh=hard --overwrite
kubectl -n $NS rollout status deploy/frontend
```

A voce: rollback d'emergenza con `rollout undo` (sospendendo prima l'auto-sync), e per prod il revert della PR di promozione.

## 10. Krateo (4 min)

[krateo.md](krateo.md): golden path "ambiente Online Boutique", parametri esposti e non esposti, diagramma, distinzione blueprint / PoC / adozione, raccomandazione. Se la PoC è stata eseguita:

```bash
kubectl get crd onlineboutiqueenvs.composition.krateo.io -o jsonpath='{.spec.versions[*].name}'
kubectl -n krateo-system get onlineboutiqueenvs
kubectl -n argocd get application boutique-team-a
```

Altrimenti mostrare la validazione dello schema:

```bash
helm template x platform/krateo/blueprint --set tier=platinum     # rifiutato dallo schema
```

## 11. Uso dell'AI (3 min)

Un caso concreto da [ai-usage.md](ai-usage.md): input, ragionamento, output, verifica e valore. Il caso del troubleshooting reale (sezione Operations) è il più forte.

## Piano B

- Ingress o DNS non raggiungibili: port-forward su `svc/frontend`.
- GitHub Actions lento: opzione B al punto 7.
- Cluster di casa irraggiungibile: `scripts/bootstrap-local.sh` su k3d in locale (preparato prima, ~10 minuti).

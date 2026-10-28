# Runbook operativo

Comandi riferiti a `boutique-dev`: per prod sostituisci il namespace e il nome dell'Application.

```bash
NS=boutique-dev
APP=online-boutique-dev
```

## Metodo

1. **Sintomo**: cosa vede l'utente o quale alert è scattato, da quando, in quale ambiente.
2. **Perimetro**: un servizio o tutti? Un ambiente o entrambi? Coincide con un deploy (`git log`, history di Argo CD)?
3. **Ipotesi** in ordine di probabilità, partendo dall'ultimo cambiamento.
4. **Verifica** con evidenze: eventi, log, metriche. Niente modifiche prima di avere una causa probabile.
5. **Azione** minima e reversibile; se il problema è nato da un commit, prima il `git revert`, poi l'analisi.
6. **Escalation** se la causa è fuori dal perimetro (nodo, rete del cluster, registry, dipendenze esterne), con le evidenze raccolte (sezione [Escalation](#escalation)).

## Verifica dello stato

```bash
# GitOps: l'ambiente corrisponde a Git?
kubectl -n argocd get application $APP
kubectl -n argocd get application $APP -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}{"\n"}'

# Workload
kubectl -n $NS get deploy,rs,pods -o wide
kubectl -n $NS get events --sort-by=.lastTimestamp | tail -20

# Rete: i Service hanno endpoint? L'Ingress ha host e certificato?
kubectl -n $NS get svc,endpointslices
kubectl -n $NS get ingress frontend
kubectl -n $NS get certificate,secret frontend-tls

# Guardrail
kubectl -n $NS describe resourcequota environment-quota
kubectl get ns $NS --show-labels           # PSA restricted

# Funzionale
scripts/smoke-test.sh $NS
```

Atteso: Application `Synced` e `Healthy`; 12 Deployment in dev (11 in prod) con tutte le repliche disponibili; ogni Service con almeno un endpoint; smoke test tutto `OK`.

### Health check, log e metriche

```bash
# Probe configurate e loro esito
kubectl -n $NS describe pod -l app=frontend | grep -A3 -E 'Liveness|Readiness'
kubectl -n $NS port-forward svc/frontend 8080:80 9090:9090 &
curl -s localhost:8080/_healthz            # ok
curl -s localhost:9090/metrics | grep ^frontend_

# Log strutturati: filtro per livello e per richiesta
kubectl -n $NS logs deploy/frontend --since=10m | jq -c 'select(.severity=="error")'
# log di accesso ("request complete"): solo con LOG_LEVEL=debug, quindi in dev
kubectl -n $NS logs deploy/frontend --since=10m | jq -r 'select(."http.resp.status">=500) | [."http.req.path", ."http.resp.status", ."http.resp.took_ms"] | @tsv'
kubectl -n $NS logs deploy/checkoutservice --since=10m | grep -iE 'warn|error'
```

PromQL utili (Prometheus o Grafana → Explore):

```promql
sum by (code) (rate(frontend_http_requests_total{namespace="boutique-dev"}[5m]))
boutique:frontend_errors:ratio5m
histogram_quantile(0.95, sum by (le, route) (rate(frontend_http_request_duration_seconds_bucket{namespace="boutique-dev"}[5m])))
ALERTS{namespace=~"boutique-.*"}
```

## Troubleshooting per sintomo

### Frontend 5xx

Alert `BoutiqueFrontendHighErrorRate`. Il pod del frontend di solito è Ready (la readiness non controlla i backend), quindi il guasto è quasi sempre **a valle**.

```bash
# Quale route fallisce? Il log dice quale backend e con che codice gRPC
kubectl -n $NS logs deploy/frontend --since=5m | jq -r 'select(.severity=="error") | .error' | sort | uniq -c
```

| Errore nel log | Causa probabile | Verifica |
|---|---|---|
| `could not retrieve cart ... Unavailable` / `DeadlineExceeded` | cartservice irraggiungibile o lento | `get pods -l app=cartservice`, endpoint, NetworkPolicy |
| `could not retrieve cart ... Internal` + log cartservice su Redis | Redis giù o password errata | `get deploy redis-cart`, log di cartservice (`RedisConnectionException`, `NOAUTH`) |
| `could not retrieve products` | productcatalogservice | log e endpoint di productcatalogservice |
| `failed to complete the order` | catena di checkout | [Checkout](#checkout) |
| `connection refused` verso un nome di servizio | Service senza endpoint (pod non Ready o selector errato) | `get endpointslices -l kubernetes.io/service-name=<svc>` |

Se l'errore è comparso subito dopo un deploy: [Rollback](#rollback) e poi analisi.

### Latenza

Alert `BoutiqueFrontendSlow`. Cerca la route lenta con la query p95 per `route` e poi il backend corrispondente.

```bash
kubectl -n $NS top pods                                    # CPU vicino al limite = throttling
kubectl -n $NS get hpa                                     # prod: l'HPA è al massimo?
kubectl -n $NS describe pod <pod> | grep -A5 'Limits'
```

Cause tipiche: CPU limit troppo basso (throttling di adservice o recommendationservice sotto carico), nodo saturo, timeout di rete parziale (NetworkPolicy che lascia passare solo alcune connessioni).

### Checkout

Alert `BoutiqueOrdersFailing`.

```bash
kubectl -n $NS logs deploy/checkoutservice --since=10m | grep -iE 'failed|error'
```

Payment, shipping, cart e currency sono bloccanti: se uno è giù l'ordine fallisce. Email no: l'ordine riesce e checkout logga solo `failed to send order confirmation`.

### Pod non Ready

Alert `BoutiqueDeploymentUnavailable`.

```bash
kubectl -n $NS get pods -l app=<servizio>
kubectl -n $NS describe pod <pod>          # sezione Events in fondo
```

| Stato / evento | Causa | Azione |
|---|---|---|
| `Pending` + `exceeded quota` (negli eventi del **ReplicaSet**) | ResourceQuota esaurita (es. surge durante un rollout) | `describe resourcequota`; aumentare la quota in Git o ridurre le richieste |
| `Pending` + `Insufficient cpu/memory` | Nodo pieno | `kubectl describe node`; escalation se il cluster è sottodimensionato |
| ReplicaSet con `violates PodSecurity "restricted"` | Manifest non conforme (es. manca `seccompProfile`) | Correggere in Git; `policy-check.sh` dovrebbe averlo intercettato in CI |
| `ImagePullBackOff` / `ErrImagePull` | Tag inesistente (`not found`), package privato o credenziali (`unauthorized` / `403`), registry irraggiungibile (timeout) | `describe pod` mostra il messaggio esatto; tag inesistente da un deploy: [Rollback](#rollback); `unauthorized`: visibilità del package o `imagePullSecret` |
| `CreateContainerConfigError` + `secret "redis-auth" not found` | Secret non creato nel namespace | `scripts/create-secrets.sh $NS` |
| `Running` ma `0/1 Ready` | Readiness fallita: guardare il motivo negli eventi (`Readiness probe failed: ...`) | Log del container; per i servizi gRPC verificare che la porta sia quella della probe |

Durante un rollout con immagine sbagliata il vecchio pod continua a servire: con 1 replica la strategia di default (`maxUnavailable` 25% arrotondato a 0, `maxSurge` 1) non toglie il pod vecchio finché il nuovo non è Ready. Il servizio resta su, il rollout resta bloccato: `kubectl -n $NS rollout status deploy/<svc>` va in timeout.

### CrashLoopBackOff

Alert `BoutiquePodRestarting`.

```bash
kubectl -n $NS logs <pod> --previous       # log del container morto
kubectl -n $NS get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated}{"\n"}'
```

| `reason` / exit code | Significato | Azione |
|---|---|---|
| `OOMKilled` / 137 | Limite di memoria superato | Aumentare `limits.memory` in Git dopo aver guardato il trend in Grafana |
| `Error` + log `too many open files` all'avvio di un controller | Limite inotify del nodo esaurito (default Ubuntu 128 istanze), tipico su nodi con molti pod o anche Docker | Contare le istanze (`sudo find /proc/*/fd -lname 'anon_inode:inotify' \| wc -l`); alzare `fs.inotify.max_user_instances` in `/etc/sysctl.d/` |
| `Error` / 2 + `panic: environment variable "X" not set` | Variabile obbligatoria mancante (il frontend va in panic all'avvio) | Correggere l'overlay |
| `Error` + `read-only file system` | Il processo scrive su disco con `readOnlyRootFilesystem` | Montare un `emptyDir` sul path, non togliere il vincolo |
| Liveness killing | La liveness fallisce ripetutamente | `describe pod`; valutare `initialDelaySeconds` o una `startupProbe` |
| `Error` / 137 senza `OOMKilled` + evento `failed liveness probe` subito dopo l'avvio | L'app è più lenta ad avviarsi della finestra della liveness (caso reale: emailservice, 16 s di avvio contro circa 15 s concessi) | Confrontare l'ora di avvio del container con il log "listening"; aggiungere una `startupProbe`, non allungare la liveness |

### Ingress

```bash
kubectl -n $NS get ingress frontend -o wide
kubectl -n kube-system logs deploy/traefik --since=10m | grep -i boutique
curl -kv https://boutique-dev.homelab.local:<porta-https-traefik>/ 2>&1 | grep -E '^< HTTP|subject'
```

- **404 da Traefik**: host sbagliato (DNS o `/etc/hosts`) o `ingressClassName` diverso da quello del controller.
- **502/504 da Traefik**: il Service non ha endpoint o la NetworkPolicy del frontend non ammette il namespace del controller (`kube-system` su k3s). Il controller va aggiunto in `components/network-policies/frontend.yaml`.
- **Certificato self-signed di default di Traefik**: il Certificate non è Ready (`kubectl -n $NS describe certificate frontend-tls`); manca il `ClusterIssuer` `selfsigned-cluster-issuer` o cert-manager.

### NetworkPolicy

Sintomi: timeout (non `connection refused`) tra servizi, `DeadlineExceeded` nei log gRPC.

```bash
kubectl -n $NS get networkpolicy
kubectl -n $NS describe networkpolicy <servizio>
# Prova di connettività dal frontend (immagine distroless: niente shell)
kubectl -n $NS debug -it deploy/frontend --image=busybox:1.38 --target=server -- nc -zv -w3 cartservice 7070
```

`kubectl debug` crea un container effimero: con PSA `restricted` serve un profilo compatibile (`--profile=restricted`). Il default-deny upstream vale per tutto il namespace: un nuovo servizio senza la sua policy è isolato.

### Metriche

Alert `BoutiqueFrontendMetricsDown`, oppure dashboard vuota.

```bash
# Prometheus vede il ServiceMonitor? La label release deve combaciare con il selector
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}{"\n"}{.items[0].spec.ruleSelector}{"\n"}'
kubectl -n $NS get servicemonitor frontend --show-labels
# Il target risponde?
kubectl -n $NS port-forward svc/frontend 9090:9090 & curl -s localhost:9090/metrics | head
```

Cause: label `release` diversa dal nome della release Helm di kube-prometheus-stack (va cambiata in `components/monitoring` e in `observability/`), NetworkPolicy che non ammette il namespace `monitoring`, frontend con immagine upstream (senza `/metrics`) perché la CI non ha ancora aggiornato il tag.

### Argo CD

```bash
kubectl -n argocd get application $APP -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
kubectl -n argocd get application $APP -o jsonpath='{.status.operationState.message}{"\n"}'
```

| Stato | Causa tipica |
|---|---|
| `OutOfSync` che torna `Synced` da solo | Modifica manuale annullata da selfHeal: è il comportamento voluto |
| Sync fallito `is not permitted in project` | Kind o namespace fuori dall'AppProject |
| `ComparisonError` / `kustomize build` fallito | Errore nel repo: lo stesso errore esce da `scripts/render.sh` in locale e in CI |
| `Healthy` ma l'app non funziona | Argo CD controlla lo stato degli oggetti, non la funzionalità: smoke test e alert |

## Rollback

### Standard: revert in Git

```bash
git log --oneline -- platform/kustomize/overlays/dev | head -5
git revert <commit-del-deploy>
git push
kubectl -n argocd get application $APP -w          # torna Synced/Healthy sulla nuova revisione
kubectl -n $NS rollout status deploy/frontend
scripts/smoke-test.sh $NS
```

Per prod: revert del merge della PR di promozione (`git revert -m 1 <merge>`), oppure una PR che rimette il tag precedente.

### Emergenza: rollback nel cluster

Più veloce di un giro di CI, ma crea divergenza da Git: va riallineato subito dopo.

```bash
# 1. sospendo l'auto-sync, altrimenti selfHeal annulla il rollback
kubectl -n argocd patch application $APP --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
# 2. torno alla revisione precedente del Deployment
kubectl -n $NS rollout history deploy/frontend
kubectl -n $NS rollout undo deploy/frontend
kubectl -n $NS rollout status deploy/frontend
# 3. allineo Git (revert come sopra) e riattivo l'auto-sync
kubectl -n argocd patch application $APP --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

In alternativa dalla UI di Argo CD: History and Rollback sulla revisione precedente (richiede anch'esso l'auto-sync disattivato).

## Secret

Il Secret `redis-auth` non è in Git. Se manca, redis-cart e cartservice restano in `CreateContainerConfigError`.

```bash
scripts/create-secrets.sh boutique-dev boutique-prod
```

### Rotazione password Redis

```bash
scripts/create-secrets.sh --rotate boutique-dev
```

Lo script sostituisce il Secret e riavvia redis-cart e cartservice (Redis legge la password solo all'avvio). Impatto: i carrelli in memoria si perdono e per qualche secondo le operazioni sul carrello falliscono. In prod va fatto in una finestra concordata.

## Scenari di guasto per la demo

`scripts/chaos.sh <scenario> inject|recover [namespace]`

| Scenario | Cosa succede | Dove si vede | Lezione |
|---|---|---|---|
| `redis-down` | Redis a 0 repliche | 5xx su `/` e `/cart`, p95 a circa 5 s (ogni richiesta aspetta il timeout di connessione del client Redis, 5000 ms), log cartservice `RedisConnectionException ... ConnectTimeout`, alert error rate dopo 2 min. Tutti i pod restano Ready. | Readiness superficiale; Argo CD non ripara uno `scale` perché `replicas` non è dichiarato |
| `cart-network` | NetworkPolicy che isola cartservice | Timeout (`DeadlineExceeded`) nel frontend, latenza p95 in salita, pod tutti Running/Ready | Distinguere timeout da refused; un oggetto extra non gestito da Git non viene rimosso da Argo CD |
| `drift` | Env del frontend modificata a mano | Application `OutOfSync`, poi `Synced` in pochi secondi; nuovo rollout | selfHeal: lo stato voluto è quello in Git |
| immagine inesistente (via Git) | Commit con tag sbagliato nell'overlay dev | `ImagePullBackOff` sul nuovo pod, il vecchio continua a servire, rollout bloccato | Rolling update sicuro; rollback con `git revert` |

## Escalation

Si scala quando la causa è fuori dal namespace dell'applicazione: nodo `NotReady` o in pressione, DNS di cluster, controller di rete, registry, Argo CD stesso. Informazioni da allegare:

- ambiente, inizio del problema, ultimo deploy (commit e ora)
- `kubectl -n $NS get pods -o wide` e gli eventi rilevanti
- log degli ultimi minuti dei servizi coinvolti
- grafico o query Prometheus che mostra l'inizio del problema
- cosa è stato già verificato ed escluso

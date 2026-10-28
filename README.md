# Online Boutique Platform

Rilascio, esercizio e troubleshooting di un'applicazione cloud-native a microservizi su Kubernetes, in GitOps con Argo CD. Workload: [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) di Google Cloud.

| Documento | Contenuto |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Componenti, flussi, scelte e trade-off |
| [docs/runbook.md](docs/runbook.md) | Verifiche, troubleshooting per sintomo, rollback |
| [docs/demo.md](docs/demo.md) | Scaletta della demo end-to-end con i comandi |
| [docs/krateo.md](docs/krateo.md) | Valutazione Krateo, blueprint e PoC |
| [docs/ai-usage.md](docs/ai-usage.md) | Come è stata usata l'AI e come è stata verificata |

## Perché Online Boutique

È l'applicazione suggerita dalla challenge e la superficie operativa è realistica per un L2 senza scrivere codice da zero:

- **11 microservizi in 5 linguaggi** (Go, C#, Node.js, Python, Java) che parlano **gRPC**, più **Redis** come stato del carrello.
- **Un solo ingresso HTTP** (il frontend): routing, esposizione e propagazione dei guasti sono facili da seguire.
- **Manifest e componenti Kustomize mantenuti upstream** (network policy, load generator disattivabile, frontend non pubblico): lo sforzo va sulla piattaforma attorno all'app, non sul packaging.
- **Probe, log JSON e tracing OpenTelemetry opzionale** già presenti.
- **Load generator Locust integrato**: in demo metriche e dashboard hanno traffico vero.

Dominio: e-commerce. L'utente sfoglia il catalogo, aggiunge al carrello e completa un ordine; il checkout orchestra pagamento (simulato), spedizione, email di conferma e conversione valuta.

### Perimetro

| Usato | Escluso | Motivo |
|---|---|---|
| 11 servizi core, `redis-cart`, `loadgenerator` | `shoppingassistantservice` | Richiede Gemini e AlloyDB su GCP |
| Base e componenti Kustomize upstream | Helm chart, Istio, Terraform, Cloud Build, Skaffold | Un solo percorso di packaging, nessuna dipendenza da GCP |

### Modifiche rispetto all'upstream

L'app upstream resta intatta tranne il **frontend**, che ora espone metriche Prometheus su una porta dedicata (`src/frontend/metrics.go`, più 5 righe in `main.go` e `handlers.go`) e legge il livello di log da `LOG_LEVEL`. Il resto è nuovo:

```
platform/
├── kustomize/
│   ├── base/                 # sopra kustomize/base upstream: hardening, ingress, auth Redis, metriche
│   ├── components/           # network-policies, guardrails (quota/limitrange), monitoring, team-rbac
│   └── overlays/{dev,prod}/  # ambienti
├── argocd/                   # AppProject + Application (dev, prod, observability) + root app
├── observability/            # PrometheusRule (alert) e dashboard Grafana
└── krateo/                   # blueprint Helm + CompositionDefinition (golden path self-service)
scripts/                      # bootstrap, secret, smoke test, chaos, render e policy check
.github/workflows/            # validate, build-frontend, promote-to-prod
docs/
```

Rimossi i workflow GitHub upstream (puntano alla CI di Google). Il README originale è in [docs/upstream-README.md](docs/upstream-README.md).

## Prerequisiti

- Cluster Kubernetes ≥ 1.30 con ~2 vCPU e ~3 GiB di memoria liberi per ambiente. Riferimento: k3s single node con Traefik (incluso in k3s/k3d).
- `kubectl`, `helm`, `kustomize` ≥ 5; per il cluster locale `docker` e `k3d`.
- Fork pubblico di questo repo (Argo CD lo legge in HTTPS senza credenziali).

## Installazione

### A. Cluster con Argo CD e kube-prometheus-stack già presenti

È il caso del cluster di riferimento (homelab k3s).

```bash
# 1. Secret applicativi: fuori da Git, generati nel cluster
scripts/create-secrets.sh boutique-dev boutique-prod

# 2. Root app: porta dentro AppProject, Application dev/prod e osservabilità
kubectl apply -f platform/argocd/bootstrap/root-app.yaml
kubectl -n argocd get applications -w
```

Verifica che le label `release` di ServiceMonitor e PrometheusRule combacino con il Prometheus installato (vedi [runbook, Metriche](docs/runbook.md#metriche)).

### B. Da zero su k3d

```bash
scripts/bootstrap-local.sh
```

Crea il cluster, installa cert-manager, kube-prometheus-stack e Argo CD con versioni fissate, poi esegue i passi di A.

### Accesso

```bash
# Senza DNS: port-forward
kubectl -n boutique-dev port-forward svc/frontend 8080:80     # http://localhost:8080

# Con Ingress: host boutique-dev.homelab.local / boutique.homelab.local verso il nodo
```

## Build

```bash
# Immagine locale del frontend modificato
docker build -t online-boutique/frontend:dev src/frontend
docker run --rm -p 8080:8080 -p 9090:9090 \
  -e PRODUCT_CATALOG_SERVICE_ADDR=x:1 -e CURRENCY_SERVICE_ADDR=x:1 -e CART_SERVICE_ADDR=x:1 \
  -e RECOMMENDATION_SERVICE_ADDR=x:1 -e CHECKOUT_SERVICE_ADDR=x:1 -e SHIPPING_SERVICE_ADDR=x:1 \
  -e AD_SERVICE_ADDR=x:1 -e SHOPPING_ASSISTANT_SERVICE_ADDR=x:1 \
  online-boutique/frontend:dev
curl -s localhost:9090/metrics | grep ^frontend_
```

In CI ([build-frontend.yml](.github/workflows/build-frontend.yml)) ogni push su `main` che tocca `src/frontend` builda l'immagine, la scansiona con Trivy, la pubblica su GHCR con tag `sha-<commit>` e aggiorna l'overlay dev. Argo CD vede il commit e fa il rollout. La promozione in prod passa da una PR ([promote-to-prod.yml](.github/workflows/promote-to-prod.yml)).

> Al primo push il package GHCR è privato: impostalo **public** (Package settings) oppure aggiungi un `imagePullSecret`.

Gli altri servizi usano le immagini upstream `v0.10.7`, fissate nella base.

## Validazione e test

```bash
scripts/render.sh rendered            # kustomize build di tutto
kubeconform -strict -summary rendered/*.yaml \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
kube-linter lint --config .kube-linter.yaml rendered/dev.yaml rendered/prod.yaml
scripts/policy-check.sh rendered      # PSA, SA dedicati, niente :latest, limiti, probe
scripts/smoke-test.sh boutique-dev    # home, prodotto, carrello, checkout, metriche
```

Le stesse validazioni girano in CI su ogni PR ([validate.yml](.github/workflows/validate.yml)).

## Limiti noti

- **Readiness superficiale.** `/_healthz` del frontend risponde `ok` anche se i backend sono giù: il pod resta Ready mentre le pagine danno 500. Lo coprono metriche e alert, non le probe. Discussione in [architecture.md](docs/architecture.md#probe-e-readiness).
- **Secret fuori da Git e senza gestione del ciclo di vita.** `redis-auth` è creato da script; l'evoluzione prevista è Sealed Secrets o External Secrets + Vault.
- **Redis senza persistenza** (`emptyDir`, come upstream): un restart svuota i carrelli. Accettabile per dati di sessione.
- **Nessun admission controller.** Le policy sono verificate in CI (`policy-check.sh`, kube-linter) e da Pod Security Admission `restricted`; chi ha accesso diretto al cluster può aggirarle.
- **Solo il frontend ha metriche applicative.** Gli altri servizi sono osservati tramite kube-state-metrics e cAdvisor.

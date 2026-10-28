# Uso dell'AI

## Strumenti

| Strumento | Uso |
|---|---|
| Claude (Anthropic), modalità agente su claude.ai, con shell, git, Go e strumenti Kubernetes in una sandbox | Analisi del codice upstream, scrittura di manifest, script, workflow e documentazione, verifica locale (build, test, render, lint) |

La sandbox non ha accesso al cluster né a Docker: tutto ciò che riguarda il cluster è stato verificato da me sul k3s di casa (sezione [Verifiche sul cluster](#verifiche-sul-cluster)).

## Regole che ho seguito

- **Nessun segreto nei prompt.** La password di Redis è generata nel cluster da `create-secrets.sh`; né io né l'AI l'abbiamo mai vista. Kubeconfig e token non sono stati condivisi.
- **Ogni output verificato con uno strumento, non a occhio**: `go build`/`go test`, `kustomize build`, kubeconform, kube-linter, `helm lint`/`template`, shellcheck, e sul cluster smoke test e prove di guasto.
- **Fatti verificati alla fonte**: versioni di action e chart lette dai repository (`git ls-remote`, index Helm), comportamento di Krateo letto dal suo repository, non dalla memoria del modello.
- **Comandi distruttivi solo se compresi** e solo su dev: gli scenari di `chaos.sh` hanno sempre un `recover` e sono documentati.
- **Plausibile ≠ funzionante**: dove qualcosa non è stato provato sul cluster lo dico esplicitamente (es. PoC Krateo).

## 1. Analisi iniziale

**Problema.** Capire in fretta un'applicazione di 11 servizi in 5 linguaggi e trovare i punti critici per il deploy su un cluster con Pod Security `restricted` e NetworkPolicy.

**Approccio.** Ho chiesto all'AI di leggere la base Kustomize e il codice dei servizi chiave (frontend, checkout, cartservice) e di riportare dipendenze, porte e rischi con il riferimento al file.

**Cosa ne è uscito, e come l'ho verificato.**

| Risultato | Verifica |
|---|---|
| I pod upstream non hanno `seccompProfile`: con PSA `restricted` sarebbero rifiutati | Lettura dei manifest; ora `policy-check.sh` e PSA lo controllano |
| `redis-cart` non ha ServiceAccount (usa `default`) | Render della base |
| La NetworkPolicy upstream del frontend accetta tutto in ingresso | Lettura del componente `network-policies` |
| `/_healthz` del frontend risponde `ok` anche con tutti i backend giù | **Provato**: frontend compilato e avviato con backend inesistenti, `/_healthz` = 200 e `/` = 500 |
| Il checkout ignora il fallimento di emailservice | Lettura di `checkoutservice/main.go` (log `Warn`, l'ordine prosegue) |
| cartservice accetta una stringa di connessione StackExchange.Redis, quindi `,password=` | Lettura di `Startup.cs` |

**Valore.** Il quadro dei rischi in poche ore invece che in un paio di giorni. Le scoperte sulla readiness e sull'email hanno guidato alert e scenari di guasto.

## 2. Implementazione

**Dove l'AI ha accelerato:** struttura di base e overlay, metriche del frontend, workflow, script, chart del blueprint, dashboard Grafana (generata da script per non scrivere a mano 14 pannelli di JSON).

**Dove è servito correggere o cambiare strada** (problemi emersi dalle verifiche, non dalla prima stesura):

| Problema | Come è emerso | Correzione |
|---|---|---|
| La password Redis va composta in `REDIS_ADDR` con `$(REDIS_PASSWORD)`, ma Kubernetes espande solo variabili definite **prima** nella lista. Una strategic merge patch avrebbe aggiunto `REDIS_PASSWORD` in coda, rompendo l'espansione | Ragionamento sull'ordine delle env, verificato sul manifest renderizzato | JSON patch che sostituisce l'intera lista env di cartservice nell'ordine giusto |
| `go vet` fallisce su avvisi `copylocks` | Esecuzione di `go vet` | Sono preesistenti nel codice upstream generato (`genproto.Money`): escluso solo quel check in CI, motivandolo nel workflow |
| kube-linter: init container del load generator senza risorse, PDB senza `unhealthyPodEvictionPolicy` | kube-linter sui manifest renderizzati | Aggiunte risorse all'init container e la policy al PDB |
| `policy-check.sh` segnalava il load generator senza readiness | Prima esecuzione | Regola raffinata: la readiness è obbligatoria solo per i container che espongono porte |
| Versioni di action e tool proposte dalla memoria del modello erano vecchie | Confronto con `git ls-remote` e con gli index Helm | Versioni aggiornate e fissate |
| Il blueprint Krateo si basa sull'override del namespace di Kustomize: rinomina anche l'oggetto `Namespace`? | Dubbio esplicito prima di affidarcisi | Provato con `kustomize build`: sì |
| Bozza dei workflow scriveva in `/usr/local/bin` sul runner | Revisione | Tool installati in `$RUNNER_TEMP` |

**Scartato:** introdurre una coda di messaggi per avere un "worker" (troppo invasivo sul codice upstream, motivato in architecture.md); readiness "profonda" sui backend (peggiora i guasti a cascata).

## 3. Operations e troubleshooting

### Caso 1: readiness verde, pagine in errore (in locale)

- **Input**: frontend avviato con backend irraggiungibili; `/_healthz` 200, `/` e `/product/{id}` 500.
- **Ragionamento**: un pod Ready che serve errori non viene tolto dal bilanciamento; il guasto si vede solo misurando le risposte. Rendere la readiness dipendente dai backend toglierebbe tutti i frontend insieme quando cade un backend comune.
- **Output**: metrica `frontend_http_requests_total` con label `code`, regola `boutique:frontend_errors:ratio5m`, alert `BoutiqueFrontendHighErrorRate`, scenario `redis-down` nella demo.
- **Verifica**: metriche lette da `/metrics` dopo le richieste di prova (`code="500"` presente, `/metrics` assente sulla porta 8080).
- **Valore**: un limite dell'applicazione trasformato in un caso di diagnosi documentato.

### Caso 2: emailservice in CrashLoopBackOff (sul cluster)

Al primo deploy di dev e prod, `emailservice` è andato in `CrashLoopBackOff` in prod e ha avuto 2 restart in dev.

| Campo | |
|---|---|
| Sintomo | `boutique-prod/emailservice` 0/1 `CrashLoopBackOff`, 7 restart; Application `online-boutique-prod` ferma su `Progressing` |
| Evidenze fornite all'AI (senza segreti) | `lastState.terminated` (`exitCode 137`, `reason: Error`), log del container precedente, eventi del pod (`failed liveness probe, will be restarted`; `failed to connect service ... within 1s`) |
| Ipotesi proposte | 1) OOM; 2) NetworkPolicy che blocca la probe del kubelet; 3) avvio più lento della finestra concessa dalla liveness |
| Verifica fatta | 137 senza `OOMKilled` esclude l'OOM (è il SIGKILL del kubelet). Gli altri servizi gRPC con le stesse NetworkPolicy passano le probe: esclusa la rete. Tempi: container avviato alle 13:19:45, log `listening on port: 8080` alle 13:20:01 (16 s), ucciso alle 13:20:02. La probe upstream (`periodSeconds: 5`, 3 fallimenti, nessun `initialDelaySeconds`, timeout 1 s) concede circa 15 s. In più 24 pod partivano insieme sotto il limite di 200m CPU |
| Causa reale e correzione | Avvio lento sotto limite CPU. Aggiunta una `startupProbe` (fino a 2 minuti) e timeout di 3 s su liveness e readiness, come patch nella base (`patches/emailservice-probes.yaml`). Dopo il sync: nuovo pod 1/1, 0 restart; prod `Healthy` |
| Valore | Causa isolata in pochi minuti ragionando sulle evidenze invece di provare a caso (es. alzare memoria o rimuovere la NetworkPolicy, che non avrebbero risolto). La correzione è minima, in Git e vale per entrambi gli ambienti |

## 4. Documentazione e demo

L'AI ha prodotto la prima stesura di README, architecture, runbook, demo e valutazione Krateo partendo dai file effettivi del repo. Controlli prima di accettarla:

- ogni comando del runbook e della demo eseguito sul cluster almeno una volta (sezione seguente);
- i dettagli citati confrontati con il codice (es. il frontend va in **panic**, exit code 2, se manca una variabile: la prima stesura diceva exit code 1);
- i punti non verificati dichiarati come tali (es. condizione di readiness della `CompositionDefinition` nello script Krateo, perché la documentazione ufficiale non era raggiungibile dalla sandbox).

## Verifiche sul cluster

Eseguite il 28/10/2026 sul k3s dell'homelab (single node, k3s v1.35, Traefik, kube-prometheus-stack, Argo CD 3.4).

| Verifica | Esito | Note |
|---|---|---|
| Application dev, prod, observability `Synced/Healthy` | OK | Prod `Healthy` dopo il fix di emailservice (caso 2) |
| Pod ammessi da PSA `restricted` | OK | 12 deployment in dev, 11 + HPA in prod, nessun rifiuto |
| Probe gRPC/HTTP con le NetworkPolicy (kube-router di k3s) | OK | Unico problema delle probe: avvio lento di emailservice, non la rete |
| Redis con password, cartservice connesso | OK | Smoke test con carrello e checkout verdi |
| Ingress Traefik + certificato cert-manager | OK | `200` su dev e prod via NodePort 30443, Certificate `True` |
| ServiceMonitor e regole caricate da Prometheus | OK | Target frontend dev `up`; gruppi `online-boutique.*` caricati |
| Dashboard Grafana caricata dal sidecar | OK | Traffico del load generator visibile; riquadri statistici corretti per mostrare 0 invece di "No data" |
| `smoke-test.sh` dev | OK | 8/8 |
| Build CI, push GHCR, commit del tag, rollout dev | OK | `sha-a1b745d` |
| Promozione in prod via PR | OK | PR #1, rollout con `maxUnavailable: 0` |
| Scenario `redis-down` | OK | 5xx all'11%, p95 a 5 s (timeout di connessione del client Redis), pod tutti Ready, Argo CD `Synced`. Diagnosi dashboard → pod → frontend → cartservice → Redis |
| Scenario immagine inesistente + rollback `git revert` | OK | Nuovo pod `ImagePullBackOff` (`not found`), pod vecchio sempre `Running`, smoke test 8/8 durante il guasto; revert e rollout completato senza disservizio |
| Scenari `cart-network` e `drift` | Da provare | |
| `smoke-test.sh` prod | Da provare | |
| `bootstrap-local.sh` su k3d | Da provare | |
| PoC Krateo | Non eseguita | Valutazione e blueprint in [krateo.md](krateo.md) |

## Limiti riscontrati

- L'AI non vede il cluster: tutto ciò che dipende dall'ambiente (CNI, nome della release Prometheus, Traefik) resta un'ipotesi fino alla verifica.
- La memoria del modello su versioni e API recenti non è affidabile: va sempre confrontata con la fonte.
- La documentazione prodotta tende a essere completa ma lunga: va riletta e asciugata dove non aggiunge informazioni operative.

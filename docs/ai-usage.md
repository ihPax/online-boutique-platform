# Uso dell'AI

## Strumenti

| Strumento | Uso |
|---|---|
| Claude (Anthropic), modalità agente su claude.ai, con shell, git, Go e strumenti Kubernetes in una sandbox | Analisi del codice upstream, scrittura di manifest, script, workflow e documentazione, verifica locale (build, test, render, lint) |
| _da completare: eventuali altri strumenti (Copilot nell'IDE, ecc.)_ | |

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

### Caso 2: troubleshooting sul cluster

_Da completare con un caso reale emerso durante il deploy sul k3s: errore osservato (evento, log o metrica), cosa ho chiesto all'AI, ipotesi proposte, quale era corretta, come l'ho verificato, quanto tempo ha fatto risparmiare._

| Campo | |
|---|---|
| Sintomo | |
| Evidenze fornite all'AI (senza segreti) | |
| Ipotesi proposte | |
| Verifica fatta | |
| Causa reale e correzione | |
| Valore | |

## 4. Documentazione e demo

L'AI ha prodotto la prima stesura di README, architecture, runbook, demo e valutazione Krateo partendo dai file effettivi del repo. Controlli prima di accettarla:

- ogni comando del runbook e della demo eseguito sul cluster almeno una volta (sezione seguente);
- i dettagli citati confrontati con il codice (es. il frontend va in **panic**, exit code 2, se manca una variabile: la prima stesura diceva exit code 1);
- i punti non verificati dichiarati come tali (es. condizione di readiness della `CompositionDefinition` nello script Krateo, perché la documentazione ufficiale non era raggiungibile dalla sandbox).

## Verifiche sul cluster

_Da completare dopo il deploy sul k3s._

| Verifica | Esito | Note |
|---|---|---|
| Application dev e prod `Synced/Healthy` | | |
| Pod ammessi da PSA `restricted` | | |
| Probe gRPC/HTTP funzionanti con le NetworkPolicy (kube-router di k3s) | | |
| Redis con password, cartservice connesso | | |
| Ingress Traefik + certificato cert-manager | | |
| ServiceMonitor e regole caricate da Prometheus (label `release`) | | |
| Dashboard Grafana caricata dal sidecar | | |
| `smoke-test.sh` dev e prod | | |
| Build CI, push GHCR, commit del tag, rollout | | |
| Scenari `redis-down`, `cart-network`, `drift`, immagine errata | | |
| Rollback con `git revert` | | |
| PoC Krateo | | |

## Limiti riscontrati

- L'AI non vede il cluster: tutto ciò che dipende dall'ambiente (CNI, nome della release Prometheus, Traefik) resta un'ipotesi fino alla verifica.
- La memoria del modello su versioni e API recenti non è affidabile: va sempre confrontata con la fonte.
- La documentazione prodotta tende a essere completa ma lunga: l'ho asciugata dove non aggiungeva informazioni operative.

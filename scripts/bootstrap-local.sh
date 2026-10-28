#!/usr/bin/env bash
# Ambiente riproducibile da zero su un cluster vuoto (k3d di default).
# Installa lo stesso stack del cluster di riferimento (homelab k3s):
# Traefik (incluso in k3s/k3d), cert-manager, kube-prometheus-stack, Argo CD.
# Poi crea i Secret e la root app, e Argo CD fa il resto.
#
# Uso:
#   scripts/bootstrap-local.sh            # crea il cluster k3d "obp" e installa tutto
#   SKIP_CLUSTER=1 scripts/bootstrap-local.sh   # usa il contesto kubectl corrente
#
# Prerequisiti: docker, k3d, kubectl, helm. Repo pubblico su GitHub (Argo CD lo legge in HTTPS).
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER="${CLUSTER:-obp}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.11.6}"
KPS_CHART_VERSION="${KPS_CHART_VERSION:-92.14.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.3}"

step() { printf '\n==> %s\n' "$*"; }

if [[ "${SKIP_CLUSTER:-0}" != "1" ]]; then
  step "Cluster k3d '$CLUSTER' (porte 8080->80, 8443->443)"
  k3d cluster list "$CLUSTER" >/dev/null 2>&1 || \
    k3d cluster create "$CLUSTER" --agents 1 \
      -p "8080:80@loadbalancer" -p "8443:443@loadbalancer" --wait
fi
kubectl cluster-info >/dev/null

step "Repository Helm"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update >/dev/null

step "cert-manager $CERT_MANAGER_VERSION + ClusterIssuer self-signed"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --wait
kubectl apply -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-cluster-issuer
spec:
  selfSigned: {}
YAML

step "kube-prometheus-stack $KPS_CHART_VERSION (release: kube-prometheus-stack)"
# La release DEVE chiamarsi kube-prometheus-stack: ServiceMonitor e PrometheusRule
# della piattaforma usano la label release=kube-prometheus-stack.
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace --version "$KPS_CHART_VERSION" \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.dashboards.label=grafana_dashboard \
  --set alertmanager.enabled=true \
  --wait --timeout 10m

step "Argo CD $ARGOCD_CHART_VERSION"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace --version "$ARGOCD_CHART_VERSION" \
  --set configs.params."server\.insecure"=true --wait

step "Secret applicativi (fuori da Git)"
scripts/create-secrets.sh boutique-dev boutique-prod

step "Root application"
kubectl apply -f platform/argocd/bootstrap/root-app.yaml

step "Fatto"
cat <<TXT
Argo CD sincronizza ora AppProject, dev, prod e osservabilità. Segui con:
  kubectl -n argocd get applications -w

Password admin Argo CD:
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
UI Argo CD:   kubectl -n argocd port-forward svc/argocd-server 8081:80
Grafana:      kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
Smoke test:   scripts/smoke-test.sh boutique-dev
TXT

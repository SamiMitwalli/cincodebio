#!/usr/bin/env bash
# ============================================================================
# CincoDeBio Local Installer
# Deploys the full CincoDeBio platform on a local minikube cluster (macOS/Linux)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$SCRIPT_DIR/charts/cincodebio"
RELEASE_NAME="cincodebio"
NAMESPACE="default"
TIMEOUT_HELM="10m"
TIMEOUT_PODS="600"  # seconds

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- pre-flight checks ----------
check_tool() {
  command -v "$1" >/dev/null 2>&1 || error "'$1' is not installed. Please install it first."
}

info "Checking prerequisites..."
check_tool minikube
check_tool helm
check_tool kubectl
check_tool docker

# ---------- DockerHub credentials ----------
# Accept from environment or prompt interactively
if [ -z "${DOCKER_HUB_USERNAME:-}" ]; then
  read -rp "DockerHub username: " DOCKER_HUB_USERNAME
fi
if [ -z "${DOCKER_HUB_PASSWORD:-}" ]; then
  read -rsp "DockerHub password: " DOCKER_HUB_PASSWORD
  echo
fi
[ -z "$DOCKER_HUB_USERNAME" ] && error "DOCKER_HUB_USERNAME is required"
[ -z "$DOCKER_HUB_PASSWORD" ] && error "DOCKER_HUB_PASSWORD is required"

# ---------- minikube ----------
if minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
  info "Minikube is already running."
else
  info "Starting minikube (docker driver, Kubernetes v1.28.0)..."
  minikube start --driver=docker --kubernetes-version=v1.28.0 --cpus=4 --memory=8192
fi

info "Enabling minikube addons (ingress, registry)..."
minikube addons enable ingress 2>/dev/null || true
minikube addons enable registry 2>/dev/null || true

# Enable snippet annotations and regex paths for nginx ingress controller
info "Configuring nginx ingress controller for snippet & regex support..."
kubectl -n ingress-nginx patch configmap ingress-nginx-controller \
  --type merge -p '{"data":{"allow-snippet-annotations":"true"}}' 2>/dev/null || true
# The validating webhook independently rejects snippets; remove it for local dev
kubectl delete validatingwebhookconfiguration ingress-nginx-admission 2>/dev/null || true
kubectl -n ingress-nginx rollout restart deployment ingress-nginx-controller 2>/dev/null || true
info "Waiting for nginx ingress controller to be ready..."
kubectl -n ingress-nginx rollout status deployment ingress-nginx-controller --timeout=120s 2>/dev/null || true

# Wait for registry to be ready
info "Waiting for registry pod..."
kubectl wait --for=condition=Ready pod -l kubernetes.io/minikube-addons=registry \
  -n kube-system --timeout=120s 2>/dev/null || warn "Registry pod not ready yet — continuing"

# Fix: the minikube registry-proxy image (gcr.io/k8s-minikube/kube-registry-proxy:0.0.9)
# has been removed from gcr.io. Replace it with a socat-based proxy so that
# localhost:5000 works on the node for kubelet image pulls.
if kubectl get daemonset registry-proxy -n kube-system >/dev/null 2>&1; then
  PROXY_READY=$(kubectl get daemonset registry-proxy -n kube-system \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  if [ "$PROXY_READY" = "0" ]; then
    info "Fixing registry-proxy (upstream image unavailable)..."
    eval $(minikube docker-env) && docker pull alpine/socat:latest >/dev/null 2>&1 || true
    kubectl patch daemonset registry-proxy -n kube-system --type='json' -p='[
      {"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "alpine/socat:latest"},
      {"op": "replace", "path": "/spec/template/spec/containers/0/command", "value": ["socat"]},
      {"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["TCP-LISTEN:80,fork,reuseaddr", "TCP:registry.kube-system.svc.cluster.local:80"]}
    ]' 2>/dev/null || true
    sleep 10
    kubectl wait --for=condition=Ready pod -l kubernetes.io/minikube-addons=registry \
      -l actual-registry=true -n kube-system --timeout=60s 2>/dev/null || \
    kubectl get pods -n kube-system -l k8s-app=registry-proxy --no-headers 2>/dev/null
  fi
fi

# ---------- cert-manager ----------
if kubectl get namespace cert-manager >/dev/null 2>&1; then
  info "cert-manager namespace exists — checking pods..."
  if kubectl get pods -n cert-manager -l app.kubernetes.io/instance=cert-manager \
       --no-headers 2>/dev/null | grep -q Running; then
    info "cert-manager is already running."
  else
    warn "cert-manager pods not healthy — reinstalling..."
    helm uninstall cert-manager -n cert-manager 2>/dev/null || true
    kubectl delete namespace cert-manager --wait=true 2>/dev/null || true
    sleep 5
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update jetstack
    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager --create-namespace \
      --version v1.17.2 \
      --set crds.enabled=true --wait --timeout=5m
  fi
else
  info "Installing cert-manager..."
  helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
  helm repo update jetstack
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version v1.17.2 \
    --set crds.enabled=true --wait --timeout=5m
fi

# ---------- create required secrets ----------
# Frontend requires cinco-cloud-main-secrets with an authPublicKey for JWT verification
if ! kubectl get secret cinco-cloud-main-secrets -n "$NAMESPACE" >/dev/null 2>&1; then
  info "Creating cinco-cloud-main-secrets (local dev placeholder)..."
  kubectl create secret generic cinco-cloud-main-secrets \
    --from-literal=authPublicKey="local-dev-placeholder-key" \
    -n "$NAMESPACE"
fi

# ---------- helm install / upgrade ----------
info "Deploying CincoDeBio chart..."
if helm list -n "$NAMESPACE" --short 2>/dev/null | grep -q "^${RELEASE_NAME}$"; then
  info "Release '$RELEASE_NAME' exists — upgrading..."
  helm upgrade "$RELEASE_NAME" "$CHART_DIR" \
    -n "$NAMESPACE" \
    -f "$CHART_DIR/values-local.yaml" \
    --set global.containers.docker_hub_username="$DOCKER_HUB_USERNAME" \
    --set global.containers.docker_hub_password="$DOCKER_HUB_PASSWORD" \
    --timeout "$TIMEOUT_HELM" \
    --wait
else
  helm install "$RELEASE_NAME" "$CHART_DIR" \
    -n "$NAMESPACE" \
    -f "$CHART_DIR/values-local.yaml" \
    --set global.containers.docker_hub_username="$DOCKER_HUB_USERNAME" \
    --set global.containers.docker_hub_password="$DOCKER_HUB_PASSWORD" \
    --timeout "$TIMEOUT_HELM"
fi

# ---------- wait for pods ----------
info "Waiting for pods to become Ready (up to ${TIMEOUT_PODS}s)..."
CORE_APPS=(code-generator data-manager execution-api execution-environment frontend jobs-api minio mongodb ontology-manager rabbitmq sib-manager)
DEADLINE=$((SECONDS + TIMEOUT_PODS))

for app in "${CORE_APPS[@]}"; do
  while true; do
    if [ $SECONDS -ge $DEADLINE ]; then
      warn "Timeout waiting for $app — continuing"
      break
    fi
    STATUS=$(kubectl get pods -l "app=$app" -n "$NAMESPACE" --no-headers 2>/dev/null \
             | awk '{print $3}' | head -1)
    if [ "$STATUS" = "Running" ]; then
      info "  $app — Running"
      break
    fi
    sleep 5
  done
done

# ---------- wait for sib-manager startup (kaniko build) ----------
info "Waiting for sib-manager to complete startup (kaniko build, ~2-5 min)..."
SIB_DEADLINE=$((SECONDS + 600))
while true; do
  if [ $SECONDS -ge $SIB_DEADLINE ]; then
    warn "Timeout waiting for sib-manager startup — check logs: kubectl logs -l app=sib-manager"
    break
  fi
  if kubectl logs -l app=sib-manager -n "$NAMESPACE" --tail=20 2>/dev/null | grep -q "Application startup complete"; then
    info "sib-manager startup complete!"
    break
  fi
  sleep 10
done

# ---------- rebuild frontend from local source ----------
# The DockerHub image may lack JWT removal for public access
# Build from local source and push to the minikube registry.
if [ -d "$SCRIPT_DIR/services/frontend" ]; then
  info "Building frontend from local source..."
  eval $(minikube docker-env)
  docker build -t localhost:5000/frontend:latest "$SCRIPT_DIR/services/frontend/" >/dev/null 2>&1
  docker push localhost:5000/frontend:latest >/dev/null 2>&1
  kubectl set image deployment/frontend frontend=localhost:5000/frontend:latest -n "$NAMESPACE" 2>/dev/null || true
  kubectl rollout restart deployment/frontend -n "$NAMESPACE" 2>/dev/null || true
  kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  info "frontend rebuilt from local source."
fi

# ---------- rebuild sib-manager from local source ----------
# The DockerHub image may lack bug fixes (binary read mode, response_model, etc.)
# Build from local source and push to the minikube registry.
if [ -d "$SCRIPT_DIR/services/sib-manager" ]; then
  info "Building sib-manager from local source..."
  eval $(minikube docker-env)
  docker build -t localhost:5000/sib-manager:latest "$SCRIPT_DIR/services/sib-manager/" >/dev/null 2>&1
  docker push localhost:5000/sib-manager:latest >/dev/null 2>&1
  kubectl set image deployment/sib-manager sib-manager=localhost:5000/sib-manager:latest -n "$NAMESPACE" 2>/dev/null || true
  kubectl rollout restart deployment/sib-manager -n "$NAMESPACE" 2>/dev/null || true
  kubectl rollout status deployment/sib-manager -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
  info "sib-manager rebuilt from local source."
fi

# ---------- service-api might need image fix for minikube ----------
# In minikube, kubelet can't resolve cluster-internal DNS for the registry.
# The sib-manager sets service-api image to registry.kube-system.svc.cluster.local/service-api:latest
# but kubelet needs localhost:5000/service-api:latest
SA_IMAGE=$(kubectl get deployment service-api -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
if echo "$SA_IMAGE" | grep -q "registry.kube-system.svc.cluster.local"; then
  info "Fixing service-api image reference for minikube..."
  kubectl set image deployment/service-api service-api=localhost:5000/service-api:latest -n "$NAMESPACE"
  kubectl rollout status deployment/service-api -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
fi

# ---------- port-forward ----------
info "Setting up port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1

kubectl port-forward svc/sib-manager  8081:80 -n "$NAMESPACE" >/dev/null 2>&1 &
kubectl port-forward svc/execution-api 8082:80 -n "$NAMESPACE" >/dev/null 2>&1 &
kubectl port-forward svc/service-api   8084:80 -n "$NAMESPACE" >/dev/null 2>&1 &
kubectl port-forward svc/frontend      8080:80 -n "$NAMESPACE" >/dev/null 2>&1 &
sleep 3

# ---------- smoke test ----------
info "Running smoke test..."
SMOKE_OK=true
for url in "http://localhost:8081/health" "http://localhost:8082/health" "http://localhost:8084/health"; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  SVC=$(echo "$url" | sed 's/.*:\([0-9]*\)\/.*/\1/')
  if [ "$HTTP" = "200" ]; then
    info "  port $SVC — healthy"
  else
    warn "  port $SVC — HTTP $HTTP (may need a moment to start)"
    SMOKE_OK=false
  fi
done

echo ""
info "============================================"
info " CincoDeBio deployment complete!"
info "============================================"
info ""
info " Services:"
info "   Frontend:       http://localhost:8080"
info "   SIB Manager:    http://localhost:8081"
info "   Execution API:  http://localhost:8082"
info "   Service API:    http://localhost:8084"
info ""
info " Run tests:"
info "   python3 $SCRIPT_DIR/tests/test_endpoints.py"
info "   bash    $SCRIPT_DIR/tests/test_endpoints.sh"
info "   node    $SCRIPT_DIR/tests/test_endpoints.js"
info ""
info " Stop:"
info "   pkill -f 'kubectl port-forward'"
info "   minikube stop"
info ""
if [ "$SMOKE_OK" = true ]; then
  info "All health checks passed!"
else
  warn "Some health checks failed — services may still be starting."
  warn "Wait a minute and try: curl http://localhost:8081/health"
fi

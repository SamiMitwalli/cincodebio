#!/bin/sh
# ============================================================================
# CincoDeBio All-in-One Entrypoint
# Starts k3s, deploys infrastructure (registry, ingress, cert-manager),
# then deploys the CincoDeBio Helm chart.
# ============================================================================
set -e

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*"; exit 1; }

# ---- Validate environment --------------------------------------------------
[ -z "${DOCKER_HUB_USERNAME:-}" ] && error "DOCKER_HUB_USERNAME is required (-e DOCKER_HUB_USERNAME=...)"
[ -z "${DOCKER_HUB_PASSWORD:-}" ] && error "DOCKER_HUB_PASSWORD is required (-e DOCKER_HUB_PASSWORD=...)"

# ---- Write registries.yaml with DockerHub auth -----------------------------
# Avoids Docker Hub anonymous pull rate limits by authenticating all pulls.
cat > /etc/rancher/k3s/registries.yaml <<REGEOF
mirrors:
  "registry.kube-system.svc.cluster.local":
    endpoint:
      - "http://127.0.0.1:5000"
  "localhost:5000":
    endpoint:
      - "http://127.0.0.1:5000"
  "docker.io":
    endpoint:
      - "https://registry-1.docker.io"
configs:
  "registry-1.docker.io":
    auth:
      username: "${DOCKER_HUB_USERNAME}"
      password: "${DOCKER_HUB_PASSWORD}"
REGEOF

# ---- Prepare cgroups for cgroupv2 (Docker Desktop / modern hosts) -----------
# k3s needs a clean cgroup subtree.  On cgroupv2 hosts the kubepods hierarchy
# must be created before the kubelet starts.
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  info "cgroupv2 detected — preparing cgroup subtree..."
  mkdir -p /sys/fs/cgroup/kubepods
  # Delegate controllers to the kubepods subtree
  cat /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
fi

# ---- Start k3s -------------------------------------------------------------
info "Starting k3s (Kubernetes v1.28)..."
/bin/k3s server \
  --disable=traefik \
  --write-kubeconfig-mode=644 \
  &
K3S_PID=$!

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

info "Waiting for k3s to become ready..."
TRIES=0
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  TRIES=$((TRIES + 1))
  [ "$TRIES" -ge 120 ] && error "k3s did not become ready within 4 minutes"
  sleep 2
done
info "k3s is ready"

# ---- In-cluster container registry -----------------------------------------
info "Deploying in-cluster container registry..."
kubectl apply -f /opt/cincodebio/registry.yaml
kubectl wait --for=condition=Available deployment/registry \
  -n kube-system --timeout=120s 2>/dev/null || warn "Registry not available yet — continuing"

# ---- nginx-ingress controller ----------------------------------------------
info "Installing nginx-ingress controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null 2>&1
helm repo update ingress-nginx >/dev/null 2>&1
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=ClusterIP \
  --set controller.allowSnippetAnnotations=true \
  --set controller.config.ssl-redirect=false \
  --set controller.admissionWebhooks.enabled=false \
  --wait --timeout=3m
info "nginx-ingress ready"

# ---- cert-manager ----------------------------------------------------------
info "Installing cert-manager v1.17.2..."
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1
helm repo update jetstack >/dev/null 2>&1
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.17.2 \
  --set crds.enabled=true --wait --timeout=5m
info "cert-manager ready"

# ---- Pre-deploy secrets ----------------------------------------------------
info "Creating platform secrets..."
kubectl create secret generic cinco-cloud-main-secrets \
  --from-literal=authPublicKey="local-dev-placeholder-key" \
  -n default 2>/dev/null || true

# ---- Deploy CincoDeBio Helm chart -----------------------------------------
info "Deploying CincoDeBio chart..."
helm install cincodebio /opt/cincodebio/chart/ \
  -n default \
  -f /opt/cincodebio/chart/values-local.yaml \
  -f /opt/cincodebio/values-docker.yaml \
  --set global.containers.docker_hub_username="${DOCKER_HUB_USERNAME}" \
  --set global.containers.docker_hub_password="${DOCKER_HUB_PASSWORD}" \
  --timeout 10m
info "Helm chart deployed"

# ---- Populate kaniko Docker-Hub auth PVC -----------------------------------
# The sib-manager creates a PVC called "kaniko-secret" and mounts it at
# /kaniko/.docker inside kaniko build pods.  It is created empty, so kaniko
# pulls are unauthenticated and hit Docker Hub rate limits.  We populate it
# with a config.json containing the DH credentials.
info "Populating kaniko Docker Hub auth..."
DH_AUTH_B64=$(printf '%s:%s' "${DOCKER_HUB_USERNAME}" "${DOCKER_HUB_PASSWORD}" | base64)

# Create the PVC if it doesn't already exist
cat <<PVCEOF | kubectl apply -f - 2>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kaniko-secret
  namespace: default
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Mi
PVCEOF

# Write a pod spec to a tmp file (avoids shell quoting issues in heredocs)
cat > /tmp/kaniko-writer.yaml <<WREOF
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-auth-writer
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: writer
    image: busybox
    command: ["sh", "-c", "printf '{\"auths\":{\"https://index.docker.io/v1/\":{\"auth\":\"%s\"}}}' '${DH_AUTH_B64}' > /secret/config.json && echo done"]
    volumeMounts:
    - name: kaniko-secret
      mountPath: /secret
  volumes:
  - name: kaniko-secret
    persistentVolumeClaim:
      claimName: kaniko-secret
WREOF

kubectl apply -f /tmp/kaniko-writer.yaml 2>/dev/null

# Wait for the writer to finish
kubectl wait --for=condition=Ready pod/kaniko-auth-writer -n default --timeout=120s 2>/dev/null || true
sleep 5
kubectl delete pod kaniko-auth-writer -n default --force 2>/dev/null || true
info "kaniko Docker Hub auth populated"

# ---- Wait for core pods ----------------------------------------------------
info "Waiting for core services to start..."
for app in code-generator data-manager execution-api execution-environment \
           frontend jobs-api minio mongodb ontology-manager rabbitmq sib-manager; do
  kubectl wait --for=condition=Ready pod -l "app=$app" \
    -n default --timeout=300s 2>/dev/null \
    && info "  $app — ready" \
    || warn "  $app — not ready (timeout)"
done

# ---- Wait for sib-manager startup (includes kaniko build) ------------------
info "Waiting for sib-manager startup (kaniko build, ~2-5 min)..."
deadline=$(($(date +%s) + 600))
while true; do
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    warn "Timeout waiting for sib-manager startup"
    warn "Debug: docker exec <container> kubectl logs -l app=sib-manager"
    break
  fi
  if kubectl logs -l app=sib-manager -n default --tail=20 2>/dev/null \
       | grep -q "Application startup complete"; then
    info "sib-manager startup complete!"
    break
  fi
  sleep 10
done

# ---- Fix service-api image reference if needed -----------------------------
# kaniko pushes to registry.kube-system.svc.cluster.local but the containerd
# mirror (registries.yaml) should handle it.  If it still fails, patch to
# localhost:5000.
SA_IMAGE=$(kubectl get deployment service-api -n default \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
if echo "$SA_IMAGE" | grep -q "registry.kube-system.svc.cluster.local"; then
  info "Patching service-api image reference for k3s..."
  kubectl set image deployment/service-api \
    service-api=localhost:5000/service-api:latest -n default 2>/dev/null || true
  kubectl rollout status deployment/service-api \
    -n default --timeout=120s 2>/dev/null || true
fi

# ---- Patch sib-manager bugs (DockerHub image has stale code) ---------------
# Bug 1: cinco_interface.py opens file with 'r' instead of 'rb', causing
#         TypeError on str + bytes concatenation in compute_local_hash().
# Bug 2: external.py uses response_model=UtdSibFilesResponse (plural) on the
#         get-utd-sib-file endpoint instead of UtdSibFileResponse (singular).
SIB_POD=$(kubectl get pods -l app=sib-manager -n default \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$SIB_POD" ]; then
  info "Patching sib-manager source bugs..."
  kubectl create configmap sib-manager-patches \
    --from-file=cinco_interface.py=/opt/cincodebio/patches/cinco_interface.py \
    --from-file=external.py=/opt/cincodebio/patches/external.py \
    -n default --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

  # Check if patch volumes already present (idempotent)
  HAS_PATCH=$(kubectl get deploy sib-manager -n default \
    -o jsonpath='{.spec.template.spec.volumes[?(@.name=="patches")].name}' 2>/dev/null || echo "")
  if [ -z "$HAS_PATCH" ]; then
    PATCH_JSON='{"spec":{"template":{"spec":{"volumes":[{"name":"patches","configMap":{"name":"sib-manager-patches"}}],"containers":[{"name":"sib-manager","volumeMounts":[{"name":"patches","mountPath":"/app/cinco_interface.py","subPath":"cinco_interface.py"},{"name":"patches","mountPath":"/app/external.py","subPath":"external.py"}]}]}}}}'
    kubectl patch deployment sib-manager -n default --type=strategic -p "$PATCH_JSON" 2>/dev/null || true
    kubectl rollout status deployment/sib-manager -n default --timeout=120s 2>/dev/null || true
  fi
fi

# ---- Ready -----------------------------------------------------------------
echo ""
info "============================================"
info " CincoDeBio is ready!"
info "============================================"
info ""
info " Frontend:         http://localhost/app/"
info " Minio Console:    http://localhost/minio-console/"
info ""
info " API paths (via ingress):"
info "   /execution-api/ext/..."
info "   /services-api/ext/..."
info "   /sib-manager/ext/..."
info "   /data-manager/ext/..."
info "   /jobs-api/ext/..."
info ""
info " kubectl:"
info "   docker exec <container> kubectl get pods"
info "   docker exec <container> kubectl logs -l app=sib-manager"
info ""
info " Stop:"
info "   docker stop <container> && docker rm <container>"
info ""

# Keep the container alive — k3s is PID 1's child
wait $K3S_PID

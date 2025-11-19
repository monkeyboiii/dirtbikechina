# Local Single-Node k3s Test Environment

**Purpose**: Test the entire Dirtbikechina k8s migration on a local single-node k3s cluster before provisioning production infrastructure.

**Status**: ✅ **RECOMMENDED FOR PHASE 0 VALIDATION**

---

## Overview

This guide helps you set up a complete test environment on a single machine (local workstation, VM, or single VPS) to validate:

- ✅ All Kubernetes manifests work correctly
- ✅ Security hardening (SealedSecrets, RBAC, NetworkPolicies)
- ✅ CloudNativePG database HA (simulated with 3 instances on 1 node)
- ✅ Observability stack (Prometheus, Grafana, Loki)
- ✅ Application deployments (WordPress, Logto, etc.)
- ✅ CI/CD pipelines and custom image builds
- ✅ Ingress routing and A/B testing configuration

**Benefits**:
- 💰 **Zero additional cost** - test on existing hardware
- 🚀 **Fast iteration** - quick to rebuild and test
- 🎓 **Learn k8s** - hands-on experience without production pressure
- ✅ **Validate everything** - find issues before production deployment

---

## Prerequisites

### Hardware Requirements

**Minimum** (for basic testing):
- 8GB RAM
- 4 CPU cores
- 40GB free disk space
- Ubuntu 22.04 LTS (or similar Linux distro)

**Recommended** (for realistic testing):
- 16GB RAM
- 8 CPU cores
- 100GB free disk space
- SSD storage

### Software Requirements

- Ubuntu 22.04 LTS (or Debian 11+, Fedora 38+, etc.)
- Docker installed (for building custom images)
- Git installed
- Basic Linux command-line knowledge

---

## Quick Start (TL;DR)

```bash
# 1. Install k3s (single node)
curl -sfL https://get.k3s.io | sh -s - server \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb

# 2. Install kubectl (if not already installed)
sudo cp /usr/local/bin/k3s /usr/local/bin/kubectl

# 3. Verify cluster
kubectl get nodes

# 4. Clone repository
git clone <your-repo>
cd dirtbikechina

# 5. Run deployment script
cd cluster
./scripts/deploy.sh --environment dev --profile minimal

# 6. Access services
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000 (admin/prom-operator)
```

---

## Step-by-Step Installation

### Step 1: Install k3s (Single Node)

**On Ubuntu/Debian**:

```bash
# Install k3s without built-in Traefik and ServiceLB (we'll install separately)
curl -sfL https://get.k3s.io | sh -s - server \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb

# Verify installation
sudo systemctl status k3s

# Check node status
kubectl get nodes

# Expected output:
# NAME       STATUS   ROLES                  AGE   VERSION
# your-host  Ready    control-plane,master   1m    v1.28.x+k3s1
```

**Configuration Applied**:
- `--write-kubeconfig-mode=644` - Make kubeconfig readable without sudo
- `--disable=traefik` - We'll install Traefik via Helm for A/B testing support
- `--disable=servicelb` - Not needed for local testing (use port-forward instead)

### Step 2: Set Up kubectl Access

```bash
# k3s automatically installs kubectl at /usr/local/bin/k3s
# Create a symlink for convenience
sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl

# Set KUBECONFIG for current session
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Add to ~/.bashrc for persistence
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

# Verify kubectl works
kubectl version --short
kubectl get pods -A
```

### Step 3: Install Helm (Package Manager)

```bash
# Install Helm 3
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify installation
helm version

# Add required Helm repositories
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add traefik https://traefik.github.io/charts
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts
helm repo update
```

### Step 4: Install Local Storage (Longhorn Alternative)

For single-node testing, use k3s's built-in `local-path` provisioner (simpler than Longhorn):

```bash
# Check if local-path storage class exists
kubectl get storageclass

# Expected output:
# NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer

# No additional installation needed - k3s includes this by default
```

**For production-like testing** (optional), install Longhorn:

```bash
# Install Longhorn
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.5.3/deploy/longhorn.yaml

# Wait for Longhorn to be ready
kubectl wait --for=condition=ready pod -n longhorn-system --all --timeout=300s

# Verify Longhorn storage class
kubectl get storageclass longhorn
```

---

## Deployment Steps

### Phase 1: Infrastructure Setup

#### 1.1 Create Namespaces

```bash
# Navigate to cluster directory
cd ~/dirtbikechina/cluster

# Apply namespace definitions
kubectl apply -f base/namespaces.yaml

# Verify namespaces
kubectl get namespaces
# Expected: prod, stage, dev, test, infra, monitoring, ingress-system
```

#### 1.2 Install SealedSecrets Controller

```bash
# Install SealedSecrets controller
kubectl apply -f base/secrets/sealed-secrets-controller.yaml

# Wait for controller to be ready
kubectl wait --for=condition=ready pod \
  -n kube-system \
  -l name=sealed-secrets-controller \
  --timeout=300s

# Verify installation
kubectl get pods -n kube-system | grep sealed-secrets
```

**Install kubeseal CLI** (for creating sealed secrets):

```bash
# Download kubeseal binary
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz

# Extract and install
tar -xvzf kubeseal-0.24.0-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal

# Verify installation
kubeseal --version
```

#### 1.3 Apply RBAC Policies

```bash
# Apply RBAC for all services
kubectl apply -f base/rbac/wordpress-rbac.yaml
kubectl apply -f base/rbac/database-rbac.yaml
kubectl apply -f base/rbac/app-services-rbac.yaml

# Verify service accounts
kubectl get serviceaccounts -A | grep -E 'wordpress|postgres|mysql|logto'
```

#### 1.4 Apply NetworkPolicies

```bash
# Apply default deny-all policy
kubectl apply -f base/network-policies/00-default-deny.yaml

# Apply database network policies
kubectl apply -f base/network-policies/database-policies.yaml

# Apply application network policies
kubectl apply -f base/network-policies/app-policies.yaml

# Verify network policies
kubectl get networkpolicies -A
```

#### 1.5 Install Observability Stack

**Install kube-prometheus-stack** (Prometheus + Grafana):

```bash
# Create monitoring namespace (if not already created)
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Apply RBAC for monitoring
kubectl apply -f monitoring/kube-prometheus-stack.yaml

# Install kube-prometheus-stack via Helm
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword=admin \
  --wait --timeout=10m

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod \
  -n monitoring \
  --all \
  --timeout=600s
```

**Install Loki** (log aggregation):

```bash
# Install Loki stack
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=10Gi \
  --wait --timeout=5m

# Verify installation
kubectl get pods -n monitoring
```

**Apply ServiceMonitors**:

```bash
# Apply ServiceMonitors for applications
kubectl apply -f monitoring/servicemonitors/app-servicemonitors.yaml

# Verify ServiceMonitors
kubectl get servicemonitors -A
```

**Access Grafana**:

```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Open browser: http://localhost:3000
# Username: admin
# Password: admin (or what you set above)
```

---

### Phase 2: Database Deployment

#### 2.1 Build Custom PostgreSQL Image

```bash
# Navigate to project root
cd ~/dirtbikechina

# Build PostgreSQL image with CJK parser
docker build -f discourse.Dockerfile -t dirtbikechina/postgres:15-cjk .

# Tag for local k3s registry (optional - k3s can use local Docker images)
docker tag dirtbikechina/postgres:15-cjk localhost:5000/postgres:15-cjk

# Verify image
docker images | grep postgres
```

**Import image to k3s** (for k3s to use local Docker image):

```bash
# Save image to tar
docker save dirtbikechina/postgres:15-cjk -o postgres-cjk.tar

# Import to k3s
sudo k3s ctr images import postgres-cjk.tar

# Verify import
sudo k3s crictl images | grep postgres
```

#### 2.2 Install CloudNativePG Operator

```bash
# Install CloudNativePG operator
kubectl apply -f cluster/base/databases/cloudnative-pg-operator.yaml

# Wait for operator to be ready
kubectl wait --for=condition=ready pod \
  -n cnpg-system \
  -l app.kubernetes.io/name=cloudnative-pg \
  --timeout=300s

# Verify installation
kubectl get pods -n cnpg-system
```

#### 2.3 Create Sealed Secrets for Databases

**Create PostgreSQL credentials**:

```bash
# Create secret (plain)
kubectl create secret generic postgres-credentials \
  --namespace infra \
  --from-literal=username=postgres \
  --from-literal=password='MySecurePassword123' \
  --dry-run=client -o yaml > /tmp/postgres-secret.yaml

# Seal the secret
kubeseal -f /tmp/postgres-secret.yaml -w base/secrets/postgres-sealed-secret.yaml

# Apply sealed secret
kubectl apply -f base/secrets/postgres-sealed-secret.yaml

# Verify secret was decrypted
kubectl get secret postgres-credentials -n infra
```

**Create MySQL credentials** (similar process):

```bash
kubectl create secret generic mysql-credentials \
  --namespace infra \
  --from-literal=root-password='MyRootPassword123' \
  --from-literal=database=wordpress \
  --from-literal=username=wordpress \
  --from-literal=password='MyWPPassword123' \
  --dry-run=client -o yaml > /tmp/mysql-secret.yaml

kubeseal -f /tmp/mysql-secret.yaml -w base/secrets/mysql-sealed-secret.yaml
kubectl apply -f base/secrets/mysql-sealed-secret.yaml
```

#### 2.4 Deploy CloudNativePG Cluster

**For single-node testing**, modify `postgres-cnpg-cluster.yaml` to use `local-path` storage:

```bash
# Edit the cluster manifest (or create a dev overlay)
# Change storageClass from 'longhorn-retain' to 'local-path'

# Option 1: Edit directly
kubectl apply -f base/databases/postgres-cnpg-cluster.yaml

# Option 2: Use kustomize overlay (recommended)
# Create environments/dev/postgres-patch.yaml with storage class override
```

**Deploy PostgreSQL cluster**:

```bash
# Apply CloudNativePG cluster
kubectl apply -f base/databases/postgres-cnpg-cluster.yaml

# Watch cluster creation
kubectl get cluster -n infra --watch

# Wait for cluster to be ready (may take 2-5 minutes)
kubectl wait --for=condition=ready cluster/postgres-cluster -n infra --timeout=600s

# Verify all 3 PostgreSQL instances are running
kubectl get pods -n infra -l cnpg.io/cluster=postgres-cluster
```

#### 2.5 Run Discourse CJK Init Job

```bash
# Apply Discourse init job for CloudNativePG
kubectl apply -f base/databases/discourse-init-cnpg-job.yaml

# Watch job progress
kubectl logs -n infra job/discourse-init -f

# Verify job completed successfully
kubectl get job -n infra discourse-init
# STATUS should show 'Complete'

# Check logs for CJK parser smoke tests
kubectl logs -n infra job/discourse-init | grep -A5 "Running CJK parser smoke tests"
# All tests should return 't' (true)
```

#### 2.6 Deploy MySQL

```bash
# Apply MySQL StatefulSet
kubectl apply -f base/databases/mysql-statefulset.yaml

# Wait for MySQL to be ready
kubectl wait --for=condition=ready pod/mysql-0 -n infra --timeout=300s

# Verify MySQL is running
kubectl get pods -n infra -l app=mysql
kubectl logs -n infra mysql-0 --tail=20
```

---

### Phase 3: Application Deployment

#### 3.1 Deploy WordPress (Dev Environment)

**Create WordPress sealed secrets**:

```bash
# WordPress database connection
kubectl create secret generic wordpress-db \
  --namespace dev \
  --from-literal=host=mysql.infra.svc.cluster.local \
  --from-literal=database=wordpress \
  --from-literal=username=wordpress \
  --from-literal=password='MyWPPassword123' \
  --dry-run=client -o yaml > /tmp/wordpress-db-secret.yaml

kubeseal -f /tmp/wordpress-db-secret.yaml -w base/secrets/wordpress-db-sealed-secret.yaml
kubectl apply -f base/secrets/wordpress-db-sealed-secret.yaml
```

**Deploy WordPress**:

```bash
# Deploy WordPress to dev namespace
kubectl apply -f base/apps/wordpress-deployment.yaml -n dev

# Wait for WordPress to be ready
kubectl wait --for=condition=ready pod \
  -n dev \
  -l app=wordpress \
  --timeout=300s

# Verify deployment
kubectl get pods -n dev
kubectl logs -n dev -l app=wordpress --tail=20
```

**Access WordPress** (via port-forward for local testing):

```bash
# Port-forward WordPress service
kubectl port-forward -n dev svc/wordpress 8080:80

# Open browser: http://localhost:8080
# Complete WordPress installation wizard
```

#### 3.2 Deploy Additional Applications (Optional)

Follow similar patterns for:
- **Logto**: Authentication service
- **Wanderer**: Trail tracking (Svelte + PocketBase)
- **PHPMyAdmin**: Database management

---

### Phase 4: Ingress & A/B Testing

#### 4.1 Install Traefik Ingress Controller

```bash
# Create ingress-system namespace
kubectl create namespace ingress-system --dry-run=client -o yaml | kubectl apply -f -

# Install Traefik via Helm
helm install traefik traefik/traefik \
  --namespace ingress-system \
  --set ports.web.nodePort=30080 \
  --set ports.websecure.nodePort=30443 \
  --set service.type=NodePort \
  --wait --timeout=5m

# Verify Traefik installation
kubectl get pods -n ingress-system
kubectl get svc -n ingress-system
```

#### 4.2 Apply Ingress Routes (with A/B Testing)

**For local testing**, modify IngressRoutes to use `localhost`:

```bash
# Create test IngressRoute for WordPress
cat <<EOF | kubectl apply -f -
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: wordpress-test
  namespace: dev
spec:
  entryPoints:
    - web
  routes:
    - match: Host(\`localhost\`) || Host(\`127.0.0.1\`)
      kind: Rule
      services:
        - name: wordpress
          port: 80
EOF

# Verify IngressRoute
kubectl get ingressroute -n dev
```

**Access via Traefik**:

```bash
# Get Traefik NodePort
kubectl get svc -n ingress-system traefik -o jsonpath='{.spec.ports[?(@.name=="web")].nodePort}'

# Access WordPress via Traefik
# http://localhost:<NodePort>
# Example: http://localhost:30080
```

---

## Testing & Validation

### 1. Database HA Testing

**Test PostgreSQL automatic failover**:

```bash
# Get current primary pod
PRIMARY_POD=$(kubectl get pods -n infra -l cnpg.io/cluster=postgres-cluster,role=primary -o jsonpath='{.items[0].metadata.name}')

echo "Current primary: $PRIMARY_POD"

# Delete primary pod to trigger failover
kubectl delete pod -n infra $PRIMARY_POD

# Watch failover (should complete in <30 seconds)
kubectl get cluster -n infra postgres-cluster --watch

# Verify new primary was elected
kubectl get pods -n infra -l cnpg.io/cluster=postgres-cluster,role=primary
```

**Expected Result**: New primary elected within 30 seconds, applications continue working.

### 2. CJK Parser Testing

**Test Japanese/Korean text search**:

```bash
# Connect to PostgreSQL
kubectl exec -it -n infra postgres-cluster-1 -- psql -U postgres -d discourse

# Run CJK smoke tests
SELECT to_tsvector('のび太 野比大雄') @@ plainto_tsquery('のび太');
-- Should return: t (true)

SELECT to_tsvector('大韩민국개인정보') @@ plainto_tsquery('민국개인');
-- Should return: t (true)

# Exit psql
\q
```

### 3. Security Testing

**Test NetworkPolicy enforcement**:

```bash
# Try to access PostgreSQL from a non-allowed pod
kubectl run test-pod --image=postgres:15 -n dev --rm -it -- bash

# Inside test pod, try to connect to PostgreSQL
psql -h postgres-cluster-rw.infra.svc.cluster.local -U postgres
# Should FAIL (connection timeout) due to NetworkPolicy

# Try from an allowed pod (e.g., WordPress)
kubectl exec -it -n dev <wordpress-pod> -- nc -zv postgres-cluster-rw.infra.svc.cluster.local 5432
# Should SUCCEED if NetworkPolicy allows WordPress → PostgreSQL
```

**Test RBAC**:

```bash
# Test ServiceAccount permissions
kubectl auth can-i get secrets --as=system:serviceaccount:dev:wordpress -n dev
# Should return: yes

kubectl auth can-i delete secrets --as=system:serviceaccount:dev:wordpress -n dev
# Should return: no (least privilege)
```

### 4. Observability Testing

**View Grafana Dashboards**:

```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Open http://localhost:3000
# Login: admin / admin

# Check dashboards:
# - Kubernetes / Compute Resources / Namespace (Pods)
# - Node Exporter / Nodes
# - PostgreSQL (if CloudNativePG ServiceMonitor is working)
```

**Query Prometheus**:

```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

# Open http://localhost:9090
# Example queries:
# - container_memory_usage_bytes
# - up{namespace="infra"}
```

**View Loki Logs**:

```bash
# Access Grafana → Explore → Loki datasource
# Example query: {namespace="dev", app="wordpress"}
```

---

## Single-Node Adaptations

### Differences from Production 3-Node Setup

| Component | 3-Node Production | Single-Node Test |
|-----------|-------------------|------------------|
| k3s Installation | `--cluster-init` (3 masters) | Single server mode |
| Storage | Longhorn (replicated) | `local-path` (no replication) |
| PostgreSQL HA | 3 instances on 3 nodes | 3 instances on 1 node (simulated HA) |
| Ingress | LoadBalancer / MetalLB | NodePort or port-forward |
| DNS | Real domain (`*.dirtbikechina.com`) | `localhost` or `/etc/hosts` |
| SSL Certificates | cert-manager + Let's Encrypt | Self-signed or no SSL |
| Resource Limits | Production values | Reduced for testing |

### Resource Adjustments

**Reduce resource requests/limits** for single-node testing:

```yaml
# Example: WordPress deployment adjustment
resources:
  requests:
    memory: "128Mi"  # Reduced from 256Mi
    cpu: "50m"       # Reduced from 100m
  limits:
    memory: "512Mi"  # Reduced from 1Gi
    cpu: "250m"      # Reduced from 500m
```

**PostgreSQL instances**: Can test with 1 instance instead of 3 for very resource-constrained environments:

```yaml
# postgres-cnpg-cluster.yaml (for minimal testing)
spec:
  instances: 1  # Reduced from 3 (loses HA testing)
```

---

## Cleanup & Troubleshooting

### Complete Cleanup (Reset Everything)

```bash
# Stop and remove k3s completely
sudo /usr/local/bin/k3s-uninstall.sh

# Remove k3s data
sudo rm -rf /var/lib/rancher/k3s
sudo rm -rf /etc/rancher/k3s

# Remove custom images
docker rmi dirtbikechina/postgres:15-cjk

# Reinstall k3s (fresh start)
curl -sfL https://get.k3s.io | sh -s - server --write-kubeconfig-mode=644
```

### Common Issues

**1. Pods stuck in Pending**:

```bash
# Check events
kubectl describe pod <pod-name> -n <namespace>

# Common causes:
# - Insufficient resources (CPU/memory)
# - Storage provisioner not ready
# - Node taints (shouldn't apply to single-node)
```

**2. NetworkPolicy blocking legitimate traffic**:

```bash
# Temporarily disable NetworkPolicy to test
kubectl delete networkpolicy <policy-name> -n <namespace>

# Or: Label-based exclusion for testing
kubectl label namespace dev network-policy-disabled=true
```

**3. SealedSecret not decrypting**:

```bash
# Check sealed-secrets-controller logs
kubectl logs -n kube-system -l name=sealed-secrets-controller

# Verify controller is running
kubectl get pods -n kube-system | grep sealed-secrets

# Re-create sealed secret if needed
```

**4. PostgreSQL cluster not starting**:

```bash
# Check CloudNativePG operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg

# Check cluster events
kubectl describe cluster -n infra postgres-cluster

# Common issues:
# - Storage class not found (use 'local-path' for single-node)
# - Insufficient resources
# - Image pull errors
```

**5. Image not found**:

```bash
# For local images, ensure they're imported to k3s:
docker save <image> -o image.tar
sudo k3s ctr images import image.tar

# Or push to a registry and pull from there
```

---

## Next Steps After Local Testing

### Validation Checklist

Before proceeding to production 3-node deployment, ensure:

- [ ] All manifests apply without errors
- [ ] PostgreSQL cluster starts and CJK smoke tests pass
- [ ] Applications deploy successfully (at least WordPress)
- [ ] NetworkPolicies don't block legitimate traffic
- [ ] RBAC permissions work (ServiceAccounts can access what they need)
- [ ] SealedSecrets encrypt/decrypt correctly
- [ ] Grafana dashboards show metrics
- [ ] Loki aggregates logs
- [ ] PostgreSQL failover works (if testing with 3 instances)
- [ ] Port-forwarding to applications works
- [ ] No critical alerts in Prometheus

### Transition to Production

Once local testing is successful:

1. **Provision 3 VPS nodes** (8GB RAM, 4 CPU each recommended)
2. **Install 3-master k3s cluster** (follow `cluster/k3s-3-master-setup.md`)
3. **Replace `local-path` with Longhorn** (distributed storage)
4. **Configure real DNS** (point `*.dirtbikechina.com` to cluster)
5. **Install cert-manager** (automatic SSL certificates)
6. **Update resource limits** (use production values)
7. **Deploy to prod namespace** (instead of dev)
8. **Follow Phase 1-3 timeline** (from `cluster/evaluation.md`)

---

## Reference Commands

### Quick Access Commands

```bash
# View all pods across all namespaces
kubectl get pods -A

# View PostgreSQL cluster status
kubectl get cluster -n infra

# View all services
kubectl get svc -A

# Port-forward Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Port-forward WordPress
kubectl port-forward -n dev svc/wordpress 8080:80

# View logs for a pod
kubectl logs -n <namespace> <pod-name> -f

# Execute command in pod
kubectl exec -it -n <namespace> <pod-name> -- /bin/bash

# View events (for debugging)
kubectl get events -A --sort-by='.lastTimestamp'

# View resource usage
kubectl top nodes
kubectl top pods -A
```

### Useful Aliases

Add to `~/.bashrc`:

```bash
alias k='kubectl'
alias kgp='kubectl get pods -A'
alias kgs='kubectl get svc -A'
alias kgn='kubectl get nodes'
alias kdp='kubectl describe pod'
alias klf='kubectl logs -f'
```

---

## Cost Analysis

### Single-Node Testing Costs

**If using existing hardware**: **$0** (zero cost)

**If renting a VPS for testing**:
- **Minimum**: $5-10/month (Hetzner, Vultr, DigitalOcean)
  - 4GB RAM, 2 CPU, 80GB SSD
  - Sufficient for basic testing

- **Recommended**: $20-40/month
  - 8GB RAM, 4 CPU, 160GB SSD
  - Comfortable for realistic testing

**Time Investment**:
- Initial setup: 2-4 hours
- Learning k8s: 1-2 weeks (if new to k8s)
- Testing all components: 1 week

**ROI**: Invaluable for catching issues before production deployment.

---

## Documentation References

- **k3s Documentation**: https://docs.k3s.io/
- **CloudNativePG Documentation**: https://cloudnative-pg.io/documentation/
- **Traefik Documentation**: https://doc.traefik.io/traefik/
- **SealedSecrets**: https://github.com/bitnami-labs/sealed-secrets
- **Prometheus Operator**: https://prometheus-operator.dev/

---

**Document Version**: 1.0
**Last Updated**: 2025-11-19
**Status**: ✅ **READY FOR USE**

**Questions?** Review the main migration documentation:
- `cluster/evaluation.md` - Migration strategy
- `cluster/PHASE-0-READINESS.md` - Deployment checklist
- `cluster/expert-panel-review.md` - Panel approval and recommendations

# Kubernetes (k3s) Cluster Configuration

This directory contains Kubernetes manifests and documentation for migrating the Dirtbikechina platform from Docker Compose to a k3s cluster.

## Directory Structure

```
cluster/
├── README.md                    # This file
├── evaluation.md                # Detailed migration evaluation and strategy
│
├── base/                        # Base Kubernetes manifests
│   ├── namespaces.yaml         # Namespace definitions (prod, stage, dev, test, infra)
│   ├── databases/              # Database StatefulSets and init jobs
│   │   ├── postgres-statefulset.yaml
│   │   ├── mysql-statefulset.yaml
│   │   └── discourse-init-job.yaml
│   ├── apps/                   # Application deployments
│   │   └── wordpress-deployment.yaml
│   ├── ingress/                # Ingress routes with A/B testing
│   │   └── traefik-ingress-routes.yaml
│   ├── configmaps/             # ConfigMaps (environment configs)
│   ├── secrets/                # Secret templates (never commit actual secrets!)
│   └── storage/                # PVC templates
│
├── environments/                # Environment-specific overlays (Kustomize)
│   ├── prod/                   # Production environment
│   ├── stage/                  # Staging environment
│   ├── dev/                    # Development environment
│   └── test/                   # Testing environment
│
├── backup/                      # Backup configurations
│   ├── postgres-backup-cronjob.yaml
│   ├── local/                  # Local backup scripts
│   └── offsite/                # Off-site backup configs
│
└── scripts/                     # Utility scripts
    ├── deploy.sh               # Deployment automation
    ├── rollback.sh             # Rollback script
    └── blue-green-switch.sh    # Blue-green traffic switching
```

## Quick Start

### 🚀 New to k8s? Start with Local Testing!

**Before deploying to production**, we **strongly recommend** testing on a local single-node k3s cluster:

👉 **See `LOCAL-TEST-ENVIRONMENT.md`** for complete step-by-step instructions

**Benefits**:
- ✅ Zero cost (use existing hardware)
- ✅ Learn k8s safely
- ✅ Validate all manifests work
- ✅ Test security, HA, observability
- ✅ Find issues before production

**Quick Local Setup**:
```bash
# Install k3s (single node)
curl -sfL https://get.k3s.io | sh -s - server --write-kubeconfig-mode=644

# Deploy and test
cd cluster
./scripts/deploy.sh --environment dev --profile minimal
```

---

### Production Prerequisites

For **production 3-node deployment** (after successful local testing):

1. **k3s cluster** with 3 master nodes (HA control plane)
2. **kubectl** configured to access the cluster
3. **Longhorn** storage provider installed (or alternative like NFS)
4. **Traefik** ingress controller with A/B testing support
5. **cert-manager** for automatic SSL certificates
6. **CloudNativePG operator** for PostgreSQL HA
7. **SealedSecrets controller** for encrypted secret management

### Installation Steps

#### 1. Create Namespaces

```bash
kubectl apply -f base/namespaces.yaml
```

#### 2. Create Secrets

**Important**: Never commit actual secrets to git!

```bash
# PostgreSQL credentials
kubectl create secret generic postgres-credentials \
  --namespace infra \
  --from-literal=username=postgres \
  --from-literal=password='your-secure-password'

# Discourse database credentials
kubectl create secret generic discourse-credentials \
  --namespace infra \
  --from-literal=db-password='discourse-password'

# MySQL credentials
kubectl create secret generic mysql-credentials \
  --namespace infra \
  --from-literal=username=wordpress \
  --from-literal=password='mysql-password' \
  --from-literal=root-password='mysql-root-password'

# Copy secrets to all namespaces (prod, stage, dev, test)
for ns in prod stage dev test; do
  kubectl get secret mysql-credentials -n infra -o yaml | \
    sed "s/namespace: infra/namespace: $ns/" | \
    kubectl apply -f -
done
```

#### 3. Deploy Databases

```bash
# Deploy PostgreSQL with custom CJK image
kubectl apply -f base/databases/postgres-statefulset.yaml

# Wait for PostgreSQL to be ready
kubectl wait --for=condition=ready pod -l app=postgres -n infra --timeout=300s

# Run Discourse initialization job
kubectl apply -f base/databases/discourse-init-job.yaml

# Check init job logs
kubectl logs -f job/discourse-init -n infra

# Deploy MySQL
kubectl apply -f base/databases/mysql-statefulset.yaml
```

#### 4. Deploy Applications

```bash
# Deploy to production
kubectl apply -f base/apps/wordpress-deployment.yaml

# Deploy other apps (Discourse, Logto, Wanderer)
# kubectl apply -f base/apps/discourse-deployment.yaml
# kubectl apply -f base/apps/logto-deployment.yaml
# kubectl apply -f base/apps/wanderer-deployment.yaml
```

#### 5. Configure Ingress

```bash
# Create Let's Encrypt ClusterIssuer
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
EOF

# Deploy ingress routes
kubectl apply -f base/ingress/traefik-ingress-routes.yaml
```

#### 6. Verify Deployment

```bash
# Check all pods
kubectl get pods -A

# Check services
kubectl get svc -A

# Check ingress routes
kubectl get ingressroute -A

# Check certificates
kubectl get certificate -A

# Test internal connectivity
kubectl run -it --rm debug --image=busybox --restart=Never -- sh
# Inside container:
# nslookup postgres-primary.infra.svc.cluster.local
# nslookup mysql-primary.infra.svc.cluster.local
```

## Blue-Green Deployment

### Deploy Green Version

```bash
# 1. Deploy green version (example: WordPress)
cat base/apps/wordpress-deployment.yaml | \
  sed 's/blue/green/g' | \
  sed 's/replicas: 2/replicas: 2/g' | \
  kubectl apply -f -

# 2. Test green version internally
kubectl port-forward svc/wordpress-green 8080:80 -n prod
curl http://localhost:8080

# 3. Switch traffic to green
kubectl patch service wordpress -n prod -p '{"spec":{"selector":{"version":"green"}}}'

# 4. Monitor for issues
kubectl logs -f -l app=wordpress,version=green -n prod

# 5. If successful, remove blue deployment
kubectl delete deployment wordpress-blue -n prod

# 6. If issues, instant rollback
kubectl patch service wordpress -n prod -p '{"spec":{"selector":{"version":"blue"}}}'
```

### Automated Blue-Green Script

```bash
#!/bin/bash
# scripts/blue-green-switch.sh

APP_NAME=$1
NAMESPACE=${2:-prod}

if [ -z "$APP_NAME" ]; then
  echo "Usage: $0 <app-name> [namespace]"
  exit 1
fi

# Get current version
CURRENT_VERSION=$(kubectl get service $APP_NAME -n $NAMESPACE -o jsonpath='{.spec.selector.version}')

# Determine new version
if [ "$CURRENT_VERSION" == "blue" ]; then
  NEW_VERSION="green"
else
  NEW_VERSION="blue"
fi

echo "Switching $APP_NAME from $CURRENT_VERSION to $NEW_VERSION in $NAMESPACE"

# Patch service selector
kubectl patch service $APP_NAME -n $NAMESPACE -p "{\"spec\":{\"selector\":{\"version\":\"$NEW_VERSION\"}}}"

echo "Traffic switched to $NEW_VERSION"
echo "Monitor with: kubectl logs -f -l app=$APP_NAME,version=$NEW_VERSION -n $NAMESPACE"
echo "Rollback with: kubectl patch service $APP_NAME -n $NAMESPACE -p '{\"spec\":{\"selector\":{\"version\":\"$CURRENT_VERSION\"}}}'"
```

## A/B Testing (30% Traffic to Stage)

The Traefik IngressRoute in `base/ingress/traefik-ingress-routes.yaml` is pre-configured for A/B testing:

- **70% of traffic** → Production environment
- **30% of traffic** → Staging environment

### Enable A/B Testing

```bash
# Deploy staging environment
kubectl apply -k environments/stage/

# Apply A/B testing ingress route
kubectl apply -f base/ingress/traefik-ingress-routes.yaml
```

### Monitor A/B Test Results

```bash
# Check traffic distribution (requires Prometheus)
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Query:
# rate(traefik_service_requests_total{service=~".*wordpress.*"}[5m])
```

### Disable A/B Testing (100% to Prod)

Edit `base/ingress/traefik-ingress-routes.yaml` and remove the stage service from the weighted services list, or comment out the A/B testing route and uncomment the production-only route.

## Database Backups

### On-Site Backups (Longhorn Snapshots)

```bash
# Install Velero for cluster-level backups
velero install \
  --provider aws \
  --bucket dirtbikechina-k8s-backups \
  --secret-file ./aws-credentials \
  --use-volume-snapshots=true

# Create daily backup schedule
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --include-namespaces prod,infra
```

### Off-Site Backups (CronJob)

```bash
# Create off-site backup credentials secret
kubectl create secret generic offsite-backup-credentials \
  --namespace infra \
  --from-file=rclone.conf=./rclone.conf

# Deploy backup CronJobs
kubectl apply -f backup/postgres-backup-cronjob.yaml
```

### Manual Backup

```bash
# PostgreSQL
kubectl exec -n infra postgres-0 -- pg_dumpall -U postgres | gzip > backup-$(date +%Y%m%d).sql.gz

# MySQL
kubectl exec -n infra mysql-0 -- mysqldump -u root -p'password' --all-databases | gzip > mysql-backup-$(date +%Y%m%d).sql.gz
```

### Restore from Backup

```bash
# PostgreSQL
gunzip < backup-20250117.sql.gz | kubectl exec -i -n infra postgres-0 -- psql -U postgres

# MySQL
gunzip < mysql-backup-20250117.sql.gz | kubectl exec -i -n infra mysql-0 -- mysql -u root -p'password'
```

## Scaling

### Manual Scaling

```bash
# Scale WordPress to 5 replicas
kubectl scale deployment wordpress-blue -n prod --replicas=5

# Scale down
kubectl scale deployment wordpress-blue -n prod --replicas=2
```

### Horizontal Pod Autoscaler (HPA)

```bash
# Create HPA based on CPU usage
kubectl autoscale deployment wordpress-blue -n prod \
  --min=2 --max=10 --cpu-percent=70
```

## Monitoring

### View Logs

```bash
# Tail logs for all WordPress pods
kubectl logs -f -l app=wordpress -n prod

# Logs for specific pod
kubectl logs -f wordpress-blue-<pod-id> -n prod

# Previous container logs (after restart)
kubectl logs --previous wordpress-blue-<pod-id> -n prod
```

### Resource Usage

```bash
# Node resource usage
kubectl top nodes

# Pod resource usage
kubectl top pods -n prod

# Detailed pod metrics
kubectl describe pod <pod-name> -n prod
```

### Dashboard Access

```bash
# Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# Traefik Dashboard
kubectl port-forward -n kube-system svc/traefik 9000:9000

# Access http://localhost:9000/dashboard/
```

## Troubleshooting

### Pod Not Starting

```bash
# Describe pod to see events
kubectl describe pod <pod-name> -n prod

# Check pod logs
kubectl logs <pod-name> -n prod

# Check previous logs if crashed
kubectl logs --previous <pod-name> -n prod
```

### Database Connection Issues

```bash
# Test PostgreSQL connectivity
kubectl run -it --rm psql-test --image=postgres:15 --restart=Never -- \
  psql -h postgres-primary.infra.svc.cluster.local -U postgres

# Test MySQL connectivity
kubectl run -it --rm mysql-test --image=mysql:latest --restart=Never -- \
  mysql -h mysql-primary.infra.svc.cluster.local -u root -p
```

### Ingress/SSL Issues

```bash
# Check certificate status
kubectl get certificate -A
kubectl describe certificate <cert-name> -n <namespace>

# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager

# Check Traefik logs
kubectl logs -n kube-system deploy/traefik
```

### Storage Issues

```bash
# Check PVCs
kubectl get pvc -A

# Check Longhorn volumes
kubectl get volumes -n longhorn-system

# Describe PVC
kubectl describe pvc <pvc-name> -n <namespace>
```

## Migration from Docker Compose

### Data Migration Process

1. **Export data from Docker Compose**:

```bash
# PostgreSQL
docker exec postgres pg_dumpall -U postgres > postgres-export.sql

# MySQL
docker exec mysql mysqldump -u root -p --all-databases > mysql-export.sql

# WordPress files
tar czf wordpress-files.tar.gz ./wordpress/

# Discourse shared directory
tar czf discourse-shared.tar.gz /var/discourse/shared/
```

2. **Import data to Kubernetes**:

```bash
# PostgreSQL
kubectl cp postgres-export.sql infra/postgres-0:/tmp/
kubectl exec -n infra postgres-0 -- psql -U postgres < /tmp/postgres-export.sql

# MySQL
kubectl cp mysql-export.sql infra/mysql-0:/tmp/
kubectl exec -n infra mysql-0 -- mysql -u root -p < /tmp/mysql-export.sql

# WordPress files (requires RWX PVC)
kubectl cp wordpress-files.tar.gz prod/wordpress-blue-<pod-id>:/tmp/
kubectl exec -n prod wordpress-blue-<pod-id> -- tar xzf /tmp/wordpress-files.tar.gz -C /var/www/html/
```

3. **Verify data integrity**:

```bash
# Check database row counts
kubectl exec -n infra postgres-0 -- psql -U postgres discourse -c "SELECT COUNT(*) FROM topics;"
kubectl exec -n infra mysql-0 -- mysql -u root -p wordpress -e "SELECT COUNT(*) FROM wp_posts;"
```

## Custom Images

### Build Custom PostgreSQL Image

```bash
# From repository root
cd submodules/pg_cjk_parser/
docker build -f ../../discourse.Dockerfile -t dirtbikechina/postgres:15-cjk .

# Push to registry (Docker Hub, Harbor, etc.)
docker push dirtbikechina/postgres:15-cjk

# Or save to tar for manual import on k3s nodes
docker save dirtbikechina/postgres:15-cjk | gzip > postgres-cjk.tar.gz
scp postgres-cjk.tar.gz worker-1:/tmp/
ssh worker-1 'sudo k3s ctr images import /tmp/postgres-cjk.tar.gz'
```

### Discourse Image (HTTP Mode)

Discourse needs to be modified to expose HTTP port instead of Unix socket for Kubernetes compatibility.

**In Discourse `app.yml`**, change:
```yaml
templates:
  - "templates/web.template.yml"       # Use this (HTTP)
  # - "templates/web.socketed.template.yml"  # Don't use this (Unix socket)
```

Then rebuild Discourse container and expose port 3000.

## Best Practices

1. **Always test in dev/stage before prod**
2. **Use blue-green for zero-downtime deployments**
3. **Monitor metrics during traffic switches**
4. **Keep backups of both on-site and off-site**
5. **Test restore procedures regularly**
6. **Use resource limits to prevent resource exhaustion**
7. **Use namespaces for environment isolation**
8. **Never commit secrets to git** (use Sealed Secrets or external secret managers)
9. **Label everything** for easy filtering and selection
10. **Document custom configurations**

## Useful Commands

```bash
# Get all resources in namespace
kubectl get all -n prod

# Port forward for local testing
kubectl port-forward svc/wordpress 8080:80 -n prod

# Execute command in pod
kubectl exec -it <pod-name> -n prod -- /bin/bash

# Copy files to/from pod
kubectl cp local-file.txt prod/<pod-name>:/tmp/
kubectl cp prod/<pod-name>:/tmp/file.txt ./local-file.txt

# Watch pod status
kubectl get pods -n prod --watch

# Delete all pods in deployment (rolling restart)
kubectl rollout restart deployment/wordpress-blue -n prod

# View rollout history
kubectl rollout history deployment/wordpress-blue -n prod

# Rollback to previous version
kubectl rollout undo deployment/wordpress-blue -n prod
```

## Additional Resources

- [k3s Documentation](https://docs.k3s.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Traefik Kubernetes Ingress](https://doc.traefik.io/traefik/providers/kubernetes-ingress/)
- [Longhorn Documentation](https://longhorn.io/docs/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Velero Backup & Restore](https://velero.io/docs/)

## Support

For issues or questions:
1. Check `evaluation.md` for architecture details
2. Review Kubernetes events: `kubectl get events -n <namespace>`
3. Check pod logs: `kubectl logs <pod-name> -n <namespace>`
4. Consult official documentation for specific components

---

**Last Updated**: 2025-11-17
**Status**: Migration Planning Phase

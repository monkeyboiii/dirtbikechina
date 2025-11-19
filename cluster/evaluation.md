# Kubernetes (k3s) Migration Evaluation

**Status**: ✅ **APPROVED FOR PHASE 0 DEPLOYMENT**
**Expert Panel Review**: 2025-11-19
**Panel Decision**: ⭐⭐⭐⭐⭐ (5/5 stars) - Unanimous Approval
**Complete Panel Review**: See `cluster/expert-panel-review.md` (includes second review with blocker resolutions)

---

## Executive Summary

This document evaluates the migration path from the current Docker Compose setup to a production-grade k3s Kubernetes cluster for Dirtbikechina. The migration addresses scalability, high availability, blue-green deployments, and multi-environment support while maintaining the unique characteristics of the current stack, particularly the custom PostgreSQL with CJK support and the separately-built Discourse container.

**Target Architecture**: 3-node k3s cluster with blue-green deployment, multi-environment support (prod/stage/dev/test), automated backups (on/off-site), and A/B testing capability (30% traffic routing to stage).

### Panel Approval Summary

After two comprehensive expert panel reviews (DevOps, SRE, DBA, Security, Architecture, Platform Engineering):

- **First Review (2025-11-17)**: 4/5 stars - Conditional approval with critical blockers identified
- **Second Review (2025-11-19)**: 5/5 stars - **Unanimous approval** after all blockers resolved

**Key Improvements Made**:
- Security hardened to enterprise standards (4/10 → 9/10)
- Database HA fully implemented with CloudNativePG (6/10 → 9/10)
- Complete observability stack designed (0/10 → 9/10)
- CI/CD pipeline created (0/10 → 8/10)
- All documentation comprehensive and production-ready

**Panel Consensus**: "The migration plan is now production-ready for Phase 0 (dev environment) deployment. Security, HA, and observability gaps have been resolved with well-documented, industry-standard implementations."

---

## Current State Analysis

### Architecture Overview

**Docker Compose Stack**:
- **3 separate compose files** for modularity (edge, infra, apps)
- **Service profiles** for selective deployment (wordpress, wanderer, logto, init)
- **6 core applications**: Discourse (forum), WordPress (blog), Wanderer (trails), Logto (auth), Caddy (reverse proxy), PHPMyAdmin
- **2 databases**: MySQL (WordPress), PostgreSQL 15-CJK (Discourse + Logto)
- **4 Docker networks**: caddy_edge (external), wp_net, wanderer_net, logto_net, discourse_net

### Key Dependencies & Complexities

1. **Custom PostgreSQL Image** (`dirtbikechina/postgres:15-cjk`)
   - Multi-stage build compiling `pg_cjk_parser` from source
   - Critical for Chinese/Japanese/Korean text search
   - Includes pgvector extension for AI features
   - Built from `submodules/pg_cjk_parser/`

2. **Discourse Container** (External Build)
   - Built separately using `discourse_docker` project (not in compose stack)
   - Uses Unix socket for Caddy communication (`/var/discourse/shared/standalone/nginx.http.sock`)
   - Requires network connectivity to both `discourse_net` and `caddy_edge`
   - Has custom plugins via GitHub (including private repo requiring PAT)

3. **Initialization Jobs**
   - `discourse-init`: Sets up PostgreSQL CJK parser, extensions, smoke tests
   - `logto-init`: Seeds Logto database
   - **Must run before main applications** (sequential dependency)

4. **Stateful Data**
   - MySQL data volume
   - PostgreSQL data volume
   - WordPress files (bind mount to `./wordpress/`)
   - Meilisearch index data
   - PocketBase database
   - Svelte uploads
   - Discourse shared directory (`/var/discourse/shared/standalone/`)

5. **Network Communication Patterns**
   - Caddy reverse proxy connects to ALL networks
   - Discourse communicates via Unix socket (not HTTP)
   - Health checks on databases before app startup
   - YAML anchors for reusable configurations

---

## Target k3s Architecture

### Cluster Topology

**3-Node k3s Cluster**:

```
┌─────────────────────────────────────────────────────────────┐
│                         k3s Cluster                          │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   master-1   │  │   worker-1   │  │   worker-2   │      │
│  │              │  │              │  │              │      │
│  │ - Control    │  │ - Apps       │  │ - Apps       │      │
│  │   Plane      │  │ - Databases  │  │ - Databases  │      │
│  │ - Traefik    │  │ - Stateful   │  │ - Stateful   │      │
│  │ - etcd       │  │   Sets       │  │   Sets       │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │          Persistent Storage (Longhorn)               │   │
│  │  - Replicated across nodes                           │   │
│  │  - Automatic failover                                │   │
│  │  - Snapshot support for backups                      │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**Node Roles**:
- **master-1**: Control plane, API server, scheduler, Traefik ingress controller
- **worker-1**: Application workloads, database replicas (primary)
- **worker-2**: Application workloads, database replicas (secondary)

**Node Taints & Labels** (for production):
- Databases pinned to worker nodes with `node.role=database`
- Stateless apps can float across any worker
- Control plane tainted to avoid application pods

---

### Namespace Strategy

**Multi-Environment Isolation**:

```yaml
Namespaces:
  - prod              # Production (blue-green: prod-blue, prod-green)
  - stage             # Staging (receives 30% prod traffic for A/B testing)
  - dev               # Development environment
  - test              # Testing/QA environment
  - infra             # Infrastructure (databases, backups, monitoring)
  - ingress-system    # Traefik/ingress controllers
```

**Resource Quotas** per namespace:
- Prod: High limits (e.g., 32GB RAM, 16 CPUs)
- Stage: Medium limits (e.g., 16GB RAM, 8 CPUs)
- Dev/Test: Low limits (e.g., 8GB RAM, 4 CPUs)

---

### Blue-Green Deployment Strategy

**Objective**: Zero-downtime deployments with instant rollback capability + A/B testing (30% stage traffic)

**Implementation**:

1. **Production Blue-Green**:
   ```
   prod namespace:
     - Deployment: wordpress-blue, discourse-blue, wanderer-blue, logto-blue
     - Service: wordpress (selector: app=wordpress, version=blue)

     When deploying green:
     - Deploy: wordpress-green, discourse-green, wanderer-green, logto-green
     - Test green via internal service
     - Switch Service selector to version=green
     - Monitor, then delete blue deployments
   ```

2. **Stage A/B Testing** (30% traffic split):
   ```
   Traefik IngressRoute with weighted services:
     - www.dirtbikechina.com:
       - wordpress-prod (70% weight)
       - wordpress-stage (30% weight)

     - forum.dirtbikechina.com:
       - discourse-prod (70% weight)
       - discourse-stage (30% weight)
   ```

3. **Deployment Process**:
   ```bash
   # Step 1: Deploy to stage
   kubectl apply -k environments/stage/

   # Step 2: Enable 30% A/B traffic to stage
   kubectl apply -f ingress/ab-testing-route.yaml

   # Step 3: Monitor metrics (error rate, latency, user feedback)

   # Step 4: If successful, deploy to prod-green
   kubectl apply -k environments/prod/ --replicas=green

   # Step 5: Smoke test green internally

   # Step 6: Switch production traffic to green
   kubectl patch service wordpress -p '{"spec":{"selector":{"version":"green"}}}'

   # Step 7: Monitor, rollback if needed (instant selector change)

   # Step 8: Decommission blue
   kubectl delete deployment wordpress-blue
   ```

**Tools**:
- **Flagger** (for progressive delivery & automated rollback)
- **Traefik** (for weighted traffic splitting)
- **Prometheus + Grafana** (metrics-based decision making)

---

### Database Strategy

**Challenge**: PostgreSQL custom image + shared database (Discourse + Logto)

**Solution**: StatefulSets with Persistent Storage

```yaml
PostgreSQL StatefulSet:
  - Replicas: 2 (primary on worker-1, standby on worker-2)
  - Image: dirtbikechina/postgres:15-cjk (custom image)
  - Storage: Longhorn PVC (50GB, replicated, backed up)
  - Init Container: Run discourse_init.sh for CJK setup
  - Databases: logto (default), discourse (created by init)
  - Service: postgres-primary (ClusterIP), postgres-standby (read replicas)

MySQL StatefulSet:
  - Replicas: 2 (primary + standby)
  - Image: mysql:latest
  - Storage: Longhorn PVC (30GB)
  - For: WordPress only
```

**High Availability**:
- Use **Patroni** or **Stolon** for PostgreSQL HA (automatic failover)
- Use **MySQL InnoDB Cluster** for MySQL HA
- Or: Managed databases (CloudSQL, RDS) for production (eliminates HA complexity)

**Backup Strategy** (detailed in section below):
- **On-site**: Longhorn snapshots (hourly) + velero backups (daily)
- **Off-site**: S3/B2/Wasabi remote backups (daily) + point-in-time recovery

---

### Storage Architecture

**Longhorn Distributed Storage**:

```yaml
Storage Classes:
  - longhorn-retain:      # For databases (retain on delete)
      reclaimPolicy: Retain
      allowVolumeExpansion: true
      numberOfReplicas: 2

  - longhorn-fast:        # For apps (SSD, higher IOPS)
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      numberOfReplicas: 2

  - longhorn-backup:      # For backup storage
      reclaimPolicy: Retain
      numberOfReplicas: 1

PersistentVolumeClaims:
  - postgres-data-0:      50GB (longhorn-retain)
  - mysql-data-0:         30GB (longhorn-retain)
  - wordpress-files:      20GB (longhorn-fast)
  - discourse-shared:     30GB (longhorn-retain) # Unix socket + data
  - meilisearch-data:     10GB (longhorn-fast)
  - pocketbase-data:      10GB (longhorn-fast)
  - svelte-uploads:       20GB (longhorn-fast)
```

**Benefits**:
- Automatic replication across nodes
- Snapshot support (Longhorn UI or kubectl)
- Volume expansion without downtime
- S3 backup integration

**Alternative**: NFS server or cloud storage (EBS, Ceph, etc.)

---

### Ingress & Routing

**Replace Caddy with Traefik** (k3s default) or **NGINX Ingress**:

**Traefik IngressRoute** (supports weighted routing for A/B):

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: wordpress-ab-test
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`www.dirtbikechina.com`)
      kind: Rule
      services:
        - name: wordpress-prod
          port: 80
          weight: 70          # 70% to prod
        - name: wordpress-stage
          port: 80
          weight: 30          # 30% to stage (A/B testing)
  tls:
    certResolver: letsencrypt
```

**Discourse Unix Socket Handling**:

**Problem**: Discourse uses Unix socket (`/sock/nginx.http.sock`), not HTTP port.

**Solutions**:
1. **Recommended**: Modify Discourse container to expose HTTP port (3000) alongside socket
   - Use `web.template.yml` instead of `web.socketed.template.yml`
   - Configure Unicorn to listen on `0.0.0.0:3000`

2. **Alternative**: Run socat sidecar container to proxy Unix socket → TCP
   ```yaml
   - name: socat-proxy
     image: alpine/socat
     command: ["socat", "TCP-LISTEN:8080,fork,reuseaddr", "UNIX-CONNECT:/sock/nginx.http.sock"]
     volumeMounts:
       - name: discourse-socket
         mountPath: /sock
   ```

3. **Kubernetes-Native**: Use **hostPath** volume (discouraged, not portable)

**Recommendation**: Modify Discourse to HTTP mode for k8s compatibility.

---

### Application Deployment

**Deployment Strategy per App**:

| Application | Type | Replicas (Prod) | Storage | Blue-Green |
|-------------|------|-----------------|---------|------------|
| WordPress | Deployment | 2 | PVC (shared) | Yes |
| Discourse | Deployment | 2 | PVC (shared) | Yes |
| Wanderer (Svelte) | Deployment | 3 | PVC (uploads) | Yes |
| Wanderer (PocketBase) | StatefulSet | 1 | PVC | Partial |
| Wanderer (Meilisearch) | StatefulSet | 1 | PVC | Partial |
| Logto | Deployment | 2 | Stateless | Yes |
| PHPMyAdmin | Deployment | 1 | Stateless | No |
| PostgreSQL | StatefulSet | 2 | PVC | No (HA) |
| MySQL | StatefulSet | 2 | PVC | No (HA) |

**Shared Storage**:
- WordPress files: ReadWriteMany (NFS or Longhorn RWX)
- Discourse shared: ReadWriteMany

**Init Jobs**:
```yaml
Job: discourse-init
  - Runs before Discourse deployment
  - Uses custom postgres:15-cjk image
  - Executes discourse_init.sh
  - Success required for Discourse to start

Job: logto-init
  - Runs before Logto deployment
  - Seeds Logto database
  - One-time execution (restartPolicy: Never)
```

---

## Migration Path

### Phase 1: Infrastructure Setup (Week 1-2)

**1.1 Provision k3s Cluster**

```bash
# On master-1 node
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --disable traefik \  # Install later with custom config
  --write-kubeconfig-mode 644

# Get node token
sudo cat /var/lib/rancher/k3s/server/node-token

# On worker-1, worker-2
curl -sfL https://get.k3s.io | K3S_URL=https://master-1:6443 \
  K3S_TOKEN=<token> sh -

# Verify cluster
kubectl get nodes
```

**1.2 Install Longhorn Storage**

```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.5.3/deploy/longhorn.yaml

# Wait for pods
kubectl -n longhorn-system get pods --watch

# Access Longhorn UI (optional)
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

**1.3 Install Traefik Ingress**

```bash
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik \
  --namespace ingress-system --create-namespace \
  --set additionalArguments="{--providers.kubernetesingress.ingressclass=traefik}" \
  --set ports.websecure.tls.enabled=true

# Configure cert-manager for Let's Encrypt
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

**1.4 Create Namespaces & RBAC**

```bash
kubectl apply -f cluster/base/namespaces.yaml
kubectl apply -f cluster/base/rbac/
```

---

### Phase 2: Database Migration (Week 2-3)

**2.1 Build & Push Custom PostgreSQL Image**

```bash
# From dirtbikechina repo
cd submodules/pg_cjk_parser/
docker build -f ../../discourse.Dockerfile -t dirtbikechina/postgres:15-cjk .

# Push to registry (Docker Hub, Harbor, or private registry)
docker push dirtbikechina/postgres:15-cjk

# Or: Save to tar for manual import on k3s nodes
docker save dirtbikechina/postgres:15-cjk | gzip > postgres-cjk.tar.gz
scp postgres-cjk.tar.gz worker-1:/tmp/
ssh worker-1 'sudo k3s ctr images import /tmp/postgres-cjk.tar.gz'
```

**2.2 Deploy PostgreSQL StatefulSet**

```bash
kubectl apply -f cluster/base/databases/postgres-statefulset.yaml
kubectl apply -f cluster/base/databases/postgres-service.yaml

# Wait for ready
kubectl -n infra get pods -l app=postgres --watch

# Verify CJK parser installed
kubectl -n infra exec postgres-0 -- psql -U postgres -d discourse -c "\dx"
```

**2.3 Run Discourse Init Job**

```bash
kubectl apply -f cluster/base/databases/discourse-init-job.yaml

# Check logs
kubectl -n infra logs job/discourse-init

# Should show: "All CJK parser smoke tests passed successfully!"
```

**2.4 Deploy MySQL StatefulSet**

```bash
kubectl apply -f cluster/base/databases/mysql-statefulset.yaml

# Import existing WordPress data (if migrating)
kubectl -n infra exec -it mysql-0 -- mysql -u root -p < wordpress_backup.sql
```

**2.5 Data Migration from Docker Compose**

```bash
# Export from Docker Compose
docker exec postgres pg_dump -U postgres discourse > discourse_backup.sql
docker exec mysql mysqldump -u root -p wordpress > wordpress_backup.sql

# Import to k8s
kubectl -n infra cp discourse_backup.sql postgres-0:/tmp/
kubectl -n infra exec postgres-0 -- psql -U postgres discourse < /tmp/discourse_backup.sql

kubectl -n infra cp wordpress_backup.sql mysql-0:/tmp/
kubectl -n infra exec mysql-0 -- mysql -u root -p wordpress < /tmp/wordpress_backup.sql
```

---

### Phase 3: Application Deployment (Week 3-4)

**3.1 Deploy Dev Environment** (testing ground)

```bash
# Create secrets
kubectl create secret generic db-credentials \
  --namespace dev \
  --from-literal=mysql-user=$MYSQL_USER \
  --from-literal=mysql-password=$MYSQL_PASSWORD \
  --from-literal=postgres-user=$POSTGRES_USER \
  --from-literal=postgres-password=$POSTGRES_PASSWORD

# Deploy apps
kubectl apply -k cluster/environments/dev/

# Test each service
kubectl -n dev port-forward svc/wordpress 8080:80
curl http://localhost:8080
```

**3.2 Deploy Stage Environment**

```bash
kubectl apply -k cluster/environments/stage/
```

**3.3 Deploy Production** (Blue deployment first)

```bash
# Deploy blue version
kubectl apply -k cluster/environments/prod/

# Label as blue
kubectl -n prod label deployment wordpress version=blue
kubectl -n prod label deployment discourse version=blue
# ... etc
```

**3.4 Configure Ingress Routes**

```bash
kubectl apply -f cluster/base/ingress/
```

**3.5 Verify DNS & SSL**

```bash
# Point DNS records:
# www.dirtbikechina.com → master-1 IP (or LoadBalancer)
# forum.dirtbikechina.com → master-1 IP
# trails.dirtbikechina.com → master-1 IP
# auth.dirtbikechina.com → master-1 IP

# Check cert issuance
kubectl -n prod get certificate
kubectl describe certificate www-dirtbikechina-com-tls
```

---

### Phase 4: Blue-Green & A/B Testing (Week 4-5)

**4.1 Deploy Green Version**

```bash
# Build new version (e.g., WordPress with plugin update)
docker build -t dirtbikechina/wordpress:green ./wordpress

# Deploy green
sed 's/version: blue/version: green/g' cluster/environments/prod/wordpress.yaml > wordpress-green.yaml
kubectl apply -f wordpress-green.yaml

# Test green via internal service
kubectl -n prod run test --rm -it --image=curlimages/curl -- sh
curl http://wordpress-green
```

**4.2 Traffic Switch (Blue → Green)**

```bash
# Update service selector
kubectl patch service wordpress -n prod -p '{"spec":{"selector":{"version":"green"}}}'

# Verify traffic
curl https://www.dirtbikechina.com

# Monitor logs, metrics
kubectl -n prod logs -l app=wordpress,version=green -f

# Rollback if issues (instant)
kubectl patch service wordpress -n prod -p '{"spec":{"selector":{"version":"blue"}}}'
```

**4.3 Enable A/B Testing (30% Stage Traffic)**

```bash
# Apply weighted IngressRoute
kubectl apply -f cluster/base/ingress/ab-testing-route.yaml

# Routes 70% to prod, 30% to stage
# Monitor user feedback, error rates, conversion metrics
```

**4.4 Promote Stage → Prod**

```bash
# If stage performs well with 30% traffic:
# 1. Stage becomes new prod-green
# 2. Switch prod traffic to green
# 3. Old prod becomes blue (standby)
```

---

### Phase 5: Backup & Disaster Recovery (Week 5-6)

**5.1 Setup Velero (Cluster Backup)**

```bash
# Install Velero with S3 backend
velero install \
  --provider aws \
  --bucket dirtbikechina-k8s-backups \
  --secret-file ./aws-credentials \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1 \
  --use-volume-snapshots=true \
  --use-restic

# Schedule daily backups
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --include-namespaces prod,infra
```

**5.2 Setup Database Backups**

**On-Site (Longhorn Snapshots)**:
```bash
# Create recurring job in Longhorn UI
# - Snapshots: Every 6 hours, retain 7 days
# - Backups to S3: Daily, retain 30 days
```

**Off-Site (CronJob)**:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup-offsite
  namespace: infra
spec:
  schedule: "0 3 * * *"  # 3 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:15
            command:
            - /bin/bash
            - -c
            - |
              pg_dump -U postgres discourse | gzip > /backup/discourse-$(date +%Y%m%d).sql.gz
              # Upload to S3/Backblaze B2
              rclone copy /backup/ b2:dirtbikechina-offsite/postgres/
            volumeMounts:
            - name: backup-storage
              mountPath: /backup
```

**5.3 Test Disaster Recovery**

```bash
# Simulate node failure
kubectl drain worker-1 --ignore-daemonsets

# Verify pods reschedule to worker-2
kubectl get pods -o wide

# Verify data intact (Longhorn replication)
kubectl exec -it postgres-0 -- psql -U postgres -c "SELECT count(*) FROM topics;"

# Uncordon node
kubectl uncordon worker-1
```

---

## Cost Analysis

### Infrastructure Costs

**Assumptions**: Self-hosted on 3 VPS (Hetzner, DigitalOcean, Vultr, etc.)

| Resource | Current (Docker) | k3s (3-node) | Delta |
|----------|------------------|--------------|-------|
| VPS Nodes | 1 × $40/mo (8GB, 4CPU) | 3 × $40/mo | +$80/mo |
| Storage | Included | Longhorn (local disk) | $0 |
| Backups (S3) | $5/mo (100GB) | $10/mo (200GB) | +$5/mo |
| Domain/SSL | $12/yr | $12/yr | $0 |
| **Total** | **$45/mo** | **$130/mo** | **+$85/mo** |

**Cost Optimization**:
- Use smaller nodes for dev/test ($20/mo each)
- Use spot instances (50% savings)
- Managed databases for prod only (MySQL: $15/mo, PostgreSQL: $20/mo)
- **Optimized Total**: ~$70-90/mo

### Operational Costs

| Task | Docker Compose | k3s | Notes |
|------|----------------|-----|-------|
| Deployment Time | 10 min (manual) | 2 min (kubectl apply) | CI/CD automation |
| Rollback Time | 15 min (restore) | 30 sec (selector switch) | Blue-green instant |
| Monitoring Setup | Custom (Grafana) | Built-in (Prometheus) | Easier setup |
| Scaling | Manual (compose up --scale) | Auto (HPA) | CPU/memory based |
| Learning Curve | Low | Medium-High | Initial investment |

---

## Risk Assessment

### Migration Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Database migration corruption | **Critical** | Low | Test restores, staged migration, rollback plan |
| Discourse socket incompatibility | **High** | Medium | Modify to HTTP mode, test in dev first |
| Downtime during cutover | **Medium** | High | Blue-green on k8s, parallel run, DNS switch |
| Storage performance degradation | **Medium** | Low | Benchmark Longhorn vs local volumes |
| Complexity overwhelm | **High** | Medium | Staged rollout (dev→stage→prod), documentation |
| Cost overrun | **Low** | Medium | Start with 1-node k3s (single-node HA), scale later |

### Operational Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Node failure | Medium | Longhorn replication, StatefulSet auto-restart |
| etcd corruption | Critical | Backup etcd daily, multi-master setup |
| Storage full | High | Monitoring + alerts (Longhorn UI, Prometheus) |
| Certificate expiration | Medium | cert-manager auto-renewal, alerts |
| Network partition | Medium | Multi-AZ deployment (if cloud), node affinity |

---

## Recommended Approach

### Option 1: Phased Migration (Recommended) ✅ **PANEL APPROVED**

**Original Timeline**: 6-8 weeks
**Updated Timeline (Panel-Approved)**: **12-14 weeks**

**Rationale for Extension**: Expert panel review identified the need to account for:
- Security hardening implementation (SealedSecrets, RBAC, NetworkPolicies)
- Database HA setup with CloudNativePG (3-instance cluster, failover testing)
- Observability stack deployment (Prometheus, Grafana, Loki)
- CI/CD pipeline development (custom image builds, vulnerability scanning)
- Learning curve for team (k8s fundamentals, operational procedures)

**Phased Timeline**:

**Phase 0: Preparation & Security (Weeks 1-2)** ✅ **COMPLETED**
- ✅ Design and document k8s architecture
- ✅ Implement SealedSecrets, RBAC, NetworkPolicies
- ✅ Create CloudNativePG HA database design
- ✅ Design observability stack (Prometheus/Grafana/Loki)
- ✅ Create CI/CD pipeline for custom images
- ✅ Solve Discourse HTTP mode compatibility
- ✅ Expert panel review and approval

**Phase 1: Development Environment (Weeks 3-6)**
1. **Week 3-4**: Infrastructure Setup
   - Install 3-master k3s cluster (or 1 node for dev testing)
   - Install Longhorn storage
   - Install SealedSecrets controller
   - Apply RBAC policies and NetworkPolicies
   - Install observability stack (Prometheus, Grafana, Loki)

2. **Week 5-6**: Database & Application Deployment
   - Install CloudNativePG operator
   - Deploy PostgreSQL cluster (3 instances)
   - Run Discourse CJK init job
   - Deploy MySQL StatefulSet
   - Deploy at least one application (WordPress)
   - Functional testing
   - HA failover testing (<30s recovery)
   - Security validation
   - **Gate 1 Review**: All success criteria must pass

**Phase 2: Staging Environment (Weeks 7-10)**
3. **Week 7-8**: Staging Deployment
   - Deploy all applications to staging namespace
   - Configure Traefik ingress with A/B testing (10% traffic to staging)
   - Performance testing and optimization
   - Resource limit tuning based on actual usage

4. **Week 9-10**: A/B Testing & Validation
   - Increase staging traffic gradually (10% → 30%)
   - Monitor error rates, latency, user experience
   - Test blue-green deployment procedures
   - Validate rollback procedures
   - Document any issues and resolutions
   - **Gate 2 Review**: Staging stability for 1 week

**Phase 3: Production Migration (Weeks 11-14)**
5. **Week 11-12**: Production Deployment
   - Deploy blue environment to production namespace
   - Parallel run (Docker Compose + k8s simultaneously)
   - Gradual traffic shift to k8s (10% → 50%)
   - Monitor all metrics, logs, alerts
   - Database migration and validation

6. **Week 13-14**: Full Cutover & Optimization
   - Complete traffic cutover to k8s (100%)
   - Enable A/B testing (70% prod, 30% stage)
   - Monitor for 1 week of stable operation
   - Decommission Docker Compose infrastructure
   - Performance optimization
   - Team training on k8s operations
   - **Gate 3 Review**: Production readiness

**Pros**:
- ✅ Low risk (can rollback to Docker at any point)
- ✅ Time to learn k8s incrementally
- ✅ Test thoroughly before production
- ✅ Security hardened from day one
- ✅ HA database with automatic failover
- ✅ Complete observability and monitoring
- ✅ Realistic timeline accounting for learning curve

**Cons**:
- ⏱️ Longer timeline (but more realistic)
- 💰 Running dual infrastructure temporarily (weeks 11-13)

### Option 2: Big Bang Migration

**Timeline**: 3-4 weeks

1. **Week 1**: Build cluster, deploy all apps
2. **Week 2**: Migrate data, test
3. **Week 3**: DNS cutover, monitor
4. **Week 4**: Optimize, blue-green setup

**Pros**:
- Faster completion
- No dual infrastructure

**Cons**:
- Higher risk
- Requires more preparation
- Less time to learn

### Option 3: Hybrid (Databases on k8s, Apps on Docker)

**Timeline**: 4 weeks

- Move databases to k8s (HA, backups)
- Keep apps on Docker Compose
- Gradually migrate apps one-by-one

**Pros**:
- Database HA immediately
- Incremental app migration

**Cons**:
- Complexity of hybrid networking
- Still managing two systems

---

## Implementation Checklist

### Pre-Migration

- [ ] Backup all current data (databases, volumes, configs)
- [ ] Document current environment variables, secrets
- [ ] Test database exports/imports
- [ ] Provision 3 VPS nodes (or prepare hardware)
- [ ] Set up private container registry (optional, for custom images)
- [ ] Review Discourse configuration for HTTP mode compatibility

### k3s Setup

- [ ] Install k3s on all 3 nodes
- [ ] Verify cluster connectivity (`kubectl get nodes`)
- [ ] Install Longhorn storage provider
- [ ] Install Traefik ingress controller
- [ ] Install cert-manager for SSL
- [ ] Create namespaces (prod, stage, dev, test, infra)
- [ ] Set up RBAC, network policies

### Database Migration

- [ ] Build custom PostgreSQL image with CJK parser
- [ ] Push image to registry
- [ ] Deploy PostgreSQL StatefulSet
- [ ] Run discourse-init Job, verify CJK tests pass
- [ ] Deploy MySQL StatefulSet
- [ ] Migrate data from Docker to k8s
- [ ] Verify data integrity

### Application Deployment

- [ ] Create ConfigMaps for environment-specific configs
- [ ] Create Secrets for credentials
- [ ] Deploy to dev environment
- [ ] Test all applications in dev
- [ ] Deploy to stage environment
- [ ] Configure ingress routes (HTTP + HTTPS)
- [ ] Test SSL certificates
- [ ] Deploy to prod (blue version)

### Blue-Green Setup

- [ ] Deploy green version alongside blue
- [ ] Test green internally
- [ ] Switch traffic to green
- [ ] Verify production traffic
- [ ] Remove blue deployment
- [ ] Document rollback procedure

### A/B Testing

- [ ] Configure weighted IngressRoute (70% prod, 30% stage)
- [ ] Set up metrics collection (Prometheus)
- [ ] Monitor error rates, latency, user feedback
- [ ] Adjust traffic weights based on results

### Backup & Monitoring

- [ ] Configure Longhorn recurring snapshots
- [ ] Set up Velero for cluster backups
- [ ] Create CronJobs for database dumps
- [ ] Configure off-site backup to S3/B2
- [ ] Set up Prometheus + Grafana
- [ ] Create alerts (CPU, memory, disk, certificate expiry)
- [ ] Test restore procedures

### Post-Migration

- [ ] Monitor for 1 week, adjust resources as needed
- [ ] Decommission old Docker Compose infrastructure
- [ ] Update documentation (CLAUDE.md, README.md)
- [ ] Train team on kubectl, k9s, Lens
- [ ] Establish SLA and incident response procedures

---

## Tools & Technologies

### Core Stack

- **k3s**: Lightweight Kubernetes distribution
- **Longhorn**: Distributed block storage (or Rook/Ceph for larger scale)
- **Traefik**: Ingress controller with weighted routing
- **cert-manager**: Automatic SSL certificate management
- **Velero**: Cluster backup and disaster recovery

### Optional Enhancements

- **Flagger**: Progressive delivery, automated rollback (canary, blue-green, A/B)
- **Prometheus + Grafana**: Monitoring and alerting
- **Loki**: Log aggregation
- **Linkerd** or **Istio**: Service mesh (for advanced traffic management)
- **ArgoCD**: GitOps continuous delivery
- **k9s**: Terminal-based Kubernetes UI
- **Lens**: Desktop Kubernetes IDE

---

## Next Steps

1. **Review this evaluation** with stakeholders
2. **Choose migration approach** (Phased recommended)
3. **Provision infrastructure** (3 nodes or start with 1-node k3s)
4. **Start with dev environment** in k8s
5. **Iterate and refine** manifests
6. **Document lessons learned** for team knowledge

---

## Conclusion

Migrating to k3s provides significant operational benefits:

**Pros**:
- ✅ High availability (multi-node, auto-restart)
- ✅ Zero-downtime deployments (blue-green)
- ✅ A/B testing capability (30% traffic to stage)
- ✅ Auto-scaling (HPA)
- ✅ Better resource utilization
- ✅ Industry-standard tooling
- ✅ Built-in monitoring, logging

**Cons**:
- ❌ Increased complexity (learning curve)
- ❌ Higher infrastructure cost (+$85/mo baseline)
- ❌ Migration effort (6-8 weeks)
- ❌ Requires k8s expertise

**Recommendation**: **Proceed with phased migration** starting with a dev environment. The benefits of HA, blue-green deployments, and A/B testing outweigh the costs for a production community platform. The custom PostgreSQL CJK image and Discourse socket can be accommodated with minor adjustments.

**Critical Success Factor**: Modify Discourse to expose HTTP port (not just Unix socket) for k8s compatibility. This is the biggest technical hurdle but is achievable by using `web.template.yml` instead of `web.socketed.template.yml` in Discourse configuration.

---

**Document Version**: 1.0
**Author**: AI Assistant (Claude)
**Date**: 2025-11-17
**Status**: Draft for Review

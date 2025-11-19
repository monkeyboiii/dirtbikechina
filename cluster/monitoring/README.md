# Observability Stack Installation Guide

## Overview

Complete monitoring and logging solution for Dirtbikechina k8s cluster:

- **Prometheus**: Metrics collection and alerting
- **Grafana**: Visualization dashboards
- **Loki**: Log aggregation
- **AlertManager**: Alert routing and notification
- **Node Exporter**: Host metrics
- **Kube State Metrics**: Kubernetes object metrics

## Quick Install

```bash
# 1. Add Helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# 2. Create monitoring namespace
kubectl create namespace monitoring

# 3. Install kube-prometheus-stack (Prometheus + Grafana + AlertManager)
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword='admin-password-change-me' \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.hosts[0]=grafana.dirtbikechina.com

# 4. Install Loki stack (Loki + Promtail for logs)
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=50Gi

# 5. Apply custom ServiceMonitors
kubectl apply -f cluster/monitoring/servicemonitors/
```

## Detailed Installation

### Step 1: Install Prometheus Operator Stack

```bash
# Create custom values file
cat > /tmp/kube-prom-values.yaml <<'EOF'
prometheus:
  prometheusSpec:
    # Allow discovering all ServiceMonitors/PodMonitors
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false

    # Storage
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn-retain
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

    # Retention
    retention: 30d
    retentionSize: "45GB"

    # Resources
    resources:
      requests:
        memory: 2Gi
        cpu: 500m
      limits:
        memory: 4Gi
        cpu: 2000m

    # Scrape interval
    scrapeInterval: 30s
    evaluationInterval: 30s

grafana:
  adminPassword: "change-me-in-production"

  # Persistence
  persistence:
    enabled: true
    storageClassName: longhorn-fast
    size: 10Gi

  # Ingress
  ingress:
    enabled: true
    ingressClassName: traefik
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
    hosts:
      - grafana.dirtbikechina.com
    tls:
      - secretName: grafana-tls
        hosts:
          - grafana.dirtbikechina.com

  # Datasources (Loki will be added after installation)
  additionalDataSources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki:3100
      isDefault: false
      editable: true

  # Dashboards
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default

alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'cluster', 'service']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 12h
      receiver: 'null'
      routes:
      - match:
          alertname: Watchdog
        receiver: 'null'
      - match:
          severity: critical
        receiver: 'critical'
    receivers:
    - name: 'null'
    - name: 'critical'
      # Configure your notification channels here
      # email_configs:
      # - to: 'alerts@dirtbikechina.com'
      #   from: 'prometheus@dirtbikechina.com'
      #   smarthost: 'smtp.example.com:587'
      #   auth_username: 'alerting@example.com'
      #   auth_password: 'password'
EOF

# Install
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values /tmp/kube-prom-values.yaml
```

### Step 2: Install Loki Stack

```bash
cat > /tmp/loki-values.yaml <<'EOF'
loki:
  enabled: true
  persistence:
    enabled: true
    storageClassName: longhorn-retain
    size: 50Gi
  config:
    auth_enabled: false
    ingester:
      chunk_idle_period: 3m
      chunk_block_size: 262144
      chunk_retain_period: 1m
      max_transfer_retries: 0
      lifecycler:
        ring:
          kvstore:
            store: inmemory
          replication_factor: 1
    limits_config:
      enforce_metric_name: false
      reject_old_samples: true
      reject_old_samples_max_age: 168h
      max_entries_limit_per_query: 5000
      ingestion_rate_mb: 10
      ingestion_burst_size_mb: 20
    schema_config:
      configs:
      - from: 2020-10-24
        store: boltdb-shipper
        object_store: filesystem
        schema: v11
        index:
          prefix: index_
          period: 24h
    server:
      http_listen_port: 3100
    storage_config:
      boltdb_shipper:
        active_index_directory: /data/loki/boltdb-shipper-active
        cache_location: /data/loki/boltdb-shipper-cache
        cache_ttl: 24h
        shared_store: filesystem
      filesystem:
        directory: /data/loki/chunks
    chunk_store_config:
      max_look_back_period: 0s
    table_manager:
      retention_deletes_enabled: true
      retention_period: 336h  # 14 days

promtail:
  enabled: true
  config:
    clients:
      - url: http://loki:3100/loki/api/v1/push

grafana:
  enabled: false  # Already installed by kube-prometheus-stack

prometheus:
  enabled: false  # Already installed
EOF

helm install loki grafana/loki-stack \
  --namespace monitoring \
  --values /tmp/loki-values.yaml
```

### Step 3: Apply ServiceMonitors

See `cluster/monitoring/servicemonitors/` directory.

```bash
kubectl apply -f cluster/monitoring/servicemonitors/
```

## Access Dashboards

### Grafana

```bash
# Get Grafana password
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode ; echo

# Port-forward (local access)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Open: http://localhost:3000
# Login: admin / <password-from-above>
```

**Production**: Access via `https://grafana.dirtbikechina.com`

### Prometheus

```bash
# Port-forward
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

# Open: http://localhost:9090
```

### AlertManager

```bash
# Port-forward
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093

# Open: http://localhost:9093
```

## Pre-Built Dashboards

Grafana comes with pre-installed dashboards:

- **Kubernetes / Compute Resources / Cluster**: Overall cluster resources
- **Kubernetes / Compute Resources / Namespace (Pods)**: Per-namespace usage
- **Kubernetes / Networking / Cluster**: Network I/O
- **Node Exporter / Nodes**: Individual node metrics
- **PostgreSQL**: Database performance (after adding ServiceMonitor)

## Custom Dashboards

Import IDs from https://grafana.com/grafana/dashboards/:

1. **Traefik Dashboard**: ID `4475`
2. **NGINX Ingress**: ID `9614`
3. **Longhorn**: ID `13032`
4. **CloudNativePG**: ID `20417`

**Import Steps**:
1. Grafana UI → Dashboards → Import
2. Enter dashboard ID
3. Select Prometheus datasource
4. Click Import

## Alerting Rules

Located in `cluster/monitoring/alerts/`:

- `node-alerts.yaml`: Node down, high CPU, disk full
- `pod-alerts.yaml`: Pod crashlooping, OOMKilled
- `database-alerts.yaml`: PostgreSQL/MySQL down, replication lag
- `application-alerts.yaml`: High error rate, slow response time

```bash
kubectl apply -f cluster/monitoring/alerts/
```

## Metrics to Monitor

### Critical Metrics

**Cluster Health**:
- `kube_node_status_condition{condition="Ready"}`: Node readiness
- `kube_pod_status_phase{phase="Running"}`: Running pods

**Database**:
- `pg_up`: PostgreSQL availability
- `mysql_up`: MySQL availability
- `pg_replication_lag`: Replication delay

**Application**:
- `traefik_service_requests_total`: Request count
- `traefik_service_request_duration_seconds`: Latency
- `discourse_http_requests_total`: Discourse traffic

**Resources**:
- `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes`: Memory usage
- `node_filesystem_avail_bytes`: Disk space

### A/B Testing Metrics

Query for traffic split validation:

```promql
# Total requests to WordPress
sum(rate(traefik_service_requests_total{service=~"wordpress.*"}[5m])) by (service)

# Calculate percentage
sum(rate(traefik_service_requests_total{service="wordpress-prod"}[5m]))
/
sum(rate(traefik_service_requests_total{service=~"wordpress.*"}[5m]))
* 100
```

Expected: ~70% for prod, ~30% for stage

## Log Queries (Loki)

Access via Grafana → Explore → Loki datasource

**Examples**:

```logql
# All logs from prod namespace
{namespace="prod"}

# Errors only
{namespace="prod"} |= "error"

# Discourse errors
{namespace="prod", app="discourse"} |= "error"

# WordPress PHP errors
{namespace="prod", app="wordpress"} |~ "PHP (Warning|Error|Fatal)"

# Database connection errors
{namespace="infra", app=~"postgres|mysql"} |= "connection refused"

# Rate of errors (per minute)
rate({namespace="prod"} |= "error" [1m])
```

## Troubleshooting

### Issue: Prometheus not scraping targets

**Check**:
```bash
# View ServiceMonitor status
kubectl get servicemonitor -A

# Check Prometheus targets
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Navigate to: http://localhost:9090/targets
```

**Fix**: Ensure ServiceMonitor labels match Prometheus selector

### Issue: Grafana dashboard shows "No data"

**Causes**:
1. Wrong datasource selected
2. Prometheus not scraping metrics
3. Time range outside data retention

**Fix**: Check Prometheus targets, verify metrics exist

### Issue: Loki not receiving logs

**Check Promtail**:
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail

# Should see: "level=info msg="Successfully sent batch"
```

**Fix**: Verify Promtail DaemonSet is running on all nodes

## Backup Grafana Dashboards

```bash
# Export all dashboards
kubectl exec -n monitoring deploy/kube-prometheus-stack-grafana -- \
  grafana-cli admin export-dashboard > dashboards-backup.json

# Store in Git or S3
```

## Cleanup

```bash
# Uninstall (WARNING: Deletes all metrics and dashboards!)
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall loki -n monitoring

# Delete PVCs
kubectl delete pvc -n monitoring -l app.kubernetes.io/name=prometheus
kubectl delete pvc -n monitoring -l app=loki

# Delete namespace
kubectl delete namespace monitoring
```

---

**Document Version**: 1.0
**Last Updated**: 2025-11-17
**Stack Versions**:
- kube-prometheus-stack: v55.x
- Loki: v2.9.x
- Promtail: v2.9.x

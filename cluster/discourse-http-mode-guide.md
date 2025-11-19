# Discourse HTTP Mode Configuration for Kubernetes

## Problem

The current Discourse setup uses a Unix socket (`/sock/nginx.http.sock`) for Caddy communication, which is incompatible with Kubernetes networking. We need Discourse to expose an HTTP port (3000) instead.

## Solution: Modify Discourse to HTTP Mode

### Option 1: Build Custom Discourse Image (Recommended)

**Benefits**:
- Full control over Discourse configuration
- Can include custom plugins
- Version pinning for stability

**Steps**:

#### 1. Create Discourse Build Directory

```bash
# Clone discourse_docker (official Discourse Docker build)
git clone https://github.com/discourse/discourse_docker.git /var/discourse

cd /var/discourse
```

#### 2. Create app.yml for HTTP Mode

Copy the template below to `/var/discourse/containers/app.yml`:

```yaml
templates:
  - "templates/redis.template.yml"
  - "templates/web.template.yml"          # ← Use this (HTTP mode)
  # NOT: "templates/web.socketed.template.yml"  # ← Don't use this
  - "templates/web.ratelimited.template.yml"

expose:
  - "3000:80"  # Expose port 3000 externally, map to container port 80

env:
  LC_ALL: en_US.UTF-8
  LANG: en_US.UTF-8
  LANGUAGE: en_US.UTF-8

  DISCOURSE_HOSTNAME: 'forum.dirtbikechina.com'
  DISCOURSE_DEVELOPER_EMAILS: 'your-email@example.com'

  # SMTP Configuration (required)
  DISCOURSE_SMTP_ADDRESS: smtp.example.com
  DISCOURSE_SMTP_PORT: 587
  DISCOURSE_SMTP_USER_NAME: user@example.com
  DISCOURSE_SMTP_PASSWORD: 'smtp-password'
  DISCOURSE_SMTP_DOMAIN: example.com
  DISCOURSE_NOTIFICATION_EMAIL: 'noreply@example.com'

  # Database Configuration (PostgreSQL in k8s)
  DISCOURSE_DB_HOST: postgres-primary.infra.svc.cluster.local
  DISCOURSE_DB_PORT: 5432
  DISCOURSE_DB_NAME: discourse
  DISCOURSE_DB_USERNAME: discourse
  DISCOURSE_DB_PASSWORD: 'discourse-db-password'

  # Redis (built-in via redis.template.yml)
  DISCOURSE_REDIS_HOST: localhost

  # Disable Let's Encrypt (handled by Traefik/cert-manager)
  LETSENCRYPT_ACCOUNT_EMAIL: ''

  # SSO Configuration (Logto)
  DISCOURSE_ENABLE_DISCOURSE_CONNECT: true
  DISCOURSE_DISCOURSE_CONNECT_URL: 'https://auth.dirtbikechina.com/api/discourse-sso'
  DISCOURSE_DISCOURSE_CONNECT_SECRET: 'your-sso-secret'

params:
  version: stable  # or 'tests-passed' for latest stable

hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/merefield/discourse-locations
          - git clone https://GITHUB_TOKEN@github.com/monkeyboiii/discourse-logto-mobile-session.git

run:
  - exec: echo "Discourse HTTP mode configured for Kubernetes"
```

#### 3. Build Discourse Container

```bash
cd /var/discourse
./launcher rebuild app

# This builds a Docker container named 'local_discourse/app'
```

#### 4. Export and Push to Registry

```bash
# Save container to tar
docker save local_discourse/app:latest | gzip > discourse-http-mode.tar.gz

# Or push to registry
docker tag local_discourse/app:latest dirtbikechina/discourse:latest
docker push dirtbikechina/discourse:latest

# Or for k3s nodes, import directly
scp discourse-http-mode.tar.gz master-1:/tmp/
ssh master-1 'sudo k3s ctr images import /tmp/discourse-http-mode.tar.gz'
```

### Option 2: Use Nginx Sidecar (Quick Solution)

If you can't modify the Discourse build, add an nginx sidecar to proxy socket → HTTP:

**Kubernetes Deployment with Sidecar**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: discourse
  namespace: prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: discourse
  template:
    metadata:
      labels:
        app: discourse
    spec:
      serviceAccountName: discourse

      # Shared volume for Unix socket
      volumes:
      - name: discourse-socket
        emptyDir: {}
      - name: nginx-config
        configMap:
          name: discourse-nginx-proxy-config

      containers:
      # Original Discourse container (with Unix socket)
      - name: discourse
        image: local_discourse/app:latest  # Your existing Discourse image
        volumeMounts:
        - name: discourse-socket
          mountPath: /sock

      # Nginx sidecar: Proxies Unix socket → HTTP
      - name: nginx-proxy
        image: nginx:alpine
        ports:
        - containerPort: 3000
          name: http
        volumeMounts:
        - name: discourse-socket
          mountPath: /sock
          readOnly: true
        - name: nginx-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: discourse-nginx-proxy-config
  namespace: prod
data:
  nginx.conf: |
    events {
      worker_connections 1024;
    }

    http {
      upstream discourse {
        server unix:/sock/nginx.http.sock;
      }

      server {
        listen 3000;

        location / {
          proxy_pass http://discourse;
          proxy_set_header Host $http_host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_buffering off;
        }
      }
    }
```

## Deployment to Kubernetes

### 1. Create Discourse Deployment Manifest

```yaml
# cluster/base/apps/discourse-deployment.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: discourse-shared
  namespace: prod
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: longhorn-fast
  resources:
    requests:
      storage: 30Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: discourse-blue
  namespace: prod
  labels:
    app: discourse
    version: blue
spec:
  replicas: 2
  selector:
    matchLabels:
      app: discourse
      version: blue
  template:
    metadata:
      labels:
        app: discourse
        version: blue
    spec:
      serviceAccountName: discourse

      securityContext:
        runAsNonRoot: false  # Discourse requires root initially (for migrations)
        fsGroup: 1000

      containers:
      - name: discourse
        image: dirtbikechina/discourse:latest  # Your custom HTTP-mode image
        ports:
        - containerPort: 3000
          name: http

        env:
        # Database connection
        - name: DISCOURSE_DB_HOST
          value: postgres-primary.infra.svc.cluster.local
        - name: DISCOURSE_DB_NAME
          value: discourse
        - name: DISCOURSE_DB_USERNAME
          value: discourse
        - name: DISCOURSE_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: discourse-credentials
              key: db-password

        # Redis (assuming sidecar or separate service)
        - name: DISCOURSE_REDIS_HOST
          value: localhost

        # SMTP
        - name: DISCOURSE_SMTP_ADDRESS
          valueFrom:
            secretKeyRef:
              name: discourse-credentials
              key: smtp-address
        - name: DISCOURSE_SMTP_PASSWORD
          valueFrom:
            secretKeyRef:
              name: discourse-credentials
              key: smtp-password

        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"

        volumeMounts:
        - name: discourse-shared
          mountPath: /shared

        livenessProbe:
          httpGet:
            path: /srv/status
            port: 3000
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 10

        readinessProbe:
          httpGet:
            path: /srv/status
            port: 3000
          initialDelaySeconds: 60
          periodSeconds: 10

      # Redis sidecar (optional, or use separate service)
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379

      volumes:
      - name: discourse-shared
        persistentVolumeClaim:
          claimName: discourse-shared
---
apiVersion: v1
kind: Service
metadata:
  name: discourse
  namespace: prod
spec:
  type: ClusterIP
  ports:
  - port: 3000
    targetPort: 3000
    name: http
  selector:
    app: discourse
    version: blue
```

### 2. Deploy to Kubernetes

```bash
# Create secrets first
kubectl create secret generic discourse-credentials \
  --namespace prod \
  --from-literal=db-password='discourse-password' \
  --from-literal=smtp-address='smtp.example.com' \
  --from-literal=smtp-password='smtp-password'

# Or use SealedSecret (recommended)
# Follow: cluster/base/secrets/README.md

# Deploy Discourse
kubectl apply -f cluster/base/apps/discourse-deployment.yaml

# Verify
kubectl get pods -n prod -l app=discourse
kubectl logs -f -n prod -l app=discourse
```

### 3. Update Traefik IngressRoute

Already configured in `cluster/base/ingress/traefik-ingress-routes.yaml`:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: discourse-ab-testing
  namespace: ingress-system
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`forum.dirtbikechina.com`)
      kind: Rule
      services:
        - name: discourse
          namespace: prod
          port: 3000  # ← HTTP port (not Unix socket)
          weight: 70
        - name: discourse
          namespace: stage
          port: 3000
          weight: 30
  tls:
    secretName: dirtbikechina-tls
```

## Verification

### Test Discourse HTTP Access

```bash
# Port-forward to test locally
kubectl port-forward -n prod svc/discourse 3000:3000

# In another terminal
curl http://localhost:3000/srv/status
# Should return: {"success":"OK"}

# Test via ingress
curl https://forum.dirtbikechina.com
# Should return Discourse homepage HTML
```

### Check Logs

```bash
# Discourse logs
kubectl logs -n prod -l app=discourse -c discourse

# Should NOT see "binding to Unix socket"
# Should see: "Listening on http://0.0.0.0:3000"
```

## Migration from Docker Compose

If you have existing Discourse data:

```bash
# 1. Export from Docker Compose
docker exec app discourse backup

# Backup will be in: /var/discourse/shared/standalone/backups/default/

# 2. Copy to k8s PVC
kubectl cp /var/discourse/shared/standalone/backups/default/backup-YYYY-MM-DD.tar.gz \
  prod/discourse-blue-<pod-id>:/shared/backups/default/

# 3. Restore in k8s
kubectl exec -it -n prod discourse-blue-<pod-id> -- discourse restore backup-YYYY-MM-DD.tar.gz
```

## Troubleshooting

### Issue: Discourse won't start (migrations fail)

**Cause**: Database not initialized with CJK parser

**Solution**:
```bash
# Run Discourse init job first
kubectl apply -f cluster/base/databases/discourse-init-cnpg-job.yaml
kubectl wait --for=condition=complete job/discourse-init-cnpg -n infra
```

### Issue: 502 Bad Gateway from Traefik

**Cause**: Discourse not listening on HTTP port

**Solution**: Verify Discourse is using `web.template.yml`, not `web.socketed.template.yml`

### Issue: Redis connection refused

**Cause**: Redis not running

**Solution**: Add Redis sidecar or deploy separate Redis service

## Summary

**Recommended Approach**: Build custom Discourse image with HTTP mode

**Steps**:
1. Use `web.template.yml` template (not `web.socketed.template.yml`)
2. Set `expose: - "3000:80"` in app.yml
3. Build with `./launcher rebuild app`
4. Push to registry or import to k3s nodes
5. Deploy to Kubernetes with port 3000 exposed
6. Configure Traefik IngressRoute to route to port 3000

**Result**: Discourse accessible via HTTP, compatible with Kubernetes networking.

---

**Document Version**: 1.0
**Last Updated**: 2025-11-17
**Status**: Production-Ready

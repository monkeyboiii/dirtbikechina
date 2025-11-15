# DirtbikeChina k3s Migration Evaluation

This document explains the Kompose warnings you saw, reviews each part of the stack that was converted from Docker Compose (`kompose/compose.yml`) to Kubernetes (`kompose/k3s.yml`), and states whether the two-node k3s migration will currently work (spoiler: it will not until the items below are addressed).

## 1. Stack snapshot (Compose → generated Kubernetes)

| Component | Compose definition | Generated object(s) | Notes |
| --- | --- | --- | --- |
| Caddy reverse proxy | `kompose/compose.yml:3-41` | `Service`+`Deployment`+PVCs+ConfigMap (`kompose/k3s.yml:1-161`) | Only workload with a Service; lost the `/var/discourse/shared/standalone` socket bind. |
| Logto core + admin | `kompose/compose.yml:66-125` | `Deployment` (`kompose/k3s.yml:219-255`) | No Service generated, so `auth.dirtbikechina.com` cannot reach it via Caddy. |
| Logto DB seed (`logto-init`) | `kompose/compose.yml:86-105` | Naked Pod (`kompose/k3s.yml:256-281`) | Should be a `Job`/`initContainer`; no orchestration or retries. |
| Discourse DB init | `kompose/compose.yml:42-65` | Naked Pod + ConfigMap script (`kompose/k3s.yml:162-255`) | Talks to `postgres` DNS name that was never created. |
| PostgreSQL (logto/discourse) | `kompose/compose.yml:191-217` | `Deployment`+PVC (`kompose/k3s.yml:520-569`) | Custom image, no Service, 100 MiB RWO volume. |
| MySQL + phpMyAdmin (WordPress) | `kompose/compose.yml:131-189` & `153-169` | `Deployment`s+PVC (`kompose/k3s.yml:360-420`) | No Services; phpMyAdmin cannot reach MySQL across pods. |
| WordPress | `kompose/compose.yml:250-278` | `Deployment`+PVC+ConfigMap (`kompose/k3s.yml:646-717`) | Host bind for `/home/calvin/dirtbikechina/wordpress` became an empty PVC. |
| Meilisearch | `kompose/compose.yml:107-130` | `Deployment`+PVC (`kompose/k3s.yml:282-348`) | No Service, so `http://meili:7700` is unusable. |
| PocketBase | `kompose/compose.yml:169-190` | `Deployment`+PVC (`kompose/k3s.yml:421-469`) | Needs Service to serve `admin.trails.dirtbikechina.com`. |
| Wanderer Svelte app | `kompose/compose.yml:219-249` | `Deployment`+PVC (`kompose/k3s.yml:470-519`) | Depends on Meili & PocketBase but lacks Service endpoints. |

## 2. Kompose warnings – causes & fixes

1. **`Restart policy 'unless-stopped' … convert it to 'always'`**  
   Docker’s `unless-stopped` has no Kubernetes equivalent, so Kompose defaults to `Always`. For long-running Deployments that is fine, but the init-style services (`discourse-init`, `logto-init`) now restart on every node reboot. Model them as `Job`s with `backoffLimit` or as `initContainers` in the consuming Deployments.

2. **`File don't exist or failed to check if the directory is empty … stat :/data … /var/lib/mysql …`**  
   Kompose tries to inspect the source of every volume to decide between `hostPath` and PVC. Named Docker volumes have no path on the host, so Kompose prints this warning and falls back to generating a generic 100 MiB PVC (`kompose/k3s.yml:337-717`). If you truly need a hostPath, create the directory first or pass `--volumes hostPath`. Otherwise, explicitly annotate the desired storage size/class via labels such as `kompose.volume.size` to avoid microscopic volumes.

3. **`Service "<name>" won't be created because 'ports' is not specified`**  
   Services like Postgres, MySQL, WordPress, PocketBase, Meili, Svelte, Logto, etc. never declared `ports`/`expose` in Compose, so Kompose generated Deployments only. Without a ClusterIP Service, Kubernetes DNS will not contain `postgres`, `meili`, `logto`, etc., meaning every `DB_URL`/Caddy upstream breaks. Fix: add `expose` entries to the Compose file (e.g., `expose: ["5432"]`) or hand-write `Service` manifests for each backend after conversion.

4. **`Skip file in path /var/discourse/shared/standalone`**  
   That bind mount points to a path outside the project root and Kompose refused to include it. In Kubernetes you must re-create it explicitly (either as a `hostPath` or as a PVC backed by a shared filesystem on both nodes), otherwise the Caddy stanza `reverse_proxy unix//sock/nginx.http.sock` (`kompose/k3s.yml:134-142`) has nothing to connect to.

5. **`File … failed to check … backups`**  
   These are similar to (2) and stem from Docker-only named volumes (e.g., `backups` from Discourse). Plan how you will seed those data directories into Kubernetes volumes; Kompose cannot copy their contents.

## 3. Critical gaps blocking the migration

### Networking & ingress
- Only Caddy received a Service and it defaults to `ClusterIP` (`kompose/k3s.yml:1-69`), so it is not reachable from the internet or even from external nodes unless you change it to `LoadBalancer`/`NodePort` or run Caddy as a DaemonSet with `hostNetwork: true`.
- All backends (Postgres, MySQL, Meili, PocketBase, Logto, Svelte, WordPress, phpMyAdmin) lack Services entirely (`kompose/k3s.yml:219-717`). As a result, hostnames like `postgres`, `meili`, and `logto` that appear throughout your environment variables (`kompose/k3s.yml:236-251`, `kompose/k3s.yml:320-332`, `kompose/k3s.yml:475-486`, `kompose/k3s.yml:663-685`) will never resolve. Immediate effect: Caddy cannot proxy to any upstream and apps cannot reach their databases.
- The Compose `edge` network (`kompose/compose.yml:280-289`) previously mapped to a Docker bridge that the host firewall exposed. In Kubernetes, network segmentation must be recreated with namespaces and NetworkPolicies if you still need it.

### Storage & node affinity
- Every persistent workload now uses an automatically generated PVC with `ReadWriteOnce` access and a 100 MiB request (`kompose/k3s.yml:337-717`). On a two-node k3s cluster with the default `local-path` provisioner, each PVC is tied to the node that created it. If Kubernetes reschedules a pod to the other node (after drain/failure), it will sit in `Pending` because the volume cannot attach cross-node. Databases and WordPress assets will therefore become unavailable on failover.
- Capacity is insufficient: Postgres, MySQL, Meili, WordPress, and PocketBase all have data well above 100 MiB. Without resizing, the pods will fail with “no space left on device.”
- The WordPress bind mount of `/home/calvin/dirtbikechina/wordpress` that carries your code/uploads (`kompose/compose.yml:270-311`) has been replaced by an empty PVC (`kompose/k3s.yml:688-717`). Unless you manually copy data into that PVC, the site will come up blank.
- Caddy’s `/sock` mount, required to proxy Discourse, was dropped (`kompose/compose.yml:37-41` vs. `kompose/k3s.yml:60-67`). Discourse users will see 502 errors even if the upstream exists elsewhere.

### Lifecycle & initialization
- `logto-init` and `discourse-init` run as stand-alone Pods with `restartPolicy: Never` (`kompose/k3s.yml:162-281`). There is no controller to re-run them after node recycling, and nothing in `logto`/`logto-init` enforces ordering. If they fail once, they stay failed.
- `depends_on` semantics from Compose (`kompose/compose.yml:66-227`) vanished. Kubernetes will start everything simultaneously, so Postgres/MySQL may still be initializing when application pods attempt to connect. You need readiness probes and (ideally) `initContainers` that block until dependencies respond.
- Only Meilisearch and MySQL have liveness probes (`kompose/k3s.yml:320-332`, `kompose/k3s.yml:383-392`). No workload declares a readiness probe, so traffic can be routed to them while still booting, causing repeated crash loops.

### Configuration, secrets, and images
- Secrets remain inline in the manifests (`kompose/k3s.yml:236-251`, `kompose/k3s.yml:377-383`, `kompose/k3s.yml:475-486`, `kompose/k3s.yml:663-685`), which is risky once the repo is shared. Convert them to Kubernetes `Secret`s and reference via `envFrom`/`valueFrom`.
- The Caddyfile is now encoded in a ConfigMap snapshot (`kompose/k3s.yml:90-161`). Editing `Caddyfile` locally no longer updates the running config until you regenerate/apply the ConfigMap or move it to its own manifest.
- Your Postgres container uses a locally built image (`kompose/compose.yml:191-209`). Ensure `dirtbikechina/postgres:15-cjk` lives in a registry accessible by all nodes; otherwise the Deployment will hang in `ImagePullBackOff`.

### Multi-node operational readiness
- Nothing enforces pod anti-affinity or topology spread. If critical pods (e.g., Caddy, Postgres) land on the same node, a single node failure removes the whole stack.
- There is no discussion of how traffic will enter the cluster. If you keep Caddy as the edge proxy, you must expose it with a `LoadBalancer` Service (MetalLB) or reuse k3s’s built-in Traefik Ingress and run Caddy internally.
- Backups/restore steps for seeding PVCs from existing Docker volumes are absent. Without a data migration plan, the Kubernetes pods will start with empty databases.

## 4. Migration verdict

Applying `kompose/k3s.yml` to a two-node k3s cluster in its current form will **not** produce a working environment. Caddy has nothing to talk to, DNS names for databases do not exist, volume mounts drop critical data (Discourse socket, WordPress files), and every persistent service is tied to a single node with undersized storage. The conversion is a good starting point for container specs, but networking, storage, init orchestration, and secrets must be redesigned for Kubernetes primitives before attempting production traffic.

## 5. Remediation plan

1. **Define Services for every backend.** Add `expose` directives to `kompose/compose.yml` (e.g., `logto: ["3001","3002"]`, `postgres: ["5432"]`, `mysql: ["3306"]`, `meili: ["7700"]`, `pocketbase: ["8090"]`, `svelte: ["3000"]`, `wordpress: ["80"]`) or hand-write ClusterIP Service manifests. Re-run Kompose or craft the Services manually so DNS works.
2. **Model stateful workloads as StatefulSets with real storage.** Replace the generated Deployments with StatefulSets, size their PVCs according to actual usage, and choose shared storage (Longhorn, Rook/Ceph, NFS) if you expect failover between nodes. Import existing Docker volume data into those PVCs before cut-over.
3. **Restore required host mounts and assets.** Recreate the Discourse socket mount via `hostPath` or over the network, ensure `/home/calvin/dirtbikechina/wordpress` contents are uploaded into the WordPress PVC, and verify Caddy’s `/data`/`/config` directories persist across restarts.
4. **Convert init pods to Jobs/initContainers with dependency checks.** Wrap `discourse-init` and `logto-init` in Kubernetes `Job`s (or as `initContainers` attached to Postgres/Logto) and gate them on readiness probes so they run exactly once per cluster and retry on failure.
5. **Harden configuration management.** Move credentials into Secrets, keep the Caddyfile as a standalone ConfigMap manifest for easier updates, and publish custom images to a registry reachable from both nodes.
6. **Plan ingress & high availability.** Decide whether Caddy remains the edge proxy or if you leverage Traefik/Ingress. Update the Caddy Service to `LoadBalancer`/`NodePort`, add pod disruption budgets/anti-affinity, and test failover between the two nodes.

Only after these gaps are closed should you attempt the migration on a staging namespace, verify DNS/service discovery, confirm data integrity, and then switch production DNS to the new cluster.

# Kompose Migration Review

## TL;DR
- The generated `kompose/k3s.yml` captures container specs but fails to create any `Service` other than `caddy`, so Caddy cannot resolve downstream apps and every inter-service DNS name (postgres, logto, wordpress, etc.) will break immediately (`kompose/k3s.yml:1-20`, `kompose/k3s.yml:219-704`).
- Every stateful workload was turned into a plain `Deployment` with a 100 MiB `ReadWriteOnce` PVC that relies on the node-local default storage class (`kompose/k3s.yml:337-348`, `kompose/k3s.yml:404-717`), so data durability, node failover, and capacity requirements for Postgres/MySQL/WordPress/PocketBase/Meili are unmet.
- HostPath bindings and sockets that Compose depended on (e.g., `/var/discourse/shared/standalone` for the Discourse nginx socket) were dropped entirely, meaning Caddy cannot proxy Discourse at all (`kompose/compose.yml:24-41` vs. `kompose/k3s.yml:60-67`).
- `depends_on`, readiness ordering, and one-shot init containers (`discourse-init`, `logto-init`) were translated into standalone Pods without orchestration semantics (`kompose/k3s.yml:206-281`), so the bootstrap flow can race the databases and hang/fail.
- Given the above, migrating this stack to a two-node k3s cluster will not work until networking, storage, and lifecycle pieces are re-designed for Kubernetes primitives.

## Conversion warnings explained
1. **Restart policy “unless-stopped”** – Kompose only understands Kubernetes policies (`Always`, `OnFailure`, `Never`), so it silently rewrote everything to `Always`. That is fine for long-running Deployments, but for the init-style services you should explicitly model them as `Job`/`CronJob` so they do not restart endlessly.
2. **“File don’t exist / failed to check directory”** – Kompose inspects the source of volumes to decide whether to map them to PVCs or host paths. Your Docker volumes either pointed at Docker-managed locations or host paths that do not exist on this machine (`/data`, `/config`, `/meili_data/data.ms`, `/var/lib/mysql`, etc.), so Kompose emitted warnings. Fix by creating those directories before conversion if you truly want HostPaths, or (better) define the desired storage class/size via annotations such as `kompose.volume.size`/`kompose.volume.storage-class`.
3. **“Service … won’t be created because ‘ports’ is not specified”** – Compose services like `logto`, `postgres`, `mysql`, `svelte`, etc. never declared `ports`/`expose`, so Kompose did not know which container ports to surface as a ClusterIP Service. Without those Services, no other Pod can reach them by DNS name. Add `expose` entries in Compose (e.g., `expose: ["3001"]`) or hand-write the Services in Kubernetes.
4. **“Skip file in path /var/discourse/shared/standalone”** – The bind mount that feeds the Discourse unix socket lives outside the project root and Kompose skipped it. You will need to create a `hostPath` or CSI-backed PVC that points to the correct directory on every node, otherwise `forum.dirtbikechina.com` cannot be proxied.

## Stack review

### Networking & traffic flow
- Only Caddy got a `Service` and it defaults to `ClusterIP` (`kompose/k3s.yml:1-20`), so it cannot accept internet traffic in a multi-node cluster without changing the Service type or introducing a Kubernetes `Ingress`/`LoadBalancer`.
- Backends such as `logto`, `postgres`, `mysql`, `pocketbase`, `svelte`, `wordpress`, `phpmyadmin`, and `meili` lack Services entirely (`kompose/k3s.yml:219-717`). Consequently, the hostnames used inside the Caddyfile and environment variables (e.g., `postgres://…@postgres:5432/logto` in `kompose/k3s.yml:243-247`) will never resolve.
- Compose networks (`edge`, `logto_net`, `wanderer_net`, etc.) collapsed into the default Kubernetes network; if you require segmentation you will need to re-create it with namespaces/NetworkPolicy.

### Storage & data durability
- Every stateful container became a `Deployment` plus a tiny, generic PVC (`kompose/k3s.yml:337-717`). Databases and WordPress need far more than 100 MiB and should run as `StatefulSet`s with tuned `volumeClaimTemplates`, `fsGroup`, and regular backups.
- The PVCs default to `ReadWriteOnce`, which maps to the node-local `local-path` provisioner in k3s. If the Pod is rescheduled onto the other node, it will hang in `Pending` because the volume lives on the original node. You need shared storage (Longhorn, NFS, etc.) or node affinity/pinning.
- The Compose host bind for the WordPress code (`/home/calvin/dirtbikechina/wordpress` at `kompose/compose.yml:270-311`) became a blank PVC (`kompose/k3s.yml:688-717`), so your existing theme/uploads content will not be shipped to the cluster.
- Caddy’s `/sock` mount to the Discourse unix socket disappeared (`kompose/compose.yml:24-41` vs. `kompose/k3s.yml:60-67`), so Discourse traffic can never terminate.

### Init / lifecycle orchestration
- `logto-init` and `discourse-init` were emitted as naked Pods with `restartPolicy: Never` (`kompose/k3s.yml:256-281`, `kompose/k3s.yml:207-255`). Kubernetes will create them once, but there is no Job controller to re-run them on failure or after node drain, and there is no dependency to wait for Postgres readiness.
- `depends_on` semantics from Compose (e.g., `logto` waiting on `logto-init` and `postgres` at `kompose/compose.yml:66-105`) have no equivalent in the manifest, so your application startup order is entirely race-based now. Rely on readiness probes plus `initContainers` instead.
- Health checks were partially translated into `livenessProbe`s (e.g., MySQL and Meili at `kompose/k3s.yml:385-392` & `kompose/k3s.yml:320-328`), but there are no `readinessProbe`s, so traffic might hit them before they are accepting connections.

### Secrets & configuration
- Database credentials, encryption keys, and proxy passwords are embedded directly inside the Deployment specs (`kompose/k3s.yml:243-251`, `kompose/k3s.yml:377-383`, `kompose/k3s.yml:479-486`, `kompose/k3s.yml:673-685`). Move these into `Secret` objects and reference them via `envFrom`/`valueFrom`.
- The Caddyfile is now a ConfigMap snapshot (`kompose/k3s.yml:112-161`); any edits to `Caddyfile` in Git no longer reach the cluster unless you regenerate/apply the ConfigMap. Consider managing it as a standalone manifest or mount a Secret if it contains credentials.
- The Postgres image relies on a locally built image (`kompose/compose.yml:192-209`). Ensure `dirtbikechina/postgres:15-cjk` exists in a registry accessible to every k3s node; otherwise Pods will remain in `ImagePullBackOff`.

### Multi-node readiness
- With two nodes you must decide where traffic enters the cluster. At present, `caddy` runs a single replica without anti-affinity (`kompose/k3s.yml:32-69`). If that node goes down, all web traffic stops. Consider either running Caddy as a DaemonSet or fronting it with a cloud/VIP load balancer.
- All PVCs use `ReadWriteOnce`; only one node can mount them. If k3s schedules a database pod on the “wrong” node you must either taint/pin nodes (`nodeSelector`, `affinity`) or adopt shared storage.
- There is no backup/restore workflow defined for moving existing Docker volume contents into Kubernetes volumes. Plan a migration step to rsync data into the new PVCs before cutting over.

## Migration outlook
As it stands, applying `kompose/k3s.yml` to a two-node k3s cluster will not yield a functioning stack: Caddy cannot reach any backend, Discourse sockets and WordPress assets are missing, the databases are under-provisioned and bound to a single node, and the initialization flow is undefined. You will need to rework networking (ClusterIP Services + external exposure), storage (StatefulSets + real PVC sizing + shared storage), and init orchestration before attempting the migration.

## Recommended next steps
1. **Define Services and ports** – Add `expose` entries in `kompose/compose.yml` (e.g., `expose: ["3001","3002"]` for Logto, `["3306"]` for MySQL, `["5432"]` for Postgres, etc.) or craft Services manually so every component has stable DNS. Re-run `kompose convert` afterward.
2. **Model stateful workloads properly** – Replace the generated Deployments with `StatefulSet`s, give each realistic PVC sizes/storage classes, and decide on a storage backend that works across both nodes. Import existing volume data into those PVCs.
3. **Restore critical host mounts** – Re-create the `/var/discourse/shared/standalone` socket mount for Caddy (likely via a hostPath PV) and ensure WordPress/Caddy data from the host is copied into the cluster.
4. **Implement init & readiness logic** – Convert `discourse-init`/`logto-init` to `Job`s or `initContainers`, add readiness probes for the databases and HTTP apps, and encode ordering via those probes rather than `depends_on`.
5. **Harden config & secrets** – Move credentials to Kubernetes `Secret`s, keep the Caddyfile as a managed ConfigMap, and verify the custom Postgres image is published.
6. **Plan ingress & HA** – Decide whether Caddy remains the ingress layer or if you should switch to a native Ingress controller. Configure a `LoadBalancer`/`NodePort` Service and scale/anti-affinity so traffic survives a node loss.

Once those items are addressed, re-run the migration in a staging namespace, validate traffic across both nodes, and only then cut over production DNS.

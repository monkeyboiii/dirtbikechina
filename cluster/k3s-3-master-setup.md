# k3s 3-Master High Availability Setup Guide

## Overview

This guide walks through setting up a **3-master, 3-node k3s cluster** for high availability. This configuration eliminates the single point of failure of a single-master setup.

**Benefits**:
- ✅ **Control plane HA**: If one master fails, the other two maintain cluster operations
- ✅ **etcd HA**: Distributed etcd across 3 nodes (can tolerate 1 node failure)
- ✅ **No additional hardware**: Same 3 nodes, just configured differently
- ✅ **Worker capacity**: All 3 nodes run workloads (masters are also workers)

**Architecture**:
```
┌────────────────────────────────────────────────────────┐
│          k3s High Availability Cluster                  │
│                                                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │
│  │  master-1   │  │  master-2   │  │  master-3   │   │
│  │             │  │             │  │             │   │
│  │ Control ✓   │  │ Control ✓   │  │ Control ✓   │   │
│  │ etcd ✓      │  │ etcd ✓      │  │ etcd ✓      │   │
│  │ Worker ✓    │  │ Worker ✓    │  │ Worker ✓    │   │
│  │ Workloads   │  │ Workloads   │  │ Workloads   │   │
│  └─────────────┘  └─────────────┘  └─────────────┘   │
│                                                         │
│  Quorum: 2/3 nodes needed for writes                  │
│  Failure tolerance: 1 node can fail                    │
└────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### Hardware Requirements (Per Node)

**Minimum**:
- 2 CPUs
- 4GB RAM
- 40GB storage
- Network connectivity between nodes

**Recommended for Production**:
- 4 CPUs
- 8GB RAM
- 100GB SSD storage
- 1 Gbps network

### Operating System

- Ubuntu 22.04 LTS (recommended)
- Debian 11/12
- CentOS/RHEL 8+
- Other systemd-based Linux

### Networking

- **Static IP addresses** for all master nodes (required)
- **Hostnames** configured and resolvable
- **Firewall rules** allowing k3s ports:
  - `6443`: Kubernetes API server
  - `2379-2380`: etcd client/peer communication
  - `10250`: Kubelet metrics
  - `8472`: Flannel VXLAN (default CNI)

---

## Installation Steps

### Step 1: Prepare All Nodes

Run on **all 3 nodes** (master-1, master-2, master-3):

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Set hostnames
sudo hostnamectl set-hostname master-1  # master-1
sudo hostnamectl set-hostname master-2  # master-2
sudo hostnamectl set-hostname master-3  # master-3

# Add hosts entries (replace with your actual IPs)
cat <<EOF | sudo tee -a /etc/hosts
192.168.1.10 master-1
192.168.1.11 master-2
192.168.1.12 master-3
EOF

# Disable swap (required by Kubernetes)
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fswap

# Install required packages
sudo apt install -y curl wget vim net-tools

# Configure firewall (ufw example)
sudo ufw allow 6443/tcp    # K8s API
sudo ufw allow 2379:2380/tcp  # etcd
sudo ufw allow 10250/tcp   # Kubelet
sudo ufw allow 8472/udp    # Flannel VXLAN
sudo ufw enable
```

### Step 2: Install k3s on First Master

On **master-1** only:

```bash
# Install k3s with cluster-init flag (embedded etcd HA)
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --write-kubeconfig-mode=644 \
  --tls-san=master-1 \
  --tls-san=192.168.1.10 \
  --disable=traefik \
  --disable=servicelb

# Wait for k3s to be ready
sudo systemctl status k3s
```

**Explanation of flags**:
- `--cluster-init`: Initialize embedded etcd cluster (HA mode)
- `--write-kubeconfig-mode=644`: Allows non-root users to read kubeconfig
- `--tls-san`: Add SANs to API server certificate (for load balancer)
- `--disable=traefik`: We'll install Traefik separately with custom config
- `--disable=servicelb`: We'll use MetalLB or cloud load balancer

**Verify first master**:
```bash
# Check node status
sudo kubectl get nodes

# Should show:
# NAME       STATUS   ROLES                  AGE   VERSION
# master-1   Ready    control-plane,master   1m    v1.28.x+k3s1

# Get cluster token (needed for other masters)
sudo cat /var/lib/rancher/k3s/server/node-token
# Save this token securely!
```

### Step 3: Join Second Master

On **master-2**:

```bash
# Replace <TOKEN> with token from master-1
# Replace <MASTER1_IP> with actual IP of master-1

export K3S_TOKEN="<TOKEN_FROM_MASTER_1>"
export MASTER1_IP="192.168.1.10"

curl -sfL https://get.k3s.io | sh -s - server \
  --server https://${MASTER1_IP}:6443 \
  --token ${K3S_TOKEN} \
  --write-kubeconfig-mode=644 \
  --tls-san=master-2 \
  --tls-san=192.168.1.11 \
  --disable=traefik \
  --disable=servicelb

# Wait for k3s to start
sudo systemctl status k3s
```

**Verify on master-1**:
```bash
sudo kubectl get nodes

# Should now show 2 nodes:
# NAME       STATUS   ROLES                  AGE   VERSION
# master-1   Ready    control-plane,master   5m    v1.28.x+k3s1
# master-2   Ready    control-plane,master   1m    v1.28.x+k3s1
```

### Step 4: Join Third Master

On **master-3**:

```bash
export K3S_TOKEN="<TOKEN_FROM_MASTER_1>"
export MASTER1_IP="192.168.1.10"

curl -sfL https://get.k3s.io | sh -s - server \
  --server https://${MASTER1_IP}:6443 \
  --token ${K3S_TOKEN} \
  --write-kubeconfig-mode=644 \
  --tls-san=master-3 \
  --tls-san=192.168.1.12 \
  --disable=traefik \
  --disable=servicelb

sudo systemctl status k3s
```

**Verify all 3 masters**:
```bash
sudo kubectl get nodes

# Should show:
# NAME       STATUS   ROLES                  AGE   VERSION
# master-1   Ready    control-plane,master   10m   v1.28.x+k3s1
# master-2   Ready    control-plane,master   5m    v1.28.x+k3s1
# master-3   Ready    control-plane,master   1m    v1.28.x+k3s1
```

### Step 5: Verify etcd Cluster

Check that etcd is running on all 3 nodes:

```bash
# On any master node
sudo k3s etcd-snapshot save --name test-snapshot
sudo k3s etcd-snapshot ls

# Check etcd members
sudo k3s kubectl exec -n kube-system \
  $(sudo k3s kubectl get pods -n kube-system -l component=etcd -o name | head -1) \
  -- etcdctl --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
  member list

# Should show 3 members
```

---

## Post-Installation Configuration

### 1. Configure kubectl for Remote Access

On your local machine (laptop/workstation):

```bash
# Copy kubeconfig from any master
scp root@master-1:/etc/rancher/k3s/k3s.yaml ~/.kube/config-dirtbikechina

# Edit kubeconfig to use public IP (not 127.0.0.1)
sed -i 's/127.0.0.1/<MASTER_PUBLIC_IP>/g' ~/.kube/config-dirtbikechina

# Use it
export KUBECONFIG=~/.kube/config-dirtbikechina
kubectl get nodes
```

### 2. Label Nodes (Optional but Recommended)

```bash
# Add labels for node roles and zones
kubectl label node master-1 node.role=master zone=a
kubectl label node master-2 node.role=master zone=b
kubectl label node master-3 node.role=master zone=c

# Add taints to prevent non-system workloads on masters (optional)
# kubectl taint node master-1 node-role.kubernetes.io/master=true:NoSchedule
# kubectl taint node master-2 node-role.kubernetes.io/master=true:NoSchedule
# kubectl taint node master-3 node-role.kubernetes.io/master=true:NoSchedule

# Note: For small clusters, we want workloads on masters, so skip taints
```

### 3. Install Critical Components

```bash
# Install Longhorn storage
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.5.3/deploy/longhorn.yaml

# Install Traefik with custom values
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik \
  --namespace ingress-system --create-namespace \
  --set deployment.replicas=3 \
  --set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=100 \
  --set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.topologyKey=kubernetes.io/hostname

# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

---

## High Availability Testing

### Test 1: Master Failure

Simulate master-2 failure:

```bash
# On master-2
sudo systemctl stop k3s

# On master-1
kubectl get nodes
# master-2 should show NotReady after ~40s

# Verify cluster still functional
kubectl get pods -A
kubectl run test --image=nginx --restart=Never
kubectl delete pod test

# Cluster should work normally with 2/3 masters

# Restore master-2
# On master-2
sudo systemctl start k3s
```

### Test 2: etcd Quorum

Check etcd health during failure:

```bash
# While master-2 is down
kubectl -n kube-system logs $(kubectl get pod -n kube-system -l component=etcd -o name | head -1)

# Should show: "etcd cluster is healthy" (2/3 quorum maintained)
```

### Test 3: API Server Availability

```bash
# Test API server on each master
curl -k https://master-1:6443/healthz  # Should return "ok"
curl -k https://master-2:6443/healthz  # Should return "ok" (if up)
curl -k https://master-3:6443/healthz  # Should return "ok"
```

---

## Load Balancer Setup (Production)

For production, add a load balancer in front of the 3 API servers:

### Option A: HAProxy (recommended)

On a separate node (not one of the 3 masters):

```bash
sudo apt install -y haproxy

sudo cat <<EOF > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend k8s-api
    bind *:6443
    mode tcp
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    balance roundrobin
    option tcp-check
    server master-1 192.168.1.10:6443 check fall 3 rise 2
    server master-2 192.168.1.11:6443 check fall 3 rise 2
    server master-3 192.168.1.12:6443 check fall 3 rise 2
EOF

sudo systemctl restart haproxy
sudo systemctl enable haproxy
```

Update kubeconfig to use load balancer:
```bash
# On local machine
sed -i 's/<MASTER_IP>/<LOAD_BALANCER_IP>/g' ~/.kube/config-dirtbikechina
```

### Option B: Cloud Load Balancer

If using cloud provider (AWS, GCP, Azure):
- Create TCP load balancer
- Add all 3 masters to backend pool
- Health check: TCP port 6443
- Update kubeconfig to use LB DNS/IP

---

## Backup and Disaster Recovery

### Backup etcd Snapshots

```bash
# Manual snapshot
sudo k3s etcd-snapshot save --name manual-backup-$(date +%Y%m%d-%H%M%S)

# List snapshots
sudo k3s etcd-snapshot ls

# Snapshots stored in: /var/lib/rancher/k3s/server/db/snapshots/
```

### Automated Snapshot CronJob

```bash
# On each master, add cron job
sudo crontab -e

# Add line (daily at 2 AM)
0 2 * * * /usr/local/bin/k3s etcd-snapshot save --name auto-$(date +\%Y\%m\%d) >> /var/log/k3s-snapshot.log 2>&1
```

### Restore from Snapshot

If cluster is completely lost:

```bash
# On master-1 (with all other masters stopped)
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>

# Wait for restore to complete, then start k3s normally
sudo systemctl start k3s

# Rejoin other masters (they will sync from master-1)
```

---

## Upgrade Procedure

Upgrade one master at a time to avoid downtime:

```bash
# 1. Drain master-1
kubectl drain master-1 --ignore-daemonsets --delete-emptydir-data

# 2. Upgrade k3s on master-1
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.5+k3s1 sh -s - server \
  --cluster-init \
  --write-kubeconfig-mode=644 \
  --disable=traefik --disable=servicelb

# 3. Uncordon master-1
kubectl uncordon master-1

# 4. Wait for pods to reschedule and stabilize
kubectl get pods -A --watch

# 5. Repeat for master-2 and master-3
kubectl drain master-2 --ignore-daemonsets --delete-emptydir-data
# ... upgrade master-2 ...
kubectl uncordon master-2

kubectl drain master-3 --ignore-daemonsets --delete-emptydir-data
# ... upgrade master-3 ...
kubectl uncordon master-3
```

---

## Troubleshooting

### Issue: Master won't join cluster

**Symptoms**: `connection refused` or timeout when joining

**Solutions**:
1. Check firewall:
   ```bash
   sudo ufw status
   # Ensure ports 6443, 2379-2380 are open
   ```

2. Verify token:
   ```bash
   # On master-1
   sudo cat /var/lib/rancher/k3s/server/node-token
   # Use exact token (no extra spaces)
   ```

3. Check k3s logs:
   ```bash
   sudo journalctl -u k3s -f
   ```

### Issue: etcd unhealthy

**Symptoms**: `etcdserver: request timeout`

**Solutions**:
1. Check disk I/O (etcd is disk-sensitive):
   ```bash
   iostat -x 1
   # If %util is high, etcd will be slow
   ```

2. Check etcd member status:
   ```bash
   kubectl -n kube-system exec etcd-master-1 -- etcdctl member list
   ```

3. Remove unhealthy member and rejoin:
   ```bash
   # On healthy master
   kubectl -n kube-system exec etcd-master-1 -- etcdctl member remove <MEMBER_ID>

   # On failed master, reset and rejoin
   sudo systemctl stop k3s
   sudo rm -rf /var/lib/rancher/k3s/server/db
   # Re-run k3s server --server https://... command
   ```

### Issue: Split-brain scenario

**Prevention**: Always maintain odd number of masters (3, 5, 7)

**Recovery**:
```bash
# Stop all masters
# Restore from snapshot on one master
# Rejoin others
```

---

## Cost Optimization

### Single-Node Dev/Test

For development, you can run 1-node "HA" cluster:

```bash
curl -sfL https://get.k3s.io | sh -s - server --cluster-init

# This gives embedded etcd (for PITR testing) without HA benefits
```

### Scale Up to HA Later

Add masters to existing single-node cluster:

```bash
# Get token from existing node
sudo cat /var/lib/rancher/k3s/server/node-token

# On new master nodes
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<EXISTING_MASTER>:6443 \
  --token <TOKEN>
```

---

## Best Practices

1. ✅ **Use static IPs** for all masters
2. ✅ **Configure external load balancer** for API server
3. ✅ **Automate etcd backups** (daily cron)
4. ✅ **Monitor etcd health** (Prometheus metrics)
5. ✅ **Test failover procedures** regularly
6. ✅ **Keep k3s versions in sync** across masters
7. ✅ **Use SSD storage** for etcd (latency-sensitive)
8. ✅ **Separate etcd from heavy I/O workloads**
9. ✅ **Document recovery procedures**
10. ✅ **Maintain backup of kubeconfig and tokens**

---

## Summary

**3-Master k3s cluster provides**:
- ✅ Control plane high availability
- ✅ etcd quorum (2/3 nodes)
- ✅ API server redundancy
- ✅ Zero downtime upgrades
- ✅ Disaster recovery capability
- ✅ Production-ready foundation

**Next steps**:
1. Deploy applications: `kubectl apply -k cluster/environments/prod/`
2. Set up monitoring: Prometheus + Grafana
3. Configure backups: Velero + etcd snapshots
4. Test failover scenarios

---

**Document Version**: 1.0
**Last Updated**: 2025-11-17
**k3s Version**: v1.28.x

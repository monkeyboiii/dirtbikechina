# SealedSecrets Setup and Usage Guide

## Overview

SealedSecrets provides encrypted storage of Kubernetes secrets in Git repositories. The controller decrypts them at runtime in the cluster.

**Key Benefit**: Safe to commit encrypted secrets to public Git repos.

## Installation

### Step 1: Install Sealed Secrets Controller

```bash
# Install controller in kube-system namespace
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Wait for controller to be ready
kubectl wait --for=condition=ready pod -l name=sealed-secrets-controller -n kube-system --timeout=120s

# Verify installation
kubectl get pods -n kube-system -l name=sealed-secrets-controller
```

### Step 2: Install kubeseal CLI

```bash
# Linux
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
tar xfz kubeseal-0.24.0-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal

# macOS
brew install kubeseal

# Verify
kubeseal --version
```

## Usage

### Creating SealedSecrets

#### Example 1: PostgreSQL Credentials

```bash
# Create regular secret (DO NOT COMMIT THIS)
kubectl create secret generic postgres-credentials \
  --namespace infra \
  --from-literal=username=postgres \
  --from-literal=password='your-secure-password-here' \
  --dry-run=client \
  -o yaml > /tmp/postgres-secret.yaml

# Encrypt with kubeseal (SAFE TO COMMIT)
kubeseal --format yaml \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  < /tmp/postgres-secret.yaml \
  > cluster/base/secrets/postgres-sealed-secret.yaml

# Clean up plaintext
rm /tmp/postgres-secret.yaml

# Apply to cluster
kubectl apply -f cluster/base/secrets/postgres-sealed-secret.yaml
```

The controller automatically creates the actual Secret from the SealedSecret.

#### Example 2: MySQL Credentials

```bash
kubectl create secret generic mysql-credentials \
  --namespace infra \
  --from-literal=username=wordpress \
  --from-literal=password='mysql-password-here' \
  --from-literal=root-password='root-password-here' \
  --dry-run=client -o yaml | \
kubeseal --format yaml > cluster/base/secrets/mysql-sealed-secret.yaml

kubectl apply -f cluster/base/secrets/mysql-sealed-secret.yaml
```

#### Example 3: Discourse Credentials

```bash
kubectl create secret generic discourse-credentials \
  --namespace infra \
  --from-literal=db-password='discourse-db-password' \
  --from-literal=smtp-password='smtp-password' \
  --dry-run=client -o yaml | \
kubeseal --format yaml > cluster/base/secrets/discourse-sealed-secret.yaml
```

#### Example 4: Off-Site Backup Credentials (rclone)

```bash
# Create rclone.conf file first
cat > /tmp/rclone.conf <<EOF
[b2]
type = b2
account = YOUR_B2_APP_KEY_ID
key = YOUR_B2_APP_KEY
hard_delete = false

[s3]
type = s3
provider = AWS
access_key_id = YOUR_AWS_ACCESS_KEY
secret_access_key = YOUR_AWS_SECRET_KEY
region = us-east-1
EOF

kubectl create secret generic offsite-backup-credentials \
  --namespace infra \
  --from-file=rclone.conf=/tmp/rclone.conf \
  --dry-run=client -o yaml | \
kubeseal --format yaml > cluster/base/secrets/backup-sealed-secret.yaml

rm /tmp/rclone.conf
```

## How It Works

```
Developer Machine:
  1. Create plaintext Secret (never committed)
  2. Encrypt with kubeseal → SealedSecret (YAML)
  3. Commit SealedSecret to Git ✅

Kubernetes Cluster:
  1. Apply SealedSecret manifest
  2. Controller decrypts using private key
  3. Creates actual Secret in namespace
  4. Pods consume Secret normally
```

## Security Properties

- ✅ **Encrypted at rest**: SealedSecrets are encrypted with cluster public key
- ✅ **Namespace-scoped**: Can only be decrypted in target namespace
- ✅ **Name-scoped**: Sealed to specific secret name
- ✅ **Safe in Git**: Public repos OK, attackers can't decrypt without cluster private key
- ✅ **Rotation**: Supports automatic key rotation (30 days default)

## Re-encrypting for Different Namespaces

SealedSecrets are namespace-scoped by default. To use the same secret in multiple namespaces:

```bash
# Option A: Create per-namespace sealed secrets
for ns in prod stage dev test; do
  kubectl create secret generic mysql-credentials \
    --namespace $ns \
    --from-literal=username=wordpress \
    --from-literal=password='same-password' \
    --dry-run=client -o yaml | \
  kubeseal --format yaml > cluster/base/secrets/mysql-sealed-secret-$ns.yaml
done

# Option B: Use cluster-wide scope (less secure, not recommended)
kubeseal --scope cluster-wide --format yaml < secret.yaml > sealed-secret.yaml
```

## Backup and Disaster Recovery

### Backup Sealing Key

```bash
# Export sealing key (KEEP VERY SECURE!)
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o yaml > sealed-secrets-master-key.yaml

# Store in secure location:
# - Password manager
# - Encrypted backup drive
# - HSM / key vault
```

### Restore Sealing Key (Disaster Recovery)

```bash
# Restore to new cluster
kubectl apply -f sealed-secrets-master-key.yaml
kubectl delete pod -n kube-system -l name=sealed-secrets-controller

# Wait for controller restart
kubectl wait --for=condition=ready pod -l name=sealed-secrets-controller -n kube-system

# All SealedSecrets can now be decrypted again
```

## Rotation

### Rotate Sealing Keys

```bash
# Manual rotation (creates new key, keeps old ones for decryption)
kubectl -n kube-system create secret tls sealed-secrets-custom-key \
  --cert=tls.crt --key=tls.key

kubectl -n kube-system label secret sealed-secrets-custom-key \
  sealedsecrets.bitnami.com/sealed-secrets-key=active

kubectl delete pod -n kube-system -l name=sealed-secrets-controller
```

After rotation, re-seal all secrets with new key:

```bash
# Re-encrypt all secrets
for file in cluster/base/secrets/*-sealed-secret.yaml; do
  kubectl apply -f $file  # Deploy old version
  kubectl get secret <name> -n <namespace> -o yaml | \
    kubectl create -f - --dry-run=client -o yaml | \
    kubeseal --format yaml > $file.new
  mv $file.new $file
done
```

## Troubleshooting

### Check if SealedSecret was decrypted

```bash
# Check SealedSecret status
kubectl get sealedsecret -A

# Check if corresponding Secret exists
kubectl get secret postgres-credentials -n infra

# View controller logs
kubectl logs -n kube-system -l name=sealed-secrets-controller
```

### Common Errors

**Error**: "unable to decrypt sealed secret"
- **Cause**: Wrong namespace or name
- **Fix**: Re-seal with correct namespace and name

**Error**: "no key to decrypt secret"
- **Cause**: Sealing key was rotated and old key removed
- **Fix**: Re-seal secret with current key

## Best Practices

1. ✅ **Never commit plaintext secrets** to Git
2. ✅ **Use namespace-scoped** sealing (default)
3. ✅ **Backup sealing keys** securely
4. ✅ **Rotate keys** annually
5. ✅ **Audit secret access** in applications
6. ✅ **Use RBAC** to limit who can read Secrets
7. ✅ **Test disaster recovery** procedure

## Integration with Deployment Scripts

Update `cluster/scripts/deploy.sh`:

```bash
# Deploy SealedSecrets controller first
deploy_sealed_secrets() {
  log_info "Installing SealedSecrets controller..."
  kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml
  kubectl wait --for=condition=ready pod -l name=sealed-secrets-controller -n kube-system --timeout=120s
}

# Deploy sealed secrets
deploy_secrets() {
  log_info "Deploying SealedSecrets..."
  kubectl apply -f cluster/base/secrets/
}

# In main deployment flow:
# 1. Install controller
# 2. Deploy sealed secrets
# 3. Verify secrets created
# 4. Deploy apps
```

## Migration from Existing Secrets

If you already have secrets in the cluster:

```bash
# Export existing secret
kubectl get secret postgres-credentials -n infra -o yaml > /tmp/existing-secret.yaml

# Remove metadata that would cause conflicts
sed -i '/uid:/d; /resourceVersion:/d; /creationTimestamp:/d' /tmp/existing-secret.yaml

# Seal it
kubeseal --format yaml < /tmp/existing-secret.yaml > cluster/base/secrets/postgres-sealed-secret.yaml

# Delete old secret
kubectl delete secret postgres-credentials -n infra

# Apply sealed version
kubectl apply -f cluster/base/secrets/postgres-sealed-secret.yaml

# Verify
kubectl get secret postgres-credentials -n infra
```

## Alternative: External Secrets Operator

If you need secrets from external sources (AWS Secrets Manager, HashiCorp Vault, etc.):

```yaml
# cluster/base/secrets/external-secret-example.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-credentials
  namespace: infra
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: postgres-credentials
  data:
  - secretKey: username
    remoteRef:
      key: dirtbikechina/postgres
      property: username
  - secretKey: password
    remoteRef:
      key: dirtbikechina/postgres
      property: password
```

**Use Case**: Multi-cluster deployments, centralized secret management, compliance requirements.

---

**Document Version**: 1.0
**Last Updated**: 2025-11-17
**Status**: Production Ready

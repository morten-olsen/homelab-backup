# Longhorn Backup Helm Chart

A comprehensive backup solution for Longhorn PVCs with support for:
- **TrueNAS (NFS)** as primary backup target (fast, local)
- **Backblaze B2** as secondary encrypted offsite backup
- Automated retention policies (7 daily, 5 weekly backups)
- Backup validation and notifications
- Disaster recovery support

## Architecture

```
+-------------------+     +------------------+     +-------------------+
|   Kubernetes      |     |    TrueNAS       |     |   Backblaze B2    |
|   Cluster         |     |    (NFS)         |     |   (Encrypted)     |
|                   |     |                  |     |                   |
| +---------------+ |     |                  |     |                   |
| | Longhorn      | |     |                  |     |                   |
| | Backups       |------>| Primary Target   |---->| Offsite Copy      |
| +---------------+ |     | (Incremental)    |     | (Encrypted)       |
|                   |     |                  |     |                   |
| +---------------+ |     +------------------+     +-------------------+
| | CronJobs:     | |
| | - B2 Sync     | |
| | - Validation  | |
| | - Indexer     | |
| +---------------+ |
+-------------------+
```

## Prerequisites

1. **Longhorn** installed and running (tested with v1.5+)
2. **TrueNAS** or other NFS server accessible from the cluster
3. **Backblaze B2** account with bucket and application key
4. **Sealed Secrets** for managing sensitive credentials

## Quick Start

### 1. Create Sealed Secrets

First, create the required secrets for B2 credentials and encryption:

```bash
# Generate encryption password and salt
# IMPORTANT: Save these values securely - you need them for disaster recovery!
CRYPT_PASSWORD=$(openssl rand -base64 32)
CRYPT_SALT=$(openssl rand -base64 32)

# Obscure the passwords for rclone
OBSCURED_PASSWORD=$(echo -n "$CRYPT_PASSWORD" | rclone obscure -)
OBSCURED_SALT=$(echo -n "$CRYPT_SALT" | rclone obscure -)

# Create B2 credentials secret
kubectl create secret generic longhorn-backup-b2-credentials \
  --namespace=longhorn-backup \
  --from-literal=AWS_ACCESS_KEY_ID=<your-b2-key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-b2-app-key> \
  --dry-run=client -o yaml | kubeseal -o yaml > b2-credentials-sealed.yaml

# Create encryption secret
kubectl create secret generic longhorn-backup-b2-encryption \
  --namespace=longhorn-backup \
  --from-literal=password="$OBSCURED_PASSWORD" \
  --from-literal=salt="$OBSCURED_SALT" \
  --dry-run=client -o yaml | kubeseal -o yaml > b2-encryption-sealed.yaml

# Apply sealed secrets
kubectl apply -f b2-credentials-sealed.yaml
kubectl apply -f b2-encryption-sealed.yaml
```

### 2. Configure values.yaml

```yaml
# values.yaml
longhorn:
  namespace: longhorn  # Adjust if different

nfs:
  enabled: true
  server: "192.168.1.100"  # Your TrueNAS IP
  path: "/mnt/pool/kubernetes-backups"

backblaze:
  enabled: true
  bucket: "your-bucket-name"
  endpoint: "https://s3.us-west-004.backblazeb2.com"
  existingSecret: "longhorn-backup-b2-credentials"
  encryption:
    existingSecret: "longhorn-backup-b2-encryption"

notifications:
  enabled: true
  webhookUrl: "https://discord.com/api/webhooks/..."
```

### 3. Deploy with ArgoCD

Create an ArgoCD Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn-backup
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo
    targetRevision: main
    path: chart
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-backup
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 4. Add PVCs to Backup

```bash
# Add a PVC to daily backups
./scripts/add-pvc-to-backup.sh prod my-app-data daily

# Add a PVC to both daily and weekly backups
./scripts/add-pvc-to-backup.sh prod critical-data both
```

## PVC Labels and Annotations

The backup system uses labels and annotations to identify and track PVCs. These are managed automatically by the `add-pvc-to-backup.sh` script, but can also be applied manually.

### Labels

| Label | Required | Values | Description |
|-------|----------|--------|-------------|
| `backup.home.lab/enabled` | **Yes** | `true` | Marks the PVC for backup. The validation and indexer jobs only process PVCs with this label. |
| `backup.home.lab/tier` | No | `daily`, `weekly`, `both` | Indicates which backup schedule the PVC belongs to. Used for documentation/filtering purposes. |

### Annotations

| Annotation | Set By | Description |
|------------|--------|-------------|
| `backup.home.lab/added-at` | Script | Timestamp when the PVC was added to the backup schedule. |
| `backup.home.lab/source-namespace` | Script | Original namespace of the PVC (useful for tracking after restores). |
| `backup.home.lab/source-pvc` | Script | Original PVC name (useful for tracking after restores). |
| `backup.home.lab/restored-from` | Script | Name of the backup used to restore this PVC (set during restore). |
| `backup.home.lab/restored-at` | Script | Timestamp when this PVC was restored from backup. |
| `backup.home.lab/removed-from-backup-at` | Script | Timestamp when the PVC was removed from backup schedule. |

### Longhorn Volume Labels

In addition to PVC labels, the backup system adds labels to the underlying Longhorn volume to enable recurring backup jobs:

| Label | Description |
|-------|-------------|
| `recurring-job.longhorn.io/longhorn-backup-daily-backup=enabled` | Enables the daily backup recurring job for this volume. |
| `recurring-job.longhorn.io/longhorn-backup-weekly-backup=enabled` | Enables the weekly backup recurring job for this volume. |

### Manual Labeling Example

If you prefer to label PVCs manually instead of using the script:

```bash
# Add required backup label
kubectl label pvc -n <namespace> <pvc-name> backup.home.lab/enabled=true

# Add optional tier label
kubectl label pvc -n <namespace> <pvc-name> backup.home.lab/tier=daily

# Add annotations for tracking
kubectl annotate pvc -n <namespace> <pvc-name> \
  backup.home.lab/added-at=$(date -Iseconds) \
  backup.home.lab/source-namespace=<namespace> \
  backup.home.lab/source-pvc=<pvc-name>

# Get the Longhorn volume name
VOLUME=$(kubectl get pvc -n <namespace> <pvc-name> -o jsonpath='{.spec.volumeName}')

# Add recurring job label to Longhorn volume
kubectl -n longhorn label volume $VOLUME \
  recurring-job.longhorn.io/longhorn-backup-daily-backup=enabled
```

### Important Notes

1. **Only Longhorn volumes can be backed up** - PVCs using other storage classes (hostPath, local-path, etc.) cannot use Longhorn's backup feature. The label can still be added but no backups will be created.

2. **The `backup.home.lab/enabled=true` label is required** - Without this label, the validation and indexer jobs will not track the PVC.

3. **Longhorn volume labels are required for automatic backups** - The PVC label alone is not enough; the Longhorn volume must also have the `recurring-job.longhorn.io/*` label for the recurring backup jobs to run.

## Configuration

### Values Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `longhorn.namespace` | Namespace where Longhorn is installed | `longhorn` |
| `nfs.enabled` | Enable NFS backup target | `true` |
| `nfs.server` | NFS server IP/hostname | `192.168.1.100` |
| `nfs.path` | NFS export path | `/mnt/pool/kubernetes-backups` |
| `backblaze.enabled` | Enable B2 sync | `true` |
| `backblaze.bucket` | B2 bucket name | `""` |
| `backblaze.endpoint` | B2 S3 endpoint | `https://s3.us-west-004.backblazeb2.com` |
| `recurringJobs.daily.schedule` | Daily backup cron | `0 2 * * *` |
| `recurringJobs.daily.retain` | Daily backups to keep | `7` |
| `recurringJobs.weekly.schedule` | Weekly backup cron | `0 3 * * 0` |
| `recurringJobs.weekly.retain` | Weekly backups to keep | `5` |
| `validation.schedule` | Validation check cron | `0 6 * * *` |
| `validation.errorAgeHours` | Hours before backup age is error | `48` |

### CronJob Schedule

| Job | Default Schedule | Description |
|-----|-----------------|-------------|
| Daily Backup | `0 2 * * *` (2 AM) | Longhorn incremental backup |
| Weekly Backup | `0 3 * * 0` (3 AM Sun) | Longhorn incremental backup |
| B2 Sync | `0 4 * * *` (4 AM) | Sync to B2 with encryption |
| Validation | `0 6 * * *` (6 AM) | Check backup health |
| Indexer | `0 4 30 * *` (4:30 AM) | Generate backup index |

## Common Tasks

### Adding a PVC to Backup

```bash
# Basic usage - adds to daily backup
./scripts/add-pvc-to-backup.sh <namespace> <pvc-name>

# Specify backup tier
./scripts/add-pvc-to-backup.sh <namespace> <pvc-name> daily
./scripts/add-pvc-to-backup.sh <namespace> <pvc-name> weekly
./scripts/add-pvc-to-backup.sh <namespace> <pvc-name> both

# Example
./scripts/add-pvc-to-backup.sh prod postgresql-data both
```

### Removing a PVC from Backup

```bash
# Remove from backup schedule (keeps existing backups)
./scripts/remove-pvc-from-backup.sh <namespace> <pvc-name>

# Remove and delete all backups
./scripts/remove-pvc-from-backup.sh <namespace> <pvc-name> --delete-backups
```

### Listing Backups

```bash
# List all backups
./scripts/list-backups.sh

# Filter by namespace/PVC
./scripts/list-backups.sh prod
./scripts/list-backups.sh prod postgresql-data
```

### Restoring a PVC

```bash
# Restore latest backup
./scripts/restore-pvc.sh <namespace> <pvc-name>

# Restore specific backup
./scripts/restore-pvc.sh <namespace> <pvc-name> backup-abc123

# Restore to different name (for testing)
./scripts/restore-pvc.sh <namespace> <pvc-name> --new-name <new-pvc-name>

# Dry run
./scripts/restore-pvc.sh <namespace> <pvc-name> --dry-run
```

### Manual Backup Trigger

```bash
# Trigger immediate backup job
kubectl -n longhorn-backup create job --from=cronjob/longhorn-backup-b2-sync manual-b2-sync-$(date +%s)

# Trigger validation
kubectl -n longhorn-backup create job --from=cronjob/longhorn-backup-validation manual-validation-$(date +%s)
```

## Disaster Recovery

### Scenario 1: Restore Single PVC

Use when a single PVC is deleted or corrupted:

```bash
./scripts/restore-pvc.sh prod my-app-data
```

### Scenario 2: Cluster Lost, NFS Intact

When the cluster is destroyed but TrueNAS is accessible:

1. **Bootstrap new cluster** with ArgoCD
2. **Deploy Longhorn** via ArgoCD
3. **Deploy this backup chart** via ArgoCD
4. **Restore PVCs** from backup index:

```bash
# Check backup index
cat /mnt/truenas/kubernetes-backups/backup-index.json | jq '.backups[] | {ns: .namespace, pvc: .pvc_name, latest: .backups[-1].name}'

# Restore each PVC
./scripts/restore-pvc.sh prod app1-data
./scripts/restore-pvc.sh prod app2-data
# ... repeat for each PVC
```

### Scenario 3: Complete Disaster (NFS Lost)

When both cluster and NFS are lost, restore from B2:

1. **Install rclone** on recovery machine
2. **Download and decrypt** B2 backups:

```bash
./scripts/restore-from-b2.sh /mnt/recovery
```

3. **Copy to new NFS** or configure Longhorn to use local path
4. **Bootstrap cluster** and restore PVCs as in Scenario 2

### Scenario 4: Restore Outside Kubernetes

For extracting data without Kubernetes:

1. **Download backups** from B2 or mount NFS
2. **Use longhorn-engine** to extract:

```bash
# Install longhorn-engine binary
# https://github.com/longhorn/longhorn-engine

# Extract backup to raw disk image
longhorn-engine backup restore \
  --backup-url "nfs://server/path/backupstore/volumes/<vol>/backups/<backup>" \
  --output /path/to/restored.img

# Mount the image
sudo losetup /dev/loop0 /path/to/restored.img
sudo mount /dev/loop0 /mnt/restored
```

## Pitfalls and Troubleshooting

### Common Issues

#### 1. Backups Not Running

**Symptoms**: No new backups appearing

**Check**:
```bash
# Verify recurring jobs exist
kubectl -n longhorn get recurringjobs

# Check Longhorn volume has job selector
kubectl -n longhorn get volume <vol-name> -o yaml | grep -A5 recurringJobSelector

# Check PVC has backup label
kubectl get pvc -n <ns> <pvc> --show-labels
```

**Solution**: Re-run `add-pvc-to-backup.sh` or manually add labels

#### 2. B2 Sync Failing

**Symptoms**: B2 sync job fails

**Check**:
```bash
# Check job logs
kubectl -n longhorn-backup logs job/longhorn-backup-b2-sync-<id>

# Common issues:
# - Invalid credentials
# - Wrong bucket name
# - Incorrect encryption keys
```

**Solution**: Verify secrets contain correct values

#### 3. NFS Mount Failures

**Symptoms**: Jobs fail with mount errors

**Check**:
```bash
# Test NFS from a pod
kubectl run nfs-test --rm -it --image=busybox -- sh
# Inside pod:
mount -t nfs <server>:<path> /mnt
```

**Common causes**:
- NFS server not exporting to cluster network
- Firewall blocking NFS ports
- Incorrect permissions on export

#### 4. Restore Fails with "Backup Not Found"

**Symptoms**: restore-pvc.sh can't find backup

**Check**:
```bash
# List all backups
kubectl -n longhorn get backup

# Check backup volume
kubectl -n longhorn get backupvolume
```

**Note**: If PVC was deleted with `reclaimPolicy: Delete`, the backup volume metadata might be gone but backups still exist on NFS. Check backup index or NFS directly.

### Best Practices

1. **Test restores regularly** - Don't wait for disaster
2. **Store encryption keys securely** - Password manager, printed copy in safe
3. **Monitor backup age** - Set up alerts for validation failures
4. **Document your PVCs** - Keep track of which PVCs need backup
5. **Use `reclaimPolicy: Retain`** - Prevents accidental data loss

### Recovery Time Estimates

| Scenario | Time Estimate |
|----------|---------------|
| Single PVC restore (10GB) | 5-15 minutes |
| Full cluster restore (100GB) | 1-4 hours |
| B2 download + restore | Add 30min-2h depending on bandwidth |

## Security Considerations

1. **Encryption keys**: Store in password manager AND offline backup
2. **B2 credentials**: Use application keys with minimal permissions
3. **NFS security**: Restrict exports to cluster network only
4. **RBAC**: ServiceAccount has read-only access to PVCs

## Monitoring

The chart sends notifications for:
- B2 sync success/failure
- Validation warnings/errors
- Indexer completion

Configure webhook URL in values.yaml for Discord, Slack, or other webhook-compatible services.

## Support

For issues and feature requests, please open an issue in the repository.

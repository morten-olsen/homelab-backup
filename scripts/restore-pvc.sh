#!/bin/bash
# Restore a PVC from Longhorn backup
# Usage: ./restore-pvc.sh <namespace> <pvc-name> [backup-name] [--new-name <name>]
#
# If backup-name is not specified, the latest backup will be used.
# Use --new-name to restore to a different PVC name (useful for testing).

set -euo pipefail

show_help() {
    cat << EOF
Usage: $0 <namespace> <pvc-name> [backup-name] [options]

Restore a PVC from Longhorn backup.

Arguments:
  namespace     Target namespace for the restored PVC
  pvc-name      Original PVC name (used to find backups)
  backup-name   Specific backup to restore (optional, defaults to latest)

Options:
  --new-name <name>    Restore to a different PVC name
  --size <size>        Override storage size (e.g., 10Gi)
  --storage-class <sc> Override storage class (default: longhorn)
  --dry-run            Show what would be created without applying
  -h, --help           Show this help message

Examples:
  # Restore latest backup
  $0 prod my-app-data

  # Restore specific backup
  $0 prod my-app-data backup-abc123

  # Restore to new name (for testing)
  $0 prod my-app-data --new-name my-app-data-restored

  # Dry run
  $0 prod my-app-data --dry-run
EOF
}

# Parse arguments
NAMESPACE=""
ORIGINAL_PVC=""
BACKUP_NAME=""
NEW_NAME=""
SIZE=""
STORAGE_CLASS="longhorn"
DRY_RUN=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --new-name)
            NEW_NAME="$2"
            shift 2
            ;;
        --size)
            SIZE="$2"
            shift 2
            ;;
        --storage-class)
            STORAGE_CLASS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        *)
            if [ -z "$NAMESPACE" ]; then
                NAMESPACE="$1"
            elif [ -z "$ORIGINAL_PVC" ]; then
                ORIGINAL_PVC="$1"
            elif [ -z "$BACKUP_NAME" ]; then
                BACKUP_NAME="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$NAMESPACE" ] || [ -z "$ORIGINAL_PVC" ]; then
    show_help
    exit 1
fi

# Set restore PVC name
RESTORE_PVC=${NEW_NAME:-$ORIGINAL_PVC}

# Get Longhorn namespace
LONGHORN_NS=${LONGHORN_NS:-"longhorn"}

echo "=========================================="
echo "PVC Restore - $(date -Iseconds)"
echo "=========================================="
echo "Namespace: ${NAMESPACE}"
echo "Original PVC: ${ORIGINAL_PVC}"
echo "Restore PVC: ${RESTORE_PVC}"
echo ""

# Try to find the volume name from backup index or existing PVC
VOLUME_NAME=""

# Check if PVC still exists
if kubectl get pvc -n "${NAMESPACE}" "${ORIGINAL_PVC}" > /dev/null 2>&1; then
    VOLUME_NAME=$(kubectl get pvc -n "${NAMESPACE}" "${ORIGINAL_PVC}" -o jsonpath='{.spec.volumeName}')
    echo "Found existing PVC with volume: ${VOLUME_NAME}"
fi

# If no backup name specified, find the latest
if [ -z "$BACKUP_NAME" ]; then
    echo "Searching for backups..."
    
    if [ -n "$VOLUME_NAME" ]; then
        # Find backups by volume name
        LATEST_BACKUP=$(kubectl -n "${LONGHORN_NS}" get backup -l longhornvolume="${VOLUME_NAME}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.backupCreatedAt}{"\n"}{end}' 2>/dev/null | \
            sort -k2 -r | head -1 | cut -f1)
        
        if [ -n "$LATEST_BACKUP" ]; then
            BACKUP_NAME="$LATEST_BACKUP"
            echo "Found latest backup: ${BACKUP_NAME}"
        fi
    fi
    
    if [ -z "$BACKUP_NAME" ]; then
        # Try to find from backup volumes
        echo "Searching backup volumes..."
        
        # List all backup volumes and their backups
        kubectl -n "${LONGHORN_NS}" get backupvolume -o json 2>/dev/null | \
            jq -r '.items[] | "\(.metadata.name)\t\(.status.lastBackupName // "none")"' | \
            while read -r line; do
                echo "  ${line}"
            done
        
        echo ""
        echo "ERROR: Could not find backups automatically."
        echo "Please specify the backup name explicitly."
        echo ""
        echo "To list available backups:"
        echo "  kubectl -n ${LONGHORN_NS} get backup"
        echo ""
        echo "Or check the backup index on your NFS share:"
        echo "  cat /path/to/nfs/backup-index.json"
        exit 1
    fi
fi

# Get backup details
echo ""
echo "Fetching backup details..."
BACKUP_INFO=$(kubectl -n "${LONGHORN_NS}" get backup "${BACKUP_NAME}" -o json 2>/dev/null)

if [ -z "$BACKUP_INFO" ] || [ "$BACKUP_INFO" == "null" ]; then
    echo "ERROR: Backup '${BACKUP_NAME}' not found"
    echo ""
    echo "Available backups:"
    kubectl -n "${LONGHORN_NS}" get backup --no-headers | head -20
    exit 1
fi

# Extract backup details
BACKUP_URL=$(echo "$BACKUP_INFO" | jq -r '.status.url')
BACKUP_SIZE=$(echo "$BACKUP_INFO" | jq -r '.status.size')
BACKUP_STATE=$(echo "$BACKUP_INFO" | jq -r '.status.state')
BACKUP_CREATED=$(echo "$BACKUP_INFO" | jq -r '.status.backupCreatedAt')

echo "Backup: ${BACKUP_NAME}"
echo "State: ${BACKUP_STATE}"
echo "Created: ${BACKUP_CREATED}"
echo "Size: ${BACKUP_SIZE}"

if [ "$BACKUP_STATE" != "Completed" ]; then
    echo "WARNING: Backup state is '${BACKUP_STATE}', not 'Completed'"
    read -p "Continue anyway? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Restore cancelled."
        exit 1
    fi
fi

# Determine storage size
if [ -z "$SIZE" ]; then
    # Try to get from original PVC
    if kubectl get pvc -n "${NAMESPACE}" "${ORIGINAL_PVC}" > /dev/null 2>&1; then
        SIZE=$(kubectl get pvc -n "${NAMESPACE}" "${ORIGINAL_PVC}" -o jsonpath='{.spec.resources.requests.storage}')
    fi
    
    # Fallback: calculate from backup size (convert bytes to Gi, round up)
    if [ -z "$SIZE" ] && [ -n "$BACKUP_SIZE" ] && [ "$BACKUP_SIZE" != "null" ]; then
        SIZE_GI=$(( (BACKUP_SIZE / 1073741824) + 1 ))
        SIZE="${SIZE_GI}Gi"
    fi
    
    # Final fallback
    SIZE=${SIZE:-"10Gi"}
fi

echo ""
echo "Restore configuration:"
echo "  Target PVC: ${NAMESPACE}/${RESTORE_PVC}"
echo "  Storage Class: ${STORAGE_CLASS}"
echo "  Size: ${SIZE}"
echo "  From Backup: ${BACKUP_NAME}"
echo ""

# Check if target PVC already exists
if kubectl get pvc -n "${NAMESPACE}" "${RESTORE_PVC}" > /dev/null 2>&1; then
    echo "WARNING: PVC ${NAMESPACE}/${RESTORE_PVC} already exists!"
    
    if [ "$RESTORE_PVC" == "$ORIGINAL_PVC" ]; then
        echo ""
        echo "To restore to the same name, you must first delete the existing PVC."
        echo "This is a destructive operation!"
        echo ""
        read -p "Delete existing PVC and restore? (yes/no): " CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            echo "Restore cancelled."
            echo "Tip: Use --new-name to restore to a different PVC name."
            exit 1
        fi
        
        echo "Deleting existing PVC..."
        kubectl delete pvc -n "${NAMESPACE}" "${RESTORE_PVC}" --wait=true
    else
        echo "Please choose a different name with --new-name"
        exit 1
    fi
fi

# Create the restore PVC manifest
RESTORE_MANIFEST=$(cat << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${RESTORE_PVC}
  namespace: ${NAMESPACE}
  labels:
    backup.home.lab/enabled: "true"
    backup.home.lab/restored: "true"
  annotations:
    backup.home.lab/restored-from: "${BACKUP_NAME}"
    backup.home.lab/restored-at: "$(date -Iseconds)"
    backup.home.lab/original-pvc: "${ORIGINAL_PVC}"
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${SIZE}
  dataSource:
    kind: Backup
    apiGroup: longhorn.io
    name: ${BACKUP_NAME}
EOF
)

echo "Generated PVC manifest:"
echo "---"
echo "$RESTORE_MANIFEST"
echo "---"
echo ""

if [ "$DRY_RUN" == "true" ]; then
    echo "DRY RUN: No changes made."
    exit 0
fi

read -p "Apply this manifest? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled."
    exit 1
fi

# Apply the manifest
echo "Creating PVC..."
echo "$RESTORE_MANIFEST" | kubectl apply -f -

# Wait for PVC to be bound
echo ""
echo "Waiting for PVC to be bound (this may take a few minutes)..."
if kubectl wait --for=condition=Bound pvc/${RESTORE_PVC} -n ${NAMESPACE} --timeout=600s; then
    echo ""
    echo "=========================================="
    echo "SUCCESS: PVC restored!"
    echo "=========================================="
    echo ""
    echo "PVC Details:"
    kubectl get pvc -n "${NAMESPACE}" "${RESTORE_PVC}"
    echo ""
    echo "Volume Details:"
    kubectl get pvc -n "${NAMESPACE}" "${RESTORE_PVC}" -o jsonpath='{.spec.volumeName}' | xargs -I{} kubectl -n "${LONGHORN_NS}" get volume {}
else
    echo ""
    echo "ERROR: PVC did not become bound within timeout"
    echo "Check Longhorn UI and events for more details:"
    echo "  kubectl describe pvc -n ${NAMESPACE} ${RESTORE_PVC}"
    echo "  kubectl -n ${LONGHORN_NS} get volume"
    exit 1
fi

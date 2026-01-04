#!/bin/bash
# Remove a PVC from the backup schedule
# Usage: ./remove-pvc-from-backup.sh <namespace> <pvc-name> [--delete-backups]
# 
# Note: This only removes the PVC from future backups. Existing backups are preserved
# unless --delete-backups is specified.

set -euo pipefail

NAMESPACE=${1:?"Usage: $0 <namespace> <pvc-name> [--delete-backups]"}
PVC_NAME=${2:?"Usage: $0 <namespace> <pvc-name> [--delete-backups]"}
DELETE_BACKUPS=${3:-""}

# Default label key (matches chart values)
LABEL_KEY="backup.home.lab/enabled"

echo "Removing PVC ${NAMESPACE}/${PVC_NAME} from backup schedule..."

# Verify PVC exists
if ! kubectl get pvc -n "${NAMESPACE}" "${PVC_NAME}" > /dev/null 2>&1; then
    echo "WARNING: PVC ${NAMESPACE}/${PVC_NAME} not found. It may have already been deleted."
    echo "Checking for orphaned backups..."
fi

# Get the Longhorn volume name (if PVC exists)
VOLUME_NAME=""
if kubectl get pvc -n "${NAMESPACE}" "${PVC_NAME}" > /dev/null 2>&1; then
    VOLUME_NAME=$(kubectl get pvc -n "${NAMESPACE}" "${PVC_NAME}" -o jsonpath='{.spec.volumeName}')
    
    # Remove backup labels from PVC
    echo "Removing backup labels from PVC..."
    kubectl label pvc -n "${NAMESPACE}" "${PVC_NAME}" \
        "${LABEL_KEY}-" \
        "backup.home.lab/tier-" \
        2>/dev/null || true
    
    # Add removal annotation
    kubectl annotate pvc -n "${NAMESPACE}" "${PVC_NAME}" \
        "backup.home.lab/removed-from-backup-at=$(date -Iseconds)" \
        --overwrite 2>/dev/null || true
fi

# Get Longhorn namespace
LONGHORN_NS=${LONGHORN_NS:-"longhorn"}

# Remove recurring job from Longhorn volume if it exists
if [ -n "${VOLUME_NAME}" ] && [ "${VOLUME_NAME}" != "null" ]; then
    echo "Removing recurring jobs from Longhorn volume ${VOLUME_NAME}..."
    kubectl -n "${LONGHORN_NS}" patch volume "${VOLUME_NAME}" --type=merge \
        -p '{"spec":{"recurringJobSelector":[]}}' 2>/dev/null || {
        echo "NOTE: Could not patch Longhorn volume. It may not exist or have different permissions."
    }
fi

# Handle backup deletion if requested
if [ "${DELETE_BACKUPS}" == "--delete-backups" ]; then
    echo ""
    echo "WARNING: --delete-backups flag detected"
    echo "This will permanently delete all backups for this PVC!"
    echo ""
    read -p "Are you sure you want to delete all backups? (yes/no): " CONFIRM
    
    if [ "${CONFIRM}" != "yes" ]; then
        echo "Backup deletion cancelled."
        echo "PVC removed from backup schedule but backups preserved."
        exit 0
    fi
    
    if [ -n "${VOLUME_NAME}" ] && [ "${VOLUME_NAME}" != "null" ]; then
        echo "Deleting backups for volume ${VOLUME_NAME}..."
        
        # List backups
        BACKUPS=$(kubectl -n "${LONGHORN_NS}" get backup -l longhornvolume="${VOLUME_NAME}" -o name 2>/dev/null || echo "")
        
        if [ -z "${BACKUPS}" ]; then
            echo "No backups found for volume ${VOLUME_NAME}"
        else
            echo "Found backups to delete:"
            echo "${BACKUPS}"
            echo ""
            
            # Delete each backup
            for backup in ${BACKUPS}; do
                echo "Deleting ${backup}..."
                kubectl -n "${LONGHORN_NS}" delete "${backup}" --wait=false
            done
            
            echo ""
            echo "Backup deletion initiated. Backups will be removed in the background."
            echo "Note: This may take some time depending on backup size."
        fi
        
        # Also delete the backup volume (metadata)
        echo "Cleaning up backup volume metadata..."
        kubectl -n "${LONGHORN_NS}" delete backupvolume "${VOLUME_NAME}" 2>/dev/null || true
    else
        echo "No volume name found. Cannot delete backups without volume reference."
        echo "To manually clean up, check Longhorn UI or use:"
        echo "  kubectl -n ${LONGHORN_NS} get backupvolumes"
    fi
fi

echo ""
echo "SUCCESS: PVC ${NAMESPACE}/${PVC_NAME} removed from backup schedule"
if [ "${DELETE_BACKUPS}" != "--delete-backups" ]; then
    echo ""
    echo "Note: Existing backups have been preserved."
    echo "To delete existing backups, run:"
    echo "  $0 ${NAMESPACE} ${PVC_NAME} --delete-backups"
fi

#!/bin/bash
# Add a PVC to the backup schedule
# Usage: ./add-pvc-to-backup.sh <namespace> <pvc-name> [tier]
# tier: daily (default), weekly, or both

set -euo pipefail

NAMESPACE=${1:?"Usage: $0 <namespace> <pvc-name> [tier]"}
PVC_NAME=${2:?"Usage: $0 <namespace> <pvc-name> [tier]"}
TIER=${3:-"daily"}

# Default label key (matches chart values)
LABEL_KEY="backup.home.lab/enabled"

echo "Adding PVC ${NAMESPACE}/${PVC_NAME} to backup schedule (tier: ${TIER})..."

# Verify PVC exists
if ! kubectl get pvc -n "${NAMESPACE}" "${PVC_NAME}" > /dev/null 2>&1; then
    echo "ERROR: PVC ${NAMESPACE}/${PVC_NAME} not found"
    exit 1
fi

# Get current labels
CURRENT_LABELS=$(kubectl get pvc -n "${NAMESPACE}" "${PVC_NAME}" -o jsonpath='{.metadata.labels}')
echo "Current labels: ${CURRENT_LABELS}"

# Add backup labels
echo "Adding backup labels..."
kubectl label pvc -n "${NAMESPACE}" "${PVC_NAME}" \
    "${LABEL_KEY}=true" \
    "backup.home.lab/tier=${TIER}" \
    --overwrite

# Add annotations for tracking
kubectl annotate pvc -n "${NAMESPACE}" "${PVC_NAME}" \
    "backup.home.lab/added-at=$(date -Iseconds)" \
    "backup.home.lab/source-namespace=${NAMESPACE}" \
    "backup.home.lab/source-pvc=${PVC_NAME}" \
    --overwrite

# Get the Longhorn volume name
VOLUME_NAME=$(kubectl get pvc -n "${NAMESPACE}" "${PVC_NAME}" -o jsonpath='{.spec.volumeName}')

if [ -z "${VOLUME_NAME}" ] || [ "${VOLUME_NAME}" == "null" ]; then
    echo "WARNING: PVC is not yet bound to a volume. Backup labels added but no volume to configure yet."
    exit 0
fi

echo "Longhorn volume: ${VOLUME_NAME}"

# Get Longhorn namespace (default to 'longhorn')
LONGHORN_NS=${LONGHORN_NS:-"longhorn"}

# Add recurring job labels to the Longhorn volume
echo "Adding recurring job to Longhorn volume..."

RECURRING_JOBS='[]'
case "${TIER}" in
    daily)
        RECURRING_JOBS='[{"name":"daily-backup","isGroup":false}]'
        ;;
    weekly)
        RECURRING_JOBS='[{"name":"weekly-backup","isGroup":false}]'
        ;;
    both)
        RECURRING_JOBS='[{"name":"daily-backup","isGroup":false},{"name":"weekly-backup","isGroup":false}]'
        ;;
    *)
        echo "ERROR: Invalid tier '${TIER}'. Use: daily, weekly, or both"
        exit 1
        ;;
esac

# Patch the Longhorn volume with recurring job selector
kubectl -n "${LONGHORN_NS}" patch volume "${VOLUME_NAME}" --type=merge \
    -p "{\"spec\":{\"recurringJobSelector\":${RECURRING_JOBS}}}" 2>/dev/null || {
    echo "NOTE: Could not patch Longhorn volume directly. The volume will use StorageClass defaults."
    echo "To manually configure, edit the volume in Longhorn UI or update the StorageClass."
}

echo ""
echo "SUCCESS: PVC ${NAMESPACE}/${PVC_NAME} added to backup schedule"
echo ""
echo "Next steps:"
echo "1. Wait for the next scheduled backup (check cronjob schedule)"
echo "2. Or trigger an immediate backup:"
echo "   kubectl -n ${LONGHORN_NS} create job --from=cronjob/<release-name>-longhorn-backup-daily-backup manual-backup-\$(date +%s)"
echo ""
echo "To verify backup configuration:"
echo "   kubectl get pvc -n ${NAMESPACE} ${PVC_NAME} -o yaml | grep -A5 'labels:'"

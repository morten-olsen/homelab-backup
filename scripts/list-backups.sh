#!/bin/bash
# List all available backups
# Usage: ./list-backups.sh [namespace] [pvc-name]

set -euo pipefail

FILTER_NS=${1:-""}
FILTER_PVC=${2:-""}

LONGHORN_NS=${LONGHORN_NS:-"longhorn"}

echo "=========================================="
echo "Longhorn Backup Inventory"
echo "=========================================="
echo ""

if [ -n "$FILTER_NS" ] && [ -n "$FILTER_PVC" ]; then
    echo "Filter: ${FILTER_NS}/${FILTER_PVC}"
    echo ""
fi

# Get all PVCs with backup label
echo "Backed up PVCs:"
echo "---------------"
printf "%-20s %-30s %-40s %-10s\n" "NAMESPACE" "PVC" "VOLUME" "BACKUPS"

kubectl get pvc -A -l backup.home.lab/enabled=true -o json 2>/dev/null | \
    jq -r '.items[] | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.volumeName)"' | \
    while IFS=$'\t' read -r ns pvc vol; do
        # Filter if specified
        if [ -n "$FILTER_NS" ] && [ "$ns" != "$FILTER_NS" ]; then
            continue
        fi
        if [ -n "$FILTER_PVC" ] && [ "$pvc" != "$FILTER_PVC" ]; then
            continue
        fi
        
        # Count backups
        if [ -n "$vol" ] && [ "$vol" != "null" ]; then
            backup_count=$(kubectl -n "${LONGHORN_NS}" get backup -l longhornvolume="${vol}" --no-headers 2>/dev/null | wc -l || echo "0")
        else
            backup_count="N/A"
        fi
        
        printf "%-20s %-30s %-40s %-10s\n" "$ns" "$pvc" "${vol:-unbound}" "$backup_count"
    done

echo ""
echo "Backup Details:"
echo "---------------"

# Get all backup volumes
kubectl -n "${LONGHORN_NS}" get backupvolume -o json 2>/dev/null | \
    jq -r '.items[] | "\(.metadata.name)\t\(.status.lastBackupName // "none")\t\(.status.lastBackupAt // "never")"' | \
    while IFS=$'\t' read -r vol last_backup last_at; do
        # Get PVC info for this volume
        pvc_info=$(kubectl get pvc -A -o json 2>/dev/null | \
            jq -r --arg vol "$vol" '.items[] | select(.spec.volumeName == $vol) | "\(.metadata.namespace)/\(.metadata.name)"' | head -1)
        
        pvc_info=${pvc_info:-"(orphaned/deleted)"}
        
        # Filter if specified
        if [ -n "$FILTER_NS" ] || [ -n "$FILTER_PVC" ]; then
            if [[ "$pvc_info" != *"${FILTER_NS}"* ]] && [[ "$pvc_info" != *"${FILTER_PVC}"* ]]; then
                continue
            fi
        fi
        
        echo ""
        echo "Volume: ${vol}"
        echo "  PVC: ${pvc_info}"
        echo "  Last Backup: ${last_backup} (${last_at})"
        echo "  Backups:"
        
        kubectl -n "${LONGHORN_NS}" get backup -l longhornvolume="${vol}" \
            -o custom-columns="NAME:.metadata.name,CREATED:.status.backupCreatedAt,SIZE:.status.size,STATE:.status.state" \
            --sort-by=.status.backupCreatedAt 2>/dev/null | tail -n +2 | while read -r line; do
            echo "    ${line}"
        done
    done

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="

total_pvcs=$(kubectl get pvc -A -l backup.home.lab/enabled=true --no-headers 2>/dev/null | wc -l)
total_backups=$(kubectl -n "${LONGHORN_NS}" get backup --no-headers 2>/dev/null | wc -l)
total_size=$(kubectl -n "${LONGHORN_NS}" get backup -o json 2>/dev/null | jq '[.items[].status.size // 0] | add' | numfmt --to=iec 2>/dev/null || echo "unknown")

echo "Total PVCs with backup enabled: ${total_pvcs}"
echo "Total backup snapshots: ${total_backups}"
echo "Total backup size: ${total_size}"

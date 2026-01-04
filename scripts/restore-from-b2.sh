#!/bin/bash
# Restore backups from Backblaze B2 (encrypted offsite backup)
# Usage: ./restore-from-b2.sh <target-directory> [--list]
#
# This script is used for disaster recovery when the NFS backup target
# is unavailable or when bootstrapping a new cluster.

set -euo pipefail

show_help() {
    cat << EOF
Usage: $0 <target-directory> [options]

Restore encrypted backups from Backblaze B2.

Arguments:
  target-directory    Local directory to restore backups to

Options:
  --list              List available backups without downloading
  --config <file>     Path to rclone config file (default: prompt for credentials)
  -h, --help          Show this help message

Prerequisites:
  - rclone installed (https://rclone.org/install/)
  - B2 credentials (application key ID and key)
  - Encryption password and salt used during backup

Example:
  # List available backups
  $0 --list

  # Restore to local directory
  $0 /mnt/restore

  # Use existing rclone config
  $0 /mnt/restore --config ~/.config/rclone/rclone.conf
EOF
}

# Parse arguments
TARGET_DIR=""
LIST_ONLY=""
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --list)
            LIST_ONLY="true"
            shift
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            if [ -z "$TARGET_DIR" ]; then
                TARGET_DIR="$1"
            fi
            shift
            ;;
    esac
done

# Check for rclone
if ! command -v rclone &> /dev/null; then
    echo "ERROR: rclone is not installed"
    echo "Install it from: https://rclone.org/install/"
    exit 1
fi

# Setup rclone config
if [ -z "$CONFIG_FILE" ]; then
    echo "=========================================="
    echo "B2 Restore Configuration"
    echo "=========================================="
    echo ""
    echo "Enter your Backblaze B2 credentials:"
    echo "(These are the same credentials used for backup)"
    echo ""
    
    read -p "B2 Application Key ID: " B2_ACCOUNT_ID
    read -sp "B2 Application Key: " B2_APPLICATION_KEY
    echo ""
    read -p "B2 Bucket Name: " B2_BUCKET
    echo ""
    echo "Enter encryption credentials:"
    echo "(These must match the values used during backup)"
    echo ""
    read -sp "Encryption Password (rclone obscured): " RCLONE_PASSWORD
    echo ""
    read -sp "Encryption Salt (rclone obscured): " RCLONE_SALT
    echo ""
    
    # Create temporary config
    CONFIG_FILE=$(mktemp)
    trap "rm -f $CONFIG_FILE" EXIT
    
    cat > "$CONFIG_FILE" << EOF
[b2-raw]
type = b2
account = ${B2_ACCOUNT_ID}
key = ${B2_APPLICATION_KEY}

[b2-encrypted]
type = crypt
remote = b2-raw:${B2_BUCKET}/longhorn-backups
password = ${RCLONE_PASSWORD}
password2 = ${RCLONE_SALT}
filename_encryption = standard
directory_name_encryption = true
EOF

else
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Config file not found: $CONFIG_FILE"
        exit 1
    fi
fi

export RCLONE_CONFIG="$CONFIG_FILE"

# Test connection
echo ""
echo "Testing B2 connection..."
if ! rclone lsd b2-encrypted: > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to B2 or decrypt backups"
    echo "Please verify your credentials and encryption keys"
    exit 1
fi
echo "Connection successful!"
echo ""

# List backups
if [ "$LIST_ONLY" == "true" ] || [ -z "$TARGET_DIR" ]; then
    echo "=========================================="
    echo "Available Backups in B2"
    echo "=========================================="
    echo ""
    
    echo "Directory structure:"
    rclone tree b2-encrypted: --max-depth 3 2>/dev/null || rclone lsd b2-encrypted: -R --max-depth 3
    
    echo ""
    echo "Total size:"
    rclone size b2-encrypted:
    
    echo ""
    echo "To restore, run:"
    echo "  $0 /path/to/restore/directory"
    
    if [ -z "$TARGET_DIR" ]; then
        exit 0
    fi
fi

# Restore backups
if [ -z "$TARGET_DIR" ]; then
    echo "ERROR: Target directory not specified"
    show_help
    exit 1
fi

echo "=========================================="
echo "Restoring Backups from B2"
echo "=========================================="
echo ""
echo "Target directory: ${TARGET_DIR}"
echo ""

# Create target directory
mkdir -p "$TARGET_DIR"

echo "Starting download and decryption..."
echo "This may take a while depending on backup size."
echo ""

rclone sync b2-encrypted: "${TARGET_DIR}/" \
    --progress \
    --transfers 4 \
    --checkers 8

echo ""
echo "=========================================="
echo "Restore Complete"
echo "=========================================="
echo ""
echo "Backups restored to: ${TARGET_DIR}"
echo ""
echo "Contents:"
ls -la "${TARGET_DIR}"

echo ""
echo "Next steps:"
echo "1. Check the backup-index.json for PVC details"
echo "2. Configure Longhorn to use this directory as backup target"
echo "3. Restore PVCs using the restore-pvc.sh script"
echo ""
echo "Example Longhorn backup target configuration:"
echo "  nfs://<nfs-server>:<path-to-restored-backups>"

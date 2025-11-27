#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets file (assumes .env is in folders above dir holding this the script, adjust if needed)
. "$SCRIPT_DIR/../../.env"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_DIR="/data/perforce_backup/data/$TIMESTAMP"
LOG_DIR="/data/perforce_backup/logs"
LOGFILE="$LOG_DIR/backup_$TIMESTAMP.log"

source $SCRIPT_DIR/../logger/logger.sh

# --- Prune old backup logs, keeping only the last 100 ---
MAX_LOGS=100
mkdir -p "$LOG_DIR"
ls -1tr "$LOG_DIR"/backup_*.log | head -n -"$MAX_LOGS" | xargs -r rm -f

mkdir -p "$BACKUP_DIR"


{
    echo ""
    echo "$(date) - Starting Perforce backup..."

    # --- Check container is running ---
    if ! docker ps --format '{{.Names}}' | grep -q "^${P4D_DOCKER_INSTANCE}$"; then
        log_and_alert "FAILURE" "❌ Perforce Container $P4D_DOCKER_INSTANCE not running on $(hostname) at $(date)" "$LOGFILE" "CRITICAL"
        exit 1
    fi

    # --- Run checkpoint inside container ---
    if docker exec "$P4D_DOCKER_INSTANCE" p4d -r /data -jc; then
        log_and_alert "SUCCESS" "✅ Perforce Checkpoint created successfully on $(hostname) at $(date)" "$LOGFILE"
    else
        log_and_alert "FAILURE" "❌ Perforce Failed to create checkpoint on $(hostname) at $(date)" "$LOGFILE" "CRITICAL"
        exit 1
    fi

    META_DIR="$BACKUP_DIR/metadata"
    mkdir -p "$META_DIR"

    # Copy checkpoint files
    for file in $(docker exec "$P4D_DOCKER_INSTANCE" sh -c 'ls /data/checkpoint.* 2>/dev/null'); do
        docker cp "$P4D_DOCKER_INSTANCE:$file" "$META_DIR/"
    done

    # Copy journal files
    for file in $(docker exec "$P4D_DOCKER_INSTANCE" sh -c 'ls /data/journal.* 2>/dev/null'); do
        docker cp "$P4D_DOCKER_INSTANCE:$file" "$META_DIR/"
    done

    # Copy license and server.id if they exist
    for file in license server.id; do
        if docker exec "$P4D_DOCKER_INSTANCE" test -e "/data/$file"; then
            docker cp "$P4D_DOCKER_INSTANCE:/data/$file" "$META_DIR/"
        fi
    done

    echo "$(date) - Backup files copied to $BACKUP_DIR"

    # --- Verify checkpoint ---
    for file in "$META_DIR"/checkpoint.*; do
        [[ -f "$file" ]] || continue
        [[ "$file" == *.md5 ]] && continue # Skip .md5 files
        basename=$(basename "$file")
        if docker exec "$P4D_DOCKER_INSTANCE" p4d -r /data -jv "/data/$basename"; then
            log_and_alert "SUCCESS" "✅ Perforce Verified checkpoint $file on $(hostname) at $(date)" "$LOGFILE"
        else
            log_and_alert "FAILURE" "❌ Perforce Verification failed for checkpoint $file on $(hostname) at $(date)" "$LOGFILE" "CRITICAL"
            exit 1
        fi
    done

    # --- Verify Journals ---
    for file in "$META_DIR"/journal.*; do
        [[ -f "$file" ]] || continue
        basename=$(basename "$file")
        if docker exec "$P4D_DOCKER_INSTANCE" p4d -r /data -jv "/data/$basename"; then
            log_and_alert "SUCCESS" "✅ Perforce Verified journal $file on $(hostname) at $(date)" "$LOGFILE"
        else
            log_and_alert "FAILURE" "❌ Perforce Verification failed for journal $file on $(hostname) at $(date)" "$LOGFILE" "CRITICAL"
            exit 1
        fi
    done


    # --- Upload to S3 ---
    if [[ "${S3_ENABLED:-false}" == "true" && -n "${S3_BUCKET:-}" ]]; then
        if aws s3 cp "$BACKUP_DIR" "s3://$S3_BUCKET/perforce/$TIMESTAMP/" --recursive; then
            log_and_alert "SUCCESS" "✅ Perforce Backup uploaded to S3 bucket $S3_BUCKET" "$LOGFILE"
        else
            log_and_alert "FAILURE" "❌ Perforce Failed to upload to S3 bucket $S3_BUCKET" "$LOGFILE" "CRITICAL"
            exit 1
        fi
    else
        echo "$(date) - S3 upload skipped"
    fi

    # --- Metadata archive ---
    META_ARCHIVE="$BACKUP_DIR/perforce_metadata_$TIMESTAMP.tar.gz"
    tar -czf "$META_ARCHIVE" -C "$META_DIR" . || {
        log_and_alert "FAILURE" "❌ Perforce Failed to create metadata archive $META_ARCHIVE" "$LOGFILE" "CRITICAL"
        exit 1
    }

    # --- Sync to remote storage ---
    if [[ -n "${STORAGE_SERVER:-}" && -n "${REMOTE_META_DIR:-}" && -n "${SSH_KEY:-}" ]]; then
        if [[ ! -f "$SSH_KEY" ]]; then
            log_and_alert "FAILURE" "❌ SSH key $SSH_KEY not found, cannot sync metadata" "$LOGFILE" "CRITICAL"
            exit 1
        fi

        # Pre-create remote directory
        ssh -p "$SSH_PORT" -i "$SSH_KEY" "$STORAGE_SERVER" "mkdir -p $REMOTE_META_DIR"

        # Prune local backup directories, keeping only the last MAX_REMOTE_BACKUPS
        if [[ -n "${MAX_REMOTE_BACKUPS:-}" ]]; then
            echo "$(date) - Pruning local backup directories, keeping only the last $MAX_REMOTE_BACKUPS backups"
            ls -1tr /opt/p4data/p4d_backup/ | head -n -"$MAX_REMOTE_BACKUPS" | xargs -r -I{} rm -rf "/opt/p4data/p4d_backup/{}"
        fi

        # Rsync local backup directory to remote, mirroring contents
        rsync -aH --progress --delete -e "ssh -p${SSH_PORT} -i ${SSH_KEY}" "/opt/p4data/p4d_backup/" "$STORAGE_SERVER:$REMOTE_META_DIR/"

        log_and_alert "SUCCESS" "✅ Perforce Metadata backup synced to $STORAGE_SERVER:$REMOTE_META_DIR/ with automatic pruning" "$LOGFILE"
    else
        echo "$(date) - Metadata sync skipped (STORAGE_SERVER/REMOTE_META_DIR/SSH_KEY not set)"
    fi

    # --- Optional depot sync ---
    if [[ "${DEPOT_SYNC_ENABLED:-false}" == "true" ]]; then
        if [[ -n "${DEPOTS_DIR:-}" && -n "${STORAGE_SERVER:-}" && -n "${DEPOTS_REMOTE_DIR:-}" && -n "${SSH_KEY:-}" ]]; then
            if [[ ! -f "$SSH_KEY" ]]; then
                log_and_alert "FAILURE" "❌ SSH key $SSH_KEY not found, cannot sync depots" "$LOGFILE" "CRITICAL"
                exit 1
            fi

            # Pre-create remote depot directory
            ssh -p "$SSH_PORT" -i "$SSH_KEY" "$STORAGE_SERVER" "mkdir -p $DEPOTS_REMOTE_DIR"

            if rsync -aH --delete --progress -e "ssh -p${SSH_PORT} -i ${SSH_KEY}" "$DEPOTS_DIR/" "$STORAGE_SERVER:$DEPOTS_REMOTE_DIR/"; then
                log_and_alert "SUCCESS" "✅ Perforce Depots rsynced to $STORAGE_SERVER:$DEPOTS_REMOTE_DIR" "$LOGFILE"
            else
                log_and_alert "FAILURE" "❌ Perforce Depot rsync to $STORAGE_SERVER FAILED" "$LOGFILE" "CRITICAL"
                exit 1
            fi
        else
            echo "$(date) - Depot sync skipped (missing DEPOTS_DIR, STORAGE_SERVER, DEPOTS_REMOTE_DIR, or SSH_KEY)"
        fi
    else
        echo "$(date) - Depot sync skipped (DEPOT_SYNC_ENABLED not true)"
    fi

    # --- Rotate old checkpoints and journals, keep current journal ---
    {
        CURRENT_JOURNAL=$(docker exec "$P4D_DOCKER_INSTANCE" p4d -r /data -rstat | awk '/Journal/ {print $3}')

        echo "$(date) - Cleaning up old checkpoints and journals, keeping current journal: $CURRENT_JOURNAL"

        docker exec "$P4D_DOCKER_INSTANCE" sh -c '
            cd /data
            for file in checkpoint.* journal.*; do
                if [ "$file" != "'"$CURRENT_JOURNAL"'" ]; then
                    rm -f "$file"
                fi
            done
        '
    } >> "$LOGFILE" 2>&1

    SUCCESS_MSG="✅ Perforce backup SUCCESSFUL on $(hostname) at $(date)"
    echo "$SUCCESS_MSG"
    post_to_slack "$SUCCESS_MSG"
    post_to_newrelic "SUCCESS" "NORMAL"

} >> "$LOGFILE" 2>&1 || {
    ERROR_MSG="❌ Perforce backup FAILED on $(hostname) at $(date)"
    echo "$ERROR_MSG" >> "$LOGFILE"
    post_to_slack "$ERROR_MSG"
    post_to_newrelic "FAILURE" "CRITICAL"
    exit 1
}

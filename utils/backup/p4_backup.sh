#!/bin/bash
set -euo pipefail

# Load secrets file
. ../../.env

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_DIR="/opt/p4data/p4d_backup/$TIMESTAMP"
LOG_DIR="/opt/p4data/p4d_backup_logs"
LOGFILE="$LOG_DIR/backup_$TIMESTAMP.log"

# --- Prune old backup logs, keeping only the last 100 ---
MAX_LOGS=100
mkdir -p "$LOG_DIR"
ls -1tr "$LOG_DIR"/backup_*.log | head -n -"$MAX_LOGS" | xargs -r rm -f

mkdir -p "$BACKUP_DIR"

# --- Logging helpers ---
post_to_slack() {
    local msg="$1"
    if [[ "${SLACK_ENABLED:-false}" == "true" && -n "${SLACK_WEBHOOK:-}" ]]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"$msg\"}" \
            "$SLACK_WEBHOOK" >/dev/null || true
    fi
}

post_to_newrelic() {
    local status="$1"
    local priority="$2"
    if [[ "${NEWRELIC_ENABLED:-false}" == "true" && -n "${NEWRELIC_API_KEY:-}" && -n "${NEWRELIC_ACCOUNT_ID:-}" ]]; then
        payload=$(mktemp)
        cat > "$payload" <<EOF
[
  {
    "eventType": "PerforceBackup",
    "status": "$status",
    "host": "$(hostname)",
    "priority": "$priority"
  }
]
EOF
        gzip -c "$payload" | \
        curl -s -X POST \
             -H "Content-Type: application/json" \
             -H "Api-Key: $NEWRELIC_API_KEY" \
             -H "Content-Encoding: gzip" \
             $NEWRELIC_REGION_SERVER/v1/accounts/$NEWRELIC_ACCOUNT_ID/events \
             --data-binary @-
        rm -f "$payload"
    fi
}

log_and_alert() {
    local status="$1"
    local msg="$2"
    local priority="${3:-NORMAL}"
    echo "" >> "$LOGFILE"                 # ensure new log starts on a new line
    echo "$(date) - $msg" >> "$LOGFILE"
    post_to_slack "$msg"
    post_to_newrelic "$status" "$priority"
}

{
    echo ""
    echo "$(date) - Starting Perforce backup..."

    # --- Check container is running ---
    if ! docker ps --format '{{.Names}}' | grep -q "^${P4D_DOCKER_INSTANCE}$"; then
        log_and_alert "FAILURE" "❌ Container $P4D_DOCKER_INSTANCE not running on $(hostname) at $(date)" "CRITICAL"
        exit 1
    fi

    # --- Run checkpoint inside container ---
    if docker exec "$P4D_DOCKER_INSTANCE" p4d -r /data -jc; then
        log_and_alert "SUCCESS" "✅ Checkpoint created successfully on $(hostname) at $(date)"
    else
        log_and_alert "FAILURE" "❌ Failed to create checkpoint on $(hostname) at $(date)" "CRITICAL"
        exit 1
    fi

    META_DIR="$BACKUP_DIR/metadata"
    mkdir -p "$META_DIR"

    # --- Copy checkpoint, journals, license, server.id into META_DIR ---
    for item in checkpoint.* journal.* license server.id; do
        if docker exec "$P4D_DOCKER_INSTANCE" test -e "/data/$item"; then
            docker cp "$P4D_DOCKER_INSTANCE:/data/$item" "$META_DIR/"
        fi
    done

    echo "$(date) - Backup files copied to $BACKUP_DIR"

    # --- Verify checkpoint(s) ---
    for file in "$BACKUP_DIR"/checkpoint.* "$BACKUP_DIR"/journal.*; do
        [[ -f "$file" ]] || continue
        if docker exec -i "$P4D_DOCKER_INSTANCE" p4d -r /data -jv < "$file"; then
            log_and_alert "SUCCESS" "✅ Verified $file on $(hostname) at $(date)"
        else
            log_and_alert "FAILURE" "❌ Verification failed for $file on $(hostname) at $(date)" "CRITICAL"
            exit 1
        fi
    done

    # --- Upload to S3 ---
    if [[ "${S3_ENABLED:-false}" == "true" && -n "${S3_BUCKET:-}" ]]; then
        if aws s3 cp "$BACKUP_DIR" "s3://$S3_BUCKET/perforce/$TIMESTAMP/" --recursive; then
            log_and_alert "SUCCESS" "✅ Backup uploaded to S3 bucket $S3_BUCKET"
        else
            log_and_alert "FAILURE" "❌ Failed to upload to S3 bucket $S3_BUCKET" "CRITICAL"
            exit 1
        fi
    else
        echo "$(date) - S3 upload skipped"
    fi

    # --- Metadata archive ---
    META_ARCHIVE="$BACKUP_DIR/perforce_metadata_$TIMESTAMP.tar.gz"
    tar -czf "$META_ARCHIVE" -C "$META_DIR" . || {
        log_and_alert "FAILURE" "❌ Failed to create metadata archive $META_ARCHIVE" "CRITICAL"
        exit 1
    }

    # --- Sync to remote storage ---
    if [[ -n "${STORAGE_SERVER:-}" && -n "${REMOTE_META_DIR:-}" && -n "${SSH_KEY:-}" ]]; then
        if [[ ! -f "$SSH_KEY" ]]; then
            log_and_alert "FAILURE" "❌ SSH key $SSH_KEY not found, cannot sync metadata" "CRITICAL"
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

        log_and_alert "SUCCESS" "✅ Metadata backup synced to $STORAGE_SERVER:$REMOTE_META_DIR/ with automatic pruning"
    else
        echo "$(date) - Metadata sync skipped (STORAGE_SERVER/REMOTE_META_DIR/SSH_KEY not set)"
    fi

    # --- Optional depot sync ---
    if [[ "${DEPOT_SYNC_ENABLED:-false}" == "true" ]]; then
        if [[ -n "${DEPOTS_DIR:-}" && -n "${STORAGE_SERVER:-}" && -n "${DEPOTS_REMOTE_DIR:-}" && -n "${SSH_KEY:-}" ]]; then
            if [[ ! -f "$SSH_KEY" ]]; then
                log_and_alert "FAILURE" "❌ SSH key $SSH_KEY not found, cannot sync depots" "CRITICAL"
                exit 1
            fi

            # Pre-create remote depot directory
            ssh -p "$SSH_PORT" -i "$SSH_KEY" "$STORAGE_SERVER" "mkdir -p $DEPOTS_REMOTE_DIR"

            if rsync -aH --delete --progress -e "ssh -p${SSH_PORT} -i ${SSH_KEY}" "$DEPOTS_DIR/" "$STORAGE_SERVER:$DEPOTS_REMOTE_DIR/"; then
                log_and_alert "SUCCESS" "✅ Depots rsynced to $STORAGE_SERVER:$DEPOTS_REMOTE_DIR"
            else
                log_and_alert "FAILURE" "❌ Depot rsync to $STORAGE_SERVER FAILED" "CRITICAL"
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

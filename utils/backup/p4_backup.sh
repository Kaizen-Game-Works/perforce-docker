#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets file (assumes .env is in folders above dir holding this the script, adjust if needed)
. "$SCRIPT_DIR/../../.env"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_BASE_DIR="$P4_BACKUP_DIR_DATA"
BACKUP_DIR="$BACKUP_BASE_DIR/$TIMESTAMP"
LOG_DIR="$P4_BACKUP_DIR_LOGS"
LOGFILE="$LOG_DIR/backup_$TIMESTAMP.log"
P4ROOT="/data/master"

RSYNC_SSH_KEY=$RSYNC_SSH_KEY_DIR/$RSYNC_SSH_KEY_FILE

source $SCRIPT_DIR/../logger/logger.sh

# --- Prune old backup logs, keeping only the last 100 ---
MAX_LOGS=100
mkdir -p "$LOG_DIR"

# Make globs expand to empty array if no match
shopt -s nullglob

# Collect all backup log files
LOG_FILES=("$LOG_DIR"/backup_*.log)

# Only prune if there are more than MAX_LOGS
if (( ${#LOG_FILES[@]} > MAX_LOGS )); then
    # Sort by modification time and remove oldest files
    ls -1tr "${LOG_FILES[@]}" | head -n -"$MAX_LOGS" | xargs -r rm -f
fi

#make the backup dir if it doesn't exist
mkdir -p "$BACKUP_DIR"


{
    echo ""
    echo "$(date) - Starting Perforce backup..."

    log_and_alert "SUCCESS" "▶▶▶BACKUP▶▶▶\n🕒 $(date)\n✔ Starting Perforce Backup on $(hostname)" "$LOGFILE"

    # --- Check container is running ---
    if ! docker ps --format '{{.Names}}' | grep -q "^${P4D_DOCKER_INSTANCE}$"; then
        log_and_alert "FAILURE" "🕒 $(date)\n❌ Perforce Container $P4D_DOCKER_INSTANCE not running" "$LOGFILE" "CRITICAL"
        exit 1
    else
        log_and_alert "SUCCESS" "🕒 $(date)\n✔ Perforce Container $P4D_DOCKER_INSTANCE is running" "$LOGFILE"
    fi

    # Check P4ROOT (as specified above) exists
    if ! docker exec "$P4D_DOCKER_INSTANCE" test -d "$P4ROOT"; then
        log_and_alert "FAILURE" "🕒 $(date)\n❌ P4ROOT directory '$P4ROOT' does not exist inside container." "$LOGFILE" "CRITICAL"
        exit 1
    fi
    
    # Check db.* files exist. This is to primarily ensure we're in the right location
    DB_COUNT=$(docker exec "$P4D_DOCKER_INSTANCE" sh -c "ls $P4ROOT/db.* 2>/dev/null | wc -l")
    if [ "$DB_COUNT" -eq 0 ]; then
        log_and_alert "FAILURE" "🕒 $(date)\n❌ No db.* files found in $P4ROOT — NOT a valid Perforce server root!" "$LOGFILE" "CRITICAL"
        exit 1
    fi
    
    log_and_alert "SUCCESS" "🕒 $(date)\n✔ Valid P4ROOT detected at $P4ROOT with $DB_COUNT database tables." "$LOGFILE"

    # prepare gosu user if set
    GOSU_MODIFIER=""
    if [ -n "$P4_BACKUP_USER" ]; then
        if docker exec "$P4D_DOCKER_INSTANCE" id "$P4_BACKUP_USER" >/dev/null 2>&1; then
            GOSU_MODIFIER="gosu $P4_BACKUP_USER"
        else
            log_and_alert "FAILURE" "🕒 $(date)\n❌ Attempting to use gosu $P4_BACKUP_USER, but user does not exist" "$LOGFILE" "CRITICAL"
        fi
    fi

    # --- Run checkpoint inside container ---
    if docker exec "$P4D_DOCKER_INSTANCE" $GOSU_MODIFIER p4d -r "$P4ROOT" -jc; then
        log_and_alert "SUCCESS" "🕒 $(date)\n✔ Perforce Checkpoint created successfully" "$LOGFILE"
    else
        log_and_alert "FAILURE" "🕒 $(date)\n❌ Perforce Failed to create checkpoint" "$LOGFILE" "CRITICAL"
        exit 1
    fi

    META_DIR="$BACKUP_DIR/metadata"
    mkdir -p "$META_DIR"

    # Copy checkpoint files
    for file in $(docker exec "$P4D_DOCKER_INSTANCE" sh -c "ls $P4ROOT/checkpoint.* 2>/dev/null"); do
        docker cp "$P4D_DOCKER_INSTANCE:$file" "$META_DIR/"
    done

    # Copy journal files
    for file in $(docker exec "$P4D_DOCKER_INSTANCE" sh -c "ls $P4ROOT/journal.* 2>/dev/null"); do
        docker cp "$P4D_DOCKER_INSTANCE:$file" "$META_DIR/"
    done

    # Copy license and server.id if they exist
    for file in license server.id; do
        if docker exec "$P4D_DOCKER_INSTANCE" test -e "$P4ROOT/$file"; then
            docker cp "$P4D_DOCKER_INSTANCE:$P4ROOT/$file" "$META_DIR/"
        fi
    done

    echo "$(date) - Backup files copied to $BACKUP_DIR"

    # --- Verify checkpoint ---
    for file in "$META_DIR"/checkpoint.*; do
        [[ -f "$file" ]] || continue
        [[ "$file" == *.md5 ]] && continue  # skip hash files
    
        basename=$(basename "$file")
        md5file="$file.md5"
    
        # --- MD5 CHECK ---
        if [[ -f "$md5file" ]]; then
            echo "$(date) - Verifying MD5 for $file"
            
            # Extract expected MD5 from BSD-style file:
            # Format: MD5 (checkpoint.93) = ABC123...
            expected=$(awk -F'= ' '{print $2}' "$md5file" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')

            # Compute actual MD5 (Linux md5sum produces lowercase)
            actual=$(md5sum "$file" | awk '{print $1}' | tr '[:lower:]' '[:upper:]')
    
            if [[ "$expected" != "$actual" ]]; then
                log_and_alert "FAILURE" "🕒 $(date)\n❌ MD5 mismatch for checkpoint $file (expected $expected, got $actual)" "$LOGFILE" "CRITICAL"
                exit 1
            else
                log_and_alert "SUCCESS" "🕒 $(date)\n✔ MD5 verified for checkpoint $file" "$LOGFILE"
            fi
        else
            log_and_alert "FAILURE" "🕒 $(date)\n❌ Missing MD5 file: $md5file" "$LOGFILE" "CRITICAL"
            exit 1
        fi
    
        # --- Perform the actual P4 verification - This can be expensive. Maybe need to do this less frequently... ---
        if docker exec "$P4D_DOCKER_INSTANCE" $GOSU_MODIFIER p4d -r "$P4ROOT" -jv "$P4ROOT/$basename"; then
            CHECKPOINT_FILE_SIZE_MB=$(stat -c%s "$file")  # size in bytes
            CHECKPOINT_FILE_SIZE_MB=$((CHECKPOINT_FILE_SIZE_MB / 1048576))  # convert to MB
            log_and_alert "SUCCESS" "🕒 $(date)\n✔ Perforce Verified checkpoint $file ($CHECKPOINT_FILE_SIZE_MB MB)" "$LOGFILE"
        else
            log_and_alert "FAILURE" "🕒 $(date)\n❌ Perforce Verification failed for checkpoint $file" "$LOGFILE" "CRITICAL"
            exit 1
        fi
    done

    # --- Verify Journals ---
    for file in "$META_DIR"/journal.*; do
        [[ -f "$file" ]] || continue
        basename=$(basename "$file")
        # The first backups you do might contain journal.0, and this will always fail as it's the live file so lets skip it
        [[ "$basename" == journal.0 ]] && continue
        if docker exec "$P4D_DOCKER_INSTANCE" $GOSU_MODIFIER p4d -r "$P4ROOT" -jv "$P4ROOT/$basename"; then
            JOURNAL_FILE_SIZE_MB=$(stat -c%s "$file")  # size in bytes
            JOURNAL_FILE_SIZE_MB=$((JOURNAL_FILE_SIZE_MB / 1048576))  # convert to MB
            log_and_alert "SUCCESS" "🕒 $(date)\n✔ Perforce Verified journal $file ($JOURNAL_FILE_SIZE_MB MB)" "$LOGFILE"
        else
            log_and_alert "FAILURE" "🕒 $(date)\n❌ Perforce Verification failed for journal $file" "$LOGFILE" "CRITICAL"
            exit 1
        fi
    done


    # --- Upload to S3 ---
    if [[ "${S3_ENABLED:-false}" == "true" && -n "${S3_BUCKET:-}" ]]; then
        if aws s3 cp "$BACKUP_DIR" "s3://$S3_BUCKET/perforce/$TIMESTAMP/" --recursive; then
            log_and_alert "SUCCESS" "🕒 $(date)\n✔ Perforce Backup uploaded to S3 bucket $S3_BUCKET" "$LOGFILE"
        else
            log_and_alert "FAILURE" "🕒 $(date)\n❌ Perforce Failed to upload to S3 bucket $S3_BUCKET" "$LOGFILE" "CRITICAL"
            exit 1
        fi
    else
        echo "$(date) - S3 upload skipped"
    fi

    # --- Metadata archive ---
    META_ARCHIVE="$BACKUP_DIR/perforce_metadata_$TIMESTAMP.tar.gz"
    tar -czf "$META_ARCHIVE" -C "$META_DIR" . || {
        log_and_alert "FAILURE" "🕒 $(date)\n✔ Perforce Failed to create metadata archive $META_ARCHIVE" "$LOGFILE" "CRITICAL"
        exit 1
    }

    # --- Sync to remote storage ---
    if [[ -n "${STORAGE_SERVER:-}" && -n "${REMOTE_META_DIR:-}" ]]; then
        if [[ ! -f "$RSYNC_SSH_KEY" ]]; then
            log_and_alert "FAILURE" "🕒 $(date)\n❌ SSH key $RSYNC_SSH_KEY not found, cannot sync metadata" "$LOGFILE" "CRITICAL"
            exit 1
        fi

        # Prune local backup directories, keeping only the last MAX_REMOTE_BACKUPS
        if [[ -n "${MAX_REMOTE_BACKUPS:-}" ]]; then
            echo "$(date) - Pruning local backup directories, keeping only the last $MAX_REMOTE_BACKUPS backups"
            ls -1tr $BACKUP_BASE_DIR/ | head -n -"$MAX_REMOTE_BACKUPS" | xargs -r -I{} rm -rf "$BACKUP_BASE_DIR/{}"
        fi

        # Make the remote directory, just in case it does not exist
        ssh -p${RSYNC_SSH_PORT} -i "${RSYNC_SSH_KEY}" "$STORAGE_SERVER" "mkdir -p '$REMOTE_META_DIR'"
        #docker exec $P4D_DOCKER_INSTANCE $GOSU_MODIFIER ssh -p${RSYNC_SSH_PORT} -i "${RSYNC_SSH_KEY}" "$STORAGE_SERVER" "mkdir -p '$REMOTE_META_DIR'"
        
        # Rsync local backup directory to remote, mirroring contents
        rsync -aH --progress --delete -e "ssh -p${RSYNC_SSH_PORT} -i ${RSYNC_SSH_KEY}" "$BACKUP_BASE_DIR/" "$STORAGE_SERVER:$REMOTE_META_DIR/"
        #docker exec $P4D_DOCKER_INSTANCE $GOSU_MODIFIER rsync -a --progress --delete --update -e "ssh -p${RSYNC_SSH_PORT} -i ${RSYNC_SSH_KEY}" "$BACKUP_BASE_DIR/" "$STORAGE_SERVER:$REMOTE_META_DIR/"


        log_and_alert "SUCCESS" "🕒 $(date)\n✔ Perforce Metadata backup synced to $STORAGE_SERVER:$REMOTE_META_DIR/ with automatic pruning" "$LOGFILE"
    else
        echo "$(date) - Metadata sync skipped (STORAGE_SERVER/REMOTE_META_DIR/RSYNC_SSH_KEY not set)"
    fi

    # --- Optional depot sync ---
    if [[ "${DEPOT_SYNC_ENABLED:-false}" == "true" ]]; then
        if [[ -n "${DEPOTS_DIR:-}" && -n "${STORAGE_SERVER:-}" && -n "${DEPOTS_REMOTE_DIR:-}" && -n "${RSYNC_SSH_KEY:-}" ]]; then
            if [[ ! -f "$RSYNC_SSH_KEY" ]]; then
                log_and_alert "FAILURE" "🕒 $(date)\n❌ SSH key $RSYNC_SSH_KEY not found, cannot sync depots" "$LOGFILE" "CRITICAL"
                exit 1
            fi

            # Pre-create remote depot directory
            ssh -p${RSYNC_SSH_PORT} -i "${RSYNC_SSH_KEY}" "$STORAGE_SERVER" "mkdir -p '$DEPOTS_REMOTE_DIR'"
            # docker exec $P4D_DOCKER_INSTANCE ssh -p${RSYNC_SSH_PORT} -i "${RSYNC_SSH_KEY}" "$STORAGE_SERVER" "mkdir -p '$DEPOTS_REMOTE_DIR'"

            #if rsync -a --delete --progress --update -e "ssh -p${RSYNC_SSH_PORT} -i ${RSYNC_SSH_KEY}" "$DEPOTS_DIR/" "$STORAGE_SERVER:$DEPOTS_REMOTE_DIR/"; then
            
            # we need to run this rsync in the container to ensure that all the files can be seen
            # run this as root (no gosu user) to make sure it can access both the data, and the ssh key
            # Note that .db files in the root are excluded. We don't need them
            if docker exec $P4D_DOCKER_INSTANCE sh -c "rsync -aH --delete --ignore-existing --exclude='/db.*' --exclude='/rdb.*' -e 'ssh -p${RSYNC_SSH_PORT} -i /secrets/${RSYNC_SSH_KEY_FILE} -o StrictHostKeyChecking=no' '${P4ROOT}/' '${STORAGE_SERVER}:${DEPOTS_REMOTE_DIR}/'"; then
                log_and_alert "SUCCESS" "🕒 $(date)\n✔ Perforce Depots rsynced to $STORAGE_SERVER:$DEPOTS_REMOTE_DIR" "$LOGFILE"
            else
                log_and_alert "FAILURE" "🕒 $(date)\n❌ Perforce Depot rsync to $STORAGE_SERVER FAILED" "$LOGFILE" "CRITICAL"
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
        CURRENT_JOURNAL=$(docker exec "$P4D_DOCKER_INSTANCE" p4d -r $P4ROOT -rstat | awk '/Journal/ {print $3}')

        echo "$(date) - Cleaning up old checkpoints and journals, keeping current journal: $CURRENT_JOURNAL"

        docker exec "$P4D_DOCKER_INSTANCE" sh -c '
            cd '"$P4ROOT"'
            for file in checkpoint.* journal.*; do
                if [ "$file" != "'"$CURRENT_JOURNAL"'" ]; then
                    rm -f "$file"
                fi
            done
        '
    } >> "$LOGFILE" 2>&1

    SUCCESS_MSG="✅✅✅\n🕒 $(date)\n Perforce backup SUCCESSFUL on $(hostname)\n✅✅✅"
    echo "$SUCCESS_MSG"
    post_to_slack "$SUCCESS_MSG" "$LOGFILE"
    post_to_newrelic "SUCCESS" "NORMAL"

} >> "$LOGFILE" 2>&1 || {
    ERROR_MSG="❌❌❌\n🕒 $(date)\n Perforce backup FAILED on $(hostname)\n❌❌❌"
    echo "$ERROR_MSG" >> "$LOGFILE"
    post_to_slack "$ERROR_MSG" "$LOGFILE"
    post_to_newrelic "FAILURE" "CRITICAL"
    exit 1
}

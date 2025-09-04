#Remember to use chmod +x p4_backup.sh to ensure this is executable

#!/bin/bash
set -euo pipefail

# Load secrets file
. ../../.env

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_DIR="/opt/p4data/p4d_backup/$TIMESTAMP"
LOGFILE="/opt/p4data/p4d_backup_logs/backup.log"

mkdir -p "$BACKUP_DIR"

post_to_slack() {
    local msg="$1"
    if [[ "${SLACK_ENABLED:-false}" == "true" && -n "${SLACK_WEBHOOK:-}" ]]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"$msg\"}" \
            "$SLACK_WEBHOOK" >/dev/null || true
    fi
}

post_to_newrelic() {
    local status="$1"   # SUCCESS or FAILURE
    local priority="$2" # NORMAL or CRITICAL

    if [[ "${NEWRELIC_ENABLED:-false}" == "true" && -n "${NEWRELIC_API_KEY:-}" && -n "${NEWRELIC_ACCOUNT_ID:-}" ]]; then
        # Create JSON payload in a temporary file
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

        # Send gzip-compressed payload
        # Note that this is pointing to an EU data center
        # you might need to use a different url
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

{
    echo "$(date) - Starting Perforce backup..."

    # Check if the container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${P4D_DOCKER_INSTANCE}$"; then
        ERROR_MSG="❌ Docker container $P4D_DOCKER_INSTANCE does not exist or is not running on $(hostname) at $(date)"
        echo "$ERROR_MSG" >> "$LOGFILE"
        post_to_slack "$ERROR_MSG"
        post_to_newrelic "FAILURE" "CRITICAL"
        exit 1
    fi

    # Run checkpoint inside the Perforce container
    docker exec $P4D_DOCKER_INSTANCE p4d -r /data -jc

    # Verify integrity of the 

    # Copy checkpoint and journal
    docker cp perforce-server:/data/checkpoint.* "$BACKUP_DIR/"
    docker cp perforce-server:/data/journal.* "$BACKUP_DIR/"

    echo "$(date) - Backup files copied to $BACKUP_DIR"

    # Verify the checkpoint and journal using p4d -jv
    for file in "$BACKUP_DIR"/checkpoint.* "$BACKUP_DIR"/journal.*; do
        if [[ -f "$file" ]]; then
            echo "$(date) - Verifying $file ..."
            docker exec -i perforce-server p4d -r /data -jv < "$file" || {
                ERROR_MSG="❌ Perforce backup verification FAILED for $file on $(hostname) at $(date)"
                echo "$ERROR_MSG" >> "$LOGFILE"
                post_to_slack "$ERROR_MSG"
                post_to_newrelic "FAILURE" "CRITICAL"
                exit 1
            }
        fi
    done

    echo "$(date) - Backup verification PASSED"

    # Upload to S3 only if enabled and verification passed
    if [[ "${S3_ENABLED:-false}" == "true" && -n "${S3_BUCKET:-}" ]]; then
        aws s3 cp "$BACKUP_DIR" "s3://$S3_BUCKET/perforce/$TIMESTAMP/" --recursive
        echo "$(date) - Backup uploaded to S3 bucket $S3_BUCKET"
    else
        echo "$(date) - S3 upload skipped (S3_ENABLED not true)"
    fi

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
